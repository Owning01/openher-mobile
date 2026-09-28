import 'package:flutter/material.dart';

import 'data/connectivity/network_monitor.dart';
import 'ui/core/low_data_banner.dart';
import 'ui/core/update_banner.dart';
import 'core/network/api_client.dart';
import 'domain/models/session.dart';
import 'core/update/update_service.dart';
import 'core/network/server_config.dart';
import 'data/repositories/session_repository.dart';
import 'core/storage/creds_store.dart';
import 'core/storage/prefs_store.dart';
import 'ui/core/app_icon.dart';
import 'ui/core/layer_gate.dart';
import 'ui/core/theme.dart';
import 'ui/core/theme_variants.dart';
import 'ui/core/tokens.dart';
import 'ui/features/chat/chat_view.dart';
import 'ui/features/chat/chat_viewmodel.dart';
import 'ui/features/connect/connect_view.dart';
import 'ui/features/files/files_view.dart';
import 'ui/features/navigation/mobile_bottom_nav.dart';
import 'ui/features/navigation/mobile_nav.dart';
import 'ui/features/sessions/sessions_view.dart';
import 'ui/features/sessions/sessions_viewmodel.dart';
import 'ui/features/settings/settings_view.dart';

/// Raíz de la app.
///
/// Arranque: lee preferencias + credenciales, carga el catálogo de capas
/// aprobado, y decide entre **Conectar** (no hay credenciales) y el shell de
/// 4 pestañas. Todo con un `FutureBuilder`: el primer frame no espera al disco
/// más de lo necesario (DoD: lista de sesiones < 400 ms en local).
class OpenHerMobileApp extends StatefulWidget {
  const OpenHerMobileApp({super.key, required this.prefs, required this.creds});

  final PrefsStore prefs;
  final CredsStore creds;

  @override
  State<OpenHerMobileApp> createState() => _OpenHerMobileAppState();
}

class _OpenHerMobileAppState extends State<OpenHerMobileApp> {
  late Future<ServerConfig?> _config = _readConfig();

  /// Id crudo de la variante elegida en Ajustes; vacío = el chrome de siempre
  /// (`light()` / `dark()`).
  ///
  /// Vive como estado y no se relee de las prefs en cada build porque
  /// `MaterialApp` **no** escucha a `PrefsStore` (no es un `ChangeNotifier`):
  /// si sólo se leyera en `build`, cambiar el tema no repintaría nada hasta
  /// que otro cambio de estado moviera el árbol entero. Por eso el setState
  /// explícito de [_onThemeVariant].
  String _variantId = '';

  @override
  void initState() {
    super.initState();
    _variantId = widget.prefs.themeVariantId;
  }

  /// Ajustes -> "Tema de color". Repinta en vivo: la preferencia ya está
  /// persistida por el `PrefsStore`, acá sólo se avisa al árbol.
  void _onThemeVariant(String id) {
    if (!mounted || id == _variantId) return;
    setState(() => _variantId = id);
  }

  Future<ServerConfig?> _readConfig() async {
    // El catálogo se carga una vez: la UI consulta el singleton.
    await LayerCatalog.load(
      overrides: widget.prefs.layerSwitches,
      persist: widget.prefs.setLayers,
    );
    return widget.creds.read();
  }

  /// El probe de conexión: `GET /api/location` con timeout corto (§1.6). Si
  /// devuelve HTML, 404 o 401, `probeServer` lanza el error tipado y la
  /// pantalla de Conectar lo muestra sin navegar.
  Future<void> _probe(ServerConfig config) async {
    await ApiClient(config: config).probeServer();
  }

  /// La variante de color para un brillo, o `null` si no hay ninguna.
  ///
  /// La resolución va por el catálogo y no por un `switch` sobre el id: un id
  /// desconocido (variante borrada, typo, prefs de una versión vieja) tiene que
  /// caerse al chrome por defecto, no romper la app.
  ThemeData? _variant(ThemeVariantKind kind) {
    final v = ThemeVariants.byId(_variantId);
    if (v == null || v.kind != kind) return null;
    return AppTheme.variantOf(v);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ServerConfig?>(
      future: _config,
      builder: (context, snap) {
        final prefs = widget.prefs;
        return MaterialApp(
          title: 'OpenHer Mobile',
          debugShowCheckedModeBanner: false,
          // La variante manda sobre el chrome por defecto; sin id (o
          // con un id que el catálogo ya no conoce) se sigue con
          // light()/dark(), así que borrar el catálogo no deja la
          // app sin tema.
          theme: _variant(ThemeVariantKind.light) ?? AppTheme.light(),
          darkTheme: _variant(ThemeVariantKind.dark) ?? AppTheme.dark(),
          themeMode: switch (prefs.themeMode) {
            AppThemeMode.system => ThemeMode.system,
            AppThemeMode.light => ThemeMode.light,
            AppThemeMode.dark => ThemeMode.dark,
          },
          home: switch (snap.connectionState) {
            ConnectionState.none ||
            ConnectionState.waiting ||
            ConnectionState.active => const _BootSplash(),
            ConnectionState.done =>
              snap.data == null
                  ? ConnectView(
                      creds: widget.creds,
                      onProbe: _probe,
                      onConnected: (_) =>
                          setState(() => _config = _readConfig()),
                    )
                  : AppShell(
                      config: snap.data!,
                      prefs: prefs,
                      creds: widget.creds,
                      onThemeVariant: _onThemeVariant,
                      onProbe: _probe,
                      onLoggedOut: () =>
                          setState(() => _config = _readConfig()),
                    ),
          },
        );
      },
    );
  }
}

