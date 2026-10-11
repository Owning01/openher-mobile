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
    this.sha256 = '',
    this.notes = '',
    this.publishedAt = '',
  });

  /// Versión visible, p. ej. `1.1.0`. Es lo que se muestra y se compara.
  final String version;

  /// `versionCode` de Android (entero monotónico). Es el que decide de verdad:
  /// Android rechaza instalar un APK con un `versionCode` menor o igual.
  final int versionCode;

  /// URL directa al `.apk`. Tiene que ser `https` (lo exige [UpdateService]).
  final String apkUrl;

  /// SHA-256 en hex del APK que publica `scripts/publish-update.ps1`. Se
  /// verifica tras la descarga y antes de `ready`: un APK que no coincide no
  /// se ofrece para instalar.
  final String sha256;

  /// Huella corta para mostrar (`abcdef123456…`): el hex completo no entra en
  /// la banda y los primeros 12 ya identifican el archivo.
  String get fingerprint =>
      sha256.length <= 12 ? sha256 : '${sha256.substring(0, 12)}…';

  /// Qué cambió (texto plano, sin markdown).
  final String notes;

  /// ISO-8601, sólo informativo.
  final String publishedAt;

  /// Lee el manifiesto. Tira [FormatException] si le falta lo esencial: un
  /// manifiesto a medias es peor que ninguno, porque instalaría un APK sin
  /// poder compararlo.
  ///
  /// `sha256` y el esquema de la URL **no** se exigen acá: el parseo dice qué
  /// vino y [UpdateService.check] dice si alcanza (con el motivo en claro).
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
    final sha = decoded['sha256'];
    return UpdateInfo(
      version: version,
      versionCode: code,
      apkUrl: url,
      sha256: sha is String ? sha.toLowerCase() : '',
      notes: decoded['notes'] is String ? decoded['notes'] as String : '',
      publishedAt: decoded['published_at'] is String
          ? decoded['published_at'] as String
          : '',
    );
  }
}

