/// Ajustes: servidor, apariencia, modelo, datos y el interruptor de capas.
///
/// Es el destino 4 de la bottom nav (D5) y reemplaza Ajustes + Servidor + Remoto
/// del escritorio. Todo lo que muestra sale de [PrefsStore] y [CredsStore]; el
/// único I/O es el `Probar conexión` explícito y el `Cerrar sesión`.
///
/// ## Las 94 capas no están en este archivo
/// La lista aprobada vive en `spec/layers.json` y la carga
/// `lib/ui/core/layer_gate.dart` (`LayerCatalog`). Acá **no** se duplica: el
/// widget recibe las claves por [SettingsView.layerKeys] /
/// [SettingsView.loadLayerSpec] y, si no le pasan nada, muestra
/// [SettingsView.defaultLayerKeys] (un subconjunto, sólo para que la pantalla
/// no quede vacía sin el asset). La persistencia de cada toggle va a
/// [PrefsStore.setLayer] y se avisa por [SettingsView.onLayerToggle].
library;

import 'package:flutter/material.dart';

import '../../../core/network/server_config.dart';
import '../../../core/storage/creds_store.dart';
import '../../../core/storage/prefs_store.dart';
import '../../core/tokens.dart';
import '../connect/connect_view.dart' show ServerProbe, describeProbeError;

