/// Una burbuja de la lista de mensajes (`chat.msg.*`).
///
/// Un solo widget para los ocho tipos de [SessionMessage] porque la lista los
/// intercala en el mismo scroll y cada uno es una fracción de la misma caja:
///
/// * [UserMessage] → burbuja a la derecha, `primary` sobre `on-primary`.
/// * [AssistantMessage] → caja de actividad del **turno** (la primera en
///   [(prompt)] → [caja] → [mensajes del turno]), la card de pregunta si hay
///   un `question` pendiente, la de error del proveedor si vino
///   `assistant.error`, y el texto.
/// * [SystemMessage] / [SyntheticMessage] / [CompactionMessage] y los
///   `*-switched` → píldora centrada delgada.
/// * [ShellMessage] → píldora con el comando (un comando del server no es una
///   respuesta del modelo, pero tampoco puede desaparecer).
///
/// ## Markdown
/// El texto del asistente se renderiza con `flutter_markdown_plus` (el sucesor
/// mantenido de `flutter_markdown`, que quedó discontinuado), pero **con hoja de
/// estilos propia**: `MarkdownStyleSheet.fromTheme` deja los valores por defecto
/// de Material (8 px entre bloques, viñeta `•`, sangría de 24 px, celdas de
/// tabla de 16 px, `hr` de 5 px) y eso es justo lo que hace que el markdown se
/// vea genérico y distinto de la maqueta. Acá todo sale de `tokens.dart` —
/// ver `_markdownSheet`. [MarkdownText] además memoiza por firma: si el texto no
/// cambió, se devuelve el mismo subtree.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
// `markdown` es dependencia transitiva de flutter_markdown_plus (misma versión
// que exponen sus firmas de MarkdownElementBuilder); no se declara en pubspec.
// ignore: depend_on_referenced_packages
import 'package:markdown/markdown.dart' as md;

