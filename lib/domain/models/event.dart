/// Eventos del stream SSE del dialecto v2.
///
/// Envoltura real medida en `GET /api/event` (build que corre en :4098):
///
/// ```json
/// {"id":"evt_0e64bb95…","created":1790570117526,"type":"session.step.ended",
///  "location":{"directory":"…"},"data":{"sessionID":"ses_…", …},
///  "durable":{"aggregateID":"ses_…","seq":431,"version":1}}
/// ```
///
/// El stream por sesión (`/api/session/{id}/event`) usa `{id, event, data}` en
/// vez de `{id, type, data}`, así que [OcEvent.fromJson] acepta las dos claves.
/// Ojo: en :4098 ese endpoint da **404** (medido) — el que anda es `/api/event`
/// global, y el filtro por sesión es del lado cliente.
///
/// El heartbeat v2 es un comentario SSE (`: heartbeat`), no un evento: lo tiene
/// que descartar el parser de la capa de red, no este modelo.
library;

import 'errors.dart';

/// Un frame del stream, ya sin el envoltorio `data:` del formato SSE.
final class OcEvent {
  const OcEvent({
    required this.id,
    required this.type,
    this.data = const {},
    this.createdMs,
    this.seq,
  });

  /// Acepta `{id, type, data}` (global) y `{id, event, data}` (por sesión).
  /// `data` ausente ⇒ mapa vacío (así viene `server.connected`).
  factory OcEvent.fromJson(Map<String, Object?> json) {
    final durable = asMap(json['durable']);
    return OcEvent(
      id: asStr(json['id']) ?? '',
      type: asStr(json['type']) ?? asStr(json['event']) ?? '',
      data: asMap(json['data']) ?? const {},
      createdMs: asInt(json['created']),
      seq: asInt(durable?['seq']),
    );
  }

  /// `evt_…`. Es el `Last-Event-ID` del SSE.
  final String id;

  /// `session.text.delta`, `session.tool.success`, `server.connected`…
  final String type;

  /// El payload. Cada evento trae `sessionID` adentro (salvo los globales).
  final Map<String, Object?> data;

  /// `created` del frame, en ms de epoch.
  final int? createdMs;

  /// `durable.seq`: el cursor para reanudar con `?after=`.
  final int? seq;

  /// `data.sessionID`, o `null` en eventos globales (`server.connected`).
  String? get sessionID => asStr(data['sessionID']);

  /// El error del canal C (`session.error` → `data.error`). Ver
  /// `docs/API_CONTRACT.md` §5: el cliente de escritorio lo descarta; la app
  /// móvil lo muestra como aviso no bloqueante.
  Object? get error => data['error'];
}

// --- Clasificación de eventos. Los nombres son los MEDIDOS en :4098; los
// --- `session.next.*` son los del openapi más nuevo, por si el usuario actualiza
// --- el server. Los dos conjuntos conviven sin costo.

/// Eventos que sólo existen en vivo: el valor final llega en el `*.ended`
/// correspondiente o en el mensaje completo, así que si se pierden, un re-fetch
/// converge igual (API_CONTRACT §7.5).
const Set<String> kDeltaEvents = {
  'session.text.delta',
  'session.reasoning.delta',
  'session.tool.input.delta',
  'session.next.text.delta',
  'session.next.reasoning.delta',
  'session.next.tool.input.delta',
  'session.next.compaction.delta',
};

/// Eventos que **cierran** algo: el valor ya no va a cambiar.
const Set<String> kSettledEvents = {
  'session.text.ended',
  'session.reasoning.ended',
  'session.tool.input.ended',
  'session.tool.success',
  'session.tool.failed',
  'session.step.ended',
  'session.step.failed',
  'session.next.text.ended',
  'session.next.reasoning.ended',
  'session.next.tool.input.ended',
  'session.next.tool.success',
  'session.next.tool.failed',
  'session.next.step.ended',
  'session.next.step.failed',
};

bool isDeltaEvent(String type) => kDeltaEvents.contains(type.toLowerCase());

bool isSettledEvent(String type) => kSettledEvents.contains(type.toLowerCase());

/// Estados que significan "trabajando" (API_CONTRACT §7.4).
const Set<String> kBusyStatuses = {'busy', 'running', 'retry'};

/// Estados que significan "terminó el turno".
const Set<String> kSettledStatuses = {
  'idle',
  'completed',
  'done',
  'success',
  'succeeded',
};

/// Acepta el status como string (`"busy"`) o como objeto v2
/// (`{"type":"busy"}`, forma de `SessionStatus` en `session.status`).
bool isBusyStatus(Object? status) =>
    kBusyStatuses.contains(_statusType(status));

bool isSettledStatus(Object? status) =>
    kSettledStatuses.contains(_statusType(status));

String? _statusType(Object? status) {
  if (status is String) return status.toLowerCase();
  if (status is Map) return asStr(status['type'])?.toLowerCase();
  return null;
}
