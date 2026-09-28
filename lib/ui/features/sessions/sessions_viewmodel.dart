/// Estado de la pantalla de sesiones.
///
/// [SessionsView] no habla con la red: lee este [ChangeNotifier]. Acá viven las
/// tres decisiones que son datos y no pixeles: el filtro de búsqueda, el
/// agrupado por fecha (`HOY` / `AYER` / `ESTA SEMANA` / `ANTERIORES`) y el
/// semáforo de "en ejecución".
///
/// ## Por qué el reloj es inyectable
/// Los grupos dependen de la fecha local; con `DateTime.now()` fijo, un test que
/// corre a las 00:01 reparte mal los buckets y falla una vez por día. [clock]
/// se inyecta y los tests usan un instante fijo.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/repositories/session_repository.dart';
import '../../../domain/models/session.dart';

/// Bucket de fechas de la lista. El orden del enum es el orden en pantalla.
enum SessionBucket {
  today('HOY'),
  yesterday('AYER'),
  thisWeek('ESTA SEMANA'),
  older('ANTERIORES');

  const SessionBucket(this.label);

  /// Rótulo uppercase que va en el encabezado del grupo.
  final String label;
}

/// Un grupo de la lista: encabezado + filas.
final class SessionGroup {
  const SessionGroup(this.bucket, this.sessions);

  final SessionBucket bucket;
  final List<SessionInfo> sessions;
}

/// Acciones del menú contextual y del swipe.
///
/// El dialecto v2 **no expone** todavía renombrar, forkear ni archivar desde
/// `/api/session` ([ApiClient] no tiene esos endpoints), así que la pantalla no
/// finge hacerlos: los reporta y vuelve. Cuando `ApiClient` crezca, la app los
/// cablea por [SessionsView.onAction] sin tocar la lista.
enum SessionAction { rename, fork, exportMarkdown, archive, close }