/// Estado del chequeo/descarga, para pintar la UI sin inventar estados.
enum UpdatePhase { idle, checking, available, downloading, ready, installDenied, failed }

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
  /// fallo de descarga sí se ve por [canRetry], porque hay algo que hacer. E
  /// `installDenied` se ve: hay un permiso que conceder.
  static bool showsBannerFor(UpdatePhase phase) =>
      phase == UpdatePhase.available ||
      phase == UpdatePhase.downloading ||
      phase == UpdatePhase.ready ||
      phase == UpdatePhase.installDenied;

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
    this.checkThrottle = const Duration(hours: 24),
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// Deadline del chequeo. Es inyectable para poder testear el cuelgue sin
  /// esperar 10 s de reloj.
  final Duration checkTimeout;

  /// Ventana mínima entre chequeos al manifiesto (GitHub no se pega en cada
  /// arranque ni en cada vuelta a primer plano).
  final Duration checkThrottle;

  /// Último chequeo que respondió (sea que haya update o no). `null` = nunca.
  DateTime? _lastCheck;

  /// Fija [_lastCheck] (tests del throttle, sin esperar 24 h de reloj).
  @visibleForTesting
  void debugSetLastCheck(DateTime? value) => _lastCheck = value;

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
  ///
  /// Throttle de [checkThrottle]: si el último chequeo respondió hace menos
  /// que eso, no se pega a la red y se devuelve lo ya sabido. Un fallo NO
  /// consume la ventana (si no, un corte de red silencia el update 24 h).
  /// `force` es para "buscar ahora" explícito.
  Future<bool> check({bool force = false}) async {
    if (_state.busy) return false;
    final now = DateTime.now();
    if (!force &&
        _lastCheck != null &&
        now.difference(_lastCheck!) < checkThrottle) {
      return _state.phase == UpdatePhase.available ||
          _state.phase == UpdatePhase.downloading ||
          _state.phase == UpdatePhase.ready;
    }
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
      // El APK se baja al teléfono: http pelado es un update inyectable.
      if (!info.apkUrl.toLowerCase().startsWith('https://')) {
        _emit(
          const UpdateState(
            phase: UpdatePhase.failed,
            error: 'el manifiesto trae una URL de APK que no es https',
          ),
        );
        return false;
      }
      // Sin sha256 no hay qué verificar antes de `ready`: instalar un APK sin
      // huella es instalar a ciegas.
      if (info.sha256.isEmpty) {
        _emit(
          const UpdateState(
            phase: UpdatePhase.failed,
            error: 'el manifiesto no trae sha256 del APK',
          ),
        );
        return false;
      }
      if (info.versionCode <= await versionCode) {
        // Ya estamos al día: se vuelve a `idle` (no `failed`) para que el
        // banner no insinúe que algo anda mal.
        _lastCheck = now;
        _emit(const UpdateState());
        return false;
      }
      _lastCheck = now;
      _emit(UpdateState(phase: UpdatePhase.available, info: info));
      return true;
    } catch (e) {
      _emit(UpdateState(phase: UpdatePhase.failed, error: '$e'));
      return false;
    }
  }

  /// Baja el APK a la carpeta que el `FileProvider` declara compartida.
  ///
  /// Antes de `ready` se verifica el SHA-256 contra el manifiesto: un APK que
  /// no coincide se borra y no se ofrece para instalar. [cancelDownload]
  /// detiene la descarga en curso (cierra el sink y borra el parcial).
  Future<bool> download() async {
    // Idempotente: si ya terminÃ³, no se vuelve a bajar nada.
    if (_state.phase == UpdatePhase.ready) return true;
    final info = _state.info;
    if (info == null) return false;
    _cancel = false;
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
      // descarga entera y aparece directo el boton Instalar. Con sha en el
      // manifiesto se verifica: un parcial con el nombre justo y más de 2 MB
      // pasaba el piso de tamaño y llegaba al instalador truncado.
      final existing = await _alreadyDownloaded(info);
      if (existing != null) {
        if (info.sha256.isNotEmpty) {
          if (await sha256File(existing) == info.sha256) {
            _emit(
              UpdateState(
                phase: UpdatePhase.ready,
                info: info,
                received: existing.lengthSync(),
              ),
            );
            await discardApks(keepVersion: info.version);
            return true;
          }
          await _borrarSiExiste(existing);
        } else {
          _emit(
            UpdateState(
              phase: UpdatePhase.ready,
              info: info,
              received: existing.lengthSync(),
            ),
          );
          return true;
        }
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
          // Cancelar abandona: se deja de escribir y el `finally` cierra el
          // sink y borra el parcial.
          if (_cancel) break;
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
        completo = !_cancel;
      } finally {
        await sink.close();
        if (!completo) await _borrarSiExiste(file);
      }
      if (_cancel) {
        _emit(
          _state.copyWith(
            phase: UpdatePhase.failed,
            error: 'descarga cancelada',
          ),
        );
        return false;
      }
      // La verificación va ANTES de `ready`: un APK que no coincide con el
      // manifiesto no se instala ni se guarda.
      if (info.sha256.isNotEmpty) {
        if (await sha256File(file) != info.sha256) {
          await _borrarSiExiste(file);
          _emit(
            _state.copyWith(
              phase: UpdatePhase.failed,
              error: 'el APK bajado no coincide con el manifiesto '
                  '(sha256 distinto): no se instala nada',
            ),
          );
          return false;
        }
      }
      _emit(
        _state.copyWith(phase: UpdatePhase.ready, received: file.lengthSync()),
      );
      // Los APK viejos son 53 MB de cache que nadie vuelve a instalar.
      await discardApks(keepVersion: info.version);
      return true;
    } catch (e) {
      _emit(_state.copyWith(phase: UpdatePhase.failed, error: '$e'));
      return false;
    }
  }

  /// Cancela la descarga en curso. Cierra el sink y borra el parcial (ver
  /// [download]); fuera de `downloading` no hace nada.
  void cancelDownload() {
    if (_state.phase != UpdatePhase.downloading) return;
    _cancel = true;
  }

  bool _cancel = false;

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
  ///
  /// [keepVersion] no se borra: se llama tras una descarga ok para que sólo
  /// quede el APK listo para instalar.
  Future<void> discardApks({String? keepVersion}) async {
    final dir = await _updatesDir();
    if (dir == null) return;
    try {
      for (final f in Directory(dir).listSync().whereType<File>()) {
        if (!f.path.endsWith('.apk')) continue;
        if (keepVersion != null &&
            f.path.endsWith('openher-$keepVersion.apk')) {
          continue;
        }
        f.deleteSync();
      }
    } on FileSystemException {
      // Borrar es limpieza: si falla, no es un error de la app.
    }
  }

  /// SHA-256 en hex de unos bytes (manifiesto de tests y verificación).
  static String sha256Hex(List<int> bytes) => _Sha256.ofBytes(bytes);

  /// SHA-256 en hex de un archivo, por bloques: el APK pesa decenas de MB y
  /// no se carga entero a memoria.
  static Future<String> sha256File(File file) async {
    final hash = _Sha256();
    await for (final chunk in file.openRead()) {
      hash.add(chunk);
    }
    return hash.hex();
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
    // lleva al usuario a la pantalla donde se concede y se queda en la fase
    // `installDenied` con el motivo, en vez de un `false` silencioso.
    final can = await _tryChannel(
      () => _installChannel.invokeMethod<bool>('canRequestPackageInstalls'),
    );
    if (can == false) {
      await _tryChannel(
        () => _installChannel.invokeMethod<bool>('openInstallSettings'),
      );
      _emit(
        UpdateState(
          phase: UpdatePhase.installDenied,
          info: info,
          error: 'Falta el permiso para instalar aplicaciones: se abrieron '
              'los ajustes para concederlo. Volvé e instalá de nuevo.',
        ),
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

/// SHA-256 puro en Dart, sin dependencias.
///
/// `pubspec.yaml` no es de este módulo y no se agrega `crypto` por un solo
/// hash: son las 64 rondas del estándar, verificadas contra los vectores
/// (`abc`, cadena vacía) en `test/update_test.dart`.
class _Sha256 {
  _Sha256() {
    _h.setAll(0, _initial);
  }

  static const List<int> _initial = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];

  static const List<int> _k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  final List<int> _h = List<int>.filled(8, 0);
  final List<int> _buf = <int>[];
  int _len = 0;

  static int _rotr(int x, int n) =>
      ((x >> n) | (x << (32 - n))) & 0xffffffff;

  void add(List<int> bytes) {
    _buf.addAll(bytes);
    _len += bytes.length;
    while (_buf.length >= 64) {
      _compress(_buf.sublist(0, 64));
      _buf.removeRange(0, 64);
    }
  }

  /// Hex del digest. Agrega el padding (`0x80`, ceros hasta 56 mod 64 y el
  /// largo en bits en 8 bytes big-endian) y procesa los bloques finales.
  String hex() {
    final bitLen = _len * 8;
    var pad = 56 - (_len % 64);
    if (pad <= 0) pad += 64;
    final tail = List<int>.filled(pad + 8, 0);
    tail[0] = 0x80;
    for (var i = 0; i < 8; i++) {
      tail[pad + i] = (bitLen >> (56 - i * 8)) & 0xff;
    }
    add(tail);
    final out = StringBuffer();
    for (final v in _h) {
      out.write(v.toRadixString(16).padLeft(8, '0'));
    }
    return out.toString();
  }

  void _compress(List<int> block) {
    final w = List<int>.filled(64, 0);
    for (var i = 0; i < 16; i++) {
      w[i] =
          (block[i * 4] << 24) |
          (block[i * 4 + 1] << 16) |
          (block[i * 4 + 2] << 8) |
          block[i * 4 + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 =
          _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 =
          _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }
    var a = _h[0];
    var b = _h[1];
    var c = _h[2];
    var d = _h[3];
    var e = _h[4];
    var f = _h[5];
    var g = _h[6];
    var h = _h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e) & g);
      final t1 = (h + s1 + ch + _k[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    _h[0] = (_h[0] + a) & 0xffffffff;
    _h[1] = (_h[1] + b) & 0xffffffff;
    _h[2] = (_h[2] + c) & 0xffffffff;
    _h[3] = (_h[3] + d) & 0xffffffff;
    _h[4] = (_h[4] + e) & 0xffffffff;
    _h[5] = (_h[5] + f) & 0xffffffff;
    _h[6] = (_h[6] + g) & 0xffffffff;
    _h[7] = (_h[7] + h) & 0xffffffff;
  }

  static String ofBytes(List<int> bytes) {
    final hash = _Sha256()..add(bytes);
    return hash.hex();
  }
}
