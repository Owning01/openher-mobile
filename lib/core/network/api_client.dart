import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../domain/models/errors.dart';
import 'server_config.dart';

/// Una página de la envoltura v2 `{"data": […], "cursor": {previous, next}}`.
///
/// El cursor es base64 de algo tipo `{"id":"msg_…","order":"desc","direction":"next"}`
/// y se devuelve tal cual: el server lo owns, la app no lo interpreta
/// (`API_CONTRACT.md` §2). [next] es "cargar más".
class ApiPage {
  const ApiPage(this.data, {this.next, this.previous});

  final List<dynamic> data;
  final String? next;
  final String? previous;

  bool get hasMore => next != null && next!.isNotEmpty;
}

/// Política de espera entre reintentos: recibe el intento (0-based) y devuelve el delay.
typedef Backoff = Duration Function(int attempt);

/// Cliente HTTP del dialecto v2 (`/api/*`) de opencode.
///
/// Devuelve **JSON crudo** (`Map` / `List` / `null`); mapear a modelos es tarea
/// del repository, no de la red. Los errores se **lanzan** tipados desde
/// `OchError` (el server puede fallar de 4 maneras distintas y la UI las pinta
/// distinto): nunca se devuelve `null` para señalar un fallo.
///
/// - [getJson] reintenta **una** vez ante un fallo de transporte; [postJson]
///   nunca reintenta (un POST repetido duplica el prompt).
/// - Deadline: [probeTimeout] para el probe de versión, [defaultTimeout] para
///   el resto. Es un deadline total (connect + read), porque `package:http` no
///   separa los dos.
/// - Nunca manda un query param no declarado: el middleware responde **400** a
///   params que no están en el schema (`workspace-routing.ts:17-21`).
class ApiClient {
  ApiClient({
    required this.config,
    http.Client? client,
    Duration? timeout,
    Backoff? backoff,
    Random? random,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _timeout = timeout ?? defaultTimeout,
       _backoff = backoff ?? defaultBackoff,
       _random = random ?? Random();

  /// Deadline del probe de versión: si en 3 s no responde, no es un server
  /// opencode v2 alcanzable y hay que decirlo ya.
  static const Duration probeTimeout = Duration(seconds: 3);

  /// Deadline de una request normal.
  static const Duration defaultTimeout = Duration(seconds: 15);

  /// Un solo reintento en GET. Suficiente para un fallo de transporte puntual
  /// sin duplicar requests ni alargar la espera de error en la UI.
  static const int maxRetries = 1;

  final ServerConfig config;

  final http.Client _client;
  final bool _ownsClient;
  final Duration _timeout;
  final Backoff _backoff;
  final Random _random;

  Duration get timeout => _timeout;

  // ───────────────────────────── requests crudas ─────────────────────────────

  /// `GET` a un path de [ServerConfig.apiPrefix] y devuelve el JSON decodificado
  /// (el sobre entero: `{"data": …, "cursor": …}`), o `null` si vino `204`/vacío.
  Future<dynamic> getJson(
    String path, {
    Map<String, String?> query = const {},
  }) => _send('GET', path, query: query, timeout: _timeout, allowRetry: true);

  /// `POST` JSON. **Nunca** reintenta. Devuelve el JSON decodificado o `null`
  /// (los endpoints que devuelven `204` no tienen cuerpo).
  Future<dynamic> postJson(
    String path, {
    Object? body,
    Map<String, String?> query = const {},
  }) => _send(
    'POST',
    path,
    query: query,
    body: body,
    timeout: _timeout,
    allowRetry: false,
  );

  // ───────────────────────────── endpoints v2 ───────────────────────────────

  /// `GET /api/location` — resuelve el directorio del server.
  Future<Map<String, dynamic>> location({String? directory}) =>
      _object('/location', directory: directory);

  /// **Probe de versión.** Acepta el server si y solo si `/api/location`
  /// devuelve JSON con `directory`.
  ///
  /// `GET /api/health` **no** sirve: da 404 en el build medido
  /// (`API_CONTRACT.md` §1.6). Y `/global/health` (v1) devuelve el catch-all.
  ///
  /// Si responde HTML, o 404, o 401 ⇒ no es un opencode v2 soportado por la app
  /// (decisión D1: error explícito, no modo dual) ⇒ [UnsupportedServerError].
  Future<Map<String, dynamic>> probeServer() async {
    try {
      final body = await _send(
        'GET',
        '/location',
        query: const {},
        timeout: probeTimeout,
        allowRetry: false,
      );
      final map = body is Map<String, dynamic> ? body : null;
      if (map == null || map['directory'] is! String) {
        throw UnsupportedServerError(
          'ese host respondió JSON pero no es opencode v2 (sin "directory")',
        );
      }
      return map;
    } on AuthError catch (e) {
      // 401 en el probe = credenciales, no dialecto. El tipo sigue siendo
      // "no soportado" para que la pantalla de conectar muestre un solo error
      // accionable, pero el motivo dice la causa real.
      throw UnsupportedServerError('credenciales rechazadas: ${e.message}');
    } on UnsupportedServerError {
      rethrow;
    } on OchError catch (e) {
      throw UnsupportedServerError('${e.message}');
    }
  }

  /// `GET /api/session` — lista paginada.
  Future<ApiPage> listSessions({
    int? limit,
    String? order,
    String? search,
    String? cursor,
    String? directory,
  }) => _page('/session', <String, String?>{
    'limit': limit?.toString(),
    'order': order,
    'search': search,
    'cursor': cursor,
  }, directory);

  /// `POST /api/session` — crea una sesión y devuelve el objeto creado.
  Future<Map<String, dynamic>> createSession({
    String? id,
    String? agent,
    String? modelId,
    String? providerId,
    String? variant,
    String? directory,
  }) {
    // `'clave': ?valor` = elemento null-aware: la clave no se manda si el valor
    // es null (el server ignora campos ausentes, no mandarlos es lo correcto).
    final model = (modelId == null || providerId == null)
        ? null
        : <String, dynamic>{
            'id': modelId,
            'providerID': providerId,
            'variant': ?variant,
          };
    return _object(
      '/session',
      method: 'POST',
      directory: directory,
      body: <String, dynamic>{
        'id': ?id,
        'agent': ?agent,
        'model': ?model,
        'location': ?directory,
      },
    );
  }

  /// `GET /api/session/active` — `{"data": {"ses_…": {"type": "running"}}}`.
  /// Es el polling barato de los dots "en ejecución" de la lista.
  Future<Map<String, dynamic>> activeSessions({String? directory}) =>
      _object('/session/active', directory: directory);

  /// `GET /api/session/{id}/message` — mensajes de la sesión, paginados.
  Future<ApiPage> listMessages(
    String sessionId, {
    int? limit,
    String? order,
    String? cursor,
    String? directory,
  }) => _page('/session/$sessionId/message', <String, String?>{
    'limit': limit?.toString(),
    'order': order,
    'cursor': cursor,
  }, directory);

  /// `POST /api/session/{id}/prompt` — **admitir** el prompt.
  ///
  /// No devuelve el turno: devuelve el "admitido" y el turno llega por el SSE
  /// de la sesión (decisión D4, `API_CONTRACT.md` §8 "regla de oro del streaming").
  Future<Map<String, dynamic>> sendPrompt(
    String sessionId, {
    required String text,
    String? id,
    String? delivery,
    String? directory,
    List<Map<String, String>>? files,
    List<String>? agents,
  }) => _object(
    '/session/$sessionId/prompt',
    method: 'POST',
    directory: directory,
    body: <String, dynamic>{
      'id': ?id,
      'prompt': <String, dynamic>{
        'text': text,
        if (files != null && files.isNotEmpty) 'files': files,
        if (agents != null && agents.isNotEmpty) 'agents': agents,
      },
      'delivery': ?delivery,
    },
  );

  /// `POST /api/session/{id}/interrupt` — detener el turno. No-op si ya estaba idle.
  Future<void> interrupt(String sessionId, {String? directory}) => postJson(
    '/session/$sessionId/interrupt',
    query: _withLocation(const {}, directory),
  );

  /// `GET /api/fs/list` — lista un directorio. `path` relativo al directory.
  Future<ApiPage> listDirectory({String? directory, String? path}) =>
      _page('/fs/list', <String, String?>{'path': path}, directory);

  /// `GET /api/fs/find` — busca archivos por nombre.
  Future<ApiPage> findFiles({
    String? directory,
    required String query,
    String? type,
    int? limit,
  }) => _page('/fs/find', <String, String?>{
    'query': query,
    'type': type,
    'limit': limit?.toString(),
  }, directory);

  // ───────────────────────────── envoltura ──────────────────────────────────

  /// Desenvuelve `{"data": …}`; si no hay `data`, devuelve el sobre entero.
  ///
  /// Existe porque **toda** lista/objeto de v2 viene envuelto y el modo dual
  /// quedó afuera (D1): un solo punto donde decidir.
  static dynamic unwrapData(dynamic body) =>
      body is Map && body.containsKey('data') ? body['data'] : body;

  /// Lee `cursor[direction]` (`"next"` por defecto). `null` si no hay.
  static String? readCursor(dynamic body, {String direction = 'next'}) {
    if (body is! Map) return null;
    final cursor = body['cursor'];
    if (cursor is! Map) return null;
    final value = cursor[direction];
    return value is String && value.isNotEmpty ? value : null;
  }

  // ───────────────────────────── plumbing ───────────────────────────────────

  /// `1s * 0.8^attempt`, tope 2 s. Sin jitter: el jitter se aplica en [_retryDelay].
  static Duration defaultBackoff(int attempt) => Duration(
    milliseconds: min(1000.0 * pow(0.8, attempt).toDouble(), 2000.0).round(),
  );

  Future<dynamic> _send(
    String method,
    String path, {
    required Map<String, String?> query,
    required Duration timeout,
    required bool allowRetry,
    Object? body,
  }) async {
    final uri = config.api(path, query: query);
    final attempts = allowRetry ? maxRetries + 1 : 1;
    Object? lastError;

    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        final streamed = await _client
            .send(_request(method, uri, body))
            .timeout(timeout);
        return _decode(await http.Response.fromStream(streamed));
      } on OchError {
        // Ya es un error tipado y determinístico (401, HTML, 5xx, JSON roto):
        // reintentar sólo alarga la espera del error en la UI.
        rethrow;
      } on TimeoutException {
        lastError = 'timeout';
      } on http.ClientException catch (e) {
        lastError = e.message;
      } on IOException catch (e) {
        // SocketException / HandshakeException que el cliente no envolvió.
        // `IOException` no trae `message`: se usa el texto del error.
        lastError = e.toString();
      }
      if (attempt + 1 < attempts)
        await Future<void>.delayed(_retryDelay(attempt));
    }
    throw NetworkError(lastError == null ? 'sin red' : '$lastError');
  }

