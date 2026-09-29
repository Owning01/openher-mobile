/// Mensajes del dialecto v2 (`SessionMessage` de `packages/protocol`).
///
/// Un `data[]` de `GET /api/session/{id}/message` es **uno** de estos, y se
/// discrimina por el string `type`. Ojo con la generación: en v2 el contenido va
/// **embebido** en `assistant.content[]`; no existen los `parts[]` de la v1.
///
/// Todos los `fromJson` son **totales**: nunca tiran. Un campo ausente vale su
/// default, y un `type` ausente/malconocido produce un [SystemMessage] vacío en
/// vez de reventar el render de la lista de mensajes.
library;

import 'errors.dart';
import 'tool.dart';

/// `{id, providerID, variant?}` (`ModelRef`). Está en el mensaje assistant, en
/// `model-switched` y en la sesión.
final class ModelRef {
  const ModelRef({required this.id, required this.providerID, this.variant});

  factory ModelRef.fromJson(Object? raw) {
    final m = asMap(raw);
    if (m == null) {
      // Un `model`/`previous` que llega como string plano (dialecto v1, o un
      // `model-switched` con el nombre del modelo anterior) no debe perderse:
      // se trata como el id, sin provider.
      return ModelRef(id: asStr(raw) ?? '', providerID: '');
    }
    return ModelRef(
      id: asStr(m['id']) ?? '',
      providerID: asStr(m['providerID']) ?? '',
      variant: asStr(m['variant']),
    );
  }

  final String id;
  final String providerID;
  final String? variant;

  @override
  String toString() =>
      variant == null ? '$providerID/$id' : '$providerID/$id#$variant';
}

/// `message.time` (`created` siempre; `streamed`/`completed` si terminó).
final class MessageTime {
  const MessageTime({
    required this.createdMs,
    this.streamedMs,
    this.completedMs,
  });

  factory MessageTime.fromJson(Object? raw) {
    final m = asMap(raw) ?? const <String, Object?>{};
    return MessageTime(
      createdMs: asInt(m['created']) ?? 0,
      streamedMs: asInt(m['streamed']),
      completedMs: asInt(m['completed']),
    );
  }

  final int createdMs;
  final int? streamedMs;

  /// `null` ⇒ el turno sigue vivo. Es la evidencia de "trabajando" (API_CONTRACT
  /// §7.4), junto a `session.status`.
  final int? completedMs;

  bool get isComplete => completedMs != null;
}

/// `tokens` de mensaje y de sesión. `cache` es contexto releído, no gasto nuevo.
final class TokenUsage {
  const TokenUsage({
    this.input = 0,
    this.output = 0,
    this.reasoning = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
  });

  factory TokenUsage.fromJson(Object? raw) {
    final m = asMap(raw) ?? const <String, Object?>{};
    final cache = asMap(m['cache']) ?? const <String, Object?>{};
    return TokenUsage(
      input: asInt(m['input']) ?? 0,
      output: asInt(m['output']) ?? 0,
      reasoning: asInt(m['reasoning']) ?? 0,
      cacheRead: asInt(cache['read']) ?? 0,
      cacheWrite: asInt(cache['write']) ?? 0,
    );
  }

  final int input;
  final int output;
  final int reasoning;
  final int cacheRead;
  final int cacheWrite;

  /// `input + output + reasoning`. Excluye `cache` a propósito: lo releído del
  /// cache no son tokens nuevos de este turno.
  int get total => input + output + reasoning;
}

/// Mensaje del usuario. `files` son adjuntos (`PromptFileAttachment`).
final class UserMessage extends SessionMessage {
  const UserMessage({
    required super.id,
    required super.time,
    super.metadata,
    required this.text,
    this.files = const [],
    this.agents = const [],
    this.notDelivered = false,
  });

  factory UserMessage.fromJson(Map<String, Object?> json) => UserMessage(
    id: asStr(json['id']) ?? '',
    time: MessageTime.fromJson(json['time']),
    metadata: asMap(json['metadata']) ?? const {},
    text: asStr(json['text']) ?? '',
    files: [
      for (final f in asMapList(json['files']))
        UserFileAttachment(
          uri: asStr(f['uri']) ?? '',
          name: asStr(f['name']),
          mime: asStr(f['mime']),
        ),
    ],
    agents: asStringList(json['agents']),
  );