class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(child: CircularProgressIndicator(strokeWidth: 2)),
  );
}

/// Shell de 4 destinos con bottom-nav (D5). Cada destino conserva su estado
/// mientras no se cambie de pestaña (un `IndexedStack`).
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.config,
    required this.prefs,
    required this.creds,
    required this.onProbe,
    this.onThemeVariant,
    required this.onLoggedOut,
    this.nav,
    this.chatStreamFactory,
    this.updates,
  });

  final ServerConfig config;
  final PrefsStore prefs;
  final CredsStore creds;

  /// El mismo probe que usa la pantalla Conectar, para que la fila
  /// `Probar conexión` de Ajustes no dependa de la capa de red por su cuenta.
  final ServerProbe onProbe;

  /// Ajustes -> Apariencia -> Tema de color. Repinta en vivo.
  /// Ajustes -> Apariencia -> Tema de color. Repinta en vivo.
  ///
  /// Opcional a propósito: el tema tambien se aplica solo al arrancar
  /// (se lee de las prefs), asi que un AppShell sin selector de tema
  /// es una app perfectamente válida -- y obligarlo a inventar un
  /// callback rompe a quien arma el shell en un test sin necesitarlo.
  final ValueChanged<String>? onThemeVariant;

  final VoidCallback onLoggedOut;

  /// La pila de navegación. Por defecto es una nueva; se inyecta para que un
  /// test pueda llevar el shell a un chat abierto sin levantar un server (el
  /// camino normal, tocar la fila de la lista, necesita datos que no hay).
  final MobileNav? nav;

  /// Cómo se abre el stream del chat. Por defecto, el SSE real; un test inyecta
  /// un fake para no dejar un socket ni timers colgados.
  final ChatEventSourceFactory? chatStreamFactory;

  /// Autoupdate. Por defecto, el servicio real contra el manifiesto
  /// publicado; un test inyecta uno falso para no tocar la red.
  final UpdateService? updates;

  /// Estado del destino Chat sin ninguna sesión abierta: no hay viewmodel, no
  /// hay request y se dice qué hacer en vez de mostrar un error de red.
  static const Key noChatSessionKey = Key('shell-chat-no-session');

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  late final MobileNav _nav = widget.nav ?? MobileNav();

  /// Detector de red. Decide la política de consumo: **sólo** con datos
  /// móviles entra en modo bajo (sin streaming, polling lento, página chica).
  final NetworkMonitor _network = NetworkMonitor();

  /// El usuario puede desactivar el modo a mano aunque siga con datos
  /// móviles; eso manda por encima de la red hasta que cambie de tipo.
  bool _lowDataOverride = false;

  /// `true` = consumir poco. La red manda; el override solo puede **bajar**.
  bool get _lowData => !_lowDataOverride && _network.kind == NetworkKind.mobile;

  DataPolicy get _policy =>
      _lowData ? const DataPolicy.lowData() : const DataPolicy.normal();

  /// Autoupdate. Se inyecta para que un test no toque la red ni el canal
  /// nativo; por defecto es el servicio real.
  late final UpdateService _updates = widget.updates ?? UpdateService();
  bool _updateDismissed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _network.addListener(_onNetwork);
    _network.start();
    // El chequeo arranca después del primer frame: si se hiciera en
    // `initState`, la app espera a GitHub antes de pintar el chat.
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Volver a primer plano es el momento natural para re-chequear: es cuando
    // el usuario puede haberse bajado la versión nueva.
    if (state == AppLifecycleState.resumed) _checkForUpdate();
  }

  /// Chequea y, si hay versión nueva y **no estamos con datos móviles**, la
  /// empieza a bajar sola. No pide permiso ni abre nada: sólo aparece la banda
  /// con el progreso. Instalar es lo único que queda en mano del usuario, y
  /// Android igual pone su propia pantalla de confirmación encima.
  ///
  /// Con datos móviles **no** se baja sola: son 50 MB y el usuario no pidió
  /// gastar sus datos en esto. La banda aparece igual y él decide.
  Future<void> _checkForUpdate() async {
    if (_updateDismissed) return;
    final found = await _updates.check();
    if (!found || !mounted) return;
    _updateDismissed = false;
    if (_lowData) return;
    await _updates.download();
  }

  void _onNetwork() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _network
      ..removeListener(_onNetwork)
      ..dispose();
    _updates.dispose();
    super.dispose();
  }

  /// Las 94 claves de la spec aprobada, con su default de diseño.
  Future<Map<String, bool>> _loadLayerSpec() async => {
    for (final spec in LayerCatalog.instance.all) spec.key: spec.defaultOn,
  };

  /// El toggle del usuario: el catálogo persiste vía PrefsStore.setLayers.
  Future<void> _onLayerToggle(String key, bool value) =>
      LayerCatalog.instance.toggle(key, value);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _nav,
      builder: (context, _) {
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                // Autoupdate: banda no bloqueante, se oculta sola.
                if (!_updateDismissed)
                  ListenableBuilder(
                    listenable: _updates,
                    builder: (context, _) => UpdateBanner(
                      state: _updates.state,
                      onDownload: _updates.download,
                      onInstall: _updates.install,
                      onDismiss: () => setState(() => _updateDismissed = true),
                    ),
                  ),
                // Sólo aparece con datos móviles: explica por qué la app se
                // recorta, en vez de que el usuario adivine que anda lento.
                LowDataBanner(
                  onCellular: _lowData,
                  onDisable: () => setState(() => _lowDataOverride = true),
                ),
                Expanded(
                  child: IndexedStack(
                    index: _nav.tab.index,
                    children: [
                      _SessionsTab(
                        config: widget.config,
                        onOpen: _nav.openSession,
                      ),
                      _ChatTab(
                        sessionInfo: _nav.chatSession,
                        sessionId: _nav.chatSessionId ?? '',
                        config: widget.config,
                        visible: _nav.tab == MobileTab.chat,
                        onBack: _nav.handleBack,
                        streamFactory: widget.chatStreamFactory,
                        policy: _policy,
                        // La política forma parte de la identidad del chat:
                        // al cambiar de red se reconstruye con el consumo nuevo.
                        key: ValueKey('chat-${_nav.chatSessionId}-$_lowData'),
                      ),
                      _FilesTab(config: widget.config),
                      SettingsView(
                        config: widget.config,
                        prefs: widget.prefs,
                        creds: widget.creds,
                        onProbe: widget.onProbe,
                        onThemeVariant: widget.onThemeVariant,
                        onLoggedOut: widget.onLoggedOut,
                        // Las 94 claves de la spec aprobada salen del catálogo
                        // que ya está cargado; el toggle persiste vía PrefsStore.
                        loadLayerSpec: _loadLayerSpec,
                        onLayerToggle: _onLayerToggle,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: SafeArea(
            top: false,
            child: MobileBottomNav(
              current: _nav.tab,
              chatEnabled: _nav.chatSessionId != null,
              onSelect: (tab) {
                // Desde el header del chat, `select` hace de "atrás".
                if (tab == _nav.tab && tab == MobileTab.chat) {
                  _nav.leaveChat();
                } else {
                  _nav.select(tab);
                }
              },
            ),
          ),
        );
      },
    );
  }
}

