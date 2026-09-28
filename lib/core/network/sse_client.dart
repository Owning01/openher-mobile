import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../domain/models/event.dart';
import 'server_config.dart';

/// Estado visible del stream. La UI lo pinta como banner ("reconectando...").
enum StreamState {
  /// El SSE no está disponible: se está poll-eando por REST (fallback tras 5 intentos).
  polling,

  /// Conectado y recibiendo.
  streaming,

  /// Se cayó la conexión; esperando el backoff para reconectar.
  reconnecting,
}

/// Resultado de parsear un trozo del buffer. Todo lo que devuelve
/// [parseSseChunk] sale del string: sin I/O, sin estado, testeable sin server.
class SseParseResult {
  const SseParseResult({
    required this.events,
    required this.consumed,
    this.sawComment = false,
    this.lastEventId,
    this.maxSeq,
    this.malformed = 0,
  });

  /// Eventos decodificados de los frames **completos** del buffer.
  final List<OcEvent> events;

  /// Caracteres del buffer ya consumidos. Lo que sigue es un frame a medio
  /// llegar y queda para la próxima lectura.
  final int consumed;

  /// Hubo una línea de comentario (`: heartbeat`). En v2 el heartbeat **es** un
  /// comentario SSE, no un evento (`packages/server/src/handlers/event.ts:37`):
  /// es señal de vida y no debe emitir nada.
  final bool sawComment;

  /// Último `id` conocido (el de la línea SSE, o el del JSON del último frame).
  final String? lastEventId;

  /// Mayor `id` **numérico** visto. Sirve para reconectar con `?after=<seq>`
  /// sin perder eventos (el stream por sesión es durable y resumible).
  final int? maxSeq;

  /// Frames con `data:` que no era un objeto JSON. Se cuentan y se descartan:
  /// un frame roto no puede tumbar el stream.
  final int malformed;

  /// Hubo algo (evento o comentario) => la conexión está viva.
  bool get alive => sawComment || events.isNotEmpty;
}

/// Parsea un buffer SSE y devuelve los eventos de los frames **terminados** en
/// `\n\n`.
///
/// Función pura y sin server: es la única pieza que entiende el formato, y la
/// usan tanto el [SseClient] (por red) como el test (con strings).
///
/// Reglas medidas (v2, `docs/API_CONTRACT.md` §7):
/// - Un frame son líneas separadas por una línea vacía. Cada línea es
///   `campo: valor`; un comentario empieza con `:` y **no** es un evento.
/// - `data:` puede repetirse: se une con `\n` (spec SSE).
/// - El JSON es `{id, event, data}` en el stream **por sesión** (la clave del
///   tipo es `event`) y `{id, type, data}` en el global. Se aceptan ambos.
/// - El payload está en `data`; `properties` es la clave v1 y se acepta como
///   fallback para no romper si alguien apunta a un server viejo.
/// - Un buffer a medio frame no se parsea: [SseParseResult.consumed] lo deja
///   para la próxima llamada, que lo reprocesa pasando `offset:`.
SseParseResult parseSseChunk(String buffer, {int offset = 0}) {
  final events = <OcEvent>[];
  var sawComment = false;
  var malformed = 0;
  var consumed = offset;
  String? lastEventId;
  int? maxSeq;

  var i = offset;
  while (true) {
    final boundary = _frameBoundary(buffer, i);
    if (boundary == null) break;
    final frame = _parseFrame(buffer.substring(i, boundary.frameEnd));
    i = boundary.next;
    consumed = i;

    if (frame.comment) sawComment = true;
    if (frame.id != null) lastEventId = frame.id;
    if (frame.data == null || frame.data!.trim().isEmpty) continue;

    final Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(frame.data!);
      if (decoded is! Map) {
        malformed++;
        continue;
      }
      json = Map<String, dynamic>.from(decoded);
    } on FormatException {
      malformed++;
      continue;
    }

    // Único punto del archivo que conoce el shape del payload del server.
    final rawId = json['id'] ?? frame.id;
    // `event` gana: es el stream por sesión. `type` es el global. El nombre de
    // la línea `event:` es el último recurso (el server manda `event: message`).
    final rawType =
        json['event'] ??
        json['type'] ??
        (frame.eventName != null && frame.eventName != 'message'
            ? frame.eventName
            : null);
    final payload = json['data'] ?? json['properties'];

    final seq = rawId is int ? rawId : int.tryParse('$rawId');
    if (seq != null && (maxSeq == null || seq > maxSeq)) maxSeq = seq;
    lastEventId ??= rawId == null ? null : '$rawId';

    events.add(
      OcEvent(
        id: rawId == null ? '' : '$rawId',
        type: rawType == null ? '' : '$rawType',
        data: payload is Map
            ? Map<String, dynamic>.from(payload)
            : <String, dynamic>{},
      ),
    );
  }

  return SseParseResult(
    events: events,
    consumed: consumed,
    sawComment: sawComment,
    lastEventId: lastEventId,
    maxSeq: maxSeq,
    malformed: malformed,
  );
}

