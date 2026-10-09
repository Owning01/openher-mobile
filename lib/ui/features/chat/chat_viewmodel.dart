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
/// Eventos que abren y cierran un turno.
///
/// **Medido 2026-09-28** capturando el stream real del server durante un turno
/// completo, no leyendo el spec: en el dialecto v2 **no existe** ni
/// `session.status` ni `session.idle`. El stream manda
///
///     session.execution.started   {"sessionID":"ses_…"}
///     session.execution.succeeded {"sessionID":"ses_…"}
///
/// y, además, el endpoint de mensajes inserta un mensaje `{"type":"idle"}` al
/// terminar cada turno.
///
/// Los nombres v1 se quedan en el conjunto a propósito: si un build viejo los
/// emitiera, seguírían siendo la misma señal, y borrarlos sería volver a
/// romper el botón Detener sin avisar. Un conjunto con nombres de más es
/// inofensivo; uno con nombres de menos congela la UI.
const Set<String> kChatStatusEvents = {
  'session.execution.started',
  'session.execution.succeeded',
  'session.execution.failed',
  'session.status',
  'session.idle',
};

/// `type: "idle"` — el mensaje con el que el server cierra el turno.
///
/// No es un mensaje para la persona: `SessionMessage.fromJson` lo convertía en
/// un `SystemMessage` vacío y cada turno dejaba una burbuja en blanco en el
/// chat. Va aparte justamente para que se pueda usar como señal de cierre sin
/// que se pinte.
const String kIdleMessageType = 'idle';

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

/// La pregunta que el agente está esperando, tal como la mandó `question.asked`
/// o `form.created` (el protocolo nuevo, medido 2026-10-09 en `:4098`).
final class PendingQuestion {
  const PendingQuestion({
    required this.requestId,
    required this.questions,
    this.callId,
    this.messageId,
    this.fieldKey,
  });

  /// `que_…` o `frm_…`: el `id` del evento y el `{requestID}` del reply.
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

  /// Clave del campo en un form (`q0`): sin ella no hay `{answer:{key:value}}`
  /// que mandar al endpoint de forms. `null` en el protocolo viejo.
  final String? fieldKey;
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

  /// El cliente con el que se habla con el server.
  ///
  /// Lo expone la vista para armar lo que necesita de la red sin que el shell
  /// se lo pase por parámetro (la hoja de modelo usa su mismo `ApiClient`, y
  /// así comparte la config y las credenciales de esta sesión).
  ApiClient get api => _api;

  /// Modelo y agente **elegidos en esta sesión de la UI**, con prioridad sobre
  /// lo que dice el server.
  ///
  /// Hace falta porque los endpoints de cambio (`POST /api/session/{id}/model`
  /// y `.../agent`) responden **204 sin cuerpo** —medido—: no hay nada que
  /// deserializar, y `sessionInfo` además es `final`, entra por constructor y
  /// no se puede re-asignar. Sin estos dos campos, después de elegir un modelo
  /// los pills seguirían diciendo "Elegir modelo" hasta el próximo arranque, que
  /// es exactamente el síntoma que reportó el usuario.
  ModelRef? _pickedModel;
  String? _pickedAgent;

  /// El modelo en uso: lo elegido, y si no se eligió nada, el de la sesión.
  ModelRef? get currentModel => _pickedModel ?? sessionInfo?.model;

  /// El agente en uso: idem para el agente.
  String? get currentAgent => _pickedAgent ?? sessionInfo?.agent;

  /// Registra la elección sin volver a pedir la sesión al server.
  ///
  /// Un argumento `null` significa "no lo toco", nunca "borralo": borrar un
  /// campo es otra operación y no se puede expresar por ausencia de valor.
  void applySelection({ModelRef? model, String? agent}) {
    if (model == null && agent == null) return;
    if (model != null) _pickedModel = model;
    if (agent != null) _pickedAgent = agent;
    _safeNotify();
  }

  /// Mensajes en orden cronológico. Incluye los optimistas (`local_…`) hasta
  /// que un re-fetch los reemplaza por los del server.
  final List<SessionMessage> _messages = [];

  bool _working = false;

  /// Tri-estado del `session.status` más reciente: `true` = trabajando,
  /// `false` = terminado, `null` = nunca llegó.
  bool? _busyStatus;

