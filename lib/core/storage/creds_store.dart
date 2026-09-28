/// Credenciales del server opencode, cifradas en el dispositivo.
///
/// Decisión D2 del plan: en Android **no existe** `service.json` (a diferencia de
/// opencode v1) y no hay disco del PC donde leerlo, así que las credenciales las
/// da el usuario por la pantalla de conectar y se guardan acá, en
/// `flutter_secure_storage` (Keystore de Android).
///
/// ## El payload es un secreto
/// Lo que se escribe es el JSON de [ServerConfig.toJson], que **incluye la
/// contraseña**. Por eso en este archivo no hay un solo `print`/`debugPrint` y
/// [CredsStore.toString] no revela nada: sólo el nombre de la clave. Para
/// cualquier texto que vaya a una UI o a un log, pasalo por [redactSecret].
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../network/server_config.dart';

/// Almacenamiento cifrado clave→valor, en la forma mínima que necesita
/// [CredsStore].
///
/// Existe para dos cosas: (1) no atar el store al plugin (los tests corren sin
/// canal de plataforma) y (2) tener **una sola** implementación del guardado, no
/// una por consumidor.
abstract interface class KeyValueSecureStore {
  /// Valor crudo, o `null` si la clave no existe.
  Future<String?> read(String key);

  /// Guarda [value] **cifrado**. Sobrescribe si ya existía.
  Future<void> write(String key, String value);

  /// Borra la clave. No tira si no existía.
  Future<void> delete(String key);
}

/// Adaptador sobre el plugin real.
class FlutterSecureStore implements KeyValueSecureStore {
  const FlutterSecureStore(this.storage);

  final FlutterSecureStorage storage;

  @override
  Future<String?> read(String key) => storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

/// Backend de memoria, para tests.
///
/// Lleva contadores porque la UI necesita poder afirmar cosas que con el
/// plugin real no se ven: que "Probar conexión" **no** guarda, que "Cerrar
/// sesión" borra de verdad.
class InMemorySecureStore implements KeyValueSecureStore {
  InMemorySecureStore([Map<String, String>? seed])
    : values = <String, String>{...?seed};

  final Map<String, String> values;

  /// Escrituras servidas. Deuda de contrato para los tests de la UI.
  int writes = 0;

  /// Borrados servidos.
  int deletes = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deletes++;
    values.remove(key);
  }
}

/// Lectura/escritura de las credenciales del server.
///
/// Inyectable por constructor: en la app se usa el plugin de Android, en los
/// tests un [InMemorySecureStore].
///
/// ### Corrupción
/// [read] **no tira**: un payload que no es JSON, o que no es un objeto, se
/// traduce a `null` (= "no hay credenciales") en vez de reventar el arranque de
/// la app. Un almacenamiento cifrado que se corrompió (cambio de clave de
/// Keystore, restore de un backup) no puede ser la razón de que la app no
/// abra; como mucho, de que vuelva a pedir conectar.
class CredsStore {
  CredsStore({KeyValueSecureStore? store, FlutterSecureStorage? storage})
    : _store = store ?? FlutterSecureStore(storage ?? _defaultStorage);

  /// Clave única del payload. El sufijo `v2` es el dialecto: si alguna vez se
  /// migra el formato, la clave nueva convive con la vieja sin pisarla.
  static const String storageKey = 'openher.server.v2';

  final KeyValueSecureStore _store;

  /// Backend effective. Útil para tests y para inspeccionar sin castear.
  KeyValueSecureStore get store => _store;

  /// `EncryptedSharedPreferences` (API 23+): la clave de cifrado vive en la
  /// Keystore de Android, no en el XML de preferencias. Si el dispositivo no
  /// puede descifrar, el plugin se resetea en vez de fallar cada arranque.
  static const FlutterSecureStorage _defaultStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Config guardada, o `null` si no hay ninguna o si está corrupta.
  Future<ServerConfig?> read() async {
    final raw = await _store.read(storageKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return ServerConfig.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } on FormatException {
      return null;
    }
  }

  /// Guarda [config] (incluida la contraseña, cifrada por el backend).
  Future<void> write(ServerConfig config) =>
      _store.write(storageKey, jsonEncode(config.toJson()));

  /// Borra las credenciales. Idempotente.
  Future<void> clear() => _store.delete(storageKey);

  /// Última [ServerConfig] leída, para no volver a pegarle a la Keystore en
  /// cada build. `null` hasta que se llama a [load] o a [remember].
  ServerConfig? _cached;

  /// [read] memoizado: el arranque y las pantallas repiten el acceso, y la
  /// Keystore no es gratis.
  Future<ServerConfig?> load() async => _cached ??= await read();

  /// Remembered config, sin `await`. `null` hasta que se llama a [load].
  ServerConfig? get cached => _cached;

  /// Inyecta la config en memoria (arranque o tests). No persiste.
  void remember(ServerConfig? config) => _cached = config;

  /// Sincroniza la caché con lo que hay en disco, o la limpia.
  Future<ServerConfig?> refresh() async {
    _cached = await read();
    return _cached;
  }

  /// Sólo la clave. **Nunca** incluye la contraseña.
  @override
  String toString() => 'CredsStore($storageKey)';
}

/// Reemplaza [secret] por `***` en [text].
///
/// Última línea de defensa antes de que un mensaje de error del server (que no
/// controla esta app) llegue a una `Text` o a un log. Con [secret] vacío no
/// toca nada: `replaceAll('')` partiría la cadena en trozos.
String redactSecret(String text, String secret) =>
    secret.isEmpty ? text : text.split(secret).join('***');
