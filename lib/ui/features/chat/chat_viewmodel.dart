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
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

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

/// Eventos que traen el estado del turno. La lista es la medida en `:4098`
/// (`session.status`) más los nombres del openapi más nuevo, que conviven sin
/// costo (mismo criterio que en `lib/domain/models/event.dart`).
const Set<String> kChatStatusEvents = {
  'session.status',
  'session.idle',
  'session.next.status',
  'session.execution.started',
  'session.execution.completed',
};

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
  int _localSeq = 0;

  ChatEventSource? _source;
  StreamSubscription<OcEvent>? _events;
  StreamSubscription<StreamState>? _states;
  Timer? _deltaTimer;
  Timer? _refetchTimer;
  Timer? _pollTimer;
  String _pendingText = '';
  String _pendingReasoning = '';
  bool _disposed = false;

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

  // ───────────────────────────────── carga ──────────────────────────────────

  /// `GET /api/session/{id}/message?limit=30&order=asc`.
  ///
  /// `order: 'asc'` + el cursor `previous` que devuelve el server: la página
  /// se muestra vieja→nueva y el botón "Cargar 30 anteriores" pide la página
  /// anterior. El cursor es opaco y lo posee el server (§2): la app lo pasa de
  /// vuelta, no lo interpreta.
  Future<void> load() async {
    _loading = true;
    _error = null;
    _safeNotify();
    try {
      // `desc` + reverse: la primera página trae los ÚLTIMOS mensajes y la
      // lista queda en orden cronológico. Con `asc` se abriría en el mensaje
      // más viejo de la sesión, que es justo lo que el contrato de scroll
      // prohíbe ("al entrar al chat arrancás en el último mensaje").
      final page = await _api.listMessages(
        sessionId,
        limit: pageSize,
        order: 'desc',
        directory: directory,
      );
      _ingest(page.data.reversed.toList(growable: false));
      _earlierCursor = page.previous;
    } on OchError catch (e) {
      _error = e.message;
    } finally {
      _loading = false;
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
        limit: pageSize,
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

  /// Re-fetch silencioso. Es lo que dispara un `isSettledEvent`: el delta es
  /// live-only, el valor final llega con el mensaje completo (§7.5).
  Future<void> refresh() => load();

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
    if (_visible == visible) return;
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
    _pollTimer = Timer.periodic(pollInterval, (_) => refresh());
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

    final type = event.type;

    // Canal C: `session.error` — aviso no bloqueante (§5).
    if (type == 'session.error') {
      _error = OcErrorInfo.fromJson(event.data['error']).toString();
      _safeNotify();
      return;
    }

    if (kChatStatusEvents.contains(type.toLowerCase())) {
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

  void _applyStatus(Map<String, Object?> data) {
    final status = data['status'] ?? data['type'];
    if (isBusyStatus(status)) {
      _busyStatus = true;
    } else if (isSettledStatus(status)) {
      _busyStatus = false;
      _awaitingAssistant = false;
    } else {
      return; // un status desconocido no afirma nada
    }
    _recomputeWorking();
    _safeNotify();
  }

  void _applyDelta(String type, Map<String, Object?> data) {
    _awaitingAssistant = false;
    final chunk = asStr(data['text']) ?? asStr(data['delta']) ?? '';
    if (chunk.isEmpty) return;

    if (type.toLowerCase().contains('reasoning')) {
      _pendingReasoning += chunk;
    } else if (type.toLowerCase().contains('text')) {
      _pendingText += chunk;
    } else {
      // `tool.input.delta` es live-only y además su valor final llega en
      // `tool.input.ended` (que dispara el re-fetch): no se aplica al modelo.
      return;
    }

    // 20 fps: se agrupan los deltas de 50 ms en un solo rebuild.
    _deltaTimer ??= Timer(deltaInterval, _flushDeltas);
  }

  void _flushDeltas() {
    _deltaTimer?.cancel();
    _deltaTimer = null;
    final text = _pendingText;
    final reasoning = _pendingReasoning;
    _pendingText = '';
    _pendingReasoning = '';
    if (text.isEmpty && reasoning.isEmpty) return;

    final index = _messages.lastIndexWhere((m) => m is AssistantMessage);
    if (index < 0) return;
    final current = _messages[index] as AssistantMessage;

    final content = [...current.content];
    if (reasoning.isNotEmpty) _appendTo(content, reasoning, reasoning: true);
    if (text.isNotEmpty) _appendTo(content, text, reasoning: false);
    _messages[index] = _copyAssistant(current, content);

    _recomputeWorking();
    _safeNotify();
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

  /// Reemplaza la lista local por la del server.
  ///
  /// Los mensajes optimistas (`local_…`) se caen: el server persiste el prompt
  /// al admitirlo (decisión D4), así que la re-fetch es la que los cambia por
  /// los mensajes con id real. Si el re-fetch falla, no se toca la lista.
  void _ingest(List<dynamic> raw) {
    _messages
      ..clear()
      ..addAll(_parseAll(raw));
  }

  void _recomputeWorking() {
    final status = _busyStatus;
    if (status != null) {
      // Evidencia viva: manda el status, para que el botón Detener no quede
      // pegado por un `time.completed` que todavía no llegó (§7.4).
      _working = status;
      return;
    }
    final last = lastAssistant;
    _working = _awaitingAssistant || (last != null && !last.isComplete);
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
    _disposed = true;
    disposeStream();
    super.dispose();
  }
}