  final String text;
  final List<UserFileAttachment> files;

  /// Nombres de los `@agente` mencionados. Acepta `["build"]` y `[{name}]`.
  final List<String> agents;

  /// El server **no** lo tomó: sigue en pantalla esperando que se reintente.
  ///
  /// Antes el mensaje optimista se borraba solo si el POST fallaba, y con eso
  /// lo que el usuario habia escrito se perdia sin dejar rastro. Es lo que
  /// pasaba al mandar con el agente trabajando: el server responde **409
  /// Conflict** (declarado en el spec de `/api/session/{id}/prompt`) y el
  /// mensaje desaparecia de la pantalla. Un texto que el usuario escribio no se
  /// borra por un fallo de transporte: se marca y se reintenta.
  final bool notDelivered;

  UserMessage copyWith({bool? notDelivered}) => UserMessage(
    id: id,
    time: time,
    metadata: metadata,
    text: text,
    files: files,
    agents: agents,
    notDelivered: notDelivered ?? this.notDelivered,
  );
}

/// Adjunto del prompt del usuario.
final class UserFileAttachment {
  const UserFileAttachment({required this.uri, this.name, this.mime});

  final String uri;
  final String? name;
  final String? mime;
}

/// Respuesta del modelo. Acá vive el contenido: `content[]` embebido.
final class AssistantMessage extends SessionMessage {
  const AssistantMessage({
    required super.id,
    required super.time,
    super.metadata,
    required this.agent,
    required this.model,
    this.content = const [],
    this.finish,
    this.rawFinish,
    this.cost = 0,
    this.tokens = const TokenUsage(),
    this.error,
    this.snapshot,
  });

  factory AssistantMessage.fromJson(
    Map<String, Object?> json,
  ) => AssistantMessage(
    id: asStr(json['id']) ?? '',
    time: MessageTime.fromJson(json['time']),
    metadata: asMap(json['metadata']) ?? const {},
    agent: asStr(json['agent']) ?? '',
    model: ModelRef.fromJson(json['model']),
    // `content` es required en el spec pero un `content: []` es real (medido:
    // assistant con `finish:"error"` y contenido vacío). Ausente ⇒ vacío.
    content: [
      for (final item in asList(json['content']) ?? const <Object?>[])
        AssistantContent.fromJson(item),
    ],
    finish: asStr(json['finish']),
    rawFinish: asStr(json['rawFinish']),
    cost: asNum(json['cost']) ?? 0,
    tokens: TokenUsage.fromJson(json['tokens']),
    error: json['error'] == null ? null : OcErrorInfo.fromJson(json['error']),
    snapshot: asMap(json['snapshot']),
  );

  final String agent;
  final ModelRef model;
  final List<AssistantContent> content;

  /// `stop` | `tool-calls` | `length` | `error`…
  final String? finish;

  /// El `finish` crudo del provider (`tool_calls` vs `tool-calls`).
  final String? rawFinish;

  final double cost;
  final TokenUsage tokens;

  /// Canal A de error (API_CONTRACT §5): el turno murió.
  final OcErrorInfo? error;

  /// `snapshot: {start, end, files}` del revert. En crudo.
  final Map<String, Object?>? snapshot;

  /// `time.completed != null`.
  /// El turno terminó si hay **cualquiera** de las dos evidencias del contrato
  /// (§7.4): `time.completed` escrito, o `finish` informado. El server pone las
  /// dos, pero un build que sólo mande una no puede dejar el botón Detener
  /// pegado para siempre — que era justo lo que pasaba.
  bool get isComplete => time.isComplete || finish != null;

  bool get hasError => error != null;

  /// Los items de texto concatenados: lo que se ve como respuesta.
  String get textContent => [
    for (final item in content)
      if (item case final AssistantText t) t.text,
  ].join('\n\n');

  String get reasoningContent => [
    for (final item in content)
      if (item case final AssistantReasoning r) r.text,
  ].join('\n\n');

  List<AssistantTool> get toolItems => [
    for (final item in content)
      if (item case final AssistantTool t) t,
  ];

  List<AssistantText> get textItems => [
    for (final item in content)
      if (item case final AssistantText t) t,
  ];

  List<AssistantReasoning> get reasoningItems => [
    for (final item in content)
      if (item case final AssistantReasoning r) r,
  ];

  int get totalTokens => tokens.total;