  /// La pÃ¡gina siguiente para el botÃ³n "Cargar N anteriores".
  ///
  /// **Medido 2026-09-28** contra `:4098` con una sesiÃ³n de 200 mensajes:
  ///
  ///   order=desc&limit=3   ->  los 3 MÃS NUEVOS, del mÃ¡s nuevo al mÃ¡s viejo
  ///     cursor.previous   ->  {id: <el primero de la pÃ¡gina>, direction:"previous"}
  ///     cursor.next       ->  {id: <el Ãºltimo de la pÃ¡gina>,  direction:"next"}
  ///   cursor=previous     ->  0 Ã­tems  (va hacia lo NUEVO: ya no hay)
  ///   cursor=next         ->  los siguientes 50 hacia ATRÃS
  ///
  /// O sea que `previous` es el cursor "hacia adelante en el tiempo" y
  /// `next` es el cursor "hacia atrÃ¡s". Leer `previous` para cargar mensajes
  /// anteriores no daba error: daba una pÃ¡gina **vacÃ­a**. Por eso el botÃ³n
  /// no cargaba nada y daba la impresiÃ³n de que estaba roto.
  String? _earlierCursor;

  /// Cursor "hacia lo nuevo", que es contra el que consulta el **poll**.
  ///
  /// Es el hermano de [_earlierCursor] pero en la otra dirección: `_earlier`
  /// camina hacia atrás con `next`, este camina hacia adelante con `previous`.
  ///
  /// Existe por medición, no por gusto. El poll antes era un `refresh()`: un
  /// re-fetch de la página entera, que en la sesión medida pesaba **25.511
  /// bytes**. Con `cursor.previous` el mismo poll cuando no hay nada nuevo
  /// pesa **50 bytes**: 510x menos. Repitido cada 2 s son 45 MB/h en vez de
  /// 0,09 MB/h.
  String? _newerCursor;

  StreamState? _streamState;

  /// Enviamos un prompt y todavia no llego ningun assistant.
  bool _awaitingAssistant = false;

  String? _error;
  bool _loading = false;
  bool _loadingEarlier = false;
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

  /// Gasto y tokens **en vivo**, sin esperar el re-fetch.
  ///
  /// **Medido 2026-09-28**: el server manda `session.usage.updated` en cada
  /// paso (`{sessionID, cost, tokens:{input, output, reasoning, cache}}`).
  /// Antes solo se leian de la pagina de mensajes, o sea que el contador de
  /// contexto y de costo se congelaba hasta el proximo re-fetch: se veia
  /// "17208k contexto - $3.38" clavado mientras el modelo seguia trabajando.
  int? _liveTokens;
  double? _liveCost;

  /// El titulo que el server le puso a la sesion (`session.renamed`, medido).
  ///
  /// El server titula solo, con el primer mensaje. Sin este evento el chat se
  /// quedaba mostrando `ses_0acd172...` hasta un re-fetch completo, y el
  /// usuario veia un id donde deberia ver de que hablaba.
  String? _liveTitle;

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

  /// **Contexto en tokens**: lo que el modelo tiene cargado ahora mismo.
  ///
  /// Antes esto se llamaba `serverTokens` y devolvía la **suma acumulada de
  /// tokens de toda la sesión**, etiquetada como "contexto". Medido contra el
  /// server real sobre una sesión larga: la app mostraba **15.538.680** donde
  /// el contexto real era **102.924**, o sea **151×** inflado.
  ///
  /// La causa: `session.tokens` es un **contador acumulado** (input, output y
  /// `cache.read` de *todos* los turnos, sumados), no una foto de la ventana.
  /// Sólo crece, y en una sesión larga crece sin techo.
  ///
  /// El contexto de verdad es el prompt del **último** turno del assistant:
  /// `input + cache.read + reasoning`. Ver [TokenUsage.context] para por qué
  /// `cache.write` y `output` quedan fuera.
  ///
  /// Pasa primero por el valor del SSE ([_liveTokens]) porque durante un turno
  /// en vuelo el mensaje del assistant todavía no cerró y no tiene tokens: sin
  /// eso el contador quedaría congelado en el turno anterior justo cuando más
  /// se lo mira. Las dos fuentes usan la misma fórmula, así que el número sólo
  /// salta si el server accounta distinto el prompt, no porque la app mezclara
  /// dos definiciones (que es lo que pasaba antes: el vivo sumaba `output` y el
  /// de respaldo no leía `cache` en absoluto).
  int get contextTokens => _liveTokens ?? _contextFromMessages;