/// Fila de la lista de ajustes.
///
/// 44 px de alto mínimo (objetivo táctil del prototipo), rótulo a la izquierda,
/// valor a la derecha en el color apagado, y galón sólo si [onTap] no es `null`
/// (una fila que no navega no engaña).
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.label,
    this.value,
    this.onTap,
    this.trailing,
    this.danger = false,
    this.dotColor,
  });

  final String label;

  /// Texto del valor, a la derecha.
  final String? value;

  final VoidCallback? onTap;

  /// Control al final de la fila (un `Switch`, p.ej.). Si viene [onTap], el
  /// galón no se dibuja: la fila ya tiene su propio control.
  final Widget? trailing;

  /// Pinta el rótulo con el token `danger` del tema (fila destructiva).
  final bool danger;

  /// Punto de estado antes del valor.
  final Color? dotColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted =
        theme.textTheme.bodySmall?.color ?? theme.colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: <Widget>[
              if (dotColor != null) ...<Widget>[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: danger ? theme.colorScheme.error : null,
                    fontWeight: danger ? FontWeight.w500 : null,
                  ),
                ),
              ),
              if (value != null) ...<Widget>[
                Text(
                  value!,
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              if (trailing != null)
                trailing!
              else if (onTap != null)
                Icon(Icons.chevron_right, size: 20, color: muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tarjeta de un grupo de filas, con borde de 1 px y radio `--r-lg`.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xs,
            0,
            AppSpacing.xs,
            AppSpacing.sm,
          ),
          child: Text(title, style: theme.textTheme.labelSmall),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border.all(color: theme.colorScheme.outline, width: 1),
            borderRadius: AppRadius.lgAll,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (var i = 0; i < children.length; i++) ...<Widget>[
                if (i > 0) Divider(height: 1, color: theme.dividerColor),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Pantalla de ajustes.
class SettingsView extends StatefulWidget {
  const SettingsView({
    super.key,
    required this.creds,
    required this.prefs,
    this.config,
    this.onProbe,
    this.onLoggedOut,
    this.onLayerToggle,
    this.layerKeys,
    this.layerDefaults,
    this.loadLayerSpec,
    this.onBack,
  });

  final CredsStore creds;
  final PrefsStore prefs;

  /// Server configurado. `null` = todavía no se conectó nunca.
  final ServerConfig? config;

  /// `ApiClient(config: config).probeServer()`. Sin él, la fila de probe queda
  /// deshabilitada.
  final ServerProbe? onProbe;

  /// Tras `Cerrar sesión` confirmado: vuelve a la pantalla de conectar.
  final VoidCallback? onLoggedOut;

  /// Se llama en cada toggle de capa, después de persistir.
  final void Function(String key, bool value)? onLayerToggle;

  /// Las claves de la spec, ya resueltas (para tests y para cableado simple).
  final List<String>? layerKeys;

  /// Default de la spec por clave. Sin esto, todas en `true`.
  final Map<String, bool>? layerDefaults;

  /// Carga la spec en runtime. Tiene prioridad sobre
  /// [SettingsView.defaultLayerKeys] y es lo que debería usar la app:
  /// `LayerCatalog` ya sabe leerla.
  final Future<Map<String, bool>> Function()? loadLayerSpec;

  /// Volver. Por defecto, `Navigator.maybePop`.
  final VoidCallback? onBack;

  /// Subconjunto de la spec para cuando no hay asset ni inyección. **No** es la
  /// lista completa: las 94 claves están en `spec/layers.json` y se cargan, no
  /// se copian en Dart.
  static const List<String> defaultLayerKeys = <String>[
    'app.bottomnav',
    'sessions.appbar',
    'sessions.row.status',
    'chat.appbar',
    'chat.activitybox',
    'chat.composer',
    'chat.composer.mic',
    'chat.msg.user.bubble',
    'chat.toolcard',
    'chat.typing',
    'files.appbar',
    'settings.appbar',
  ];

  // Claves de filas, switches y del diálogo. Públicas para que los tests
  // apunten al widget exacto: `Cerrar sesión` aparece dos veces en pantalla
  // (fila y botón del confirm) y un `find.text` no las distingue.

  /// Fila `Probar conexión`.
  static const Key probeRowKey = Key('settings-probe');

  /// Switch de `Animaciones`.
  static const Key animationsSwitchKey = Key('settings-animations-switch');

  /// Switch de `Traducir ES→EN`.
  static const Key translateSwitchKey = Key('settings-translate-switch');

  /// Fila `Cerrar sesión` (la que abre el confirm).
  static const Key logoutRowKey = Key('settings-logout');

  /// Botón `Cancelar` del confirm.
  static const Key logoutCancelKey = Key('settings-logout-cancel');

  /// Botón `Cerrar sesión` del confirm, el que borra.
  static const Key logoutConfirmKey = Key('settings-logout-confirm');

  /// Cabecera plegable `Capas de la UI`.
  static const Key layersHeaderKey = Key('settings-layers-header');

  /// Fila `Tema`.
  static const Key themeRowKey = Key('settings-row-theme');

  /// Fila `Tamaño de texto`.
  static const Key textScaleRowKey = Key('settings-row-textscale');

  /// Fila de la capa [key].
  static Key layerRowKey(String key) => Key('settings-layer-$key');

  /// Switch de la capa [key].
  static Key layerSwitchKey(String key) => Key('settings-layer-switch-$key');

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  /// Defaults de la spec por clave (90 encendidas, 4 apagadas). Los **overrides**
  /// del usuario no viven acá: son [PrefsStore.layerSwitches], la única fuente
  /// de verdad, para que un toggle no pueda quedar desincronizado de lo
  /// guardado.
  Map<String, bool> _spec = const <String, bool>{};

  /// El grupo de capas arranca plegado: 94 switches no se construyen hasta que
  /// se piden.
  bool _layersOpen = false;

  bool _probing = false;

  @override
  void initState() {
    super.initState();
    _spec = _injectedSpec();
    _loadSpec();
  }

  /// Defaults que llegaron por constructor; si no llegaron, el subconjunto de
  /// respaldo, para que la pantalla no quede vacía sin el asset.
  Map<String, bool> _injectedSpec() {
    final defaults = widget.layerDefaults;
    final keys = widget.layerKeys ?? SettingsView.defaultLayerKeys;
    return <String, bool>{for (final key in keys) key: defaults?[key] ?? true};
  }

  /// La spec real la carga `LayerCatalog` (o el `loadLayerSpec` que cablee la
  /// app): 94 claves desde `spec/layers.json`, no una copia en Dart.
  Future<void> _loadSpec() async {
    final loader = widget.loadLayerSpec;
    if (loader == null) return;
    final spec = await loader();
    if (!mounted || spec.isEmpty) return;
    setState(() => _spec = spec);
  }

  /// ¿Está la capa [key] encendida? Override del usuario si lo hay; si no, el
  /// default de la spec.
  bool _layerOn(String key) =>
      widget.prefs.layerEnabled(key, fallback: _spec[key] ?? true);

  // ───────────────────────────── acciones ────────────────────────────────────

  /// `Probar conexión`: el probe de `/api/location` (API_CONTRACT §1.6). El
  /// resultado va en un snackbar; no cambia nada guardado.
  Future<void> _probe() async {
    final config = widget.config;
    final probe = widget.onProbe;
    if (config == null || probe == null || _probing) return;
    setState(() => _probing = true);
    String message;
    try {
      await probe(config);
      message = 'Conexión OK con ${config.baseUrl}';
    } catch (error) {
      message =
          'No se pudo conectar: '
          '${describeProbeError(error, secret: config.password)}';
    }
    if (!mounted) return;
    setState(() => _probing = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _setAnimations(bool value) async {
    await widget.prefs.setAnimations(value);
    if (mounted) setState(() {}); // re-pinta leyendo el valor persistido
  }

  Future<void> _setTranslate(bool value) async {
    await widget.prefs.setTranslateEsEn(value);
    if (mounted) setState(() {});
  }

  Future<void> _toggleLayer(String key, bool value) async {
    await widget.prefs.setLayer(key, value);
    if (mounted) setState(() {}); // re-pinta leyendo el valor persistido
    widget.onLayerToggle?.call(key, value);
  }

  /// `Cerrar sesión`: confirmación explícita (el borrado es irreversible) y
  /// recién después se borra.
  Future<void> _confirmLogout() async {
    final danger = Theme.of(context).colorScheme.error;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Cerrar sesión'),
        content: const Text(
          'Esta acción no se puede deshacer. Elimina las credenciales guardadas '
          'en este dispositivo.',
        ),
        actions: <Widget>[
          TextButton(
            key: SettingsView.logoutCancelKey,
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            key: SettingsView.logoutConfirmKey,
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(
              'Cerrar sesión',
              style: TextStyle(color: danger, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.creds.clear();
    if (!mounted) return;
    widget.onLoggedOut?.call();
  }

  /// Hoja de elección de [options] para las filas de presentación. Se usa la
  /// hoja y no un `DropdownButton`: el pulgar llega abajo (D5).
  Future<void> _pick<T extends Enum>(
    List<T> options,
    T current,
    String Function(T) labelOf,
    Future<void> Function(T) apply,
  ) async {
    final picked = await showModalBottomSheet<T>(
      context: context,
      builder: (sheet) => SafeArea(
        child: RadioGroup<T>(
          groupValue: current,
          onChanged: (value) {
            if (value != null) Navigator.of(sheet).pop(value);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final option in options)
                RadioListTile<T>(value: option, title: Text(labelOf(option))),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    await apply(picked);
    if (mounted) setState(() {});
  }

  // ───────────────────────────── build ───────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    final prefs = widget.prefs;
    final canProbe = config != null && widget.onProbe != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ajustes'),
        leading: IconButton(
          onPressed: widget.onBack ?? () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Volver',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: <Widget>[
          SettingsGroup(
            title: 'Servidor',
            children: <Widget>[
              SettingsRow(
                key: const Key('settings-row-host'),
                label: 'Host',
                value: config?.host ?? '—',
              ),
              SettingsRow(
                key: const Key('settings-row-port'),
                label: 'Puerto',
                value: config == null ? '—' : '${config.port}',
              ),
              SettingsRow(
                key: const Key('settings-row-user'),
                label: 'Usuario',
                value: config?.username ?? ServerConfig.defaultUsername,
              ),
              const SettingsRow(
                key: Key('settings-row-password'),
                label: 'Contraseña',
                // Nunca el valor real: la fila recuerda que hay una, no la
                // muestra.
                value: '•••••••',
              ),
              SettingsRow(
                key: const Key('settings-row-status'),
                label: 'Estado',
                value: config == null ? 'Sin conectar' : 'Conectado',
                // El verde del scope de diffs: el chrome es monocromo, pero el
                // estado de la conexión es un dato, no cromo.
                dotColor: config == null
                    ? null
                    : AppColors.diffAddOf(Theme.of(context).brightness),
              ),
              SettingsRow(
                key: SettingsView.probeRowKey,
                label: 'Probar conexión',
                onTap: canProbe ? _probe : null,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          SettingsGroup(
            title: 'Apariencia',
            children: <Widget>[
              SettingsRow(
                key: SettingsView.themeRowKey,
                label: 'Tema',
                value: prefs.themeMode.label,
                onTap: () => _pick(
                  AppThemeMode.values,
                  prefs.themeMode,
                  (mode) => mode.label,
                  prefs.setThemeMode,
                ),
              ),
              SettingsRow(
                key: SettingsView.textScaleRowKey,
                label: 'Tamaño de texto',
                value: prefs.textScale.label,
                onTap: () => _pick(
                  AppTextScale.values,
                  prefs.textScale,
                  (scale) => scale.label,
                  prefs.setTextScale,
                ),
              ),
              SettingsRow(
                key: const Key('settings-row-animations'),
                label: 'Animaciones',
                trailing: Switch(
                  key: SettingsView.animationsSwitchKey,
                  value: prefs.animations,
                  onChanged: _setAnimations,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          SettingsGroup(
            title: 'Modelo',
            children: <Widget>[
              // El selector real de modelo/agente es la hoja del composer (M7);
              // acá se muestra el valor guardado.
              SettingsRow(
                key: const Key('settings-row-model'),
                label: 'Modelo por defecto',
                value: prefs.defaultModel,
              ),
              SettingsRow(
                key: const Key('settings-row-agent'),
                label: 'Agente por defecto',
                value: prefs.defaultAgent,
              ),
              SettingsRow(
                key: const Key('settings-row-translate'),
                label: 'Traducir ES→EN',
                trailing: Switch(
                  key: SettingsView.translateSwitchKey,
                  value: prefs.translateEsEn,
                  onChanged: _setTranslate,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          SettingsGroup(
            title: 'Datos',
            children: <Widget>[
              // Los dos valores de abajo son los del diseño; el espacio real se
              // mide en M10.
              const SettingsRow(
                key: Key('settings-row-data-mode'),
                label: 'Modo de datos',
                value: 'Completo',
              ),
              const SettingsRow(
                key: Key('settings-row-usage'),
                label: 'Espacio usado',
                value: '18.4 MB',
              ),
              SettingsRow(
                key: SettingsView.logoutRowKey,
                label: 'Cerrar sesión',
                danger: true,
                onTap: _confirmLogout,
              ),
              SettingsRow(
                key: SettingsView.layersHeaderKey,
                label: 'Capas de la UI',
                value:
                    '${_spec.keys.where(_layerOn).length} de ${_spec.length}',
                onTap: () => setState(() => _layersOpen = !_layersOpen),
                trailing: Icon(
                  _layersOpen ? Icons.expand_more : Icons.chevron_right,
                  size: 20,
                ),
              ),
              if (_layersOpen)
                for (final key in _spec.keys)
                  SettingsRow(
                    key: SettingsView.layerRowKey(key),
                    label: key,
                    trailing: Switch(
                      key: SettingsView.layerSwitchKey(key),
                      value: _layerOn(key),
                      onChanged: (value) => _toggleLayer(key, value),
                    ),
                  ),
            ],
          ),
        ],
      ),
    );
  }
}
