import 'package:flutter/material.dart';

import 'core/network/api_client.dart';
import 'core/network/server_config.dart';
import 'data/repositories/session_repository.dart';
import 'core/storage/creds_store.dart';
import 'core/storage/prefs_store.dart';
import 'ui/core/layer_gate.dart';
import 'ui/core/theme.dart';
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
  });

  final ServerConfig config;
  final PrefsStore prefs;
  final CredsStore creds;

  /// El mismo probe que usa la pantalla Conectar, para que la fila
  /// `Probar conexión` de Ajustes no dependa de la capa de red por su cuenta.
  final ServerProbe onProbe;

  final VoidCallback onLoggedOut;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final MobileNav _nav = MobileNav();

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
  });

  final String sessionId;
  final ServerConfig config;
  final bool visible;
  final VoidCallback onBack;

  @override
  State<_ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<_ChatTab> {
  ChatViewModel? _vm;

  @override
  void initState() {
    super.initState();
    _openFor(widget.sessionId);
  }

  @override
  void didUpdateWidget(covariant _ChatTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) _openFor(widget.sessionId);
  }

  void _openFor(String sessionId) {
    // Una sesión por vez: se descarta la anterior (y su socket con ella).
    _vm?.dispose();
    _vm = ChatViewModel(ApiClient(config: widget.config), sessionId: sessionId)
      ..load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _vm?.setVisible(widget.visible);
  }

  @override
  void dispose() {
    _vm?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = _vm;
    if (vm == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return ChatView(viewModel: vm, onBack: widget.onBack);
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