import '../../../domain/models/errors.dart';
import '../../../domain/models/message.dart';
import '../../../domain/models/tool.dart';
import '../../../domain/models/turn_activity.dart';
import '../../core/app_icon.dart';
import '../../core/layer_gate.dart';
import '../../core/tokens.dart';
import 'turn_activity.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.working,
    this.turnActivity,
    this.absorbedActivity = false,
    this.thinkingDefault = true,
    this.onOpenDiff,
    this.onQuestionAnswer,
    this.questionRequestId,
    this.onRetrySend,
    this.isOpenAssistant,
  });

  /// Reintenta un mensaje del usuario que el server no tomó (409 al mandar
  /// con el agente trabajando, o 429 de rate limit).
  ///
  /// Antes ese mensaje se borraba de la lista y el texto se perdía sin que el
  /// usuario llegara a ver por qué.
  final ValueChanged<String>? onRetrySend;

  /// Este mensaje es el assistant que está recibiendo deltas ahora.
  ///
  /// Los puntos de escritura se pintan **sólo** en éste. Antes la
  /// condición era `working && texto vacío`, sin mirar de quién era el mensaje:
  /// como `working` es del turno entero, **todos** los assistant sin texto
  /// pintaban puntos a la vez. Y un assistant que sólo trae tool calls tiene el
  /// texto vacío por diseño, así que el fenómeno no era raro: era la norma.
  final bool? isOpenAssistant;

  final SessionMessage message;

  /// El turno de este assistant sigue vivo. Sólo afecta a los puntos de
  /// escritura: un assistant terminado no parpadea.
  final bool working;

  /// La caja del TURNO, si a este mensaje le toca pintarla.
  ///
  /// La calcula `buildTurnActivities` (`domain/models/turn_activity.dart`) con
  /// los mensajes de la sesión y se pasa una vez por build: una caja por turno,
  /// no una por mensaje de assistant, que es como el chat se llenaba de líneas
  /// sueltas. Sin este parámetro la burbuja cae en su actividad propia (el
  /// comportamiento viejo, y el que se usa al montar el widget suelto).
  final TurnActivity? turnActivity;

  /// La caja de este mensaje quedó en otro mensaje del mismo turno: no se
  /// pinta ninguna acá.
  final bool absorbedActivity;

  /// Ya no decide nada: la caja arranca cerrada y sólo la abre el usuario
  /// (adjudicado 2026-09-28, "las herramientas me llenan todo el chat de más
  /// altura"). Se conserva porque `chat_view` lo sigue pasando.
  final bool thinkingDefault;
  final ValueChanged<AssistantTool>? onOpenDiff;

  /// Responde una pregunta del tool `question` (`chat.msg.question`).
  ///
  /// Recibe el `requestID` (el `id` del `question.asked`, que puede ser `null`
  /// si el evento todavía no llegó) y las opciones elegidas. El viewmodel
  /// decide el camino: `POST …/question/{requestID}/reply` o, si ese endpoint no
  /// existe, un prompt (§6 de `API_CONTRACT.md`).
  final void Function(String? requestId, List<String> answers)?
  onQuestionAnswer;

  /// `requestID` de la pregunta pendiente, si el `question.asked` de este chat
  /// corresponde a este tool (lo resuelve `ChatViewModel.requestIdFor`).
  final String? questionRequestId;

  /// El tool `question` en `pending` de este mensaje, o `null`.
  ///
  /// Vive acá porque es **lo que decide** si se pinta la card, y el chat lo
  /// consulta para pasarle el `requestID` a la burbuja.
  static AssistantTool? pendingQuestionTool(SessionMessage message) {
    if (message case final AssistantMessage assistant) {
      for (final tool in assistant.toolItems) {
        if (tool.name == 'question' && tool.state is ToolPending) return tool;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    switch (message) {
      case final UserMessage user:
        return _user(context, user);
      case final AssistantMessage assistant:
        return _assistant(context, assistant);
      case final SystemMessage notice:
        return _pill(
          context,
          notice.text.isEmpty ? (notice.description ?? '') : notice.text,
        );
      case final SyntheticMessage notice:
        return _pill(context, notice.text);
      case final CompactionMessage compact:
        return _pill(
          context,
          'Contexto compactado · se conservaron los últimos '
          '${_recentCount(compact.recent)} mensajes',
        );
      case final AgentSwitchedMessage switched:
        return _pill(context, 'Agente: ${switched.agent}');
      case final ModelSwitchedMessage switched:
        return _pill(context, 'Modelo: ${switched.model.id}');
      case final ShellMessage shell:
        return _pill(context, r'$ ' + shell.command);
    }
  }

  /// El aviso de compactación dice cuántos mensajes sobrevivieron. El server
  /// manda `recent` como bloque de texto: si se puede contar por líneas se usa
  /// ese número, y si no (vacío o de un solo bloque) va el 12 del diseño.
  static int _recentCount(String recent) {
    final lines = recent.split('\n').where((l) => l.trim().isNotEmpty).length;
    return lines > 1 ? lines : 12;
  }

  Widget _assistant(BuildContext context, AssistantMessage assistant) {
    final children = <Widget>[];
    final activity = _turnActivityOf(assistant);

    if (activity != null) {
      children.add(TurnActivityBox(activity: activity, onOpenDiff: onOpenDiff));
    }

    // Una pregunta pendiente tiene prioridad visual sobre el texto: es la
    // única forma de desbloquear el turno (y sin ella el botón Detener era la
    // única salida).
    final pending = pendingQuestionTool(assistant);
    if (pending != null) children.add(_question(context, pending));

    // Canal A de §5: el turno murió. Va antes del texto porque es lo que hay
    // que leer primero; el texto parcial que quedó sigue debajo.
    final error = assistant.error;
    if (error != null) children.add(_errorCard(context, error));

    // El texto va con la capa que lo corresponde: mientras el turno escribe es
    // la línea de streaming (`.streamline`, texto plano), y recién al terminar
    // el mensaje es markdown (`chat.msg.assistant`). Parsear markdown en cada
    // delta es además el mayor costo de scroll del chat.
    final streaming = working && !assistant.isComplete;
    final text = assistant.textContent;
    if (text.trim().isNotEmpty) {
      children.add(
        streaming
            ? LayerGate(
                'chat.stream.text',
                child: MarkdownText(text, streaming: true),
              )
            : LayerGate('chat.msg.assistant', child: MarkdownText(text)),
      );
    }

    // Los puntos sólo mientras el texto aún no llegó: si hay algo escrito, el
    // texto ES el indicador. Y con una pregunta esperando tampoco: el modelo no
    // está escribiendo, está esperando que el usuario conteste, y parpadear
    // "pensando" en ese estado es mentir.
    //
    // Y sólo en el assistant **abierto**: ver [isOpenAssistant]. Sin esto se
    // veían varios juegos de puntos a la vez y todos se iban juntos al
    // terminar el turno.
    if (working &&
        isOpenAssistant != false &&
        pending == null &&
        assistant.textContent.trim().isEmpty) {
      children.add(const LayerGate('chat.typing', child: TypingDots()));
    }

    // `.msg{gap:6px}` del prototipo: sin esto la caja de actividad queda
    // pegada al texto y el error pegado a la card de pregunta.
    final spaced = <Widget>[];
    for (final child in children) {
      if (spaced.isNotEmpty) spaced.add(const SizedBox(height: AppSpacing.sm));
      spaced.add(child);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: spaced,
    );
  }

  /// La caja que le toca a este mensaje, o `null` si no le toca ninguna.
  ///
  /// Tres casos, en este orden:
  ///
  /// 1. **absorbido**: la caja de su turno la pintó el primer mensaje del
  ///    turno, así que acá no se dibuja ninguna.
  /// 2. **con agrupado**: `turnActivity` es la caja del turno entero (tools de
  ///    todos los mensajes del turno), y se pinta en el dueño.
  /// 3. **sin agrupado** (el widget montado suelto, o `chat_view` todavía sin
  ///    cablear `buildTurnActivities`): el turno es este mensaje, que es el
  ///    comportamiento viejo.
  TurnActivity? _turnActivityOf(AssistantMessage assistant) {
    if (absorbedActivity) return null;
    final grouped = turnActivity;
    if (grouped != null) return grouped;
    return TurnActivity(
      thinkingParts: assistant.reasoningItems,
      toolParts: assistant.toolItems,
      working: !assistant.isComplete,
      time: assistant.time,
    );
  }

  // ─────────────────────────── usuario ───────────────────────────

  Widget _user(BuildContext context, UserMessage user) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bubble = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          // La burbuja del usuario "pega" con la siguiente: la esquina inferior
          // derecha se cierra a 4px, como en el CSS.
          bottomRight: Radius.circular(4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (user.files.isNotEmpty) _attachments(context, user.files),
          if (user.files.isNotEmpty) const SizedBox(height: 6),
          Text(
            user.text,
            // El cuerpo del tema (13/1.5) con el color del chip: el `Text` solo
            // con `fontSize` heredaba el alto de línea de otra base.
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onPrimary,
            ),
          ),
          if (user.notDelivered) ...[
            const SizedBox(height: 6),
            _NotDeliveredChip(onRetry: () => onRetrySend?.call(user.id)),
          ],
        ],
      ),
    );

    return LayerGate(
      'chat.msg.user.bubble',
      // `max-width:88%` del CSS: la burbuja larga no barre la pantalla. Es un
      // tope, no un ancho — con `FractionallySizedBox` hasta un "hola" salía
      // con el 88% del ancho. El `LayoutBuilder` mide el ancho disponible (el
      // del área de chat, ya sin el padding del scroll) en vez de el de la
      // pantalla, que incluye la barra de sistema.
      child: LayoutBuilder(
        builder: (context, constraints) => Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: constraints.maxWidth.isFinite
                  ? constraints.maxWidth * _userMaxWidth
                  : double.infinity,
            ),
            child: bubble,
          ),
        ),
      ),
    );
  }

  /// `max-width:88%` de `.bubble` (`prototype/mobile.html:247`).
  static const double _userMaxWidth = 0.88;

  /// `chat.msg.user.attachment`: miniatura de 120×90 con el nombre abajo a la
  /// derecha, como el `.att` del prototipo. SVG, nunca emoji ni Material icon.
  Widget _attachments(BuildContext context, List<UserFileAttachment> files) {
    final scheme = Theme.of(context).colorScheme;
    return LayerGate(
      'chat.msg.user.attachment',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final file in files)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 120,
                    height: 90,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainer,
                      borderRadius: AppRadius.mdAll,
                      border: Border.all(color: scheme.outline),
                    ),
                    child: Center(
                      child: AppIcon(
                        _isImage(file.mime) ? 'image' : 'file',
                        size: 24,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  // `.attname`: vive dentro de la burbuja `primary`, así que el
                  // nombre va en `on-primary` al 80% — en gris se perdía contra
                  // el fondo del chip. Los 3 px de `margin-top` son los del
                  // CSS (:253): no hay token de 3, y `.syspill` usa el mismo.
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      file.name ?? file.uri.split('/').last,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.4,
                        color: scheme.onPrimary.withValues(alpha: 0.8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static bool _isImage(String? mime) => mime?.startsWith('image/') ?? false;

  // ─────────────────────── error, pill, question ───────────────────────

  /// Canal A de §5: borde `danger` de 1 px, fondo `danger-soft`,
  /// `alert-triangle` y el `name: message` del server. Ojo: en v2 el
  /// discriminador viene en `type` y `OcErrorInfo` ya resuelve `name ?? type`
  /// (API_CONTRACT.md §7.1bis).
  ///
  /// El color es el `--danger` del prototipo (`#E11D48` / `#FB7185`), que en
  /// `tokens.dart` es el rojo del scope de diffs — el mismo que ya usa el botón
  /// Detener del composer. Con el `danger` gris del chrome, el error del
  /// provider y el error de una tool se veían como dos cosas distintas y el
  /// Detener era el único botón de color de la pantalla.
  Widget _errorCard(BuildContext context, OcErrorInfo error) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final danger = AppColors.diffDelOf(brightness);
    final dangerSoft = brightness == Brightness.dark
        ? AppColors.diffDelSoftDark
        : AppColors.diffDelSoft;
    return LayerGate(
      'chat.msg.error',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          // `.errcard`: `--r3` (8), no `--r2`.
          borderRadius: AppRadius.lgAll,
          border: Border.all(color: danger),
          color: dangerSoft,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                AppIcon('alert-triangle', size: 16, color: danger),
                const SizedBox(width: 6),
                Text(
                  'Error del proveedor',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: danger,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            SelectableText(
              error.name == null
                  ? error.message
                  : '${error.name}: ${error.message}',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11.5,
                height: 1.55,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// `.syspill`: píldora centrada delgada de 12 px.
  ///
  /// Sin margen propio: la separación entre mensajes la pone el `ListView`
  /// (12 px, el `gap` de `.chat-scroll`), y con los 4 px de acá las píldoras
  /// quedaban a 20 px de sus vecinas.
  Widget _pill(BuildContext context, String text) {
    if (text.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return LayerGate(
      'chat.msg.system',
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  /// `chat.msg.question`: la card de la tool `question` en `pending`.
  Widget _question(BuildContext context, AssistantTool tool) {
    final questions = questionItems(tool);
    final first = questions.isEmpty
        ? const <String, Object?>{}
        : questions.first;
    final requestId = questionRequestId;
    return LayerGate(
      'chat.msg.question',
      child: QuestionCard(
        header: asStr(first['header']) ?? 'Pregunta del agente',
        question: asStr(first['question']) ?? '',
        options: [
          for (final option in asMapList(first['options']))
            QuestionOption(
              label: asStr(option['label']) ?? '',
              detail: asStr(option['description']),
            ),
        ],
        // Se lee el campo, no `widget.x`: mismo valor, y no depende de que el
        // analyzer resuelva el getter `widget` de `StatelessWidget` acá.
        onSubmit: (answers) => onQuestionAnswer?.call(requestId, answers),
        onSkip: (answers) => onQuestionAnswer?.call(requestId, answers),
      ),
    );
  }
}

/// Los `QuestionInfo[]` de un tool `question`, leyendo las **dos** formas del
/// `input`.
///
/// En v2 el `input` de un tool en `pending` es un **string crudo** —el JSON que
/// el modelo está armando, todavía sin parsear—, no un mapa
/// (`lib/domain/models/tool.dart` lo dice explícito). Por eso leer sólo
/// `asMap(input)` dejaba la card siempre vacía: no había pregunta, no había
/// opciones y el turno quedaba trabado hasta que el usuario apretara Detener.
/// Algunos builds mandan el input ya parseado, así que se leen las dos formas.
List<Map<String, Object?>> questionItems(AssistantTool tool) {
  final input = switch (tool.state.input) {
    null => null,
    final String raw => _jsonObject(raw),
    final Object other => asMap(other),
  };
  return asMapList(input?['questions']);
}

/// `{...}` de un JSON serializado, o `null` si no es un objeto válido.
Map<String, Object?>? _jsonObject(String raw) {
  final body = raw.trim();
  if (!body.startsWith('{')) return null;
  try {
    return asMap(jsonDecode(body));
  } on FormatException {
    // El `input` crudo todavía no es JSON: no hay nada que pintar. La card
    // muestra el header genérico y "Ahora no", que siempre funciona.
    return null;
  }
}

// ─────────────────────────── markdown del asistente ─────────────────────────

/// Markdown del texto del asistente.
///
/// `flutter_markdown_plus` (el sucesor mantenido de `flutter_markdown`, que
/// quedó discontinuado) trae títulos, listas anidadas, tablas, citas y **bloques
/// de código** — que en un chat de agente es lo que más se ve. El renderer
/// anterior sólo cubría párrafos, listas y `código` en línea.
///
/// Los estilos **no** salen de `MarkdownStyleSheet.fromTheme`: sus defaults
/// (viñeta `•` de 24 px, 8 px entre bloques, celdas de tabla de 16 px, `hr` de
/// 5 px, `code` inline como un simple fondo sin borde) son los que hacían que
/// esto se viera como un `Text` de Material y no como la maqueta. Todo sale de
/// tokens en [_markdownSheet], [_CodeBlockBuilder], [_InlineCodeBuilder] y
/// [_bullet].
///
/// La memoización por firma se conserva (es el costo #1 del render con 500
/// mensajes, plan §4): si el texto no cambió, se devuelve **la misma**
/// instancia de subtree.
///
/// Es público y sin `const` a propósito: el memo vive en el estado, así que
/// el widget tiene que ser estable entre rebuilds.
class MarkdownText extends StatefulWidget {
  const MarkdownText(this.text, {super.key, this.streaming = false});

  final String text;

  /// El turno sigue escribiendo: se pinta **texto plano** (`.streamline` del
  /// prototipo y el `streaming` del cliente desktop). Parsear markdown en cada
  /// delta, además de costly, hace parpadear los títulos y las listas a medio
  /// construir; el markdown rico entra al terminar el turno.
  final bool streaming;

  @override
  State<MarkdownText> createState() => _MarkdownTextState();
}

class _MarkdownTextState extends State<MarkdownText> {
  /// Firma de lo renderizado (texto + modo + estilo). Si no cambia, se
  /// reutiliza el subtree entero. El separador \u0000 evita que dos textos
  /// distintos den la misma firma al concatenarse.
  String? _signature;
  Widget? _cached;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // El tema entra al subárbol renderizado (colores, brillo y la escala de
    // texto del sistema): si cambia, el memo quedó rancio. La firma también,
    // o `build` devolvería el caché que acabamos de tirar.
    _signature = null;
    _cached = null;
  }

  @override
  Widget build(BuildContext context) {
    final body = widget.text.trim();
    if (body.isEmpty) return const SizedBox.shrink();
    final style = Theme.of(context).textTheme.bodyMedium!;
    final signature =
        '${widget.text}\u0000${widget.streaming}\u0000${style.color}\u0000'
        '${style.fontSize}\u0000${MediaQuery.textScalerOf(context).scale(13)}';
    if (signature != _signature) {
      _signature = signature;
      _cached = _render(context, body);
    }
    return _cached ?? const SizedBox.shrink();
  }

  Widget _render(BuildContext context, String body) {
    final theme = Theme.of(context);
    if (widget.streaming) {
      // `.streamline` del prototipo: una línea de texto del mismo cuerpo, sin
      // parsear nada.
      return Text(body, style: theme.textTheme.bodyMedium);
    }
    final muted = theme.colorScheme.onSurfaceVariant;
    final base = theme.textTheme.bodyMedium!;
    return MarkdownBody(
      data: body,
      // Seleccionable, como el cliente desktop: en un chat lo que uno quiere es
      // copiar el fragmento, no el mensaje entero.
      selectable: true,
      styleSheet: _markdownSheet(context),
      builders: {'pre': _CodeBlockBuilder(), 'code': _InlineCodeBuilder()},
      bulletBuilder: (parameters) => _bullet(parameters, base, muted),
      // La viñeta va arriba de la primera línea (`.ai li::before`), no en la
      // línea base: el punto es una caja sin texto y no tiene base que alinear.
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.start,
    );
  }
}

/// La hoja de estilos del markdown del chat.
///
/// Cada valor sale de un token o de una regla medida del prototipo
/// (`prototype/mobile.html`) o del cliente desktop, y está anotado con su
/// origen. Lo que no se usa son los defaults de `fromTheme`, que es
/// exactamente lo que había que cambiar.
MarkdownStyleSheet _markdownSheet(BuildContext context) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final dark = theme.brightness == Brightness.dark;
  final muted = scheme.onSurfaceVariant;
  final mutedStrong = dark
      ? AppColors.darkMutedStrong
      : AppColors.lightMutedStrong;
  // `.ai` (:254): 13 px sobre `--text`, que es el `bodyMedium` del tema.
  final base = theme.textTheme.bodyMedium!;

  // Escala de encabezados: los ratios del `chat.css` del cliente desktop
  // (18.4/16.8/15.2/14.08 sobre 14 px) llevados al cuerpo de 13 px. Con los
  // títulos del tema (que colapsan display/headline/title a 14 px) un `#` se
  // veía del mismo tamaño que el párrafo.
  TextStyle heading(double ratio) => base.copyWith(
    fontSize: (base.fontSize! * ratio).roundToDouble(),
    height: 1.35,
    fontWeight: FontWeight.w700,
  );

  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: base,
    a: base.copyWith(
      color: scheme.primary,
      decoration: TextDecoration.underline,
    ),
    strong: base.copyWith(fontWeight: FontWeight.w700),
    // 8 px entre bloques: el mismo default del cliente desktop. Con 0 los
    // párrafos quedan pegados.
    blockSpacing: AppSpacing.sm,
    // `.ai li{gap:7px}` con un punto de 4 px: cada nivel sangra 4 + 7.
    listIndent: AppSpacing.xs,
    listBulletPadding: const EdgeInsets.only(right: 7),
    listBullet: base,
    h1: heading(1.31),
    h2: heading(1.2),
    h3: heading(1.09),
    h4: heading(1),
    h5: heading(1),
    h6: heading(1),
    // Cita: filete de 2 px a la izquierda y `--muted` para el texto, como el
    // cliente desktop. El default (relleno `surfaceContainerHighest` + radio 3
    // + filete de 3 px) es el look "Material".
    blockquote: base.copyWith(color: muted),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: muted, width: 2)),
    ),
    blockquotePadding: const EdgeInsets.only(left: AppSpacing.md),
    // El chip inline lo pinta el builder (`code.chip` lleva borde, padding y
    // radio, que un `TextStyle` no puede expresar). El estilo queda como base
    // y para el texto que el builder no cubre.
    code: TextStyle(
      fontFamily: 'monospace',
      fontSize: 11.5,
      height: 1.55,
      color: mutedStrong,
      backgroundColor: dark ? AppColors.darkCodeBg : AppColors.lightCodeBg,
    ),
    // El bloque lo arma `_CodeBlockBuilder`; el paquete envuelve lo que
    // devuelva con este `Container`, así que va vacío para no duplicar fondo,
    // radio ni padding.
    codeblockDecoration: const BoxDecoration(),
    codeblockPadding: EdgeInsets.zero,
    // `fromTheme` pone un filete de 5 px: en un chat se lee como un bloque.
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: scheme.outline, width: 1)),
    ),
    tableHead: base.copyWith(fontWeight: FontWeight.w700),
    tableBody: base,
    tableBorder: TableBorder.all(color: scheme.outline, width: 1),
    // `fromTheme` deja 16 px horizontales: en 360 px una tabla de dos columnas
    // no entra. 10/6 es lo que usa el cliente desktop.
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    // El ancho intrínseco es lo que hace que la tabla scrollee en horizontal
    // en vez de reventar el ancho de la burbuja.
    tableColumnWidth: const IntrinsicColumnWidth(),
    // El paquete fusiona esta hoja con la del tema y en el merge el
    // `textScaler` lo gana el lado derecho: sin pasarlo explícitamente, el
    // tamaño de fuente del sistema se pierde en todo el texto del asistente.
    textScaler: MediaQuery.textScalerOf(context),
  );
}

