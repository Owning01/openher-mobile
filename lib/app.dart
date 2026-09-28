import 'package:flutter/material.dart';

import 'core/network/api_client.dart';
import 'core/network/server_config.dart';
import 'data/repositories/session_repository.dart';
import 'core/storage/creds_store.dart';
import 'core/storage/prefs_store.dart';
import 'ui/core/app_icon.dart';
import 'ui/core/layer_gate.dart';
import 'ui/core/theme.dart';
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

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ServerConfig?>(
      future: _config,
      builder: (context, snap) {
        final prefs = widget.prefs;
        return MaterialApp(
          title: 'OpenHer Mobile',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
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
    required this.onLoggedOut,
    this.nav,
    this.chatStreamFactory,
  });

  final ServerConfig config;
  final PrefsStore prefs;
  final CredsStore creds;

  /// El mismo probe que usa la pantalla Conectar, para que la fila
  /// `Probar conexión` de Ajustes no dependa de la capa de red por su cuenta.
  final ServerProbe onProbe;

  final VoidCallback onLoggedOut;

  /// La pila de navegación. Por defecto es una nueva; se inyecta para que un
  /// test pueda llevar el shell a un chat abierto sin levantar un server (el
  /// camino normal, tocar la fila de la lista, necesita datos que no hay).
  final MobileNav? nav;

  /// Cómo se abre el stream del chat. Por defecto, el SSE real; un test inyecta
  /// un fake para no dejar un socket ni timers colgados.
  final ChatEventSourceFactory? chatStreamFactory;

  /// Estado del destino Chat sin ninguna sesión abierta: no hay viewmodel, no
  /// hay request y se dice qué hacer en vez de mostrar un error de red.
  static const Key noChatSessionKey = Key('shell-chat-no-session');

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final MobileNav _nav = widget.nav ?? MobileNav();

  /// Las 94 claves de la spec aprobada, con su default de diseño.
  Future<Map<String, bool>> _loadLayerSpec() async => {
    for (final spec in LayerCatalog.instance.all) spec.key: spec.defaultOn,
  };

  /// El toggle del usuario: el catálogo persiste vía `PrefsStore.setLayers`.
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
            child: IndexedStack(
              index: _nav.tab.index,
              children: [
                _SessionsTab(config: widget.config, onOpen: _nav.openSession),
                _ChatTab(
                  sessionId: _nav.chatSessionId ?? '',
                  config: widget.config,
                  visible: _nav.tab == MobileTab.chat,
                  onBack: _nav.leaveChat,
                  streamFactory: widget.chatStreamFactory,
                ),
                _FilesTab(config: widget.config),
                SettingsView(
                  config: widget.config,
                  prefs: widget.prefs,
                  creds: widget.creds,
                  onProbe: widget.onProbe,
                  onLoggedOut: widget.onLoggedOut,
                  // Las 94 claves de la spec aprobada salen del catálogo que
                  // ya está cargado; el toggle persiste vía PrefsStore.
                  loadLayerSpec: _loadLayerSpec,
                  onLayerToggle: _onLayerToggle,
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
  final ValueChanged<String> onOpen;

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
    required this.sessionId,
    required this.config,
    required this.visible,
    required this.onBack,
    this.streamFactory,
  });

  final String sessionId;
  final ServerConfig config;
  final bool visible;
  final VoidCallback onBack;

  /// Lo inyecta el shell; ver [AppShell.chatStreamFactory].
  final ChatEventSourceFactory? streamFactory;

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
      sessionId: sessionId,
      streamFactory: widget.streamFactory,
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
    return ChatView(viewModel: vm, onBack: widget.onBack);
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
