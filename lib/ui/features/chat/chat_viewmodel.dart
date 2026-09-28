/// Estado del chat de **una** sesión: la lista de mensajes, si el turno está
/// trabajando, los tres canales de error y el stream en vivo.
///
/// ## El stream es GLOBAL, el filtro es cliente
/// `GET /api/session/{id}/event` da **404** en el build medido
/// (`docs/API_CONTRACT.md` §7.1): lo que anda es `GET /api/event`, que trae el
/// `sessionID` **dentro** del payload. Por eso [ChatEventSource] no lleva
/// sessionId: es un solo socket para toda la app y [ChatViewModel] descarta
/// los eventos de otras sesiones en [_applyEvent].
///
/// ## D3bis + §7.4: la regla de fin de turno
/// `working` = último assistant con `time.completed == null` **o**
/// `session.status` ∈ {busy, running, retry}. Cuando llega un status **vivo**,
/// manda él (es la evidencia más fresca); si no hay status, decide el último
/// assistant. Nunca "por tiempo": el botón Detener no se esconde por reloj.
///
/// ## Deltas
/// `session.text.delta` / `session.reasoning.delta` son **live-only** (§7.5):
/// se acumulan en un buffer y se aplican a 20 fps (50 ms), porque un delta por
/// token son 60 rebuilds de markdown por segundo. El valor autoritativo llega
/// en el `*.ended` (que dispara un re-fetch), así que perder un delta no
/// corrompe el mensaje.
///
/// El delta se aplica al mensaje que nombra `assistantMessageID` (igual que el
/// reducer de referencia), **no** "al último assistant": al último se le pegaba
/// el primer delta del turno siguiente al mensaje ya terminado del anterior.
///
/// ## Preguntas
/// `question.asked` trae el `id` del request (que es el `requestID` del reply) y
/// el `QuestionInfo[]`; se responde con
/// `POST /api/session/{id}/question/{requestID}/reply` `{answers:[[…]]}`. Medido
/// en `:4098`: **no hay** endpoint para listar las pendientes
/// (`GET /api/question/request` da 404), así que [answerQuestion] tiene un
/// fallback que manda las respuestas como prompt — eso siempre funciona — y
/// dice por cuál se fue ([lastQuestionReplyPath]).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/connectivity/network_monitor.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/server_config.dart';
import '../../../core/network/sse_client.dart';
import '../../../domain/models/errors.dart';
import '../../../domain/models/event.dart';
import '../../../domain/models/message.dart';
import '../../../domain/models/session.dart';

/// Fuente de eventos del chat. Es una interfaz (no una clase concreta) para
/// que los tests inyecten un fake sin abrir un socket.
abstract interface class ChatEventSource {
  Stream<OcEvent> get events;

  Stream<StreamState> get stateChanges;

  StreamState get state;

  /// URL del stream. Existe en la interfaz para que se pueda **verificar** a
  /// cuál endpoint se conecta: `/api/session/{id}/event` da 404 en el build
  /// medido (API_CONTRACT §7.1), así que el path correcto es parte del
  /// contrato, no un detalle interno.
  ///
  /// Contiene la credencial en `?auth_token=`: para loguearla o mostrarla pasa
  /// por `ServerConfig.redactAuthToken`.
  Uri streamUri({int? after});

  void connect();

  Future<void> dispose();
}

typedef ChatEventSourceFactory =
    ChatEventSource Function(ServerConfig config, String? directory);

/// [ChatEventSource] sobre el stream **global** `/api/event`.
///
/// Se implementa **subclaseando** [SseClient] y sobreescribiendo [streamUri]:
/// la clase de red no se toca (es de `lib/core/**`) y el cambio del que la app
/// necesita es exactamente uno, la URL.
class GlobalSseSource implements ChatEventSource {
  GlobalSseSource({required ServerConfig config, String? directory})
    : _sse = _GlobalSse(config: config, directory: directory);

  final _GlobalSse _sse;

  @override
  Stream<OcEvent> get events => _sse.events;

  @override
  Stream<StreamState> get stateChanges => _sse.stateChanges;

  @override
  StreamState get state => _sse.state;

  @override
  Uri streamUri({int? after}) => _sse.streamUri(after: after);

  @override
  void connect() => _sse.connect();

  @override
  Future<void> dispose() => _sse.dispose();
}

class _GlobalSse extends SseClient {
  _GlobalSse({required super.config, super.directory}) : super(sessionId: '');

  /// `/api/event` (global). **Nunca** `?sessionID=`: no está declarado en el
  /// schema y el middleware responde 400 (§7.3).
  @override
  Uri streamUri({int? after}) => config.api(
    '/event',
    query: <String, String?>{
      'after': (after ?? lastSeq)?.toString(),
      if (config.authTokenQuery != null)
        ServerConfig.authTokenParam: config.authTokenQuery,
      if (directory != null && directory!.isNotEmpty)
        ServerConfig.locationParam: directory,
    },
  );
}