// ───────────────────────────── frames SSE ───────────────────────────────────

const int _lf = 0x0a;
const int _cr = 0x0d;

class _Boundary {
  const _Boundary(this.frameEnd, this.next);
  final int frameEnd;
  final int next;
}

/// Primer separador de frame (línea en blanco) desde [from]: `\n\n`, `\n\r\n`,
/// `\r\n\r\n` o `\r\r`. `null` si el frame todavía está a medias.
_Boundary? _frameBoundary(String buffer, int from) {
  for (var i = from; i < buffer.length; i++) {
    final c = buffer.codeUnitAt(i);
    if (c == _lf) {
      if (i + 1 >= buffer.length) return null;
      final next = buffer.codeUnitAt(i + 1);
      if (next == _lf) return _Boundary(i, i + 2);
      if (next == _cr) {
        // `\n\r...` puede ser un `\n\r\n` a medio llegar: esperar más datos en
        // vez de emitir un frame partido.
        if (i + 2 >= buffer.length) return null;
        return _Boundary(i, i + 3);
      }
    } else if (c == _cr) {
      if (i + 1 < buffer.length && buffer.codeUnitAt(i + 1) == _cr)
        return _Boundary(i, i + 2);
    }
  }
  return null;
}

class _Frame {
  const _Frame(this.data, this.eventName, this.id, this.comment);
  final String? data;
  final String? eventName;
  final String? id;
  final bool comment;
}

_Frame _parseFrame(String frame) {
  final data = StringBuffer();
  var hasData = false;
  var comment = false;
  String? eventName;
  String? id;

  for (final raw in frame.split('\n')) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (line.isEmpty) continue;
    // Comentario SSE. En v2 el heartbeat llega así (`: heartbeat` cada 15 s):
    // es liveness, y si no se ignora se cuela un evento basura a la UI.
    if (line.startsWith(':')) {
      comment = true;
      continue;
    }
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    // Sólo UN espacio inicial forma parte del separador (spec SSE).
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'data':
        if (hasData) data.write('\n');
        data.write(value);
        hasData = true;
      case 'event':
        eventName = value;
      case 'id':
        id = value;
    }
  }

  return _Frame(hasData ? data.toString() : null, eventName, id, comment);
}

// ───────────────────────────── cliente ──────────────────────────────────────