  /// El contexto del último assistant que cerró. Sin ninguno, `0`.
  int get _contextFromMessages {
    for (var i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i] case final AssistantMessage a) {
        return a.tokens.context;
      }
    }
    return 0;
  }

  /// El costo acumulado de la sesión, en USD. Esto **sí** es un acumulado y por
  /// eso es correcto: el costo gastado no se reread de la ventana.
  double get serverCost {
    final live = _liveCost;
    if (live != null) return live;
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
  /// El titulo de la sesion: el que le puso el server con
  /// `session.renamed`, si no el de la lista, y si no el id recortado.
  ///
  /// El server titula solo con el primer mensaje (medido). Sin esto el
  /// chat se quedaba mostrando `ses_0acd172...` hasta un re-fetch
  /// completo: el usuario veia un id donde deberia ver de que hablaba.
  String? get liveTitle => _liveTitle ?? sessionInfo?.title;

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
      // **El orden importa**: primero la página, después el cierre de turno.
      //
      // Al revés, `_closeOpenAssistant()` marcaba el assistant abierto con un
      // `finish` local y enseguida `_ingest()` lo pisaba con la versión del
      // server de esa misma página. Cuando el server todavía no había escrito
      // el `finish` del mensaje (medido: `completed: false, finish: null` en el
      // assistant más reciente), el cierre local se deshacía en el mismo
      // breath y `working` volvía a `true`: **el botón Detener no desaparecía**.
      //
      // Ingerido primero, `_closeOpenAssistant()` marca el mensaje recién
      // operativo y nada lo sobrescribe.
      _ingest(page.data.reversed.toList(growable: false));
      _applyTurnEndFromPage(page.data);
      // El cursor de "anteriores" sÃ³lo retrocede: un re-fetch de la
      // Ãºltima pÃ¡gina no puede devolver el cursor hacia atrÃ¡s de lo
      // ya cargado. Se guarda `next` (el que avanza hacia atrÃ¡s,
      // medido) y no `previous`, que va hacia lo nuevo y siempre
      // venÃ­a vacÃ­o.
      _earlierCursor ??= page.next;
      // El de "hacia lo nuevo" sÃ­ se mueve: es el ancla del poll, y hay que
      // actualizarlo en cada pÃ¡gina completa para que el poll no se quede
      // mirando un mensaje viejo y no vea nunca los nuevos.
      _newerCursor = page.previous;
    } on OchError catch (e) {
      if (_disposed || seq < _appliedFetch) return;
      _error = e.message;
    } finally {
      if (loading) _loading = false;
      _recomputeWorking();
      _safeNotify();
    }
  }

  /// La página anterior, para el botón "Cargar N anteriores".
  ///
  /// Tres cosas que se aprendieron midiendo, y las tres costaban un botón
  /// muerto:
  ///
  /// 1. Con cursor **no** se manda `order` (medido: `InvalidCursorError:
  ///    Cursor cannot be combined with order`).
  /// 2. El cursor para ir hacia atrás es **`next`**, no `previous`. Con
  ///    `previous` la respuesta venía **vacía** y sin error, que es la peor
  ///    forma de fallar: parecía que el botón no hacía nada.
  /// 3. La página con `direction:"next"` llega del más nuevo al más viejo,
  ///    igual que la primera, así que hay que **invertirla** antes de
  ///    insertarla al frente. Sin invertir, el bloque de mensajes viejos
  ///    quedaba al revés y el chat se leía desordenado.
  Future<void> loadEarlier() async {
    final cursor = _earlierCursor;
    if (cursor == null || _loadingEarlier) return;
    _loadingEarlier = true;
    _safeNotify();
    try {
      final page = await _api.listMessages(
        sessionId,
        limit: _policy.pageSize,
        order: null,
        cursor: cursor,
        directory: directory,
      );
      if (_disposed) return;
      final older = _parseAll(page.data.reversed.toList(growable: false));
      if (older.isEmpty) {
        // Se terminó el historial. **Hay que cortar acá**: si se deja el cursor
        // puesto, el botón queda habilitado para siempre y cada toque vuelve
        // a pegarle al server por una página vacía.
        _earlierCursor = null;
        return;
      }
      _earlierCursor = page.next;
      _messages.insertAll(0, older);
    } on OchError catch (e) {
      if (_disposed) return;
      _error = e.message;
    } finally {
      _loadingEarlier = false;
      _safeNotify();
    }
  }

  /// El poll: consulta **sólo lo nuevo**, con el cursor, no la página entera.
  ///
  /// Esto es lo que baja el costo de datos, y el número es medido contra el
  /// server real, no estimado:
  ///
  /// | poll | bytes | qué trae |
  /// |---|---|---|
  /// | re-fetch de la página (`refresh()`) | **25.511** | 15 mensajes enteros |
  /// | `cursor.previous` sin nada nuevo | **50** | 0 mensajes |
  ///
  /// Son 510x por consulta, y el poll corre cada 2 s. A la larga: 45 MB/h
  /// donde antes eran 0,09 MB/h.
  ///
  /// ## Por qué no se puede usar el `previous` que devuelve la respuesta
  ///
  /// Cuando no hay nada nuevo el server responde con `0 ítems` y
  /// **`cursor.previous: null`**. Null acá **no** significa "no hay cursor",
  /// significa "no hay nada más nuevo *por ahora*". Si se guardara el null,
  /// el poll volvería a caer en la página completa de 25 KB en cada vuelta:
  /// la optimización se apagaría sola en silencio, que es la forma más
  /// difícil de detectar. Por eso el cursor viejo **se conserva**.
  ///
  /// ## Por qué es un método aparte y no un parámetro de `_fetch`
  ///
  /// `refresh()` tiene que seguir siendo la página completa: es la verdad de
  /// de fondo al volver a primer plano (`setVisible`) y no se puede recorrer
  /// con un cursor, porque si mientras tanto otro cliente de la sesion
  /// agrego mensajes, el cursor no los ve. El poll si puede vivir con el
  /// cursor porque su trabajo es "?llego algo nuevo?", no "decime todo".
  /// un cursor, porque si mientras tanto otro cliente de la sesión agregó
  /// mensajes, el cursor no los ve. El poll sí puede vivir con el cursor
  /// porque su trabajo es "¿llegó algo nuevo?", no "decime todo".
  ///
  /// Comparte [_fetchSeq] con [_fetch] a propósito: así un poll y un refresh
  /// que se solapan no se pisan, y el que llegó primero no pisa al que arrancó
  /// después.
  Future<void> _pollNewer() async {
    final cursor = _newerCursor;
    // Sin ancla no hay a dónde mirar: se cae a la página completa, que además
    // deja un cursor nuevo para el próximo poll.
    if (cursor == null) return _fetch(loading: false);

    final seq = ++_fetchSeq;
    try {
      final page = await _api.listMessages(
        sessionId,
        limit: _policy.pageSize,
        // `order` se manda `null` a propósito: con cursor el server lo
        // rechaza (medido: `Cursor cannot be combined with order`).
        order: null,
        cursor: cursor,
        directory: directory,
      );
      if (_disposed || seq < _appliedFetch) return;
      _appliedFetch = seq;

      if (page.data.isEmpty) {
        // No hay nada nuevo. Se conserva el cursor viejo: ver el doc.
        return;
      }
      // El orden de la respuesta con `previous` es **DESC** (medido: se tomó
      // una página vieja, se le pidió su `previous` y volvieron los 15
      // mensajes del más nuevo al más viejo), o sea el mismo que `order:'desc'`.
      // Por eso el `.reversed`, igual que en `_fetch`.
      _ingest(page.data.reversed.toList(growable: false));
      _applyTurnEndFromPage(page.data);
      // Acá sí hay `previous` nuevo: el ancla avanza al mensaje más nuevo.
      if (page.previous != null) _newerCursor = page.previous;
    } on OchError catch (e) {
      if (_disposed || seq < _appliedFetch) return;
      // Un cursor que el server ya no entiende (400) dejaría el poll roto en
      // silencio para siempre. Se tira el ancla y el próximo poll vuelve a la
      // página completa, que es el camino caro pero seguro.
      _newerCursor = null;
      _error = e.message;
    } finally {
      _recomputeWorking();
      _safeNotify();
    }
  }

  // ─────────────────────────────── responder ───────────────────────────────

  /// Responde la pregunta pendiente (`API_CONTRACT.md` §6).
  ///
  /// **Camino 1, el protocolo nuevo** (medido 2026-10-09):
  /// `POST /api/session/{id}/form/{formID}/reply` con `{answer: {key: value}}`
  /// —una entrada por campo, con el `value` de la opción (no el label).
  /// Devuelve 204.
  ///
  /// **Camino 2, el protocolo viejo**:
  /// `POST /api/session/{id}/question/{requestID}/reply` con
  /// `{answers: [[…]]}` — un array por pregunta, en el orden en que se
  /// hicieron. Devuelve 204.
  ///
  /// **Camino 3, el que nunca falla**: si ningún endpoint existe (404) o el
  /// POST falla, las respuestas se mandan como un prompt del usuario normal.
  /// El server los acepta como respuesta y el turno se destraca igual.
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
      // El form manda el `value` de la opción elegida bajo la clave del campo
      // (`{answer: {q0: value}}`). Sin `fieldKey` no hay mapa que armar: se
      // sigue al camino viejo.
      final key = _pendingQuestion?.fieldKey;
      final values = [for (final a in answers) ...a.where((l) => l.isNotEmpty)];
      if (key != null && key.isNotEmpty && values.isNotEmpty) {
        try {
          await _api.postJson(
            '/session/$sessionId/form/$id/reply',
            body: <String, Object?>{
              'answer': <String, Object?>{key: values.first},
            },
          );
          _pendingQuestion = null;
          _lastQuestionReplyPath = QuestionReplyPath.api;
          _recomputeWorking();
          _safeNotify();
          return QuestionReplyPath.api;
        } on OchError {
          // Sin endpoint de forms en este build: se sigue al camino viejo.
        }
      }
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

    // Sin encolar: es la respuesta a lo que el server está preguntando, no un
    // mensaje nuevo. Encolarla lo dejaba esperando para siempre.
    await send(_answerPrompt(answers), encolable: false);
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
  /// [encolable] es lo que separa "mensaje nuevo del usuario" de "respuesta a
  /// una pregunta del server".
  ///
  /// El segundo caso **nunca** se encola: el server no está trabajando, está
  /// bloqueado esperando esa respuesta, y mandarla por el prompt la
  /// convertiría en un mensaje nuevo en vez de la respuesta, dejando el turno
  /// trabado. Por eso `answerQuestion` manda con `encolable: false`.
  ///
  /// No alcanza con mirar `_pendingQuestion`: `answerQuestion` acepta un
  /// `requestId` explícito y se puede llamar sin que el app haya registrado la
  /// pendiente (medido: 3 tests de "preguntas" caían con esa regla).
  Future<void> send(
    String text, {
    List<Map<String, String>>? files,
    List<String>? agents,
    bool encolable = true,
  }) async {
    final body = text.trim();
    if (body.isEmpty) return;

    // **Si hay un turno en curso, el prompt NO se manda.** Se queda en el
    // chat como pendiente, con las tres acciones (enviar / editar /
    // eliminar), y lo manda el usuario cuando quiere.
    //
    // Medido contra el server real: mandar con la sesión ocupada **no da
    // 409**, da 200 y el mensaje vuelve con `"delivery": "steer"`, o sea que
    // el server no lo encola: redirige el turno que está corriendo. Mandarlo
    // sin que el usuario lo pida desvía la conversación en curso, que es
    // justo lo contrario de "encolar". Frenar antes del POST es lo único que
    // lo evita.
    //
    // **Excepción: hay una pregunta esperando.** Cubierta por [encolable]: la
    // respuesta a una pregunta va con `encolable: false` y nunca queda
    // pendiente.
    final enCurso = encolable && working && _pendingQuestion == null;

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

      pendingSend: enCurso,

    );

    _messages.add(local);
    _recomputeWorking();

    _safeNotify();


    // Pendiente: no hay POST. Sale acá, antes de tocar la red.

    if (enCurso) return;


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
      // **El mensaje NO se borra.** Antes se hacía `removeWhere`, y con eso lo
      // que el usuario había escrito desaparecía: al mandar con el agente
      // trabajando el server responde 409 Conflict y el prompt se perdía sin
      // dejar rastro, que es exactamente lo que reportó.
      //
      // Un texto del usuario no se borra por un fallo de transporte: se marca
      // `notDelivered`, se avisa, y queda el reintento a un toque.
      _markNotDelivered(local.id);
      _awaitingAssistant = false;
      _recomputeWorking();
      _error = e.message;
      _safeNotify();
    }
  }

  /// Marca un mensaje local como no entregado, sin sacarlo de la lista.
  void _markNotDelivered(String id) {
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      if (m is! UserMessage || m.id != id) continue;
      _messages[i] = m.copyWith(notDelivered: true);
      return;
    }
  }

  /// Vuelve a mandar un mensaje que el server no tomó.
  ///
  /// Es el camino del 409 (sesión ocupada) y del 429 (rate limit): el texto
  /// estaba en pantalla todo el tiempo, marcado, esperando este toque.
  Future<void> retrySend(String localId) async {
    final at = _messages.indexWhere((m) => m is UserMessage && m.id == localId);
    if (at < 0) return;
    final m = _messages[at];
    if (m is! UserMessage) return;

    _messages[at] = m.copyWith(notDelivered: false);
    _error = null;
    _awaitingAssistant = true;
    _busyStatus = null;
    _recomputeWorking();
    _safeNotify();

    try {
      await _api.sendPrompt(
        sessionId,
        text: m.text,
        // `sendPrompt` toma adjuntos como mapas crudos, no como
        // `UserFileAttachment`: se traduce, no se pasa la lista tal cual.
        files: m.files.isEmpty
            ? null
            : [
                for (final f in m.files) {
                  'uri': f.uri,
                  if (f.name != null) 'name': f.name!,
                  if (f.mime != null) 'mime': f.mime!,
                },
              ],
        agents: m.agents.isEmpty ? null : m.agents,
        directory: directory,
      );
    } on OchError catch (e) {
      _markNotDelivered(localId);
      _awaitingAssistant = false;
      _recomputeWorking();
      _error = e.message;
      _safeNotify();
    }
  }

  /// El id del assistant **abierto**: el último de la lista, que es al que
  /// le llegan los deltas del stream.
  ///
  /// Lo necesita la burbuja para no pintar los puntos de escritura en todos los
  /// lados. Antes la condición era `working && texto vacío`, y `working` es
  /// del turno entero: un mensaje de assistant que **sólo tiene tool calls**
  /// tiene el texto vacío por diseño, así que cada uno pintaba sus puntos
  /// durante todo el turno y todos desaparecían al terminar. Con varios
  /// mensajes así era "muchos spinner en el chat que luego desaparecen".
  String? get openAssistantId {
    for (var i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i] is AssistantMessage) return _messages[i].id;
    }
    return null;
  }

  /// Los mensajes que el usuario todavía no mandó: los que están esperando
  /// que los mande, editar o borrar. En orden de aparición.
  List<UserMessage> get pendings => [
    for (final m in _messages)
      if (m is UserMessage && m.pendingSend) m,
  ];

  /// El texto de un pendiente, para devolverlo al compositor a editar.
  ///
  /// Editar **cancela** el pendiente: el mensaje se saca del chat y el texto
  /// vuelve al campo. Si el usuario no lo manda de nuevo, no vuelve a
  /// aparecer: no queda nada de él guardado.
  String? takePendingText(String localId) {
    final at = _indexOfUser(localId);
    if (at < 0) return null;
    final m = _messages[at];
    if (m is! UserMessage || !m.pendingSend) return null;
    _messages.removeAt(at);
    _safeNotify();
    return m.text;
  }

  /// Borra un pendiente y no vuelve a aparecer.
  ///
  /// No queda ni rastro local: el mensaje nunca estuvo en el server, así que
  /// ningún re-fetch lo puede resucitar. El `removeWhere` por id es lo que
  /// garantiza eso.
  void discardPending(String localId) {
    final at = _indexOfUser(localId);
    if (at < 0) return;
    _messages.removeAt(at);
    _safeNotify();
  }

  /// Manda un pendiente que el usuario confirmó.
  ///
  /// Recibe el `delivery: steer` del server como una aceptación normal: acá el
  /// server guardó el mensaje y lo procesa. Si el POST falla, el mensaje no se
  /// borra: pasa a `notDelivered` con su reintento, como cualquier otro.
  Future<void> confirmSend(String localId) async {
    final at = _indexOfUser(localId);
    if (at < 0) return;
    final m = _messages[at];
    if (m is! UserMessage || !m.pendingSend) return;

    _messages[at] = m.copyWith(pendingSend: false);
    _awaitingAssistant = true;
    _busyStatus = null;
    _recomputeWorking();
    _safeNotify();

    try {
      await _api.sendPrompt(
        sessionId,
        text: m.text,
        files: m.files.isEmpty
            ? null
            : [
                for (final f in m.files) {
                  'uri': f.uri,
                  if (f.name != null) 'name': f.name!,
                  if (f.mime != null) 'mime': f.mime!,
                },
              ],
        agents: m.agents.isEmpty ? null : m.agents,
        directory: directory,
      );
    } on OchError catch (e) {
      _markNotDelivered(localId);
      _awaitingAssistant = false;
      _recomputeWorking();
      _error = e.message;
      _safeNotify();
    }
  }

  int _indexOfUser(String id) =>
      _messages.indexWhere((m) => m is UserMessage && m.id == id);

  /// Los mensajes del usuario que el server todavía no tomó, en orden.
  List<UserMessage> get undelivered => [
    for (final m in _messages)
      if (m is UserMessage && m.notDelivered) m,
  ];


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

  /// Deja un error a la vista desde fuera del VM.
  ///
  /// Lo usan las acciones que el chat dispara por su cuenta (cambiar de
  /// modelo o de agente): antes no había forma de que un fallo de esas
  /// se viera, porque el error sólo lo ponían los pedidos de mensajes.
  void reportError(String message) {
    if (_disposed || message.isEmpty) return;
    _error = message;
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
    // `_pollNewer()` y no `refresh()`: el timer es lo que corre cada 2 s sin
    // parar, y `refresh()` re-descarga la página entera (medido: 25.511 bytes
    // por vuelta). `_pollNewer()` pregunta con el cursor y, cuando no hay nada
    // nuevo, pesa 50 bytes. `refresh()` sigue siendo la verdad de fondo y se
    // sigue llamando desde `setVisible` y desde los eventos del stream.
    _pollTimer = Timer.periodic(_policy.pollInterval, (_) => _pollNewer());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  // ───────────────────────── aplicación de eventos ─────────────────────────

  /// Un frame del stream global. Todo el filtrado y toda la política viven acá.
  /// `session.usage.updated` - gasto y tokens en vivo.
  ///
  /// **Medido 2026-09-28**: `{sessionID, cost, tokens: {input, output,
  /// reasoning, cache}}`. Sin esto el contador de contexto queda congelado
  /// hasta el proximo re-fetch, que durante un turno puede tardar segundos.
  void _applyUsage(Map<String, Object?> data) {
    final cost = data['cost'];
    if (cost is num) _liveCost = cost.toDouble();
    final tokens = asMap(data['tokens']);
    if (tokens != null) {
      // Contexto del turno **en vuelo**: `input + cache.read + reasoning`, la
      // misma fórmula que [TokenUsage.context].
      //
      // Antes sumaba `output` y saltaba `reasoning`. El `output` no es
      // contexto: es lo que se está generando, así que contaminaba el número
      // mientras el turno corría, y el `reasoning` faltando hacía que una
      // sesión con mucho razonamiento mostrara menos de lo que tenía.
      //
      // Y antes de esto el valor vivo y el de respaldo significaban cosas
      // **distintas** (`input + output + cache.read` en vivo contra el
      // acumulado de la sesión sin cache), así que el mismo rótulo cambiaba de
      // número según el SSE estuviera conectado o no. Ahora los dos caminos
      // usan la misma definición.
      final input = asNum(tokens['input']) ?? 0;
      final reasoning = asNum(tokens['reasoning']) ?? 0;
      final cacheRead = asNum(asMap(tokens['cache'])?['read']) ?? 0;
      _liveTokens = (input + cacheRead + reasoning).toInt();
    }
    _safeNotify();
  }

  /// `session.renamed` - el server titulo la sesion sola.
  void _applyRenamed(Map<String, Object?> data) {
    final title = asStr(data['title']);
    if (title == null || title.isEmpty) return;
    if (_liveTitle == title) return;
    _liveTitle = title;
    _safeNotify();
  }

  void _applyEvent(OcEvent event) {
    // Filtro por sesión: el socket es global. Un evento sin `sessionID`
    // (`server.connected`) es de la app y se aplica.
    //
    // Los `form.*` traen la sesión anidada (`data.form.sessionID`), no en
    // `data.sessionID`: sin esa segunda mirada se aplicarían al chat
    // equivocado (o a todos).
    final id = _eventSessionId(event);
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
    // Medidos y sin manejar antes: el costo/contexto en vivo y el titulo
    // que el server le pone solo a la sesion.
    if (lower == 'session.usage.updated') {
      _applyUsage(event.data);
      return;
    }
    if (lower == 'session.renamed') {
      _applyRenamed(event.data);
      return;
    }

    if (kQuestionAskedEvents.contains(lower)) {
      _applyQuestionAsked(event.data);
      // La lista de mensajes todavía no tiene el tool `question` en `pending`:
      // el re-fetch lo trae y recién ahí se puede pintar la card.
      _scheduleRefetch();
      return;
    }
    // Protocolo nuevo (medido 2026-10-09): la pregunta viaja como
    // `form.created` con `metadata.kind == 'question'` y se cierra con
    // `form.replied`. El `question.asked` de arriba ya no lo manda el server
    // (0 frames en 688), pero se conserva por si algún build lo emite.
    if (lower == 'form.created') {
      _applyFormCreated(event.data);
      _scheduleRefetch();
      return;
    }
    if (lower == 'form.replied') {
      _clearQuestion(event.data);
      _scheduleRefetch();
      return;
    }
    if (kQuestionClosedEvents.contains(lower)) {
      _clearQuestion(event.data);
      _scheduleRefetch();
      return;
    }

    if (lower.startsWith('session.execution.')) {
      _applyExecution(lower);
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

  /// `form.created` con `metadata.kind == 'question'`.
  ///
  /// Forma medida 2026-10-09:
  /// `data.form = {id: frm_…, sessionID, title, metadata: {kind, tool?},
  /// fields: [{key, title, description, type, options: [{value, label,
  /// description}], custom}]}`. Los fields se proyectan al shape viejo
  /// (`header` ← title, `question` ← description) para que la card no cambie;
  /// lo único nuevo es el `value` de cada opción, que es lo que el endpoint de
  /// forms espera en `{answer: {key: value}}`.
  ///
  /// Solo se acepta `kind == 'question'`: otros kinds (permisos, etc.) no son
  /// preguntas y la card no sabría qué pedir.
  void _applyFormCreated(Map<String, Object?> data) {
    final form = asMap(data['form']);
    if (form == null) return;
    if (asStr(asMap(form['metadata'])?['kind']) != 'question') return;
    final fields = asMapList(form['fields']);
    if (fields.isEmpty) return;
    final tool = asMap(asMap(form['metadata'])?['tool']);
    final first = fields.first;
    _pendingQuestion = PendingQuestion(
      requestId: asStr(form['id']) ?? '',
      questions: [
        for (final field in fields)
          <String, Object?>{
            'header': asStr(field['title']),
            'question': asStr(field['description']),
            'options': [
              for (final option in asMapList(field['options']))
                <String, Object?>{
                  'label': asStr(option['label']),
                  'description': asStr(option['description']),
                  'value': asStr(option['value']),
                },
            ],
          },
      ],
      callId: asStr(tool?['id']),
      messageId: asStr(tool?['messageID']),
      fieldKey: asStr(first['key']),
    );
    _recomputeWorking();
    _safeNotify();
  }

  /// Sesión dueña del evento. Los `form.*` la traen anidada
  /// (`data.form.sessionID`), que manda sobre la externa: en el frame medido
  /// la externa ni viene.
  static String? _eventSessionId(OcEvent event) {
    if (event.type.toLowerCase().startsWith('form.')) {
      return asStr(asMap(event.data['form'])?['sessionID']) ??
          event.sessionID;
    }
    return event.sessionID;
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

  /// Cierra o abre el turno según el evento.
  ///
  /// En v2 la señal no es un `status` sino el par
  /// `session.execution.started` / `session.execution.succeeded`
  /// (**medido 2026-09-28**, ver [kChatStatusEvents]). El nombre del evento va
  /// por parámetro porque `_applyEvent` ya lo tiene y el payload de ejecución
  /// no trae ningún campo que diga si abre o cierra.
  void _applyExecution(String event) {
    if (event == 'session.execution.started') {
      _busyStatus = true;
      _recomputeWorking();
      _safeNotify();
      return;
    }

    // Un `succeeded` (o `failed`) significa que el turno **terminó**. Punto.
    //
    // El mensaje del assistant sigue apareciendo como incompleto hasta que
    // vuelve el refetch que trae `finish` y `time.completed`; si el contrato
    // de `_recomputeWorking` ("el último assistant sin cerrar = trabajando")
    // se respeta a ciegas, el botón se queda en Detener durante esa ventana y,
    // si el refetch no llega, para siempre. Eso es exactamente lo que reportó
    // el usuario: "después de que ya se ha enviado me aparece directamente el
    // botón de stop".
    //
    // Por eso el cierre es autoritativo: se marca el assistant abierto como
    // terminado **y** se pide el refetch, que después deja el mensaje con los
    // valores reales del server (costo, tokens, finish de verdad). Lo local es
    // sólo para no dejar la UI clavada mientras llega.
    _busyStatus = false;
    _awaitingAssistant = false;
    _retryNotice = null;
    _closeOpenAssistant();
    _recomputeWorking();
    _safeNotify();
    _scheduleRefetch();
  }

  /// Marca como terminado el último assistant que seguía abierto.
  void _closeOpenAssistant() {
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m is! AssistantMessage) continue;
      if (m.isComplete) return;
      _messages[i] = _copyAssistant(m, m.content, finish: 'stop');
      return;
    }
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

  /// Los mensajes de la página, en orden cronológico.
  ///
  /// Filtra el `type: "idle"` (**medido 2026-09-28**): el server lo inserta en
  /// la lista al cerrar cada turno, y sin este filtro caía en el `default` de
  /// [SessionMessage.fromJson] como `SystemMessage` con texto vacío — una
  /// burbuja en blanco por cada turno, arriba del mensaje que sí importa.
  static List<SessionMessage> _parseAll(List<dynamic> raw) => [
    for (final item in raw)
      if (asMap(item) case final Map<String, Object?> m)
        if (asStr(m['type']) != kIdleMessageType) SessionMessage.fromJson(m),
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
  /// Borra el estado de "trabajando" si la página trae un cierre de turno.
  ///
  /// **Medido 2026-09-28**: el endpoint de mensajes inserta un
  /// `{"type":"idle","time":{…},"outcome":…}` al cerrar cada turno. Ese mensaje
  /// no se pinta (ver [_parseAll]), pero es la **única** señal de fin de turno
  /// que existe en modo de bajo consumo, donde no hay SSE y por lo tanto nunca
  /// llega `session.execution.succeeded`.
  ///
  /// Sin esto, el botón se quedaba en Detener y la línea "Working" con spinner
  /// seguía girando después de que la tarea había terminado: el mensaje
  /// assistant del último paso todavía venía sin `finish` en la página que el
  /// poll había alcanzado.
  void _applyTurnEndFromPage(List<dynamic> raw) {
    var closed = false;
    for (final item in raw) {
      final m = asMap(item);
      if (m == null) continue;
      if (asStr(m['type']) == kIdleMessageType) {
        closed = true;
        break;
      }
    }
    if (!closed) return;
    _busyStatus = false;
    _awaitingAssistant = false;
    _retryNotice = null;
    _closeOpenAssistant();
    _recomputeWorking();
  }

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
    List<AssistantContent> content, {
    String? finish,
  }) => AssistantMessage(
    id: m.id,
    time: m.time,
    metadata: m.metadata,
    agent: m.agent,
    model: m.model,
    content: content,
    finish: finish ?? m.finish,
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
