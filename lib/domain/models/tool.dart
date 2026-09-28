/// Tools y estados de tool del dialecto v2.
///
/// Medido contra `127.0.0.1:4098` y contra `SessionMessageAssistantTool` /
/// `SessionMessageToolState*` de `packages/sdk/openapi.json`.
///
/// Dos trampas ya resueltas acá (API_CONTRACT §4.2 y el mapa del proyecto):
/// * `state` de un tool **no** tiene `output: String`: la salida es
///   `content: [{type:"text",text}]` (o `type:"file"`). El cliente de
///   escritorio aplana eso en un string; acá **no** se copia ese shim.
/// * `state.error` es un **objeto** `{type?, message}`, no un string. Y el
///   `input` de `pending` es un **String crudo**, no un mapa.
library;

import 'errors.dart';

/// Salida de un tool: cada item de `state.content[]` (`LLMToolContent`).
sealed class ToolContent {
  const ToolContent();

  /// Un item con `type` desconocido (o sin `type`) se trata como texto: nunca
  /// se pierde un item por no reconocerlo.
  factory ToolContent.fromJson(Object? raw) {
    final m = asMap(raw);
    if (m == null) return const TextToolContent(text: '');
    if (asStr(m['type']) == 'file') {
      return FileToolContent(
        uri: asStr(m['uri']) ?? '',
        mime: asStr(m['mime']),
        name: asStr(m['name']),
      );
    }
    return TextToolContent(text: asStr(m['text']) ?? '');
  }
}

final class TextToolContent extends ToolContent {
  const TextToolContent({required this.text});

  final String text;
}

final class FileToolContent extends ToolContent {
  const FileToolContent({required this.uri, this.mime, this.name});

  /// `data:` URL o ruta. Medido: los `read` de imagen mandan
  /// `data:image/png;base64,…` inline.
  final String uri;

  /// Opcional: el server lo omite en los `data:` URL.
  final String? mime;

  final String? name;
}

/// Base compartida de los cuatro estados de un tool.
///
/// La UI siempre lee [statusName], [inputText] y [content] sin preguntar por el
/// subtipo; lo específico (title, error, outputPaths) vive en el subtipo.
sealed class ToolStateBase {
  const ToolStateBase({
    required this.statusName,
    this.input,
    this.metadata = const {},
    this.content = const [],
    this.structured,
    this.result,
  });

  /// `pending` | `running` | `completed` | `error`, verbatim del server.
  final String statusName;

  /// Argumentos del tool. **`String` en `pending`** (input crudo), mapa en los
  /// otros estados. Va como `Object?` a propósito: forzar un tipo acá obliga a
  /// mentir en uno de los dos casos.
  final Object? input;

  /// Datos extra del server. Medido en `completed` de `shell`:
  /// `{"status":"completed","truncated":false,"exit":0}`.
  final Map<String, Object?> metadata;

  /// `state.content[]`. Vacío en `pending`/`running`.
  final List<ToolContent> content;

  final Map<String, Object?>? structured;

  /// Salida estructurada del tool. El schema no lo tipa (`{}`): va como `Object?`.
  final Object? result;

  /// El input listo para pintar: pretty JSON si es mapa, crudo si es string.
  String get inputText => switch (input) {
    null => '',
    final String s => s,
    final Object o => prettyJson(o),
  };

  /// Los items de texto de [content], concatenados.
  String get textContent => [
    for (final item in content)
      if (item case final TextToolContent t) t.text,
  ].join();
}

/// Estado del tool, discriminado por `state.status`.
///
/// Un `status` desconocido (o ausente) cae en [ToolPending]: es el estado que
/// no afirma nada. Se pierde el `status` crudo, a propósito — la UI no puede
/// pintar un estado que no conoce.
sealed class ToolState extends ToolStateBase {
  const ToolState({
    required super.statusName,
    super.input,
    super.metadata,
    super.content,
    super.structured,
    super.result,
  });

  factory ToolState.fromJson(Object? raw) {
    final m = asMap(raw) ?? const <String, Object?>{};
    final input = m['input'];
    final metadata = asMap(m['metadata']) ?? const <String, Object?>{};
    final content = [
      for (final item in asList(m['content']) ?? const <Object?>[])
        ToolContent.fromJson(item),
    ];
    final structured = asMap(m['structured']);
    final result = m['result'];
    return switch (asStr(m['status'])) {
      'completed' => ToolCompleted(
        statusName: 'completed',
        input: input,
        metadata: metadata,
        content: content,
        structured: structured,
        result: result,
        attachments: asMapList(m['attachments']),
        outputPaths: asStringList(m['outputPaths']),
      ),
      'error' => ToolError(
        statusName: 'error',
        input: input,
        metadata: metadata,
        content: content,
        structured: structured,
        result: result,
        error: OcErrorInfo.fromJson(m['error']),
      ),
      'running' => ToolRunning(
        statusName: 'running',
        input: input,
        metadata: metadata,
        content: content,
        structured: structured,
        result: result,
        title: asStr(m['title']),
        startedMs: asInt((asMap(m['time']) ?? const {})['started']),
      ),
      _ => ToolPending(input: input),
    };
  }
}

/// El model lo pidió pero todavía no corrió. `input` es un **string** crudo.
final class ToolPending extends ToolState {
  const ToolPending({super.input}) : super(statusName: 'pending');
}

/// Está corriendo.
final class ToolRunning extends ToolState {
  const ToolRunning({
    required super.statusName,
    super.input,
    super.metadata,
    super.content,
    super.structured,
    super.result,
    this.title,
    this.startedMs,
  });

  /// Subtítulo de la card ("leyendo 3 archivos").
  final String? title;

  /// `state.time.started`.
  final int? startedMs;
}

/// Terminó bien. La salida está en [ToolStateBase.content].
final class ToolCompleted extends ToolState {
  const ToolCompleted({
    required super.statusName,
    super.input,
    super.metadata,
    super.content,
    super.structured,
    super.result,
    this.attachments = const [],
    this.outputPaths = const [],
  });

  /// `PromptFileAttachment[]` en crudo: el schema no lo usa la app todavía.
  final List<Map<String, Object?>> attachments;

  /// Archivos que el tool dejó escritos.
  final List<String> outputPaths;
}

/// Falló. El turno puede seguir (API_CONTRACT §5, canal B).
final class ToolError extends ToolState {
  const ToolError({
    required super.statusName,
    super.input,
    super.metadata,
    super.content,
    super.structured,
    super.result,
    required this.error,
  });

  /// El payload crudo del error. `ToolError` es el único estado que lo tiene.
  final OcErrorInfo error;

  /// El texto para humanos del error. Vacío si el server no trajo mensaje.
  String get errorMessage => error.message;
}
