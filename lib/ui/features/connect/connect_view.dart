/// Pantalla de conectar: host, puerto y credenciales del server opencode.
///
/// Es la primera pantalla cuando no hay nada guardado en [CredsStore]. Sólo
/// aparece **antes** de tener servidor; cambiarlo después es Ajustes
/// (`SettingsView`).
///
/// ## La prueba de conexión es inyectada
/// [ConnectView] no conoce `ApiClient`: recibe un [ServerProbe]. En la app es
/// `(config) => ApiClient(config: config).probeServer()`; en los tests es un
/// fake. Motivo doble: los tests no levantan un server, y la pantalla no
/// arrastra la capa de red (la única decisión que toma es "si el probe pasa,
/// recién ahí guardo y sigo").
library;

import 'package:flutter/material.dart';

import '../../../core/network/server_config.dart';
import '../../../core/storage/creds_store.dart';
import '../../core/tokens.dart';

/// Prueba de conexión: `ApiClient(config: config).probeServer()` en la app.
///
/// **Tira** si el server no es opencode v2. Lanza la jerarquía sellada de
/// `lib/domain/models/errors.dart` (`HtmlFallbackError`, `AuthError`,
/// `NetworkError`…), que ya viene en español y con `retriable`.
typedef ServerProbe = Future<void> Function(ServerConfig config);

/// Formulario de conexión al server opencode.
class ConnectView extends StatefulWidget {
  const ConnectView({
    super.key,
    required this.onProbe,
    this.onConnected,
    this.creds,
    this.initialConfig,
  });

  /// `ApiClient(config: config).probeServer()`.
  final ServerProbe onProbe;

  /// Se llama **sólo** si el probe pasó y las credenciales ya quedaron
  /// guardadas. Un `null` deja la pantalla como destino final.
  final ValueChanged<ServerConfig>? onConnected;

  /// Si se pasa, `Conectar` guarda; si no, la pantalla no persiste nada y
  /// delega el guardado en [onConnected].
  final CredsStore? creds;

  /// Config a mostrar en el form (p.ej. la última guardada, para editarla).
  final ServerConfig? initialConfig;

  // Claves de los campos y de los botones. Son públicas para que los tests
  // apunten al widget exacto y no a un texto que puede repetirse.

  /// Campo de texto del host.
  static const Key hostFieldKey = Key('connect-host');

  /// Campo de texto del puerto.
  static const Key portFieldKey = Key('connect-port');

  /// Campo de texto del usuario.
  static const Key userFieldKey = Key('connect-user');

  /// Campo de texto de la contraseña.
  static const Key passwordFieldKey = Key('connect-password');

  /// Ojo de mostrar/ocultar la contraseña.
  static const Key togglePasswordKey = Key('connect-toggle-password');

  /// Botón primario: valida, prueba, guarda y avisa.
  static const Key connectButtonKey = Key('connect-conectar');

  /// Botón secundario: prueba sin guardar.
  static const Key probeButtonKey = Key('connect-probar');

  /// Caja del último error, inline.
  static const Key errorKey = Key('connect-error');

  @override
  State<ConnectView> createState() => _ConnectViewState();
}