  /// `1s * 0.8^attempt` con jitter ±20 %: dos devices que reconectan tras el
  /// mismo corte no lo hacen al mismo tick.
  Duration _retryDelay(int attempt) {
    final base = _backoff(attempt).inMicroseconds;
    final jitter = 1 + (_random.nextDouble() * 2 - 1) * 0.2;
    return Duration(microseconds: (base * jitter).round());
  }

  http.Request _request(String method, Uri uri, Object? body) {
    final request = http.Request(method, uri);
    request.headers['accept'] = 'application/json';
    final auth = config.basicAuthHeader;
    if (auth != null) request.headers['authorization'] = auth;
    if (body != null) request.body = jsonEncode(body);
    return request;
  }

  dynamic _decode(http.Response response, {String? path}) {
    final body = response.body;
    final status = response.statusCode;

    if (looksLikeHtml(response.headers['content-type'], body)) {
      throw HtmlFallbackError(path: path, statusCode: status);
    }
    if (status == 401 || status == 403) {
      throw AuthError(realm: response.headers['www-authenticate']);
    }
    if (status >= 400) {
      throw ApiError(statusCode: status, detail: _errorMessage(body));
    }
    if (status == 204 || body.trim().isEmpty) return null;

    try {
      return jsonDecode(body) as dynamic;
    } on FormatException {
      throw ApiError(
        statusCode: status,
        detail:
            'respuesta no JSON: '
            '${body.substring(0, body.length < 120 ? body.length : 120)}',
      );
    }
  }