class _SessionsTab extends StatefulWidget {
  const _SessionsTab({required this.config, required this.onOpen});

  final ServerConfig config;
  final void Function(SessionInfo session) onOpen;

  @override
  State<_SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<_SessionsTab> {
  late final SessionsViewModel _vm = SessionsViewModel(
    repository: SessionRepository(ApiClient(config: widget.config)),
  );

  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SessionsView(viewmodel: _vm, onOpen: widget.onOpen);
}

/// El chat de la sesión abierta.
///
/// El `IndexedStack` del shell lo mantiene montado: por eso el viewmodel
/// nace una vez y **no** se reconstruye al cambiar de pestaña (si no, se
/// perdería el scroll y se re-suscribiría el stream en cada viaje a Ajustes).
/// `setVisible(false)` pausa el SSE cuando el chat no está al frente.
class _ChatTab extends StatefulWidget {
  const _ChatTab({
    super.key,
    required this.sessionId,
    this.sessionInfo,
    required this.config,
    required this.visible,
    required this.onBack,
    this.streamFactory,
    this.policy = const DataPolicy.normal(),
  });

  /// La sesiÃ³n con su `agent` y su `model` de la lista.
  ///
  /// Sin esto el VM se creaba sin `sessionInfo` y al reentrar al chat
  /// los pills volvÃ­an a decir "Elegir modelo"/"Elegir agente" aunque el
  /// usuario ya los hubiera elegido (medido: el server sÃ­ manda `agent` y
  /// `model` en la lista de sesiones).
  final SessionInfo? sessionInfo;