  /// ¿Hay una tool `subagent`? Es la marca de que este mensaje lo produjo un
  /// subagente (la atribución no viene en un campo `from`; API_CONTRACT §4.4).
  bool get hasSubagent =>
      toolItems.any((t) => t.name == 'subagent' || t.name == 'task');
}

/// Cambió el agente de la sesión.
final class AgentSwitchedMessage extends SessionMessage {
  const AgentSwitchedMessage({
    required super.id,
    required super.time,
    super.metadata,
    required this.agent,
    this.previous,
  });

  factory AgentSwitchedMessage.fromJson(Map<String, Object?> json) =>
      AgentSwitchedMessage(
        id: asStr(json['id']) ?? '',
        time: MessageTime.fromJson(json['time']),
        metadata: asMap(json['metadata']) ?? const {},
        agent: asStr(json['agent']) ?? '',
        previous: asStr(json['previous']),
      );

  final String agent;

  /// Agente anterior (string en v2, medido).
  final String? previous;
}

/// Cambió el modelo de la sesión.
final class ModelSwitchedMessage extends SessionMessage {
  const ModelSwitchedMessage({
    required super.id,
    required super.time,
    super.metadata,
    required this.model,
    this.previous,
  });

  factory ModelSwitchedMessage.fromJson(Map<String, Object?> json) =>
      ModelSwitchedMessage(
        id: asStr(json['id']) ?? '',
        time: MessageTime.fromJson(json['time']),
        metadata: asMap(json['metadata']) ?? const {},
        model: ModelRef.fromJson(json['model']),
        // previous llega como objeto en v2 y como string plano en v1; se deja
        // pasar por el mismo fromJson, que ya tolera las dos formas.
        previous: json['previous'] == null
            ? null
            : ModelRef.fromJson(json['previous']),
      );

  final ModelRef model;

  /// Modelo anterior (objeto `ModelRef` en v2, medido).
  final ModelRef? previous;
}

/// Un comando de shell ejecutado por el server (no por el model).
final class ShellMessage extends SessionMessage {
  const ShellMessage({
    required super.id,
    required super.time,
    super.metadata,
    required this.callID,
    required this.command,
    this.output = '',
  });

  factory ShellMessage.fromJson(Map<String, Object?> json) => ShellMessage(
    id: asStr(json['id']) ?? '',
    time: MessageTime.fromJson(json['time']),
    metadata: asMap(json['metadata']) ?? const {},
    callID: asStr(json['callID']) ?? '',
    command: asStr(json['command']) ?? '',
    output: asStr(json['output']) ?? '',
  );

  final String callID;
  final String command;
  final String output;
}

/// Aviso del server (cambio de catálogo, restart, etc).
final class SystemMessage extends SessionMessage {
  const SystemMessage({
    required super.id,
    required super.time,
    super.metadata,
    required this.text,
    this.description,
  });

  factory SystemMessage.fromJson(Map<String, Object?> json) => SystemMessage(
    id: asStr(json['id']) ?? '',
    time: MessageTime.fromJson(json['time']),
    metadata: asMap(json['metadata']) ?? const {},
    text: asStr(json['text']) ?? '',
    description: asStr(json['description']),
  );

  final String text;

  /// Etiqueta corta (medido: `"Instructions updated: core/codemode"`).
  final String? description;
}

/// Mensaje inyectado por el server, no por el usuario (ej. "continuá después
/// del restart").
final class SyntheticMessage extends SessionMessage {
  const SyntheticMessage({
    required super.id,
    required super.time,
    super.metadata,
    required this.text,
    this.sessionID,
    this.description,
  });

  factory SyntheticMessage.fromJson(Map<String, Object?> json) =>
      SyntheticMessage(
        id: asStr(json['id']) ?? '',
        time: MessageTime.fromJson(json['time']),
        metadata: asMap(json['metadata']) ?? const {},
        text: asStr(json['text']) ?? '',
        sessionID: asStr(json['sessionID']),
        description: asStr(json['description']),
      );

  final String text;

  /// El server lo omite a veces (medido), aunque el spec lo marca required.
  final String? sessionID;

  final String? description;
}

/// Resumen de compactación de contexto.
final class CompactionMessage extends SessionMessage {
  const CompactionMessage({
    required super.id,
    required super.time,
    super.metadata,
    required this.reason,
    required this.summary,
    this.recent = '',
  });