class _ConnectViewState extends State<ConnectView> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late final TextEditingController _host = TextEditingController(
    text: widget.initialConfig?.host ?? ServerConfig.defaultHost,
  );
  late final TextEditingController _port = TextEditingController(
    text: '${widget.initialConfig?.port ?? ServerConfig.defaultPort}',
  );
  late final TextEditingController _user = TextEditingController(
    text: widget.initialConfig?.username ?? ServerConfig.defaultUsername,
  );
  final TextEditingController _password = TextEditingController();

  bool _obscured = true;

  /// Hay un probe en vuelo: deshabilita los botones y muestra el spinner.
  bool _busy = false;

  /// Último error, ya en español y sin secretos.
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  ServerConfig _configFromForm() => ServerConfig(
    host: _host.text.trim(),
    port: int.parse(_port.text.trim()),
    username: _user.text.trim(),
    password: _password.text,
  );

  /// `Conectar`: valida → prueba → **guarda** → avisa.
  ///
  /// El orden importa: no se persiste una contraseña que el server acaba de
  /// rechazar. Si se guardara antes del probe, un host mal tipeado dejaría la
  /// app "conectada" a un servidor muerto en el próximo arranque.
  Future<void> _conectar() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final config = _configFromForm();
    await _run(config, persist: true);
  }

  /// `Probar conexión`: valida y prueba, pero **no** guarda ni navega.
  Future<void> _probar() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await _run(_configFromForm(), persist: false);
  }

  Future<void> _run(ServerConfig config, {required bool persist}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onProbe(config);
      // Sólo `Conectar` sigue adelante: "Probar conexión" deja la pantalla
      // como está, aunque el probe haya pasado.
      if (persist) {
        await widget.creds?.write(config);
        if (!mounted) return;
        widget.onConnected?.call(config);
      }
      if (mounted) setState(() => _busy = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeProbeError(error, secret: config.password);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            // En un teléfono es el ancho entero; en tablet, una columna legible.
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      'Servidor opencode',
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'Host, puerto y credenciales del servidor opencode v2.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    _field(
                      fieldKey: ConnectView.hostFieldKey,
                      controller: _host,
                      label: 'Host',
                      hint: ServerConfig.defaultHost,
                      helper: 'Sin http:// y sin barra final.',
                      validator: _validateHost,
                      enabled: !_busy,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _field(
                      fieldKey: ConnectView.portFieldKey,
                      controller: _port,
                      label: 'Puerto',
                      hint: '${ServerConfig.defaultPort}',
                      helper: 'El de `opencode serve`.',
                      validator: _validatePort,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _field(
                      fieldKey: ConnectView.userFieldKey,
                      controller: _user,
                      label: 'Usuario',
                      hint: ServerConfig.defaultUsername,
                      helper: 'Vacío = server sin contraseña.',
                      enabled: !_busy,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _field(
                      fieldKey: ConnectView.passwordFieldKey,
                      controller: _password,
                      label: 'Contraseña',
                      hint: 'La de `OPENCODE_SERVER_PASSWORD`.',
                      // Vacía a propósito: no se vuelve a pintar un secreto que
                      // ya está en disco, y `initialConfig` no la trae.
                      enabled: !_busy,
                      obscure: _obscured,
                      textInputAction: TextInputAction.done,
                      suffix: IconButton(
                        key: ConnectView.togglePasswordKey,
                        onPressed: () => setState(() => _obscured = !_obscured),
                        icon: Icon(
                          _obscured ? Icons.visibility : Icons.visibility_off,
                        ),
                        tooltip: _obscured
                            ? 'Mostrar contraseña'
                            : 'Ocultar contraseña',
                      ),
                    ),
                    if (_error != null) ...<Widget>[
                      const SizedBox(height: AppSpacing.lg),
                      _errorBox(theme, _error!),
                    ],
                    const SizedBox(height: AppSpacing.xl),
                    FilledButton(
                      key: ConnectView.connectButtonKey,
                      onPressed: _busy ? null : _conectar,
                      child: _busy
                          ? const _BusyLabel(text: 'Conectar')
                          : const Text('Conectar'),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextButton(
                      key: ConnectView.probeButtonKey,
                      onPressed: _busy ? null : _probar,
                      // Sin spinner propio: el de `Conectar` ya dice que hay un
                      // probe en vuelo. Dos spinners en la misma pantalla
                      // parecen dos operaciones.
                      child: const Text('Probar conexión'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _field({
    required Key fieldKey,
    required TextEditingController controller,
    required String label,
    String? hint,
    String? helper,
    String? Function(String?)? validator,
    bool enabled = true,
    bool obscure = false,
    TextInputType? keyboardType,
    TextInputAction textInputAction = TextInputAction.next,
    Widget? suffix,
  }) => TextFormField(
    key: fieldKey,
    controller: controller,
    enabled: enabled,
    obscureText: obscure,
    keyboardType: keyboardType,
    textInputAction: textInputAction,
    // El input decorator del tema ya trae el borde del token `--border` y el
    // foco en `--primary`; sólo se agregan rótulo y helper.
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helper,
      suffixIcon: suffix,
    ),
    validator: validator,
  );

  Widget _errorBox(ThemeData theme, String message) => Container(
    key: ConnectView.errorKey,
    padding: const EdgeInsets.all(AppSpacing.md),
    decoration: BoxDecoration(
      // El chrome es monocromo: el error usa el token `danger` del tema (gris),
      // no el rojo del scope de diffs.
      color: theme.colorScheme.error.withValues(alpha: 0.06),
      border: Border.all(color: theme.colorScheme.error, width: 1),
      borderRadius: AppRadius.lgAll,
    ),
    child: Text(
      message,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.error,
        fontWeight: FontWeight.w500,
      ),
    ),
  );
}

/// Rótulo + spinner. El **texto no cambia** durante el probe: el botón sigue
/// siendo encontrable por su etiqueta mientras está deshabilitado.
class _BusyLabel extends StatelessWidget {
  const _BusyLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      const SizedBox(width: AppSpacing.sm),
      Text(text),
    ],
  );
}

/// Texto de error en español para lo que devuelve [ServerProbe].
///
/// No importa la jerarquía de errores a propósito: la pantalla recibe un
/// `Object` y usa la convención `'$runtimeType: $message'` que usa toda la
/// jerarquía sellada, así el mensaje llega limpio (ya viene en español) sin que
/// esta pantalla dependa de la capa de red. Lo que no siga la convención cae
/// en [Object.toString].
///
/// [secret] se borra del texto: un mensaje de error viene del server, que no
/// controla esta app, y no puede filtrar la contraseña a una pantalla.
String describeProbeError(Object error, {String secret = ''}) =>
    redactSecret(_stripType(error), secret);

String _stripType(Object error) {
  final type = error.runtimeType.toString();
  final text = error.toString().trim();
  final prefix = '$type: ';
  return (text.startsWith(prefix) ? text.substring(prefix.length) : text)
      .trim();
}

// ───────────────────────────── validadores ───────────────────────────────────

/// Host: no vacío y sin esquema. Un `http://192.168.1.5:4098` pegado tal cual
/// es el error más común y falla lejos (en el DNS), no en el campo.
String? _validateHost(String? value) {
  final host = value?.trim() ?? '';
  if (host.isEmpty) return 'Ingresá el host del servidor.';
  if (host.contains('://') || host.contains('/')) {
    return 'Sólo el host, sin http:// ni ruta.';
  }
  return null;
}

/// Puerto: entero en 1..65535. `0` y `70000` no son puertos.
String? _validatePort(String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) return 'Ingresá el puerto.';
  final port = int.tryParse(raw);
  if (port == null) return 'El puerto tiene que ser un número.';
  if (port < 1 || port > 65535) return 'El puerto va de 1 a 65535.';
  return null;
}
