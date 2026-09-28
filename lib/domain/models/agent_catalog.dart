import 'package:flutter/foundation.dart';

/// Modo de un agente. El server lo manda literal en `mode`.
enum AgentMode {
  primary('primary'),
  subagent('subagent');

  const AgentMode(this.wire);

  final String wire;

  static AgentMode fromWire(String? raw) {
    for (final m in AgentMode.values) {
      if (m.wire == raw) return m;
    }
    return AgentMode.primary;
  }

  /// Rótulo en español para la hoja de elección.
  String get label => this == AgentMode.primary ? 'Principal' : 'Subagente';
}

/// Un agente del server (`GET /api/agent`).
///
/// Medido 2026-09-28 contra opencode2: el server devuelve 26, con esta forma
/// exacta y **sin** ningún campo de modelo — el agente no trae modelo propio,
/// el modelo es de la sesión.
///
///     {"id":"build","name":"Build","request":{"settings":{},"headers":{},
///      "body":{}},"description":"The default agent. Executes tools based on
///      configured permissions.","mode":"primary","hidden":false,
///      "permissions":[{"action":"*","resource":"*","effect":"allow"}, ...]}
@immutable
class AgentInfo {
  const AgentInfo({
    required this.id,
    required this.name,
    required this.mode,
    required this.description,
    required this.hidden,
  });

  final String id;
  final String name;
  final AgentMode mode;
  final String description;

  /// `true` para los internos del server (`compaction`, `title`, `summary` y
  /// los subagentes privados de los skills). No son elegibles: el usuario no
  /// los invoca nunca a mano.
  final bool hidden;

  /// Un agente se puede elegir si existe y no está oculto.
  bool get selectable => !hidden && id.isNotEmpty;

  /// Se parsea tolerante a propósito: un agente con un campo raro no puede
  /// hacer que la hoja entera quede vacía. Lo que falta queda en su valor
  /// neutro, y un agente sin `id` se descarta porque no se podría pedir.
  static AgentInfo? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final name = raw['name'];
    return AgentInfo(
      id: id,
      name: name is String && name.isNotEmpty ? name : id,
      mode: AgentMode.fromWire(raw['mode'] as String?),
      description: raw['description'] is String
          ? raw['description'] as String
          : '',
      hidden: raw['hidden'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgentInfo &&
      other.id == id &&
      other.name == name &&
      other.mode == mode &&
      other.description == description &&
      other.hidden == hidden;

  @override
  int get hashCode => Object.hash(id, name, mode, description, hidden);

  @override
  String toString() => 'AgentInfo($id, ${mode.wire})';
}

/// Los agentes parseados, ya filtrados y agrupados.
///
/// El filtro de `hidden` va **acá** y no en la UI: si cada pantalla decidiera
/// por su cuenta, aparecerían `compaction` y `title` como opciones elegibles en
/// un lado y no en el otro.
class AgentCatalog {
  AgentCatalog(Iterable<AgentInfo> all)
    : _all = List<AgentInfo>.unmodifiable(all.where((a) => a.selectable));

  final List<AgentInfo> _all;

  /// Los que el usuario puede elegir, en el orden que los mandó el server.
  List<AgentInfo> get selectable => _all;

  /// Los principales primero: son los que se usan todos los días, y arriba es
  /// donde el dedo llega.
  List<AgentInfo> get primaries => _byMode(AgentMode.primary);

  List<AgentInfo> get subagents => _byMode(AgentMode.subagent);

  List<AgentInfo> _byMode(AgentMode mode) =>
      _all.where((a) => a.mode == mode).toList(growable: false);

  AgentInfo? byId(String? id) {
    if (id == null) return null;
    for (final a in _all) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// El nombre a mostrar en el pill del composer.
  ///
  /// Con un id desconocido cae en el mismo rótulo que se usa cuando no hay
  /// nada elegido: la app muestra "Elegir agente" en vez de una fila vacía o un
  /// `null` pelado.
  static String labelFor(AgentCatalog? catalog, String? id) {
    if (id == null || id.isEmpty) return 'Elegir agente';
    final a = catalog?.byId(id);
    if (a == null) return id;
    return a.name;
  }

  static AgentCatalog fromList(Object? data) {
    if (data is! List) return AgentCatalog(const []);
    return AgentCatalog(data.map(AgentInfo.tryParse).whereType<AgentInfo>());
  }
}
