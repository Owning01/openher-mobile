import 'package:flutter/material.dart';

import 'core/network/api_client.dart';
import 'core/network/server_config.dart';
import 'data/repositories/session_repository.dart';
import 'core/storage/creds_store.dart';
import 'core/storage/prefs_store.dart';
import 'ui/core/layer_gate.dart';
import 'ui/core/theme.dart';
import 'ui/features/connect/connect_view.dart';
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
                const _ChatTab(),
                const _FilesTab(),
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

/// El chat lo inyecta el worker de chat; acá va el hueco honesto mientras tanto.
class _ChatTab extends StatelessWidget {
  const _ChatTab();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('Chat')));
}

/// Los archivos también entran por su worker; placeholder explícito.
class _FilesTab extends StatelessWidget {
  const _FilesTab();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('Archivos')));
}