/// La viñeta de las listas.
///
/// El default del paquete es un `•` de 13 px, que pesa más que el texto y deja
/// la lista desalineada. `.ai li::before` (`prototype/mobile.html:258`) es un
/// punto de 4 px en `--muted` a 7 px de la primera línea.
Widget _bullet(
  MarkdownBulletParameters parameters,
  TextStyle base,
  Color muted,
) {
  if (parameters.style == BulletStyle.orderedList) {
    return Text(
      '${parameters.index + 1}.',
      textAlign: TextAlign.right,
      style: base.copyWith(color: muted),
    );
  }
  return Padding(
    padding: const EdgeInsets.only(top: 7),
    child: Container(
      width: 4,
      height: 4,
      decoration: BoxDecoration(color: muted, shape: BoxShape.circle),
    ),
  );
}

/// Bloque de código (`` ``` ``): `--code-bg`, borde `--border`, radio `--r2`,
/// 11.5 px monoespaciados en `--code-text`.
///
/// El default del paquete mete el texto en un `SingleChildScrollView`
/// horizontal **sin tope de alto** y con el `code` inline de fondo: un bloque
/// largo estira la lista de mensajes entera.
class _CodeBlockBuilder extends MarkdownElementBuilder {
  // Sin `const`: `MarkdownElementBuilder` no tiene constructor const.
  _CodeBlockBuilder();

