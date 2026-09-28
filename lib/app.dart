import 'package:flutter/material.dart';

import 'core/network/api_client.dart';
import 'core/network/server_config.dart';
import 'core/storage/creds_store.dart';
import 'core/storage/prefs_store.dart';
import 'ui/core/layer_gate.dart';
import 'ui/core/theme.dart';
import 'ui/features/connect/connect_view.dart';
import 'ui/features/navigation/mobile_bottom_nav.dart';
import 'ui/features/navigation/mobile_nav.dart';
import 'ui/features/sessions/sessions_view.dart';
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
    required this.onLoggedOut,
  });

  final ServerConfig config;
  final PrefsStore prefs;
  final CredsStore creds;
  final VoidCallback onLoggedOut;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final MobileNav _nav = MobileNav();

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
                  onLoggedOut: widget.onLoggedOut,
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
  late final SessionsView view = SessionsView(
    config: widget.config,
    onOpen: widget.onOpen,
  );

  @override
  Widget build(BuildContext context) => view;
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