ChatEventSource _defaultSource(ServerConfig config, String? directory) =>
    GlobalSseSource(config: config, directory: directory);

/// Eventos que traen el estado del turno.
///
/// `:4098`) y el `session.idle` deprecado. Los nombres que estaban antes acá
/// el protocolo: nadie los emitía, pero se leían como evidencia de turno y
/// por eso las reglas del repo no admiten eventos inventados.
const Set<String> kChatStatusEvents = {'session.status', 'session.idle'};

/// `question.asked`: el agente está esperando una respuesta (§6).
///
/// El dialecto v2 los publica con el prefijo de versión (`question.v2.asked`) y
/// `lib/domain/models/event.dart`.
const Set<String> kQuestionAskedEvents = {
  'question.asked',
  'question.v2.asked',
};

/// `question.replied` / `question.rejected`: la pregunta se cerró y el turno
/// sigue. También en las dos generaciones (`§6`).
const Set<String> kQuestionClosedEvents = {
  'question.replied',
  'question.v2.replied',
  'question.rejected',
  'question.v2.rejected',
};

/// Por dónde salió la respuesta de una pregunta.
enum QuestionReplyPath {
  /// `POST /api/session/{id}/question/{requestID}/reply`, que es lo que dice el
  /// protocolo (`API_CONTRACT.md` §6).
  api,

  /// este build (404) o falla — mandar la respuesta como prompt siempre
  /// funciona, y es lo único quearantea que el turno no quede trabado.
  prompt,
}

/// La pregunta que el agente está esperando, tal como la mandó `question.asked`.
final class PendingQuestion {
  const PendingQuestion({
    required this.requestId,
    required this.questions,
    this.callId,
    this.messageId,
  });

  /// `que_…`, el `id` del `question.asked` y el `{requestID}` del reply.
  final String requestId;

  /// Los `QuestionInfo[]` **en crudo** (`{question, header, options[], …}`).
  /// Quedan sin tipo fuerte a propósito: el shape es de la tool, y la UI es la
  /// que lo proyecta a la card.
  final List<Map<String, Object?>> questions;

  /// `tool.callID` si vino: el `content[].id` del tool `question` que originator
  /// la pregunta. Sirve para pegarle el `requestID` a la card correcta.
  final String? callId;

  /// `tool.messageID`: el assistant dueño de la pregunta.
  final String? messageId;
}

class ChatViewModel extends ChangeNotifier {
  /// `ChatViewModel(api, sessionId: 'ses_…')`.
  ///
  /// El [ApiClient] va **posicional** a propósito: un named parameter no puede
  /// empezar con `_`, así que un campo privado asignado desde un named
  /// obligatorio dispara `prefer_initializing_formals` siempre.
  ChatViewModel(
    this._api, {
    required this.sessionId,
    this.sessionInfo,
    this.directory,
    ChatEventSourceFactory? streamFactory,
    this._policy = const DataPolicy.normal(),
  }) : _streamFactory = streamFactory ?? _defaultSource;

  /// `ses_…`.
  final String sessionId;

  /// La sesión de la lista, si el shell ya la tenía. Sólo se usa para modelo,
  /// agente, tokens y costo; los mensajes salen siempre de la red.
  final SessionInfo? sessionInfo;

  /// `location[directory]` del server. Se manda en cada request porque el
  /// server lo usa para resolver el workspace.
  final String? directory;

  final ApiClient _api;
  final ChatEventSourceFactory _streamFactory;

  /// Mensajes en orden cronológico. Incluye los optimistas (`local_…`) hasta
  /// que un re-fetch los reemplaza por los del server.
  final List<SessionMessage> _messages = [];

  bool _working = false;

  /// Tri-estado del `session.status` más reciente: `true` = trabajando,
  /// `false` = terminado, `null` = nunca llegó.
  bool? _busyStatus;

  /// Enviamos un prompt y todavía no llegó ningún assistant.
  bool _awaitingAssistant = false;

  String? _error;
  bool _loading = false;
  bool _loadingEarlier = false;
  String? _earlierCursor;
  StreamState? _streamState;
  bool _visible = true;

  /// ese caso la vista no lo vuelve a prender al montar: la intencion del
  int _localSeq = 0;

  /// La pregunta que el agente está esperando, si hay alguna.
  PendingQuestion? _pendingQuestion;

  /// Por dónde respondió la **última** pregunta. `null` = todavía no respondió.
  QuestionReplyPath? _lastQuestionReplyPath;

  /// `session.status` con `type: "retry"`: "Reintentando en 8s — Rate limit".
  /// Vive acá porque el status por sí solo dice "busy" y no dice por qué.
  String? _retryNotice;

  /// Secuencia del último re-fetch **aplicado**. Un response más viejo que
  /// éste ya no se aplica: con el merge por `id` lo que sí haría es dejar
  /// mensajes viejos pegados al final de la lista.
  int _appliedFetch = 0;