  static dynamic _tryDecode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  /// Saca el mensaje de error que manda el server (`{"message": …}` / `{"_tag": …}`).
  static String _errorMessage(String body) {
    final decoded = _tryDecode(body);
    if (decoded is Map) {
      final message = decoded['message'];
      if (message is String && message.isNotEmpty) return message;
      final tag = decoded['_tag'];
      if (tag is String && tag.isNotEmpty) return tag;
    }
    return body.isEmpty
        ? 'sin cuerpo'
        : (body.length <= 120 ? body : '${body.substring(0, 120)}…');
  }

  Map<String, String?> _withLocation(
    Map<String, String?> query,
    String? directory,
  ) => directory == null || directory.isEmpty
      ? query
      : {...query, ServerConfig.locationParam: directory};

  Future<Map<String, dynamic>> _object(
    String path, {
    String method = 'GET',
    String? directory,
    Object? body,
  }) async {
    final query = _withLocation(const {}, directory);
    final raw = method == 'POST'
        ? await _send(
            'POST',
            path,
            query: query,
            body: body,
            timeout: _timeout,
            allowRetry: false,
          )
        : await _send(
            'GET',
            path,
            query: query,
            timeout: _timeout,
            allowRetry: true,
          );
    final data = unwrapData(raw);
    if (data is Map<String, dynamic>) return data;
    throw ApiError(
      statusCode: 200,
      detail: 'se esperaba un objeto en $path y vino ${data.runtimeType}',
    );
  }

  Future<ApiPage> _page(
    String path,
    Map<String, String?> query,
    String? directory,
  ) async {
    final raw = await _send(
      'GET',
      path,
      query: _withLocation(query, directory),
      timeout: _timeout,
      allowRetry: true,
    );
    final data = unwrapData(raw);
    return ApiPage(
      data is List ? data : const <dynamic>[],
      next: readCursor(raw),
      previous: readCursor(raw, direction: 'previous'),
    );
  }

  /// Cierra el cliente HTTP propio (inyectado no se toca: es del caller).
  void close() {
    if (_ownsClient) _client.close();
  }
}
