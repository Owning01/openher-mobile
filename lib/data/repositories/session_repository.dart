/// Repositorio de sesiones: habla con [ApiClient] y devuelve **modelos**.
///
/// Es la única traducción entre el JSON crudo de `GET /api/session` (envuelto en
/// `{"data": […]}`) y [SessionInfo]. La red no conoce el dominio y el dominio no
/// conoce el `Map` crudo: este archivo es el único punto donde se juntan.
///
/// Decisiones medidas contra el dialecto v2 (`docs/API_CONTRACT.md`):
/// - La lista **no** trae el estado de trabajo. "En ejecución" sale de
///   [fetchActive] (`GET /api/session/active`), nunca de un campo de la sesión.
/// - `/api/session` **sí pagina** con `cursor`, y hace falta. Medido 2026-09-30
///   en esta máquina: 2.000 sesiones en total (654 principales, 1.346 subagentes),
///   y una sola página de 100 traía 59 principales: **595 quedaban fuera** de la
///   pantalla sin ninguna señal de que faltaba algo. Ver [listAll].
library;

import '../../core/network/api_client.dart';
import '../../domain/models/errors.dart';
import '../../domain/models/session.dart';

/// Tope de cada página de sesiones.
///
/// No es el tope de la lista: [SessionRepository.listAll] pide varias páginas.
/// Es el tamaño de cada request, que con 100 son ~25 KB (medido) y 20 requests
/// cubren las 2.000 sesiones de esta máquina.
const int kSessionPageLimit = 100;

/// Cuántas páginas pide como máximo [SessionRepository.listAll].
///
/// Tope duro, no preferencia: si un build futuro devolviera siempre un
/// `cursor.next`, sin esto la app pediría páginas para siempre. Con 20 páginas
/// × 100 son 2.000 sesiones, que es lo que hay acá.
const int kSessionAllPages = 20;

class SessionRepository {
  const SessionRepository(this._api);

  final ApiClient _api;

  /// `GET /api/session` → [SessionInfo]s, del más reciente al más viejo.
  ///
  /// Un item que no sea un mapa se descarta: la lista nunca se rompe por un
  /// campo raro de un build nuevo.
  Future<List<SessionInfo>> list({
    int limit = kSessionPageLimit,
    String? directory,
    String? search,
  }) async {
    final page = await _api.listSessions(
      limit: limit,
      order: 'desc',
      search: search,
      directory: directory,
    );
    final sessions = <SessionInfo>[
      for (final item in page.data)
        if (asMap(item) case final Map<String, Object?> m)
          SessionInfo.fromJson(m),
    ];
    sessions.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return sessions;
  }

  /// Todas las sesiones, paginando con el cursor hasta que el server deja de
  /// mandar una página siguiente.
  ///
  /// ## Por qué existe
  ///
  /// [list] pide **una** página. Con `limit=100` en una máquina que tiene 2.000
  /// sesiones, eso son 59 principales de 654: **595 sesiones que el usuario tiene
  /// y no ve**, sin ningún aviso. El síntoma era "no me trae todas las sesiones"
  /// y la causa no era un filtro de la pantalla (ese filtro es correcto y está
  /// medido): era que la página se cortaba en 100 y de ésos, 41 eran subagentes
  /// que el interruptor esconde.
  ///
  /// ## Por qué una sola pasada y no un bucle infinito
  ///
  /// Se pide página por página con el `cursor.next` que devuelve el server
  /// (medido: dos páginas consecutivas con `limit=5` no se solapan, así que el
  /// cursor avanza de verdad), y se corta en [kSessionAllPages] páginas o cuando
  /// `next` viene `null`. El tope es lo que evita el bucle infinito si un build
  /// futuro devuelve siempre un cursor: es preferible mostrar 1.000 sesiones a
  /// quedar pidiendo páginas para siempre gastando datos.
  ///
  /// El `search` **no** se reenvía en las páginas siguientes: es el filtro del
  /// usuario, y el server lo aplica, pero repetirlo con un cursor puede devolver
  /// la misma página. Por eso el filtro por título se sigue haciendo en el
  /// cliente ([SessionsViewModel.search]), que es una lista en memoria.
  Future<List<SessionInfo>> listAll({
    int limit = kSessionPageLimit,
    String? directory,
    int maxPages = kSessionAllPages,
  }) async {
    final porId = <String, SessionInfo>{};
    String? cursor;
    for (var page = 0; page < maxPages; page++) {
      final respuesta = await _api.listSessions(
        limit: limit,
        order: 'desc',
        cursor: cursor,
        directory: directory,
      );
      for (final item in respuesta.data) {
        if (asMap(item) case final Map<String, Object?> m) {
          final s = SessionInfo.fromJson(m);
          porId[s.id] = s;
        }
      }
      final siguiente = respuesta.next;
      // Sin cursor, o un cursor repetido (el server no avanzó), se corta: en
      // ambos casos pedir otra página devolvería lo mismo.
      if (siguiente == null || siguiente.isEmpty || siguiente == cursor) break;
      cursor = siguiente;
    }
    final sessions = porId.values.toList()
      ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return sessions;
  }

  /// `GET /api/session/active` → los `ses_…` que ahora mismo están corriendo.
  ///
  /// Es el polling barato de los dots "en ejecución". El server manda
  /// `{"ses_x": {"type": "running"}}`; se acepta también el atajo
  /// `{"ses_x": "running"}` porque algunos builds lo mandan así. Cualquier
  /// otro valor cuenta como "no corriendo": el default es no prometer trabajo
  /// que no se ve.
  Future<Set<String>> fetchActive({String? directory}) async {
    final raw = await _api.activeSessions(directory: directory);
    return {
      for (final entry in raw.entries)
        if (entry.key.isNotEmpty && _isRunning(entry.value)) entry.key,
    };
  }

  /// `POST /api/session` → la sesión recién creada.
  ///
  /// Sin `directory` el server usa el directorio actual de la máquina, que es
  /// lo que el botón `+` quiere ("una sesión en el directorio actual").
  Future<SessionInfo> create({
    String? directory,
    String? agent,
    String? modelId,
    String? providerId,
  }) async {
    final raw = await _api.createSession(
      directory: directory,
      agent: agent,
      modelId: modelId,
      providerId: providerId,
    );
    return SessionInfo.fromJson(raw);
  }

  static bool _isRunning(Object? value) => switch (asMap(value)) {
    final Map<String, Object?> m => asStr(m['type']) == 'running',
    null => asStr(value) == 'running',
  };
}