  ChatEventSource? _source;
  StreamSubscription<OcEvent>? _events;
  StreamSubscription<StreamState>? _states;
  Timer? _deltaTimer;
  Timer? _refetchTimer;
  Timer? _pollTimer;
  String _pendingText = '';
  String _pendingReasoning = '';

  /// `assistantMessageID` del turno al que pertenecen los deltas en el buffer.
  String? _deltaMessageId;
  bool _disposed = false;
  final Set<String> _seenEventIds = <String>{};

  // ───────────────────────────── lectura de estado ──────────────────────────

  List<SessionMessage> get messages => List.unmodifiable(_messages);

  /// Hay un turno en curso. Es lo que decide el botón Detener del composer.
  bool get working => _working;

  /// Canal C: error de **transporte/protocolo** (`OchError`), listo para pintar
  /// como banner. Los canales A (`assistant.error`) y B (`tool.state.error`)
  /// viven en el mensaje, no acá.
  String? get error => _error;

  bool get loading => _loading;

  bool get loadingEarlier => _loadingEarlier;

  /// El server dijo que hay mensajes más viejos que los que tenemos.
  bool get hasEarlier => _earlierCursor != null;

  /// `null` si el SSE nunca se conectó. La UI lo pinta como aviso.
  StreamState? get streamState => _streamState;

  /// ¿El chat está en pantalla? En `false` no hay socket ni timers (batería).
  bool get visible => _visible;

  /// Contexto en tokens. `session.tokens` si el shell lo trajo; si no, la suma
  /// en memoria de los `assistant.tokens` que ya tenemos.
  int get serverTokens {
    final info = sessionInfo;
    if (info != null) return info.tokens.total;
    var total = 0;
    for (final m in _messages) {
      if (m case final AssistantMessage a) total += a.tokens.total;
    }
    return total;
  }

  /// Gasto en USD, con el mismo fallback que [serverTokens].
  double get serverCost {
    final info = sessionInfo;
    if (info != null) return info.cost;
    var total = 0.0;
    for (final m in _messages) {
      if (m case final AssistantMessage a) total += a.cost;
    }
    return total;
  }