  @override
  bool isBlockElement() => true;

  /// El texto del fence entra por acá. El placeholder vacío es obligatorio: si
  /// además se texturiza, el paquete lo vuelca como bloque propio y el código
  /// sale dos veces.
  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) =>
      const SizedBox.shrink();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = element.textContent;
    return _CodeBlock(
      code: code.endsWith('\n') ? code.substring(0, code.length - 1) : code,
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.xs),
      decoration: BoxDecoration(
        color: dark ? AppColors.darkCodeBg : AppColors.lightCodeBg,
        border: Border.all(color: theme.colorScheme.outline),
        borderRadius: AppRadius.mdAll,
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        // `.codeblock{max-height:190px;overflow:auto}` (:299-302): el mismo
        // tope que usa la salida de una tool.
        constraints: const BoxConstraints(maxHeight: 190),
        child: SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              // `softWrap:false` + scroll horizontal: una línea larga scrollea
              // en vez de desbordar la burbuja.
              child: Text(
                code,
                softWrap: false,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11.5,
                  height: 1.55,
                  color: dark
                      ? AppColors.darkCodeText
                      : AppColors.lightCodeText,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `code` en línea: el chip de `prototype/mobile.html:259-262`.
///
/// Un `TextStyle` sólo puede pintar el fondo de los glifos, así que el borde
/// de 1 px, el padding de 1/5 y el radio de `--r1` necesitan un widget: sin
/// esto el código en línea salía como texto mono pelado.
class _InlineCodeBuilder extends MarkdownElementBuilder {
  // Sin `const`: `MarkdownElementBuilder` no tiene constructor const.
  _InlineCodeBuilder();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => _CodeChip(code: element.textContent, style: preferredStyle);
}

class _CodeChip extends StatelessWidget {
  const _CodeChip({required this.code, this.style});

  final String code;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      // 1 px / 5 px son los del CSS; no hay token de 1 ni de 5.
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: dark ? AppColors.darkCodeBg : AppColors.lightCodeBg,
        border: Border.all(color: theme.colorScheme.outline),
        borderRadius: AppRadius.smAll,
      ),
      // El fondo lo pone la decoración: el del estilo se descarta para que no
      // se vea un rectángulo detrás de otro.
      child: Text(
        code,
        style: (style ?? const TextStyle()).copyWith(
          backgroundColor: Colors.transparent,
        ),
      ),
    );
  }
}