/// Stream de eventos de **una** sesión: `GET /api/session/{id}/event?after=<seq>`.
///
/// Por qué el stream por sesión y no el global (`docs/API_CONTRACT.md` §7.1): es
/// durable y acepta `?after=`, así que reconectar no pierde el turno. El global
/// no manda `Last-Event-ID` y obliga a re-snapshotear.
///
/// Dos detalles que el server no perdona:
/// - **Nunca** mandar `sessionID` como query del stream: no está declarado en el
///   schema y el middleware responde **400**. El filtro por sesión es cliente.
/// - La auth va en `?auth_token=` (carrier que el server chequea antes del
///   header). La URL se redacta antes de cualquier log.
class SseClient {
  SseClient({
    required this.config,
    required this.sessionId,
    http.Client? client,
    this.directory,
    this.watchdog = const Duration(seconds: 45),
    this.connectTimeout = const Duration(seconds: 10),
    this.maxAttempts = 5,
    this.baseBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    Random? random,
    this.onPollFallback,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _random = random ?? Random();

  final ServerConfig config;
  final String sessionId;

  /// Deadline de lectura: si pasan 45 s sin un solo byte (ni un comentario), la
  /// conexión está colgada y hay que reconectar. El heartbeat de v2 es cada
  /// 15 s, así que 45 s es margen de sobra.
  final Duration watchdog;

  final Duration connectTimeout;

  /// Intentos de reconexión seguidos antes de rendirse y pedir polling.
  final int maxAttempts;

  final Duration baseBackoff;
  final Duration maxBackoff;
  final String? directory;

  /// Se llama cuando el SSE se rinde. El handoff al polling es del repository
  /// (que ya sabe traer mensajes por REST); este cliente sólo avisa y se
  /// detiene, para no dejar dos bombas de timers vivas.
  final void Function(int attempts)? onPollFallback;

  final http.Client _client;
  final bool _ownsClient;
  final Random _random;

  final StreamController<OcEvent> _events =
      StreamController<OcEvent>.broadcast();
  final StreamController<StreamState> _states =
      StreamController<StreamState>.broadcast();
  StreamSubscription<String>? _subscription;
  Timer? _watchdogTimer;
  final StringBuffer _buffer = StringBuffer();

  bool _closed = false;
  bool _alive = false;
  int _offset = 0;
  int? _lastSeq;
  StreamState _state = StreamState.polling;
  Future<void>? _loop;

  /// Eventos de la sesión, en orden. Broadcast: la UI y el watchdog pueden mirar
  /// sin pelearse por la suscripción.
  Stream<OcEvent> get events => _events.stream;

  /// Cambios de estado (para el banner). El estado actual está en [state].
  Stream<StreamState> get stateChanges => _states.stream;

  StreamState get state => _state;

  /// `?after=` del próximo intento: el mayor `id` numérico ya entregado.
  int? get lastSeq => _lastSeq;

  /// URL del stream, con `auth_token` y **sin** `sessionID`. Contiene la
  /// credencial: para mostrarla o loguearla, pasarla por
  /// [ServerConfig.redactAuthToken].
  Uri streamUri({int? after}) => config.api(
    '/session/$sessionId/event',
    query: <String, String?>{
      'after': (after ?? _lastSeq)?.toString(),
      if (config.authTokenQuery != null)
        ServerConfig.authTokenParam: config.authTokenQuery,
      if (directory != null && directory!.isNotEmpty)
        ServerConfig.locationParam: directory,
      // OJO: acá NO va `sessionID`. No está declarado en el schema del
      // stream y el server responde 400 (§7.3).
    },
  );

  /// Arranca el loop. Idempotente.
  void connect() {
    if (_closed || _loop != null) return;
    _loop = _run();
  }

  /// `1s * 1.8^attempt`, tope [maxBackoff], con jitter ±30 %: dos devices que
  /// reconectan tras el mismo corte no lo hacen al mismo tick.
  Duration reconnectDelay(int attempt) {
    final grown = baseBackoff.inMicroseconds * pow(1.8, attempt);
    final capped = min(grown, maxBackoff.inMicroseconds.toDouble());
    final jitter = 1 + (_random.nextDouble() * 2 - 1) * 0.3;
    return Duration(microseconds: (capped * jitter).round());
  }

  Future<void> _run() async {
    var attempt = 0;
    while (!_closed) {
      if (attempt > 0) {
        _setState(StreamState.reconnecting);
        final wait = reconnectDelay(attempt);
        developer.log(
          'sse: reconectando en ${wait.inMilliseconds}ms '
          '(intento $attempt de $maxAttempts) ${ServerConfig.redactAuthToken(streamUri())}',
          name: 'openher.sse',
        );
        await Future<void>.delayed(wait);
        if (_closed) return;
      }
      try {
        // Una conexión que demostró vida (evento o heartbeat) no gasta intentos:
        // el contador se reinicia y el corte no acerca el fallback.
        attempt = await _openOnce() ? 0 : attempt + 1;
      } catch (error) {
        attempt++;
        developer.log(
          'sse: caída ($error) ${ServerConfig.redactAuthToken(streamUri())}',
          name: 'openher.sse',
        );
      }
      if (attempt >= maxAttempts) {
        _setState(StreamState.polling);
        onPollFallback?.call(attempt);
        return;
      }
    }
  }

  /// Una conexión completa. Devuelve `true` si demostró vida.
  Future<bool> _openOnce() async {
    final request = http.Request('GET', streamUri())
      ..headers['accept'] = 'text/event-stream'
      ..headers['cache-control'] = 'no-store';
    // El query ya autentica (el server lo precedencea), pero el header no estorba
    // y deja el stream funcionando si una URL con el token se pierde en un log.
    final auth = config.basicAuthHeader;
    if (auth != null) request.headers['authorization'] = auth;

    _resetBuffer();
    final response = await _client.send(request).timeout(connectTimeout);
    if (response.statusCode != 200) {
      throw http.ClientException('SSE respondió ${response.statusCode}');
    }
    // El catch-all del SPA responde HTML 200: acá sería un stream infinito de
    // index.html, nunca heartbeats. Sólo se mira el `content-type` — leer el
    // cuerpo para sniffearlo drenaría el stream (que no termina nunca) y
    // colgaría la conexión antes de escuchar el primer evento.
    if (looksLikeHtml(response.headers['content-type'], '')) {
      throw http.ClientException(htmlFallbackMessage);
    }

    _setState(StreamState.streaming);
    final done = Completer<void>();
    late final StreamSubscription<String> subscription;
    subscription = response.stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (text) => _onChunk(text),
          onError: (Object error) {
            if (!done.isCompleted) done.completeError(error);
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
    _subscription = subscription;
    _armWatchdog(done);

    try {
      await done.future;
    } finally {
      _watchdogTimer?.cancel();
      _watchdogTimer = null;
      _subscription = null;
      await subscription.cancel();
    }
    return _alive;
  }

  void _onChunk(String text) {
    if (_closed || text.isEmpty) return;
    _alive = true;
    _buffer.write(text);
    final result = parseSseChunk(_buffer.toString(), offset: _offset);
    if (result.malformed > 0) {
      developer.log(
        'sse: ${result.malformed} frame(s) con data inválido, descartados',
        name: 'openher.sse',
      );
    }
    if (result.maxSeq != null) _lastSeq = result.maxSeq;
    _offset = result.consumed;
    _trim();

    // Cualquier byte recibido es liveness: se rearma el watchdog haya habido o
    // no evento. Un stream con heartbeats y sin eventos está perfecto.
    _armWatchdog();

    for (final event in result.events) {
      if (!_events.isClosed) _events.add(event);
    }
  }

  /// Saca del buffer lo ya parseado: si no, el texto vivo del stream crece
  /// durante todo el turno y el `substring` se vuelve O(n^2).
  void _trim() {
    if (_offset <= 0) return;
    final pending = _buffer.toString();
    if (_offset >= pending.length) {
      _buffer.clear();
    } else {
      _buffer
        ..clear()
        ..write(pending.substring(_offset));
    }
    _offset = 0;
  }

  void _resetBuffer() {
    _buffer.clear();
    _offset = 0;
    _alive = false;
  }

  /// Rearma el watchdog. Si [done] está activo y nadie lo rearma antes, se
  /// completa con error: el default son 45 s contra un heartbeat de 15 s.
  void _armWatchdog([Completer<void>? done]) {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(watchdog, () {
      _watchdogTimer = null;
      if (_closed || done == null || done.isCompleted) return;
      done.completeError(TimeoutException('SSE sin datos por $watchdog'));
    });
  }

  void _setState(StreamState next) {
    if (_state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    await _events.close();
    await _states.close();
    if (_ownsClient) _client.close();
  }
}