class SessionsViewModel extends ChangeNotifier {
  SessionsViewModel({
    required this.repository,
    this.pollInterval = const Duration(seconds: 5),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// La capa de datos. Pública para que un test pueda assertar contra el mismo
  /// repository, no para que la UI lo use: la pantalla sólo lee el estado.
  final SessionRepository repository;

  final DateTime Function() _clock;

  /// Cada cuánto se repregunta `GET /api/session/active` mientras la pantalla
  /// está montada. Es el polling barato de los dots "en ejecución".
  final Duration pollInterval;

  List<SessionInfo> _sessions = const <SessionInfo>[];
  Set<String> _running = const <String>{};
  Set<String> _attention = const <String>{};
  bool _loading = false;
  bool _loaded = false;
  bool _disposed = false;
  String? _error;
  String _query = '';
  Timer? _poll;

  /// Todo lo que trajo el server, del más reciente al más viejo. Sin filtro.
  List<SessionInfo> get sessions => _sessions;

  /// La sesiÃ³n con ese id, o `null`.
  ///
  /// Se usa al abrir un chat reciÃ©n creado para pasarle el `agent` y el
  /// `model` que el server ya devolviÃ³, en vez de un `SessionInfo` vacÃ­o.
  SessionInfo? findById(String id) {
    for (final s in _sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// [sessions] con el filtro de [query] aplicado (por título).
  List<SessionInfo> get visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _sessions;
    return [
      for (final s in _sessions)
        if (s.title.toLowerCase().contains(q)) s,
    ];
  }

  /// [visible] agrupado por día calendario de `time.updated`.
  List<SessionGroup> get groups => groupSessions(visible, _clock());

  /// Los `ses_…` que el server dice que están corriendo ahora mismo.
  Set<String> get running => _running;

  /// Ids de las sesiones que piden atención del usuario.
  ///
  /// Heurística medida y deliberada: `parentID` presente ⇒ la sesión es un
  /// **subagente** de otra, o sea que hay un hijo esperando y el padre no está
  /// mirando. La lista de sesiones no trae el estado de las preguntas del tool
  /// `question` (eso llega por SSE del chat), así que no se puede afirmar
  /// "1 pregunta" sin inventarlo; lo que sí se puede marcar es el subagente.
  Set<String> get attention => _attention;

  /// `true` mientras va un `GET /api/session` o un `+`.
  bool get loading => _loading;

  /// Ya se intentó cargar al menos una vez (evita recargar al reentrar).
  bool get loaded => _loaded;

  /// Último error de la carga, ya en español y sin secretos.
  String? get error => _error;

  /// Texto del filtro de búsqueda.
  String get query => _query;

  bool isRunning(SessionInfo session) => _running.contains(session.id);

  bool needsAttention(SessionInfo session) => _attention.contains(session.id);

  /// Tiempo relativo de la fila, contra el **mismo** reloj que arma los grupos:
  /// si la fila dijera `ayer` y el encabezado `HOY` sería una contradicción
  /// visible en la misma pantalla.
  String relativeTime(SessionInfo session) =>
      formatRelative(session.updatedAtMs, _clock());

  /// Gasto de la fila: `$0.42`.
  String costOf(SessionInfo session) => formatCost(session.cost);

  /// Primera carga: muestra el spinner. [refresh] es el pull-to-refresh.
  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    _error = null;
    _notify();
    try {
      final sessions = await repository.list();
      _sessions = sessions;
      _attention = {
        for (final s in sessions)
          if (s.parentID != null) s.id,
      };
      _loaded = true;
    } on Object catch (error) {
      _error = describeSessionsError(error);
    } finally {
      _loading = false;
      _notify();
    }
    // El "en ejecución" se pregunta aparte: si `active` falla, la lista igual
    // sirve y sólo se pierden los dots.
    await pollActive();
  }

  /// Pull-to-refresh: recarga la lista y el estado en curso.
  Future<void> refresh() => load();

  /// Filtra la lista cargada por título. No va al server: la lista ya está en
  /// memoria y el `search` de `/api/session` no pagina igual.
  void search(String value) {
    if (_query == value) return;
    _query = value;
    _notify();
  }

  /// Crea una sesión en el directorio actual del server.
  ///
  /// Devuelve el `ses_…` nuevo para que la pantalla abra el chat, o `null` si
  /// el server falló (el error queda en [error]).
  Future<String?> create() async {
    _loading = true;
    _error = null;
    _notify();
    try {
      final session = await repository.create();
      _sessions = [
        session,
        for (final s in _sessions)
          if (s.id != session.id) s,
      ];
      _attention = {
        for (final s in _sessions)
          if (s.parentID != null) s.id,
      };
      return session.id;
    } on Object catch (error) {
      _error = describeSessionsError(error);
      return null;
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// `GET /api/session/active`. Silencioso: un fallo acá no ensucia [error]
  /// porque la lista es válida sin los dots.
  Future<void> pollActive() async {
    try {
      final active = await repository.fetchActive();
      if (_disposed) return;
      // Sin `notifyListeners` si no cambió: el polling no debe repintar la lista
      // cada 5 s.
      if (_setEquals(active, _running)) return;
      _running = active;
      _notify();
    } on Object catch (error) {
      if (_disposed) return;
      // Los dots se apagan si el server no contesta: preferimos "no prometo
      // trabajo" a un punto que miente.
      if (_running.isEmpty) return;
      _running = const <String>{};
      _notify();
      debugPrint('sessions: /session/active falló — $error');
    }
  }

  /// Arranca el polling de `active`. Idempotente.
  void startPolling() {
    if (_disposed || _poll != null || pollInterval <= Duration.zero) return;
    _poll = Timer.periodic(pollInterval, (_) => pollActive());
  }

  /// Corta el polling. Lo llama [dispose] y el `deactivate` de la pantalla.
  void stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  @override
  void dispose() {
    // Doble dispose (un rebuild que descarta la vista y el cierre del shell a
    // la vez) reventaba con el assert de `ChangeNotifier`. Ahora es idempotente.
    if (_disposed) return;
    _disposed = true;
    stopPolling();
    super.dispose();
  }

  /// `notifyListeners` tolerante al dispose: el polling se cancela, pero un
  /// request que ya estaba en vuelo puede volver tarde y `notifyListeners`
  /// revienta en debug si el [ChangeNotifier] ya se destruyó.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }
}

/// Mensaje de error para pintar, sin jerga.
///
/// La jerarquía de `lib/domain/models/errors.dart` ya responde en español y sin
/// secretos ([OchError.message]); lo que no la siga cae en un texto genérico,
/// porque el `toString` de una excepción cruda puede traer una URL con usuario.
String describeSessionsError(Object error) {
  if (error is! Exception) return 'No se pudieron cargar las sesiones.';
  final type = error.runtimeType.toString();
  final text = error.toString().trim();
  final prefix = '$type: ';
  return (text.startsWith(prefix) ? text.substring(prefix.length) : text)
      .trim();
}

bool _setEquals(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

/// Agrupa por **día calendario** de `time.updated`.
///
/// Día calendario y no "hace 24 h": a las 23:50 la sesión de las 23:40 de ayer
/// es `AYER` aunque no hayan pasado 24 horas.
List<SessionGroup> groupSessions(List<SessionInfo> sessions, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final buckets = <SessionBucket, List<SessionInfo>>{
    for (final b in SessionBucket.values) b: <SessionInfo>[],
  };
  for (final s in sessions) {
    final at = DateTime.fromMillisecondsSinceEpoch(s.updatedAtMs);
    final day = DateTime(at.year, at.month, at.day);
    buckets[bucketOfDays(today.difference(day).inDays)]!.add(s);
  }
  return [
    for (final b in SessionBucket.values)
      if (buckets[b]!.isNotEmpty) SessionGroup(b, buckets[b]!),
  ];
}

/// Días de calendario hacia atrás ⇒ bucket. Un `updated` en el futuro (reloj
/// desfasado) cae en `HOY`: no existe un grupo "MAÑANA".
SessionBucket bucketOfDays(int days) {
  if (days <= 0) return SessionBucket.today;
  if (days == 1) return SessionBucket.yesterday;
  if (days < 7) return SessionBucket.thisWeek;
  return SessionBucket.older;
}

/// Tiempo relativo de la fila: `ahora`, `2 min`, `14 min`, `1 h`, `ayer`,
/// `3 d`, `12/9`.
///
/// Comparación por día calendario para que la fila y el encabezado de grupo
/// nunca se contradigan (a las 23:50 de ayer la fila dice `ayer` y el grupo
/// dice `AYER`).
String formatRelative(int updatedMs, DateTime now) {
  final at = DateTime.fromMillisecondsSinceEpoch(updatedMs);
  final days = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(at.year, at.month, at.day)).inDays;
  if (days <= 0) {
    final elapsed = now.difference(at);
    final minutes = elapsed.inMinutes;
    if (minutes <= 0) return 'ahora';
    if (minutes < 60) return '$minutes min';
    return '${elapsed.inHours} h';
  }
  if (days == 1) return 'ayer';
  if (days < 7) return '$days d';
  return '${at.day}/${at.month}';
}

/// Gasto de la fila: `$0.42`.
String formatCost(double cost) => '\$${cost.toStringAsFixed(2)}';
