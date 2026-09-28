/// Errores del dominio de OpenHer Mobile.
///
/// Dos cosas distintas y **separadas a propósito**:
///
/// 1. [OchError] — la jerarquía sellada de excepciones que lanza la capa de red
///    (`lib/core/**`) y que la UI muestra al usuario. Siempre en español, con
///    [OchError.retriable] para decidir si vale la pena reintentar.
/// 2. [OcErrorInfo] — el **modelo del payload de error que devuelve el server**
///    (`assistant.error`, `tool.state.error`, `session.error`). No es una
///    excepción: es dato que se pinta en la burbuja de error del chat.
///
/// Forma medida (API_CONTRACT §5 + `packages/sdk/openapi.json`):
/// * v2 tool: `{"type":"unknown","message":"…"}` (`SessionErrorUnknown`)
/// * v2 message: `{"type":"provider.auth","message":"…","status":401}`
/// * v1/SDK: `{"name":"APIError","data":{"message":"…","isRetryable":true}}`
library;

import 'dart:convert';

/// Jerarquía sellada de fallos de transporte/proTOCOLO.
///
/// `ApiError` = el server respondió con un status HTTP no-2xx.
/// `AuthError` = 401/403 (credenciales).
/// `NetworkError` = no hubo respuesta (DNS, TLS, timeout, offline).
/// `HtmlFallbackError` = el server devolvió `text/html`: es el catch-all del
/// SPA, o sea que **la ruta no existe en este build** (medido: `/api/health`
/// y `/api/session/{id}/event` dan HTML o 404 en :4098).
sealed class OchError implements Exception {
  const OchError();

  /// Texto listo para pintar en la UI (español, sin jerga).
  String get message;

  /// `true` si volver a intentar el mismo request tiene sentido.
  bool get retriable;

  @override
  String toString() => '$runtimeType: $message';
}

/// El server respondió con un status HTTP ≥ 400.
final class ApiError extends OchError {
  const ApiError({required this.statusCode, this.detail});

  final int statusCode;

  /// Cuerpo crudo de la respuesta, si el parser lo dejó guardar. Para debug.
  final String? detail;

  @override
  String get message => switch (statusCode) {
    400 => 'El servidor rechazó el pedido (400).',
    401 || 403 => 'El servidor rechazó las credenciales.',
    404 => 'El servidor no tiene ese endpoint (404).',
    409 => 'Conflicto en el servidor (409).',
    413 => 'El prompt es demasiado grande para el modelo (413).',
    429 => 'El proveedor está limitando pedidos (429).',
    >= 500 => 'El servidor falló ($statusCode).',
    _ => 'El servidor respondió $statusCode.',
  };

  @override
  bool get retriable =>
      statusCode == 0 ||
      statusCode == 408 ||
      statusCode == 429 ||
      statusCode >= 500;
}

/// 401/403: usuario o contraseña del server opencode incorrectos.
final class AuthError extends OchError {
  const AuthError({this.realm});

  /// Valor de `www-authenticate: Basic realm="…"` si vino.
  final String? realm;

  @override
  String get message =>
      'Credenciales inválidas: revisá usuario y contraseña del servidor opencode.';

  @override
  bool get retriable => false;
}

/// No hubo respuesta: sin red, TLS, timeout o socket cortado.
final class NetworkError extends OchError {
  const NetworkError([this.detail]);

  final String? detail;

  @override
  String get message => 'No se pudo conectar con el servidor.';

  @override
  bool get retriable => true;
}

/// El server devolvió `text/html` en vez de JSON.
///
/// Trampa conocida del dialecto v2: **todo path desconocido cae al SPA** con
/// HTML 200, así que un parser ingenuo revienta al hacer `jsonDecode`.
final class HtmlFallbackError extends OchError {
  const HtmlFallbackError({this.path, this.statusCode});

  /// Path que se pidió, para que el error sea accionable.
  final String? path;

  final int? statusCode;

  @override
  String get message => path == null
      ? 'El servidor devolvió HTML en vez de JSON: el endpoint no existe.'
      : 'El servidor devolvió HTML en vez de JSON: "$path" no existe '
            'en este build o no estás en el dialecto v2.';

  @override
  bool get retriable => false;
}