  /// El último `AssistantMessage` de la lista (o `null`).
  AssistantMessage? get lastAssistant {
    for (var i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i] case final AssistantMessage a) return a;
    }
    return null;
  }

  /// La pregunta que el agente está esperando, o `null` si no hay ninguna.
  PendingQuestion? get pendingQuestion => _pendingQuestion;

  /// Hay una pregunta esperando respuesta.
  ///
  /// El turno **sigue** `working` (§7.4: no se esconde el botón Detener sin la
  /// evidencia real de fin de turno), pero la card de la pregunta es la salida:
  /// el usuario contesta ahí y el turno se destraba. Sin esto lo único que había
  /// era Detener.
  bool get awaitingAnswer => _pendingQuestion != null;

  /// Por dónde respondió la última pregunta. `null` si todavía no respondió
  /// ninguna: así el test puede distinguir "no se intentó" de "falló el endpoint".
  QuestionReplyPath? get lastQuestionReplyPath => _lastQuestionReplyPath;

  /// Atajo booleano de [lastQuestionReplyPath] para la UI y los tests.
  bool? get questionReplyViaApi => switch (_lastQuestionReplyPath) {
    null => null,
    QuestionReplyPath.api => true,
    QuestionReplyPath.prompt => false,
  };

  /// `Reintentando en 8s — Rate limit` cuando el `session.status` es `retry`
  /// con `action`; `null` en cualquier otro status. Sin esto un reintento es
  /// indistinguible de un turno trabajando.
  String? get retryNotice => _retryNotice;

  /// El `requestID` de la pregunta que corresponde a este tool (`callID`).
  ///
  /// `null` si no hay ninguna pendiente o si la pendiente es de otro tool. El
  /// id de la pregunta vive en el evento, no en el mensaje: la lista de
  /// mensajes sólo tiene el `callID` del tool.
  String? requestIdFor(String callId) {
    final pending = _pendingQuestion;
    if (pending == null || pending.requestId.isEmpty) return null;
    if (pending.callId == null || pending.callId == callId) {
      return pending.requestId;
    }
    return null;
  }

  // ───────────────────────────────── carga ──────────────────────────────────

  /// `GET /api/session/{id}/message?limit=30&order=desc` (primera carga).
  ///
  /// `desc` + reverse: la primera página trae los ÚLTIMOS mensajes y la lista
  /// queda en orden cronológico. Con `asc` se abriría en el mensaje más viejo
  /// de la sesión, que es justo lo que el contrato de scroll prohíbe ("al
  /// entrar al chat arrancás en el último mensaje").
  ///
  /// Comparte el camino con [refresh]: los dos **mergean** (ver [_ingest]).
  Future<void> load() => _fetch(loading: true);

  /// Re-fetch silencioso. Es lo que dispara un `isSettledEvent` y el poll de
  /// respaldo.
  ///
  /// **No puede tirar la lista**: hace un upsert por `id`, así que lo que
  /// `loadEarlier()` metió más arriba se queda. Antes `refresh() => load()` y
  /// `_ingest` borraba todo para volver a agregar sólo la última página: cada
  /// `*.ended` acortaba la conversación bajo los pies del que scrolleaba.
  Future<void> refresh() => _fetch(loading: false);

  /// Número de fetch iniciado, para que un response viejo no pise uno nuevo.
  int _fetchSeq = 0;

  Future<void> _fetch({required bool loading}) async {
    if (loading) {
      _loading = true;
      _error = null;
      _safeNotify();
    }
    final seq = ++_fetchSeq;
    try {
      final page = await _api.listMessages(
        sessionId,
        limit: _policy.pageSize,
        order: 'desc',
        directory: directory,
      );
      // Un response que ya quedó viejo no se aplica: `load()` y `refresh()`
      // pueden solaparse (el poll de 2 s contra un `*.ended`) y el que
      // responde primero no es necesariamente el que arrancó después.
      if (_disposed || seq < _appliedFetch) return;
      _appliedFetch = seq;
      _ingest(page.data.reversed.toList(growable: false));
      // El cursor de "anteriores" sólo retrocede: un re-fetch de la última
      // página no puede devolver el cursor hacia atrás de lo ya cargado.
      _earlierCursor ??= page.previous;
    } on OchError catch (e) {
      if (_disposed || seq < _appliedFetch) return;
      _error = e.message;
    } finally {
      if (loading) _loading = false;
      _recomputeWorking();
      _safeNotify();
    }
  }

  /// La página anterior, para el botón "Cargar 30 anteriores".
  Future<void> loadEarlier() async {
    final cursor = _earlierCursor;
    if (cursor == null || _loadingEarlier) return;
    _loadingEarlier = true;
    _safeNotify();
    try {
      final page = await _api.listMessages(
        sessionId,
        limit: _policy.pageSize,
        order: 'asc',
        cursor: cursor,
        directory: directory,
      );
      final older = _parseAll(page.data);
      _earlierCursor = page.previous;
      if (older.isNotEmpty) _messages.insertAll(0, older);
    } on OchError catch (e) {
      _error = e.message;
    } finally {
      _loadingEarlier = false;
      _safeNotify();
    }
  }

  // ─────────────────────────────── responder ───────────────────────────────

  /// Responde la pregunta pendiente (`API_CONTRACT.md` §6).
  ///
  /// **Camino 1, el del protocolo**:
  /// `POST /api/session/{id}/question/{requestID}/reply` con
  /// `{answers: [[…]]}` — un array por pregunta, en el orden en que se
  /// hicieron. Devuelve 204.
  ///
  /// **Camino 2, el que nunca falla**: si el endpoint no existe (404 en el
  /// build medido) o el POST falla, las respuestas se mandan como un prompt
  /// del usuario normal. El server los acepta como respuesta y el turno se
  /// destraca igual.
  ///
  /// Devuelve (y deja en [lastQuestionReplyPath]) por cuál se fue. Un 404 **no**
  /// se reporta como error: el fallback funcionó, así que no hay nada que
  /// avisasle al usuario como error — sólo que la respuesta no fue por el
  /// endpoint.
  Future<QuestionReplyPath> answerQuestion(
    String? requestId, {
    required List<List<String>> answers,
  }) async {
    if (answers.isEmpty) {
      return _lastQuestionReplyPath ?? QuestionReplyPath.prompt;
    }

    final id = requestId?.trim() ?? '';
    if (id.isNotEmpty) {
      try {
        await _api.postJson(
          '/session/$sessionId/question/$id/reply',
          body: <String, Object?>{'answers': answers},
          query: <String, String?>{
            if (directory != null && directory!.isNotEmpty)
              ServerConfig.locationParam: directory,
          },
        );
        // 204: el server tomó la respuesta. La pendiente se cae ahora mismo
        // para que la card no quede pidiendo algo que ya se contestó.
        _pendingQuestion = null;
        _lastQuestionReplyPath = QuestionReplyPath.api;
        _recomputeWorking();
        _safeNotify();
        return QuestionReplyPath.api;
      } on OchError {
        // El endpoint no existe en este build (404) o no respondió: se va por
        // el prompt. El error del POST **no** se reporta: el fallback funcionó,
        // así que no hay nada que el usuario pueda arreglar. Queda dicho por
        // dónde se contestó y nada más.
        _lastQuestionReplyPath = QuestionReplyPath.prompt;
      }
    } else {
      // No hay `requestID` (el evento no llegó o el tool no trae `callID`):
      // tampoco hay a quién preguntarle, así que directo al prompt.
      _lastQuestionReplyPath = QuestionReplyPath.prompt;
    }

    await send(_answerPrompt(answers));
    _pendingQuestion = null;
    _recomputeWorking();
    _safeNotify();
    return QuestionReplyPath.prompt;
  }

  /// El prompt del fallback: una línea por opción elegida. `Ahora no.` es el
  /// *skip* (lista vacía) y conserva el texto que ya usaba el botón.
  static String _answerPrompt(List<List<String>> answers) {
    final lines = [for (final a in answers) ...a.where((l) => l.isNotEmpty)];
    return lines.isEmpty ? 'Ahora no.' : lines.join('\n');
  }

  // ───────────────────────────────── enviar ─────────────────────────────────

  /// Admite un prompt: burbuja optimista + `POST /api/session/{id}/prompt`.
  ///
  /// El POST devuelve el "admitido", **no** el turno: el turno llega por el
  /// stream (decisión D4). Por eso la burbuja optimista se queda hasta el
  /// primer re-fetch, que la reemplaza por el mensaje con id real.
  Future<void> send(
    String text, {
    List<Map<String, String>>? files,
    List<String>? agents,
  }) async {
    final body = text.trim();
    if (body.isEmpty) return;

    final local = UserMessage(
      id: 'local_${++_localSeq}',
      time: MessageTime(createdMs: DateTime.now().millisecondsSinceEpoch),
      text: body,
      files: [
        for (final f in files ?? const <Map<String, String>>[])
          UserFileAttachment(
            uri: f['uri'] ?? '',
            name: f['name'],
            mime: f['mime'],
          ),
      ],
      agents: agents ?? const <String>[],
    );
    _messages.add(local);
    _awaitingAssistant = true;
    // El status del turno anterior quedó viejo: a partir de acá decide el
    // prompt nuevo.
    _busyStatus = null;
    _recomputeWorking();
    _safeNotify();

    try {
      await _api.sendPrompt(
        sessionId,
        text: body,
        files: (files == null || files.isEmpty) ? null : files,
        agents: (agents == null || agents.isEmpty) ? null : agents,
        directory: directory,
      );
    } on OchError catch (e) {
      _messages.removeWhere((m) => m.id == local.id);
      _awaitingAssistant = false;
      _recomputeWorking();
      _error = e.message;
      _safeNotify();
    }
  }

  /// `POST /api/session/{id}/interrupt`. No-op si el server ya estaba idle.
  Future<void> abort() async {
    try {
      await _api.interrupt(sessionId, directory: directory);
    } on OchError catch (e) {
      _error = e.message;
      _safeNotify();
      return;
    }
    _busyStatus = false;
    _awaitingAssistant = false;
    _flushDeltas();
    _recomputeWorking();
    _safeNotify();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    _safeNotify();
  }

  // ─────────────────────────────── el stream ───────────────────────────────

  /// Abre (o reabre) el stream global. Idempotente.
  void connectStream() {
    if (_disposed) return;
    if (_source != null) return;
    // Modo de bajo consumo (datos móviles): no se abre el stream en vivo. El
    // turno llega por el polling, que con datos cellulares es 6x más barato
    // que un socket que manda deltas cada 50 ms.
    if (!_policy.streamingEnabled) {
      _startPolling();
      return;
    }
    if (_source != null) return;
    final source = _streamFactory(
      // La config no vive en el VM: la app tiene una sola y la inyecta el
      // shell a través de la factoría por defecto.
      _api.config,
      directory,
    );
    _source = source;
    _events = source.events.listen(_applyEvent);
    _states = source.stateChanges.listen(_onStreamState);
    source.connect();
  }

  /// Cierra el stream. Sin I/O: sólo cancela suscripciones y timers.
  void disposeStream() {
    _stopPolling();
    _deltaTimer?.cancel();
    _deltaTimer = null;
    _refetchTimer?.cancel();
    _refetchTimer = null;
    _pendingText = '';
    _pendingReasoning = '';
    _deltaMessageId = null;
    unawaited(_events?.cancel());
    unawaited(_states?.cancel());
    _events = null;
    _states = null;
    unawaited(_source?.dispose());
    _source = null;
    _streamState = null;
  }

  /// Pausa/redice el stream cuando el chat sale/entra de pantalla.
  ///
  /// Es la regla de batería: con el chat fuera de pantalla no hay socket ni
  /// timers. Al volver se reconecta y se re-snapshotéa, porque entre la ida y
  /// la vuelta se perdieron deltas (que son live-only, §7.5).
  void setVisible(bool visible) {
    if (_visible == visible) {
      // Idempotencia: un viewmodel que ya esta visible tiene que tener el
      // stream arriba. Sin esto, el que nace visible (el caso normal) nunca
      // conectaba, porque la conexion solo ocurria en la transicion.
      if (visible && _source == null) {
        connectStream();
        unawaited(refresh());
      }
      return;
    }
    _visible = visible;
    if (visible) {
      connectStream();
      unawaited(refresh());
    } else {
      disposeStream();
    }
  }

  /// El SSE publica su estado: cuando se rinde pasa a `polling` y ahí hay que
  /// compensar con REST (el estado inicial también es `polling`, pero no se
  /// emite hasta que cambia, así que no arranca un poll que nadie pidió).
  void _onStreamState(StreamState state) {
    if (state == StreamState.polling) {
      _startPolling();
    } else {
      _stopPolling();
    }
    if (_streamState == state) return;
    _streamState = state;
    _safeNotify();
  }

  void _startPolling() {
    if (_pollTimer != null || _disposed) return;
    _pollTimer = Timer.periodic(_policy.pollInterval, (_) => refresh());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  // ───────────────────────── aplicación de eventos ─────────────────────────

  /// Un frame del stream global. Todo el filtrado y toda la política viven acá.
  void _applyEvent(OcEvent event) {
    // Filtro por sesión: el socket es global. Un evento sin `sessionID`
    // (`server.connected`) es de la app y se aplica.
    final id = event.sessionID;
    if (id != null && id != sessionId) return;

    // Dedupe por id de evento: al reconectar, el server re-emite desde el
    // principio (no hay ?after= funcional porque su endpoint da 404) y los
    // deltas arrival dos veces. Un evento repetido no se reaplica, asi que
    // el texto del asistente no se duplica.
    final key = event.id;
    if (key.isNotEmpty && !_seenEventIds.add(key)) return;
    if (_seenEventIds.length > 4000) {
      _seenEventIds.clear();
      _seenEventIds.add(key);
    }

    final type = event.type;
    final lower = type.toLowerCase();

    // Canal C: `session.error` — aviso no bloqueante (§5).
    if (lower == 'session.error') {
      _error = OcErrorInfo.fromJson(event.data['error']).toString();
      _safeNotify();
      return;
    }

    // Preguntas (§6). Van antes que el status porque el `requestID` de la
    // respuesta vive acá, no en el mensaje.
    if (kQuestionAskedEvents.contains(lower)) {
      _applyQuestionAsked(event.data);
      // La lista de mensajes todavía no tiene el tool `question` en `pending`:
      // el re-fetch lo trae y recién ahí se puede pintar la card.
      _scheduleRefetch();
      return;
    }
    if (kQuestionClosedEvents.contains(lower)) {
      _clearQuestion(event.data);
      _scheduleRefetch();
      return;
    }

    if (kChatStatusEvents.contains(lower)) {
      _applyStatus(event.data);
      return;
    }

    if (isDeltaEvent(type)) {
      _applyDelta(type, event.data);
      return;
    }

    // `*.ended` / `tool.success` / `step.ended`: el valor ya no va a cambiar,
    // así que el mensaje completo manda. Re-fetch debounced.
    if (isSettledEvent(type)) _scheduleRefetch();
  }

  /// `question.asked {id, sessionID, questions[], tool?}`.
  ///
  /// El `id` es el `requestID` del reply y `tool.callID` es el `content[].id`
  /// del tool `question` que la originator: sin el segundo la card no sabe a
  /// qué pregunta pertenece.
  void _applyQuestionAsked(Map<String, Object?> data) {
    final tool = asMap(data['tool']);
    final requestId = asStr(data['id']) ?? asStr(tool?['callID']) ?? '';
    _pendingQuestion = PendingQuestion(
      requestId: requestId,
      questions: asMapList(data['questions']),
      callId: asStr(tool?['callID']),
      messageId: asStr(tool?['messageID']),
    );
    _recomputeWorking();
    _safeNotify();
  }

  /// `question.replied {sessionID, requestID, answers[]}` /
  /// `question.rejected {sessionID, requestID}`: la pregunta se cerró.
  ///
  /// Si el `requestID` es de **otra** pregunta, la que espera sigue esperando:
  /// se descartan las viejas, no la viva.
  void _clearQuestion(Map<String, Object?> data) {
    final pending = _pendingQuestion;
    if (pending == null) return;
    final requestId = asStr(data['requestID']) ?? asStr(data['id']);
    if (requestId != null &&
        requestId.isNotEmpty &&
        requestId != pending.requestId) {
      return;
    }
    _pendingQuestion = null;
    _recomputeWorking();
    _safeNotify();
  }

  void _applyStatus(Map<String, Object?> data) {
    final status = data['status'] ?? data['type'];
    if (isBusyStatus(status)) {
      _busyStatus = true;
      // `retry` es un `busy` con motivo y con cuenta regresiva: sin el `action`
      // un reintento es indistinguible de un turno trabajando.
      _retryNotice = _statusRetryNotice(status);
    } else if (isSettledStatus(status)) {
      _busyStatus = false;
      _awaitingAssistant = false;
      _retryNotice = null;
    } else {
      return; // un status desconocido no afirma nada
    }
    _recomputeWorking();
    _safeNotify();
  }

  /// `SessionStatus.retry` trae
  /// `{type, attempt, message, action:{reason, provider, title, message, label, link}, next}`.
  /// `next` es el delay en ms hasta el próximo intento: de ahí sale el "en Ns".
  static String? _statusRetryNotice(Object? status) {
    final map = asMap(status);
    if (map == null || asStr(map['type'])?.toLowerCase() != 'retry') {
      return null;
    }
    final nextMs = asInt(map['next']);
    final base = nextMs == null || nextMs <= 0
        ? 'Reintentando'
        : 'Reintentando en ${(nextMs / 1000).ceil()}s';
    final title = asStr(asMap(map['action'])?['title'])?.trim();
    if (title == null || title.isEmpty) return base;
    return '$base — $title';
  }

  void _applyDelta(String type, Map<String, Object?> data) {
    final chunk = asStr(data['text']) ?? asStr(data['delta']) ?? '';
    if (chunk.isEmpty) return;

    if (type.toLowerCase().contains('reasoning')) {
      _pendingReasoning += chunk;
    } else if (type.toLowerCase().contains('text')) {
      _pendingText += chunk;
    } else {
      // `tool.input.ended` (que dispara el re-fetch): no se aplica al modelo.
      return;
    }
    _awaitingAssistant = false;

    // A qué assistant pertenecen estos deltas. El id se lee de **cada** delta
    // (el primero puede no traerlo) y el último que lo trajo manda.
    final id = asStr(data['assistantMessageID']) ?? asStr(data['messageID']);
    if (id != null && id.isNotEmpty) _deltaMessageId = id;

    // 20 fps: se agrupan los deltas de 50 ms en un solo rebuild.
    _deltaTimer ??= Timer(deltaInterval, _flushDeltas);
  }

  void _flushDeltas() {
    _deltaTimer?.cancel();
    _deltaTimer = null;
    final text = _pendingText;
    final reasoning = _pendingReasoning;
    final target = _deltaMessageId;
    _pendingText = '';
    _pendingReasoning = '';
    _deltaMessageId = null;
    if (text.isEmpty && reasoning.isEmpty) return;

    final index = _deltaTarget(target);
    if (index < 0) return;
    final current = _messages[index] as AssistantMessage;

    final content = [...current.content];
    if (reasoning.isNotEmpty) _appendTo(content, reasoning, reasoning: true);
    if (text.isNotEmpty) _appendTo(content, text, reasoning: false);
    _messages[index] = _copyAssistant(current, content);

    _recomputeWorking();
    _safeNotify();
  }

  /// Dónde se aplica un delta.
  ///
  /// 1. Al `AssistantMessage` con ese `id`, como el reducer de referencia
  ///    (`assistantMessageID`). Sin esto el primer delta de un turno nuevo se
  ///    pegaba al mensaje **ya terminado** del turno anterior.
  /// 2. Si el id no está en la lista todavía (el mensaje llegó después del
  ///    delta), al último assistant **incompleto**: es el único que puede
  ///    seguir creciendo.
  /// 3. Si no hay ninguno incompleto, al último assistant. Antes se perdía el
  ///    texto; ahora es el último recurso.
  int _deltaTarget(String? id) {
    if (id != null && id.isNotEmpty) {
      final index = _messages.indexWhere(
        (m) => m.id == id && m is AssistantMessage,
      );
      if (index >= 0) return index;
    }
    final incomplete = _messages.lastIndexWhere(
      (m) => m is AssistantMessage && !m.isComplete,
    );
    if (incomplete >= 0) return incomplete;
    return _messages.lastIndexWhere((m) => m is AssistantMessage);
  }

  /// Agrega al último item de texto (o razonamiento) del `content[]`, o crea
  /// uno si el turno todavía no había hablado.
  void _appendTo(
    List<AssistantContent> content,
    String chunk, {
    required bool reasoning,
  }) {
    if (content.isNotEmpty) {
      final last = content.last;
      if (reasoning && last is AssistantReasoning) {
        content[content.length - 1] = AssistantReasoning(
          id: last.id,
          time: last.time,
          text: last.text + chunk,
        );
        return;
      }
      if (!reasoning && last is AssistantText) {
        content[content.length - 1] = AssistantText(
          id: last.id,
          time: last.time,
          text: last.text + chunk,
        );
        return;
      }
    }
    content.add(
      reasoning ? AssistantReasoning(text: chunk) : AssistantText(text: chunk),
    );
  }

  void _scheduleRefetch() {
    _refetchTimer?.cancel();
    _refetchTimer = Timer(refetchDelay, () {
      _refetchTimer = null;
      unawaited(refresh());
    });
  }

  // ─────────────────────────────── interno ────────────────────────────────

  /// 30 mensajes por página: la misma ventana que el cliente de escritorio y
  /// la del prototipo ("Cargar 30 anteriores").
  /// Política de consumo. Con datos móviles se recorta el polling, la página y
  /// el streaming (ver `DataPolicy`). Es inyectable para tests.
  final DataPolicy _policy;

  /// La política activa. El chat lee "qué hacer", no la regla.
  DataPolicy get policy => _policy;
  static const int pageSize = 30;

  /// Buffer de deltas: 50 ms ⇒ 20 fps.
  static const Duration deltaInterval = Duration(milliseconds: 50);

  /// Agrupa los `*.ended` de un turno (vienen de a uno) en un solo re-fetch.
  static const Duration refetchDelay = Duration(milliseconds: 250);

  /// Poll REST de respaldo cuando el SSE se rinde (§2.3 del plan).
  static const Duration pollInterval = Duration(seconds: 2);

  static List<SessionMessage> _parseAll(List<dynamic> raw) => [
    for (final item in raw)
      if (asMap(item) case final Map<String, Object?> m)
        SessionMessage.fromJson(m),
  ];

  /// Inserta la página del server **sin perder** lo ya cargado (upsert por
  /// `id`).
  ///
  /// Antes esto **borraba** la lista y volvía a agregar sólo la última página:
  /// cada `*.ended` y cada poll del fallback tiraban abajo todo lo que
  /// `loadEarlier()` había cargado, y la conversación se acortaba sola debajo
  /// del que estaba scrolleando hacia arriba.
  ///
  /// El orden se respeta: cada mensaje que ya estaba se reemplaza en su lugar y
  /// los que sólo trae el server van al final, que es donde están (la página es
  /// cronológica y su último item es el más nuevo).
  ///
  /// Una página vacía **no** toca la lista: es un fallo o una sesión recién
  /// creada, y en los dos casos el mejor dato es el que ya tenemos.
  ///
  /// Los optimistas (`local_…`) se caen recién cuando el server trae un mensaje
  /// del usuario con ese mismo texto: el prompt se persiste al admitirlo, pero
  /// hasta que aparezca no tiene por qué parpadear.
  void _ingest(List<dynamic> raw) {
    final fresh = _parseAll(raw);
    if (fresh.isEmpty) return;

    final incoming = <String, SessionMessage>{for (final m in fresh) m.id: m};
    final serverTexts = <String>{
      for (final m in fresh)
        if (m is UserMessage) m.text,
    };

    final merged = <SessionMessage>[];
    final kept = <String>{};
    for (final message in _messages) {
      final server = incoming.remove(message.id);
      if (server != null) {
        merged.add(server);
        kept.add(server.id);
        continue;
      }
      final confirmed =
          message.id.startsWith('local_') &&
          message is UserMessage &&
          serverTexts.contains(message.text);
      if (confirmed) continue;
      merged.add(message);
      kept.add(message.id);
    }
    for (final message in fresh) {
      if (kept.add(message.id)) merged.add(message);
    }

    _messages
      ..clear()
      ..addAll(merged);
  }

  void _recomputeWorking() {
    final last = lastAssistant;
    // Evidencia del ultimo mensaje: el turno sigue vivo si el assistant
    // todavia no se cerro (sin time.completed y sin finish).
    final assistantBusy =
        _awaitingAssistant || (last != null && !last.isComplete);
    final status = _busyStatus;
    if (status == null) {
      _working = assistantBusy;
      return;
    }
    // Un status busy mantiene el turno vivo aunque el mensaje ya se haya
    // cerrado por un camino raro (APIError, compaction).
    if (status) {
      _working = true;
      return;
    }
    // Status settled (idle/completed): manda el cierre, salvo que el ultimo
    // assistant siga abierto — si el server dijo idle pero el mensaje no
    // cerro, todavia hay trabajo y el boton Detener tiene que seguir
    // visible (contrato 7.4: working = assistant incompleto O status busy).
    _working = assistantBusy;
  }

  /// `AssistantMessage` es inmutable: para un delta hay que copiarlo entero.
  static AssistantMessage _copyAssistant(
    AssistantMessage m,
    List<AssistantContent> content,
  ) => AssistantMessage(
    id: m.id,
    time: m.time,
    metadata: m.metadata,
    agent: m.agent,
    model: m.model,
    content: content,
    finish: m.finish,
    rawFinish: m.rawFinish,
    cost: m.cost,
    tokens: m.tokens,
    error: m.error,
    snapshot: m.snapshot,
  );

  /// `notifyListeners` sin romper después de [dispose]: el stream y los timers
  /// son asíncronos y pueden hablar tarde.
  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    // Doble dispose (el shell descarta la vista y el widget se cierra a la
    // vez) reventaba con el assert de ChangeNotifier. Idempotente.
    if (_disposed) return;
    _disposed = true;
    disposeStream();
    super.dispose();
  }
}