  final String sessionId;
  final ServerConfig config;
  final bool visible;

  /// El boton atras: 	rue si la app debe cerrarse. El nav decide.
  final bool Function() onBack;

  /// Lo inyecta el shell; ver [AppShell.chatStreamFactory].
  final ChatEventSourceFactory? streamFactory;

  /// Política de consumo: con datos móviles el chat recorta streaming,
  /// polling y tamaño de página (ver DataPolicy).
  final DataPolicy policy;

  /// Estado sin sesión abierta (prueba de que no se pide nada a un id vacío).
  static const Key noSessionKey = AppShell.noChatSessionKey;

  @override
  State<_ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<_ChatTab> {
  ChatViewModel? _vm;

  @override
  void initState() {
    super.initState();
    _openFor(widget.sessionId);
    // Sin sesión no hay viewmodel que pausar: el `IndexedStack` construye los
    // 4 destinos aunque no estén al frente, así que esto también evita que el
    // stream arranque solo por existir.
    _vm?.setVisible(widget.visible);
  }

  @override
  void didUpdateWidget(covariant _ChatTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) _openFor(widget.sessionId);
    // La visibilidad cambia al cambiar de pestaña, y para eso Flutter llama a
    // `didUpdateWidget`: `didChangeDependencies` corre UNA vez por `State`, así
    // que desde ahí el socket y el poll de 2 s seguían vivos con el chat
    // fuera de pantalla y la regla de batería de `chat_viewmodel` no aplicaba.
    if (oldWidget.visible != widget.visible) _vm?.setVisible(widget.visible);
  }

  /// Abre (o cierra) el chat de una sesión.
  ///
  /// Un id vacío **no** construye viewmodel: `load()` pediría
  /// `/api/session//message`, una ruta que no existe, en cada arranque y en
  /// cada `leaveChat()`. Sin sesión se muestra [_ChatNoSession].
  void _openFor(String sessionId) {
    // Una sesión por vez: se descarta la anterior (y su socket con ella).
    _vm?.dispose();
    _vm = null;
    if (sessionId.isEmpty) return;
    _vm = ChatViewModel(
      ApiClient(config: widget.config),
      sessionInfo: widget.sessionInfo,
      sessionId: sessionId,
      streamFactory: widget.streamFactory,
      policy: widget.policy,
    )..load();
  }

  @override
  void dispose() {
    _vm?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = _vm;
    if (vm == null) return const _ChatNoSession();
    // El botÃ³n atrÃ¡s del sistema sale del chat en vez de cerrar la app.
    // Antes no habÃ­a `PopScope` en ningÃºn lado y el gesto cerraba la app
    // desde cualquier pestaÃ±a. AcÃ¡ consume el nav, que recorre su pila y
    // devuelve false sÃ³lo en la raÃ­z â€”que es lo que deja cerrar al
    // sistema. La sesiÃ³n NO se borra: se conserva para volver a entrar al
    // mismo chat con su modelo y su agente.
    return PopScope(
      canPop: widget.onBack(),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onBack();
      },
      child: ChatView(viewModel: vm, onBack: widget.onBack),
    );
  }
}

/// El destino Chat sin ninguna sesión abierta.
///
/// Es un estado real, no un error: la lista de sesiones es la que lleva al
/// chat, así que esto sólo se ve en el `IndexedStack` del arranque. Lo que
/// **no** se hace es pedir mensajes de un id inexistente para poder mostrar
/// algo.
class _ChatNoSession extends StatelessWidget {
  const _ChatNoSession();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        key: _ChatTab.noSessionKey,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(
                'message-square',
                size: 48,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.7,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text('Sin sesión abierta', style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Elegí una sesión de la lista para ver su chat.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Archivos: explorar el workspace del server y mandar un path al chat.
class _FilesTab extends StatefulWidget {
  const _FilesTab({required this.config});

  final ServerConfig config;

  @override
  State<_FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<_FilesTab> {
  final List<String> _pendingForChat = [];

  @override
  Widget build(BuildContext context) {
    return FilesView(
      config: widget.config,
      onAddToChat: (path) {
        // El chat todavía no está cableado (M4): guardamos el path para que
        // el composer lo reciba en cuanto aterrice, en vez de perderlo.
        _pendingForChat.add(path);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Se mandará al chat: $path'),
            duration: const Duration(seconds: 2),
          ),
        );
      },
    );
  }
}
