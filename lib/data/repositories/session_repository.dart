/// Repositorio de sesiones: habla con [ApiClient] y devuelve **modelos**.
///
/// Es la única traducción entre el JSON crudo de `GET /api/session` (envuelto en
/// `{"data": […]}`) y [SessionInfo]. La red no conoce el dominio y el dominio no
/// conoce el `Map` crudo: este archivo es el único punto donde se juntan.
///
/// Decisiones medidas contra el dialecto v2 (`docs/API_CONTRACT.md`):
/// - La lista **no** trae el estado de trabajo. "En ejecución" sale de
///   [fetchActive] (`GET /api/session/active`), nunca de un campo de la sesión.
/// - [ApiPage.next] existe pero **no se pagina todavía**: la pantalla pide una
///   sola página grande y filtra por fecha/título en el cliente. Cuando haga
///   falta "cargar más", el cursor se expone acá sin cambiar la pantalla.
library;

import '../../core/network/api_client.dart';
import '../../domain/models/errors.dart';
import '../../domain/models/session.dart';

/// Tope de la página única que pide la pantalla de sesiones.
const int kSessionPageLimit = 100;

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
