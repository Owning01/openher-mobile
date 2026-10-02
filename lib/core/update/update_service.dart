import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Canal nativo que sabe abrir el instalador de Android.
const MethodChannel _installChannel = MethodChannel('ai.openher/install');

/// Qué dice el manifiesto de actualización publicado junto al APK.
@immutable
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.versionCode,
    required this.apkUrl,
    this.notes = '',
    this.publishedAt = '',
  });

  /// Versión visible, p. ej. `1.1.0`. Es lo que se muestra y se compara.
  final String version;

  /// `versionCode` de Android (entero monotónico). Es el que decide de verdad:
  /// Android rechaza instalar un APK con un `versionCode` menor o igual.
  final int versionCode;

  /// URL directa al `.apk`.
  final String apkUrl;

  /// Qué cambió (texto plano, sin markdown).
  final String notes;

  /// ISO-8601, sólo informativo.
  final String publishedAt;

  /// Lee el manifiesto. Tira [FormatException] si le falta lo esencial: un
  /// manifiesto a medias es peor que ninguno, porque instalaría un APK sin
  /// poder compararlo.
  static UpdateInfo? tryParse(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final version = decoded['version'];
    final code = decoded['versionCode'] ?? decoded['build_number'];
    final url = decoded['url'] ?? decoded['apk'];
    if (version is! String || code is! int || url is! String) return null;
    if (version.isEmpty || url.isEmpty) return null;
    return UpdateInfo(
      version: version,
      versionCode: code,
      apkUrl: url,
      notes: decoded['notes'] is String ? decoded['notes'] as String : '',
      publishedAt: decoded['published_at'] is String
          ? decoded['published_at'] as String
          : '',
    );
  }
}

/// Estado del chequeo/descarga, para pintar la UI sin inventar estados.
enum UpdatePhase { idle, checking, available, downloading, ready, failed }

/// Estado completo del autoupdate.
@immutable
class UpdateState {
  const UpdateState({
    this.phase = UpdatePhase.idle,
    this.info,
    this.received = 0,
    this.total = 0,
    this.error,
  });

  final UpdatePhase phase;
  final UpdateInfo? info;

  /// Bytes bajados del APK, para la barra de progreso.
  final int received;
  final int total;
  final String? error;

  bool get busy =>
      phase == UpdatePhase.checking || phase == UpdatePhase.downloading;

  /// Si la banda de actualización tiene que verse.
  ///
  /// Vive acá y no en el widget para que sea **una sola** regla: si el
  /// widget decidiera por su cuenta, un `checking` bastaría para que aparezca
  /// una franja vacía en cada arranque de la app.
  ///
  /// Ojo: esto es la regla **por fase**. Un `failed` no se ve *aca*, pero un
  /// fallo de descarga sí se ve por [canRetry], porque hay algo que hacer.
  static bool showsBannerFor(UpdatePhase phase) =>
      phase == UpdatePhase.available ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.ready;

  /// ¿Se puede volver a bajar el APK?
  ///
  /// Es la diferencia entre los **dos** fallos que existen y que antes se
  /// trataban igual:
  ///
  /// - **Falló el chequeo** (`info == null`): no hay manifest, no hay URL, no
  ///   hay nada que descargar. Un botón acá no serviría de nada, así que la
  ///   banda sigue oculta.
  /// - **Falló la descarga** (`info != null`): sabemos exactamente qué bajar y
  ///   el archivo quedó a medias en el disco. Un APK de 30 MB en datos móviles
  ///   se corta seguido, y sin botón el usuario se queda sin update hasta que
  ///   cierre y vuelva a abrir la app — o sea, hasta que reinicie el chequeo.
  bool get canRetry =>
      phase == UpdatePhase.failed && info != null && error != null;

  bool get showsBanner => showsBannerFor(phase) || canRetry;

  /// Descarga 0/0 no debe pintar progreso indeterminado: el total sólo se
  /// conoce cuando el server manda `Content-Length`.
  double? get progress {
    if (total <= 0) return null;
    return (received / total).clamp(0.0, 1.0);
  }

