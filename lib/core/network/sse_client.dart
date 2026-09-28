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

  /// Mayor **cursor** visto en los frames de este chunk.
  ///
  /// Es `durable.seq` (medido en `/api/event`), que es el contador durable del
  /// agregado. El `id` numérico es sólo el fallback para un build viejo que no
  /// manda `durable`; el `id` medido (`evt_…`) no es número y por lo tanto
  /// nunca inventa un cursor falso.
  ///
  /// Se **expone** pero no se manda: no hay un endpoint medido que acepte
  /// `?after=` (el por sesión da 404), así que la reanudación sin duplicados
  /// no está implementada. Sirve para diagnóstico y para el día que exista.
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
/// - `durable: {aggregateID, seq, version}` y `created` se leen por [OcEvent];
///   el cursor es `durable.seq` (el `id` `evt_…` medido no es numérico).
/// - Un buffer a medio frame no se parsea: [SseParseResult.consumed] lo deja
///   para la próxima llamada, que lo reprocesa pasando `offset:`.
///
/// [sessionId] filtra por sesión, porque `/api/event` es **global**: manda las
/// sesiones de todos los directorios y el server no acepta `?sessionID=` (400).
/// Se leen `data.sessionID` (o `properties.sessionID` en v1) y `durable.aggregateID`;
/// un frame sin ninguno de los dos se deja pasar (los globales, como
/// `server.connected`, no pertenecen a ninguna sesión). Vacío o `null` = sin
/// filtro, que es lo que necesita quien ya filtra por su cuenta.
SseParseResult parseSseChunk(
  String buffer, {
  int offset = 0,
  String? sessionId,
}) {
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

    // El modelo es el que sabe leer `durable` y `created`: el parser sólo
    // normaliza las dos ambigüedades del formato (la línea `event:` y la clave
    // v1 `properties`) y se lo pasa como un frame ya plano.
    final event = OcEvent.fromJson(<String, Object?>{
      'id': rawId == null ? '' : '$rawId',
      'type': rawType == null ? '' : '$rawType',
      'data': payload,
      if (json['created'] != null) 'created': json['created'],
      if (json['durable'] != null) 'durable': json['durable'],
    });

    // Filtro por sesión del stream global (ver [parseSseChunk]).
    if (sessionId != null && sessionId.isNotEmpty) {
      final owner = event.sessionID ?? event.aggregateID;
      if (owner != null && owner != sessionId) continue;
    }

    // El cursor durable manda; el `id` numérico es el fallback de un build sin
    // `durable`. El `evt_…` medido no es número ⇒ nunca un cursor inventado.
    final cursor = event.seq ?? (rawId is int ? rawId : int.tryParse('$rawId'));
    if (cursor != null && (maxSeq == null || cursor > maxSeq)) maxSeq = cursor;
    lastEventId ??= rawId == null ? null : '$rawId';

    events.add(event);
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
      if (i + 1 < buffer.length && buffer.codeUnitAt(i + 1) == _cr) {
        return _Boundary(i, i + 2);
      }
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

/// Stream de eventos: `GET /api/event` (**global**), con la sesión filtrada del
/// lado cliente.
///
/// Lo medido contra el build que corre en `:4098` (no de la doc, del server):
/// - `GET /api/event` ⇒ **200 `text/event-stream`**. Es el único que anda.
/// - `GET /api/session/{id}/event` ⇒ **404**. Este build no tiene stream por
///   sesión, así que ése **no** puede ser el default de la clase de red: si lo
///   fuera, el cliente "funcionaría" sólo mientras otro capa lo sobreescribiera,
///   y un uso directo de [SseClient] se caería al 404 en cada reconexión.
/// - El stream global trae las sesiones de todos los directorios, y el server
///   **no** acepta filtrar por query. El filtro es cliente: [parseSseChunk]
///   deja pasar sólo los frames de [sessionId] (`data.sessionID` /
///   `properties.sessionID` / `durable.aggregateID`).
///
/// Dos detalles que el server no perdona:
/// - **Nunca** mandar `sessionID` como query del stream: no está declarado en el
///   schema y el middleware responde **400**.
/// - La auth va en `?auth_token=` (carrier que el server chequea antes del
///   header). La URL se redacta antes de cualquier log.
///
/// ## Reanudación: NO implementada (y por qué)
///
/// Cada frame trae su cursor durable en `durable.seq` y el cliente lo expone
/// como [lastSeq]. Aun así **no** se manda `?after=`: el único endpoint que lo
/// aceptaría es el por sesión, y ese da 404. Mandar un query no declarado trae
/// un 400 del middleware, así que la reanudación sin duplicados queda para
/// cuando exista un endpoint medido que la soporte. Consecuencia conocida: al
/// reconectar, el server puede re-emitir eventos ya entregados y el consumidor
/// tiene que deduplicar por `id`/tipo.
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

  /// Ids de eventos ya entregados. El server durable re-sirve desde el
  /// principio al reconectar, asi que sin esto cada reconexion duplicaria
  /// el texto del asistente.
  final Set<String> _deliveredIds = <String>{};
  StreamState _state = StreamState.polling;
  Future<void>? _loop;

  /// Eventos de la sesión, en orden. Broadcast: la UI y el watchdog pueden mirar
  /// sin pelearse por la suscripción.
  Stream<OcEvent> get events => _events.stream;

  /// Cambios de estado (para el banner). El estado actual está en [state].
  Stream<StreamState> get stateChanges => _states.stream;

  StreamState get state => _state;

  /// Mayor `durable.seq` entregado. Es el cursor durable, listo para reanudar,
  /// pero el default **no** lo manda: ver la nota de reanudación de la clase.
  int? get lastSeq => _lastSeq;

  /// URL del stream, con `auth_token` y **sin** `sessionID`. Contiene la
  /// credencial: para mostrarla o loguearla, pasarla por
  /// [ServerConfig.redactAuthToken].
  ///
  /// [after] se acepta para no romper la firma que sobreescriben los
  /// consumidores, pero el default **lo ignora a propósito**: mandar `?after=`
  /// al stream global no se pudo verificar (el endpoint que lo declara da 404)
  /// y un query no declarado trae un 400 del middleware.
  Uri streamUri({int? after}) => config.api(
    '/event',
    query: <String, String?>{
      if (config.authTokenQuery != null)
        ServerConfig.authTokenParam: config.authTokenQuery,
      if (directory != null && directory!.isNotEmpty)
        ServerConfig.locationParam: directory,
      // OJO: acá NO va `sessionID` (400 del middleware, §7.3) ni `after`
      // (no hay endpoint medido que lo acepte).
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
    // El filtro por sesión va adentro del parser: el stream es global y el
    // server rechaza `?sessionID=`, así que filtrar es cosa del cliente.
    final result = parseSseChunk(
      _buffer.toString(),
      offset: _offset,
      sessionId: sessionId,
    );
    // El server durable re-sirve desde el principio al reconectar (su
    // endpoint con ?after= da 404 en este build, asi que no se puede
    // reanudar por cursor). Sin este filtro, cada reconexion entregaria
    // otra vez todos los deltas y el texto del asistente se duplicaria.
    final fresh = <OcEvent>[];
    for (final event in result.events) {
      if (event.id.isNotEmpty && !_deliveredIds.add(event.id)) continue;
      fresh.add(event);
    }
    if (_deliveredIds.length > 8000) {
      _deliveredIds.clear();
    }
    // Sólo avanza con lo que se entregó: un `durable.seq` de otra sesión no
    // puede pisar el cursor de ésta.
    if (result.maxSeq != null) {
      _lastSeq = _lastSeq == null || result.maxSeq! > _lastSeq!
          ? result.maxSeq
          : _lastSeq;
    }
    _offset = result.consumed;
    _trim();

    // Cualquier byte recibido es liveness: se rearma el watchdog haya habido o
    // no evento. Un stream con heartbeats y sin eventos está perfecto.
    _armWatchdog();

    for (final event in fresh) {
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