/// El server respondió, pero **no es un opencode v2 que la app pueda usar**.
///
/// Ojo con la detección (medido en `docs/API_CONTRACT.md` §1.6): *todo* path
/// desconocido cae al catch-all del SPA y devuelve **HTML 200**, así que un
/// `404` no es la señal. El probe real es `GET /api/location`, y si eso no
/// devuelve JSON con `directory`, el server es v1 (o no es opencode).
///
/// Decisión D1: la app móvil habla **sólo v2**; en vez de mantener dos
/// dialectos, avisa explícitamente.
final class UnsupportedServerError extends OchError {
  const UnsupportedServerError(this.reason);

  /// Motivo concreto, para que la pantalla de conectar sea accionable.
  final String reason;

  @override
  String get message => 'Ese servidor no es un opencode v2 compatible: $reason';

  @override
  bool get retriable => false;
}

/// El payload de error **del server**, modelado. No es una excepción.
///
/// Se usa en los tres canales de error de `docs/API_CONTRACT.md` §5:
/// `assistant.error`, `tool.state.error` y el `data.error` de `session.error`.
///
/// Nunca tira: un payload raro produce `message: ''`.
final class OcErrorInfo {
  const OcErrorInfo({this.name, this.message = '', this.data = const {}});

  factory OcErrorInfo.fromJson(Object? raw) {
    if (raw is String) return OcErrorInfo(message: raw);
    final m = asMap(raw);
    if (m == null) return const OcErrorInfo();
    // `data` es el sobre de los errores del SDK v1 ({name, data:{message}});
    // si no está, el resto del payload crudo sirve igual.
    final data = asMap(m['data']) ?? m;
    final name = asStr(m['name']) ?? asStr(m['type']);
    final message =
        asStr(m['message']) ??
        asStr(data['message']) ??
        asStr(m['error']) ??
        asStr(m['text']) ??
        '';
    return OcErrorInfo(name: name, message: message, data: data);
  }

  /// Discriminador del error: `APIError`, `ProviderAuthError`,
  /// `ContextOverflowError`… (v1) o `provider.auth`, `tool.execution`,
  /// `unknown` (v2 medido). `null` si el payload no lo trajo.
  final String? name;

  /// Texto para humanos. Viene de `message`; si el payload lo anida en
  /// `data.message` también se acepta. Nunca `null`.
  final String message;

  /// El sobre `data` del error, o el payload crudo si no lo tenía.
  final Map<String, Object?> data;

  @override
  String toString() => name == null ? message : '$name: $message';
}

// ---------------------------------------------------------------------------
// Lectores de JSON totales. Viven acá porque `errors.dart` es la base de la
// cadena de imports del dominio (errors → tool → message → session).
// Ninguno tira: un valor ausente o de otro tipo devuelve el default.
// ---------------------------------------------------------------------------

/// `[a, b]` o `null`.
List<Object?>? asList(Object? raw) {
  if (raw is List) return raw;
  if (raw is Iterable) return raw.toList();
  return null;
}

/// `{...}` o `null`. Tolera `Map<dynamic, dynamic>`.
Map<String, Object?>? asMap(Object? raw) {
  if (raw is Map) {
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }
  return null;
}

/// `String` o `null` (no castea: un número no es un string).
String? asStr(Object? raw) => raw is String ? raw : null;

/// `int` o `null`. Acepta `double`/`num` y los trunca.
int? asInt(Object? raw) => raw is num ? raw.toInt() : null;

/// `double` o `null`. Acepta `int`.
double? asNum(Object? raw) => raw is num ? raw.toDouble() : null;

/// `bool` o `null` (no castea: `"true"` no es `true`).
bool? asBool(Object? raw) => raw is bool ? raw : null;

/// Lista de strings, tolerando items que sean mapas con `name`/`text`
/// (`input.agents` es `[{name, source}]`, pero algunos builds mandan strings).
List<String> asStringList(Object? raw) {
  final list = asList(raw);
  if (list == null) return const [];
  return [
    for (final item in list)
      if (asStr(item) case final String s)
        s
      else if (asStr(asMap(item)?['name']) case final String s)
        s
      else
        '',
  ];
}

/// Lista de mapas, descartando los items que no son mapas.
List<Map<String, Object?>> asMapList(Object? raw) {
  final list = asList(raw);
  if (list == null) return const [];
  return [
    for (final item in list)
      if (asMap(item) case final Map<String, Object?> m) m,
  ];
}

/// Pretty-print de un input de tool para la card.
String prettyJson(Object? value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } on JsonUnsupportedObjectError {
    return value.toString();
  }
}