  UpdateState copyWith({
    UpdatePhase? phase,
    UpdateInfo? info,
    int? received,
    int? total,
    String? error,
    bool clearError = false,
  }) => UpdateState(
    phase: phase ?? this.phase,
    info: info ?? this.info,
    received: received ?? this.received,
    total: total ?? this.total,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Autoupdate: compara contra un manifiesto, baja el APK y abre el instalador.
///
/// **No bloquea nada.** Nunca muestra un diálogo modal ni detiene la app: el
/// chequeo es una llamada de red con timeout, la descarga va en background y
/// la UI sólo muestra una banda. Si todo falla, se queda en silencio.
class UpdateService extends ChangeNotifier {
  UpdateService({
    http.Client? client,
    this.fallbackVersionCode = 1,
    this.checkTimeout = const Duration(seconds: 10),
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// Deadline del chequeo. Es inyectable para poder testear el cuelgue sin
  /// esperar 10 s de reloj.
  final Duration checkTimeout;

  /// Se usa cuando no hay canal nativo (tests, o un host que no es Android).
  /// En el APK real manda [versionCode], que lee `BuildConfig`.
  final int fallbackVersionCode;

  int? _versionCode;

  /// `versionCode` de este build, leído de `BuildConfig.VERSION_CODE`.
  ///
  /// Android **rechaza** instalar un APK con un `versionCode` menor o igual al
  /// instalado, así que la comparación tiene que ser contra el número real y
  /// no contra un string de versión ni contra un número copiado a mano (que
  /// se desincroniza del `pubspec.yaml` en el primer bump).
  Future<int> get versionCode async =>
      _versionCode ??= await _nativeVersionCode() ?? fallbackVersionCode;

  Future<int?> _nativeVersionCode() async =>
      _tryChannel(() => _installChannel.invokeMethod<int>('versionCode'));

  UpdateState _state = const UpdateState();
  UpdateState get state => _state;

  /// Dónde se busca el manifiesto. Se puede sobreescribir para tests y para
  /// apuntar a otro mirror.
  ///
  /// `releases/latest/download/` lo resuelve GitHub al último release no
  /// prerelease: no hace falta mover ningún tag ni un symlink a mano, que es
  /// exactamente la clase de paso que se olvida y rompe el autoupdate.
  Uri manifestUrl = Uri.parse(
    'https://github.com/Owning01/openher-mobile/releases/latest/download/latest.json',
  );

  bool _disposed = false;
  void _emit(UpdateState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  /// Chequea el manifiesto. Devuelve `true` si hay una versión nueva.
  ///
  /// Es idempotente y no tira: cualquier fallo es un `false` silencioso,
  /// porque una app de chat no puede dejar de funcionar porque GitHub no
  /// respondió.
  Future<bool> check() async {
    if (_state.busy) return false;
    _emit(const UpdateState(phase: UpdatePhase.checking));
    try {
      final res = await _client.get(manifestUrl).timeout(checkTimeout);
      if (res.statusCode != 200) {
        _emit(
          UpdateState(
            phase: UpdatePhase.failed,
            error: 'HTTP ${res.statusCode}',
          ),
        );
        return false;
      }
      final info = UpdateInfo.tryParse(res.body);
      if (info == null) {
        _emit(
          const UpdateState(
            phase: UpdatePhase.failed,
            error: 'manifiesto ilegible',
          ),
        );
        return false;
      }
      if (info.versionCode <= await versionCode) {
        // Ya estamos al día: se vuelve a `idle` (no `failed`) para que el
        // banner no insinúe que algo anda mal.
        _emit(const UpdateState());
        return false;
      }
      _emit(UpdateState(phase: UpdatePhase.available, info: info));
      return true;
    } catch (e) {
      _emit(UpdateState(phase: UpdatePhase.failed, error: '$e'));
      return false;
    }
  }

  /// Baja el APK a la carpeta que el `FileProvider` declara compartida.
  Future<bool> download() async {
    // Idempotente: si ya terminÃ³, no se vuelve a bajar nada.
    if (_state.phase == UpdatePhase.ready) return true;
    final info = _state.info;
    if (info == null) return false;
    _emit(
      _state.copyWith(
        phase: UpdatePhase.downloading,
        received: 0,
        total: 0,
        clearError: true,
      ),
    );
    try {
      // Si el APK de esta version YA esta en el disco, se saltea la
      // descarga entera y aparece directo el boton Instalar.
      final existing = await _alreadyDownloaded(info);
      if (existing != null) {
        _emit(
          UpdateState(
            phase: UpdatePhase.ready,
            info: info,
            received: existing.lengthSync(),
          ),
        );
        return true;
      }
      final dir = await _updatesDir();
      if (dir == null) {
        _emit(
          _state.copyWith(
            phase: UpdatePhase.failed,
            error: 'sin carpeta de descargas',
          ),
        );
        return false;
      }
      final file = File('$dir/openher-${info.version}.apk');
      // Reanudar una descarga a medio hacer no vale la pena (el servidor no
      // negocia rangos de forma fiable): se pisa el archivo.
      //
      // Y si la descarga **no llega a terminarse**, el archivo se borra. Sin
      // esto un corte a mitad deja un archivo con el nombre correcto que, si
      // pasó de los 2 MB de [_minApkBytes], el próximo arranque lo da por bueno
      // con [_alreadyDownloaded]: el instalador recibiría un APK truncado y
      // fallaría sin explicar nada. Con el botón de reintentar el camino queda
      // todavía más fácil de alcanzar, así que el borrado va acá y no depende
      // de que alguien se acuerde de limpiar.
      var completo = false;
      final sink = file.openWrite();
      try {
        final req = http.Request('GET', Uri.parse(info.apkUrl));
        final res = await _client
            .send(req)
            .timeout(const Duration(minutes: 10));
        if (res.statusCode != 200) {
          _emit(
            _state.copyWith(
              phase: UpdatePhase.failed,
              error: 'HTTP ${res.statusCode}',
            ),
          );
          return false;
        }
        final total = res.contentLength ?? 0;
        _emit(
          _state.copyWith(
            phase: UpdatePhase.downloading,
            received: 0,
            total: total,
          ),
        );
        var received = 0;
        await for (final chunk in res.stream) {
          sink.add(chunk);
          received += chunk.length;
          _emit(
            _state.copyWith(
              phase: UpdatePhase.downloading,
              received: received,
              total: total,
            ),
          );
        }
        completo = true;
      } finally {
        await sink.close();
        if (!completo) await _borrarSiExiste(file);
      }
      _emit(
        _state.copyWith(phase: UpdatePhase.ready, received: file.lengthSync()),
      );
      return true;
    } catch (e) {
      _emit(_state.copyWith(phase: UpdatePhase.failed, error: '$e'));
      return false;
    }
  }

  /// Borra el archivo a medias de una descarga cortada.
  ///
  /// Nunca tira: si el borrado falla, el piso de tamaño de [_minApkBytes]
  /// sigue siendo la segunda barrera, y un archivo que no se puede borrar es
  /// un problema del sistema de archivos, no del update.
  Future<void> _borrarSiExiste(File file) async {
    try {
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // Sin logger a mano en el service: el estado ya quedó en `failed` con el
      // error real, que es lo que el usuario ve.
    }
  }

  /// Si el APK de esta version **ya esta en el disco**, lo da por descargado
  /// sin volver a pegarle al server.
  ///
  /// Sin esto la app se bajaba 53 MB en cada arranque y en cada vuelta a
  /// primer plano: el chequeo encuentra la version nueva y la baja otra vez.
  /// El instalador de Android, una vez que tiene el archivo, no lo necesita.
  ///
  /// El piso de tamano no es paranoia: un corte de red a mitad deja un
  /// archivo de pocos KB con el nombre correcto, y sin el piso la app lo
  /// daria por bueno y el instalador fallaria sin explicar nada.
  Future<File?> _alreadyDownloaded(UpdateInfo info) async {
    final dir = await _updatesDir();
    if (dir == null) return null;
    final file = File('$dir/openher-${info.version}.apk');
    try {
      if (!file.existsSync()) return null;
      if (file.lengthSync() < _minApkBytes) return null;
      return file;
    } on FileSystemException {
      return null;
    }
  }

  /// Tamano minimo creible para un APK. El release real pesa 53 MB, asi que el
  /// margen es enorme y un archivo truncado no lo pasa.
  static const int _minApkBytes = 2 * 1024 * 1024;

  /// Borra los APK viejos de cacheDir: son 53 MB que el sistema puede limpiar
  /// solo, pero mientras tanto ocupan cache que el usuario ve en Ajustes.
  Future<void> discardApks() async {
    final dir = await _updatesDir();
    if (dir == null) return;
    try {
      for (final f in Directory(dir).listSync().whereType<File>()) {
        if (f.path.endsWith('.apk')) f.deleteSync();
      }
    } on FileSystemException {
      // Borrar es limpieza: si falla, no es un error de la app.
    }
  }

  /// Abre el instalador de Android. `false` si no se pudo.
  Future<bool> install() async {
    final info = _state.info;
    if (info == null) return false;
    final dir = await _updatesDir();
    if (dir == null) return false;
    final path = '$dir/openher-${info.version}.apk';
    if (!File(path).existsSync()) return false;
    final ok = await _tryChannel(
      () => _installChannel.invokeMethod<bool>('install', {'path': path}),
    );
    if (ok == true) return true;
    // Sin el permiso `REQUEST_INSTALL_PACKAGES` Android no abre nada: se
    // lleva al usuario a la pantalla donde se concede.
    final can = await _tryChannel(
      () => _installChannel.invokeMethod<bool>('canRequestPackageInstalls'),
    );
    if (can == false) {
      await _tryChannel(
        () => _installChannel.invokeMethod<bool>('openInstallSettings'),
      );
    }
    return false;
  }

  /// Carpeta compartida con el `FileProvider`; la declara el nativo.
  Future<String?> _updatesDir() async =>
      _tryChannel(() => _installChannel.invokeMethod<String>('updatesDir'));

  /// Habla con el canal nativo sin que una ausencia de plataforma rompa nada.
  ///
  /// `catch (e)` y no `on MissingPluginException`: medido, en un host sin
  /// plataforma el canal no tira `MissingPluginException` sino un
  /// `FlutterError: Binding has not yet been initialized`, que es un `Error`
  /// y se escapa de cualquier `on Exception`. Cualquier resultado raro acá
  /// significa lo mismo —"no hay Android debajo"— y el valor por defecto es
  /// el seguro, así que se lo traga.
  static Future<T?> _tryChannel<T>(Future<T?> Function() call) async {
    try {
      return await call();
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _client.close();
    super.dispose();
  }
}