  factory CompactionMessage.fromJson(Map<String, Object?> json) =>
      CompactionMessage(
        id: asStr(json['id']) ?? '',
        time: MessageTime.fromJson(json['time']),
        metadata: asMap(json['metadata']) ?? const {},
        reason: asStr(json['reason']) ?? '',
        summary: asStr(json['summary']) ?? '',
        recent: asStr(json['recent']) ?? '',
      );

  /// `auto` | `manual`.
  final String reason;

  final String summary;

  /// Los mensajes recientes que sobrevivieron a la compactación.
  final String recent;
}

/// Un mensaje de la sesión, discriminado por `type`.
sealed class SessionMessage {
  const SessionMessage({
    required this.id,
    required this.time,
    this.metadata = const {},
  });

  /// dispatch por `type`. Un `type` ausente o desconocido ⇒ [SystemMessage] con
  /// `text` vacío: la UI lista de mensajes nunca se rompe por un tipo nuevo.
  factory SessionMessage.fromJson(Map<String, Object?> json) =>
      switch (asStr(json['type'])) {
        'assistant' => AssistantMessage.fromJson(json),
        'user' => UserMessage.fromJson(json),
        'agent-switched' => AgentSwitchedMessage.fromJson(json),
        'model-switched' => ModelSwitchedMessage.fromJson(json),
        'shell' => ShellMessage.fromJson(json),
        'synthetic' => SyntheticMessage.fromJson(json),
        'compaction' => CompactionMessage.fromJson(json),
        _ => SystemMessage.fromJson(json),
      };

  /// `msg_…`.
  final String id;
  final MessageTime time;

  /// `metadata` crudo. La app no lo lee todavía; queda para debug/diff.
  final Map<String, Object?> metadata;

  int get createdAtMs => time.createdMs;
}

/// Un item de `assistant.content[]`, discriminado por `type`.
sealed class AssistantContent {
  const AssistantContent({this.id, this.time});

  /// Un item con `type` desconocido se trata como texto (la respuesta visible).
  factory AssistantContent.fromJson(Object? raw) {
    final m = asMap(raw);
    if (m == null) return const AssistantText(text: '');
    return switch (asStr(m['type'])) {
      'reasoning' => AssistantReasoning(
        id: asStr(m['id']),
        time: asMap(m['time']) == null ? null : MessageTime.fromJson(m['time']),
        text: asStr(m['text']) ?? '',
      ),
      'tool' => AssistantTool(
        id: asStr(m['id']) ?? '',
        name: asStr(m['name']) ?? '',
        executed: asBool(m['executed']) ?? false,
        state: ToolState.fromJson(m['state']),
      ),
      _ => AssistantText(id: asStr(m['id']), text: asStr(m['text']) ?? ''),
    };
  }

  /// El spec lo pide required, pero los `text` medidos no lo traen.
  final String? id;

  final MessageTime? time;
}

/// Respuesta visible del model.
final class AssistantText extends AssistantContent {
  const AssistantText({super.id, super.time, required this.text});

  final String text;
}

/// El "pensamiento". Medido: llega con `text: ""` cuando el provider lo
/// encripta, así que puede estar vacío y hay que hidingarlo.
final class AssistantReasoning extends AssistantContent {
  const AssistantReasoning({super.id, super.time, required this.text});

  final String text;
}

/// Llamada a un tool (`shell`, `read`, `edit`, `question`, `subagent`…).
final class AssistantTool extends AssistantContent {
  const AssistantTool({
    required String id,
    super.time,
    required this.name,
    required this.executed,
    required this.state,
  }) : super(id: id);

  /// `call_function_…` (vive en [AssistantContent.id]).
  final String name;

  /// `true` = lo ejecutó el provider, no el server. Medido en `false`.
  final bool executed;

  final ToolState state;

  /// Las preguntas del tool `question` (`input.questions`), en crudo.
  ///
  /// Queda sin tipo fuerte a propósito: el shape pertenece a la tool, no al
  /// dominio, y el server puede agregar campos. La UI de pregunta lo proyecta.
  List<Map<String, Object?>> get questionsRaw =>
      asMapList(asMap(state.input)?['questions']);

  /// La descripción del subagente, si esta tool es un `subagent`/`task`.
  String? get subagentDescription => asStr(asMap(state.input)?['description']);
}