// ─────────────────────────── card de pregunta ───────────────────────────

class QuestionOption {
  const QuestionOption({required this.label, this.detail});

  final String label;
  final String? detail;
}

/// La card de la tool `question` (`chat.msg.question`).
///
/// Sólo se muestra con el tool en `pending`, que es el único estado en el que
/// se puede contestar. La card **no** manda nada: entrega las opciones elegidas
/// (o la lista vacía del "Ahora no") a `MessageBubble.onQuestionAnswer`, y de
/// ahí al viewmodel, que las manda al endpoint de reply del protocolo y —si ese
/// endpoint no existe en el build— las manda como prompt. Ver
/// `ChatViewModel.answerQuestion`.
class QuestionCard extends StatefulWidget {
  const QuestionCard({
    super.key,
    required this.header,
    required this.question,
    required this.options,
    this.onSubmit,
    this.onSkip,
  });

  final String header;
  final String question;
  final List<QuestionOption> options;

  final void Function(List<String> answers)? onSubmit;

  /// "Ahora no": lista vacía. El server lo trata como un *skip*.
  final void Function(List<String> answers)? onSkip;

  static const Key submitKey = Key('question-submit');
  static const Key skipKey = Key('question-skip');

  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  final Set<int> _selected = {};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mutedStrong = theme.brightness == Brightness.dark
        ? AppColors.darkMutedStrong
        : AppColors.lightMutedStrong;
    return Container(
      // El margen vertical lo pone el `.msg` del chat (6 px entre hijos).
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: AppRadius.lgAll,
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // `.qhead` (:314): banda `surface-subtle` con filete abajo, rótulo en
          // mayúsculas de 11 px.
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              border: Border(bottom: BorderSide(color: scheme.outline)),
            ),
            child: Row(
              children: [
                AppIcon('message-square', size: 16, color: mutedStrong),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    // El texto va **tal cual** lo mandó el modelo: `.qhead` del
                    // prototipo lo pasa por `text-transform:uppercase`, que en
                    // Flutter no existe como estilo (habría que recorrer la
                    // cadena) y rompería el rótulo que el agente escribió. La
                    // banda, el filete y la escala de 11 px w700 ya dan la
                    // lectura de "rótulo".
                    widget.header,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.3,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.66,
                      color: mutedStrong,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // `.qbody` (:315): 12 px de padding y 8 px entre los hijos.
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.question.isNotEmpty) ...[
                  Text(
                    widget.question,
                    style: TextStyle(fontSize: 13, color: scheme.onSurface),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                for (var i = 0; i < widget.options.length; i++) ...[
                  _option(context, i),
                  if (i != widget.options.length - 1)
                    const SizedBox(height: AppSpacing.sm),
                ],
              ],
            ),
          ),
          // `.qactions` (:325-326): 12 px laterales, 12 abajo, botones de 36 px.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.md,
            ),
            child: Row(
              children: [
                Expanded(
                  child: _GhostButton(
                    key: QuestionCard.submitKey,
                    label: 'Enviar',
                    primary: true,
                    // `.qactions .ghostbtn{height:36px}`.
                    height: 36,
                    onTap: _selected.isEmpty
                        ? null
                        : () => widget.onSubmit?.call(_answers()),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: _GhostButton(
                    key: QuestionCard.skipKey,
                    label: 'Ahora no',
                    height: 36,
                    onTap: () => widget.onSkip?.call(const <String>[]),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// `.qopt` (:317-323): fila con borde y radio, `primary-soft` marcada, y un
  /// radio de 16 px con punto de 8 px adentro. Antes era un `InkWell` sin borde
  /// con un círculo de 12 px, que no se leía como opción.
  Widget _option(BuildContext context, int index) {
    final option = widget.options[index];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final picked = _selected.contains(index);
    // `--primary-soft` de `.qopt[aria-checked="true"]`.
    final soft = theme.brightness == Brightness.dark
        ? AppColors.darkPrimarySoft
        : AppColors.lightPrimarySoft;
    return Semantics(
      button: true,
      selected: picked,
      child: Material(
        color: picked ? soft : scheme.surface,
        borderRadius: AppRadius.mdAll,
        child: InkWell(
          onTap: () => setState(() {
            if (!picked) {
              _selected.add(index);
            } else {
              _selected.remove(index);
            }
          }),
          borderRadius: AppRadius.mdAll,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              borderRadius: AppRadius.mdAll,
              border: Border.all(
                color: picked ? scheme.primary : scheme.outline,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Radio(picked: picked),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        option.label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurface,
                        ),
                      ),
                      if (option.detail case final String detail) ...[
                        const SizedBox(height: 1),
                        Text(
                          detail,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<String> _answers() => [
    for (final i in _selected) widget.options[i].label,
  ];
}

/// `.radio` (:320-322): círculo de 16 px con filete de 1.5 px y, marcada, un
/// punto de 8 px adentro.
class _Radio extends StatelessWidget {
  const _Radio({required this.picked});

  final bool picked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 16,
      height: 16,
      margin: const EdgeInsets.only(top: 2),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: picked ? scheme.primary : scheme.outlineVariant,
          width: 1.5,
        ),
      ),
      child: picked
          ? Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary,
              ),
            )
          : null,
    );
  }
}

// ─────────────────────────── piezas compartidas ───────────────────────────

/// Botón fantasma (`.ghostbtn`, `prototype/mobile.html:233-242`): borde 1 px,
/// 12 px en `--muted-strong`, y `primary` con w600 cuando es la acción
/// principal de la fila.
///
/// La altura la fija la fila que lo usa: `.ghostbtn` mide 32 y `.qactions
/// .ghostbtn` 36 (:326). Por eso es un parámetro con default.
class _GhostButton extends StatelessWidget {
  const _GhostButton({
    super.key,
    required this.label,
    this.onTap,
    this.primary = false,
    this.height = 32,
  });

  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onTap != null;
    final mutedStrong = theme.brightness == Brightness.dark
        ? AppColors.darkMutedStrong
        : AppColors.lightMutedStrong;
    final fg = primary
        ? scheme.onPrimary
        : (enabled ? mutedStrong : scheme.onSurfaceVariant);
    return Material(
      color: primary ? scheme.primary : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.mdAll,
        side: BorderSide(color: primary ? scheme.primary : scheme.outline),
      ),
      child: InkWell(
        onTap: onTap,
        child: Opacity(
          // `.ghostbtn:disabled{opacity:.45}`: el "Enviar" sin selección se ve
          // apagado, no en un gris distinto al del texto.
          opacity: enabled ? 1 : 0.45,
          child: Container(
            height: height,
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `chat.typing`: tres puntos con desfase de 150 ms (`.typing` del
/// prototipo). Es la única animación infinita del chat mientras se espera.
class TypingDots extends StatefulWidget {
  const TypingDots({super.key});

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return SizedBox(
      height: 18,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            AnimatedBuilder(
              animation: _c,
              builder: (_, _) {
                // Un seno por punto con 150 ms de desfase: el mismo "bounce"
                // escalonado del CSS, sin depender de un asset de animación.
                final phase = (_c.value * 3 - i * 0.15) % 3;
                final wave = math.sin(phase / 3 * math.pi);
                // `@keyframes bounce` (:333): además del fade, el punto sube
                // 3 px en el pico. Sólo con el fade los tres puntos se leían
                // como una fila de círculos quietos.
                return Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.only(right: 5),
                  transform: Matrix4.translationValues(0, -3 * wave, 0),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.28 + 0.72 * wave),
                    shape: BoxShape.circle,
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}



/// Aviso de "este mensaje todavía no lo tomó el server", con reintento.
///
/// Va **dentro** de la burbuja y no como banner: el aviso pertenece a ese
/// mensaje, no a toda la conversación. Con un banner el usuario no sabe
/// cuál de sus mensajes falló.
class _NotDeliveredChip extends StatelessWidget {
  const _NotDeliveredChip({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dim = scheme.onPrimary.withValues(alpha: 0.85);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.error_outline, size: 13, color: dim),
        const SizedBox(width: 4),
        Text(
          'No se envío',
          style: theme.textTheme.labelSmall?.copyWith(fontSize: 11, color: dim),
        ),
        const SizedBox(width: 6),
        // Botón chico y explícito: el usuario tiene que poder reintentar
        // sin volver a escribir el mensaje.
        InkWell(
          onTap: onRetry,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            child: Text(
              'Reintentar',
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: scheme.onPrimary,
                decoration: TextDecoration.underline,
                decorationColor: scheme.onPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}