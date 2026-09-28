/// Sesión del dialecto v2 (`SessionV2Info` de `GET /api/session`).
///
/// Ojo: la lista **no** trae el estado de trabajo. "En ejecución" se lee del
/// SSE (`session.status` / `session.execution.started`) o del polling barato
/// `GET /api/session/active`, nunca de un campo de acá (API_CONTRACT §3).
library;

import 'errors.dart';
import 'message.dart';

/// `location: {directory, workspaceID?}` (`LocationRef`). El directorio es
/// **relative a la máquina del server**: en Android hay que mostrarlo, no
/// intentar abrirlo.
final class SessionLocation {
  const SessionLocation({required this.directory, this.workspaceID});

  factory SessionLocation.fromJson(Object? raw) {
    final m = asMap(raw) ?? const <String, Object?>{};
    return SessionLocation(
      directory: asStr(m['directory']) ?? '',
      workspaceID: asStr(m['workspaceID']),
    );
  }

  final String directory;
  final String? workspaceID;
}

/// `time` de la sesión: `created`, `updated` y `archived` (este último aparece
/// sólo si la sesión se archivó).
final class SessionTime {
  const SessionTime({
    required this.createdMs,
    required this.updatedMs,
    this.archivedMs,
  });

  factory SessionTime.fromJson(Object? raw) {
    final m = asMap(raw) ?? const <String, Object?>{};
    return SessionTime(
      createdMs: asInt(m['created']) ?? 0,
      updatedMs: asInt(m['updated']) ?? 0,
      archivedMs: asInt(m['archived']),
    );
  }

  final int createdMs;
  final int updatedMs;
  final int? archivedMs;

  bool get isArchived => archivedMs != null;
}

/// Una sesión de la lista de sesiones.
final class SessionInfo {
  const SessionInfo({
    required this.id,
    required this.projectID,
    required this.title,
    required this.cost,
    required this.tokens,
    required this.time,
    this.location = const SessionLocation(directory: ''),
    this.parentID,
    this.agent,
    this.model,
    this.subpath,
    this.revert,
    this.legacyDirectory,
  });

  factory SessionInfo.fromJson(Map<String, Object?> json) {
    final locationRaw = asMap(json['location']);
    return SessionInfo(
      id: asStr(json['id']) ?? '',
      projectID: asStr(json['projectID']) ?? '',
      title: asStr(json['title']) ?? '',
      cost: asNum(json['cost']) ?? 0,
      tokens: TokenUsage.fromJson(json['tokens']),
      time: SessionTime.fromJson(json['time']),
      // `location.directory` es el campo del spec v2; los builds viejos mandan
      // `directory` en el nivel raíz, así que se acepta de los dos lados.
      location: locationRaw == null
          ? SessionLocation(directory: asStr(json['directory']) ?? '')
          : SessionLocation(
              directory:
                  asStr(locationRaw['directory']) ??
                  asStr(json['directory']) ??
                  '',
              workspaceID: asStr(locationRaw['workspaceID']),
            ),
      parentID: asStr(json['parentID']),
      agent: asStr(json['agent']),
      model: asMap(json['model']) == null
          ? null
          : ModelRef.fromJson(json['model']),
      subpath: asStr(json['subpath']),
      revert: asMap(json['revert']),
      legacyDirectory: asStr(json['directory']),
    );
  }

  /// `ses_…`.
  final String id;

  final String projectID;
  final String title;

  /// Gasto acumulado de la sesión en USD.
  final double cost;

  final TokenUsage tokens;
  final SessionTime time;
  final SessionLocation location;

  /// Presente ⇒ esta sesión es un **subagente** de otra.
  final String? parentID;

  final String? agent;
  final ModelRef? model;

  /// Sub-ruta dentro del proyecto, si la sesión se creó con `--subpath`.
  final String? subpath;

  /// `revert` pendiente, en crudo (`{messageID, partID?, snapshot?, …}`).
  final Map<String, Object?>? revert;

  /// El `directory` de nivel raíz de los builds viejos, si vino.
  final String? legacyDirectory;

  bool get isSubagent => parentID != null;

  bool get isArchived => time.isArchived;

  /// Directorio del server, venga de donde venga. Para pintar en la fila.
  String get directory => location.directory.isNotEmpty
      ? location.directory
      : (legacyDirectory ?? '');

  int get updatedAtMs => time.updatedMs;
}
