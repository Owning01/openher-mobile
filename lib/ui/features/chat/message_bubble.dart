/// Una burbuja de la lista de mensajes (`chat.msg.*`).
///
/// Un solo widget para los ocho tipos de [SessionMessage] porque la lista los
/// intercala en el mismo scroll y cada uno es una fracción de la misma caja:
///
/// * [UserMessage] → burbuja a la derecha, `primary` sobre `on-primary`.
/// * [AssistantMessage] → caja de actividad (razonamiento + tools), la card de
///   pregunta si hay un `question` pendiente, la de error del proveedor si vino
///   `assistant.error`, y el texto.
/// * [SystemMessage] / [SyntheticMessage] / [CompactionMessage] y los
///   `*-switched` → píldora centrada delgada.
/// * [ShellMessage] → píldora con el comando (un comando del server no es una
///   respuesta del modelo, pero tampoco puede desaparecer).
///
/// ## Markdown: renderer mínimo, sin dependencia
/// No hay `flutter_markdown` en el `pubspec` y agregarlo por esto sería una
/// dependencia grande para tres casos: párrafos, listas con `-` y `` `código` ``
/// en línea. Eso es exactamente lo que usa el prototipo (`.ai p`, `.ai li`,
/// `code.chip`). Lo que **no** se soporta (tablas, anidado, HTML) se muestra
/// como texto plano, que es el mismo resultado visual que un parser que
/// descarta lo que no entiende.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../../domain/models/errors.dart';
import '../../../domain/models/message.dart';
import '../../../domain/models/tool.dart';
import '../../core/app_icon.dart';
import '../../core/layer_gate.dart';
import '../../core/tokens.dart';
import 'turn_activity.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.working,
    this.thinkingDefault = true,
    this.onOpenDiff,
    this.onQuestionAnswer,
  });

  final SessionMessage message;

  /// El turno de este assistant sigue vivo. Sólo afecta a los puntos de
  /// escritura: un assistant terminado no parpadea.
  final bool working;

  final bool thinkingDefault;
  final ValueChanged<AssistantTool>? onOpenDiff;

  /// Responde una pregunta del tool `question` (`chat.msg.question`). La
  /// respuesta vuelve como un prompt del usuario, que es lo que el server
  /// espera (`API_CONTRACT.md` §4.3 y §6).
  final void Function(List<String> answers)? onQuestionAnswer;

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
    final tools = assistant.toolItems;

    if (tools.isNotEmpty) {
      children.add(
        TurnActivityBox(
          tools: tools,
          working: working && !assistant.isComplete,
          time: assistant.time,
          thinkingDefault: thinkingDefault,
          onOpenDiff: onOpenDiff,
        ),
      );
    }

    // Una pregunta pendiente tiene prioridad visual sobre el texto: es la
    // única forma de desbloquear el turno.
    for (final tool in tools) {
      if (tool.name == 'question' && tool.state is ToolPending) {
        children.add(_question(context, tool));
        break;
      }
    }

    // Canal A de §5: el turno murió. Va antes del texto porque es lo que hay
    // que leer primero; el texto parcial que quedó sigue debajo.
    final error = assistant.error;
    if (error != null) children.add(_errorCard(context, error));

    children.add(
      LayerGate(
        'chat.msg.assistant',
        child: MarkdownText(assistant.textContent),
      ),
    );

    // Los puntos sólo mientras el texto aún no llegó: si hay algo escrito, el
    // texto ES el indicador.
    if (working && assistant.textContent.trim().isEmpty) {
      children.add(const LayerGate('chat.typing', child: TypingDots()));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  // ─────────────────────────── usuario ───────────────────────────

  Widget _user(BuildContext context, UserMessage user) {
    final scheme = Theme.of(context).colorScheme;
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
            style: TextStyle(fontSize: 13, color: scheme.onPrimary),
          ),
        ],
      ),
    );

    return LayerGate(
      'chat.msg.user.bubble',
      child: Align(
        alignment: Alignment.centerRight,
        child: FractionallySizedBox(
          // `max-width: 88%` del CSS: la burbuja larga no barre la pantalla.
          widthFactor: 0.88,
          alignment: Alignment.centerRight,
          child: bubble,
        ),
      ),
    );
  }

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
              padding: const EdgeInsets.only(bottom: 4),
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
                  Text(
                    file.name ?? file.uri.split('/').last,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
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
  Widget _errorCard(BuildContext context, OcErrorInfo error) {
    final scheme = Theme.of(context).colorScheme;
    final danger = AppColors.dangerOf(Theme.of(context).brightness);
    return LayerGate(
      'chat.msg.error',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          borderRadius: AppRadius.mdAll,
          border: Border.all(color: danger),
          color: scheme.surfaceContainerHighest,
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
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// `.syspill`: píldora centrada delgada de 12 px.
  Widget _pill(BuildContext context, String text) {
    if (text.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return LayerGate(
      'chat.msg.system',
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
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
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  /// `chat.msg.question`: la card de la tool `question` en `pending`.
  Widget _question(BuildContext context, AssistantTool tool) {
    final questions = tool.questionsRaw;
    final first = questions.isEmpty
        ? const <String, Object?>{}
        : questions.first;
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
        onSubmit: onQuestionAnswer,
        onSkip: onQuestionAnswer,
      ),
    );
  }
}

// ─────────────────────────── markdown mínimo ───────────────────────────

/// Markdown del texto del asistente.
///
/// `flutter_markdown_plus` (el sucesor mantenido de `flutter_markdown`, que
/// quedó discontinuado) trae títulos, listas anidadas, tablas y **bloques de
/// código** — que en un chat de agente es lo que más se ve. El renderer
/// anterior sólo cubría párrafos, listas y `código` en línea.
///
/// La memoización por firma se conserva (es el costo #1 del render con 500
/// mensajes, plan §4): si el texto no cambió, se devuelve **la misma**
/// instancia de subtree.
///
/// Es público y sin `const` a propósito: el memo vive en el estado, así que
/// el widget tiene que ser estable entre rebuilds.
class MarkdownText extends StatefulWidget {
  const MarkdownText(this.text, {super.key});

  final String text;

  @override
  State<MarkdownText> createState() => _MarkdownTextState();
}

class _MarkdownTextState extends State<MarkdownText> {
  /// Firma de lo renderizado (texto + estilo). Si no cambia, se reutiliza el
  /// subtree entero. El separador   evita que dos textos distintos den la
  /// misma firma al concatenarse.
  String? _signature;
  Widget? _cached;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium!;
    final signature = '${widget.text} ${style.color} ${style.fontSize}';
    if (signature != _signature) {
      _signature = signature;
      _cached = _render(context, style);
    }
    return _cached ?? const SizedBox.shrink();
  }

  Widget _render(BuildContext context, TextStyle style) {
    final body = widget.text.trim();
    if (body.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final codeBg = isDark ? AppColors.darkCodeBg : AppColors.lightCodeBg;

    return MarkdownBody(
      data: body,
      // El padding del body lo pone la burbuja: acá 0 para no duplicar.
      selectable: false,
      shrinkWrap: true,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: style,
        a: style.copyWith(
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
        ),
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11.5,
          color: theme.colorScheme.onSurfaceVariant,
          backgroundColor: codeBg,
        ),
        codeblockDecoration: BoxDecoration(
          color: codeBg,
          borderRadius: AppRadius.smAll,
        ),
        codeblockPadding: const EdgeInsets.all(AppSpacing.sm),
        blockquoteDecoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: AppRadius.smAll,
        ),
        blockquotePadding: const EdgeInsets.all(AppSpacing.sm),
        // Tablas y código largo scrollean: en 360 px no entran.
        tableBorder: TableBorder.all(color: theme.dividerColor, width: 1),
        tableCellsPadding: const EdgeInsets.all(6),
        tableColumnWidth: const IntrinsicColumnWidth(),
        h1: style.copyWith(fontSize: 20, fontWeight: FontWeight.w700),
        h2: style.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
        h3: style.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
        listBullet: style.copyWith(color: theme.colorScheme.onSurfaceVariant),
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
/// se puede contestar. Al enviar, las respuestas vuelven como un prompt del
/// usuario con el formato que el server ya entiende (una línea por respuesta).
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

  /// "Ahora no": contesta con la lista vacía (el server lo trata como *skip*).
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
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: AppRadius.mdAll,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.sm,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                AppIcon('message-square', size: 16),
                const SizedBox(width: 6),
                Text(
                  widget.header,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          if (widget.question.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: Text(
                widget.question,
                style: TextStyle(fontSize: 13, color: scheme.onSurface),
              ),
            ),
          for (var i = 0; i < widget.options.length; i++) _option(context, i),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Row(
              children: [
                Expanded(
                  child: _GhostButton(
                    key: QuestionCard.submitKey,
                    label: 'Enviar',
                    primary: true,
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

  Widget _option(BuildContext context, int index) {
    final option = widget.options[index];
    final scheme = Theme.of(context).colorScheme;
    final picked = _selected.contains(index);
    return InkWell(
      onTap: () => setState(() {
        if (!picked) {
          _selected.add(index);
        } else {
          _selected.remove(index);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 6,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 12,
              height: 12,
              margin: const EdgeInsets.only(top: 3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: picked ? scheme.primary : scheme.outlineVariant,
                  width: picked ? 4 : 1,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    option.label,
                    style: TextStyle(fontSize: 13, color: scheme.onSurface),
                  ),
                  if (option.detail case final String detail)
                    Text(
                      detail,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<String> _answers() => [
    for (final i in _selected) widget.options[i].label,
  ];
}

// ─────────────────────────── piezas compartidas ───────────────────────────

/// Botón fantasma (`.ghostbtn`): borde 1 px, 13 px, y `primary` cuando es la
/// acción principal de la fila.
class _GhostButton extends StatelessWidget {
  const _GhostButton({
    super.key,
    required this.label,
    this.onTap,
    this.primary = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    final fg = primary
        ? scheme.onPrimary
        : (enabled ? scheme.onSurface : scheme.onSurfaceVariant);
    return Material(
      color: primary ? scheme.primary : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.mdAll,
        side: BorderSide(color: primary ? scheme.primary : scheme.outline),
      ),
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 32,
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: primary ? FontWeight.w600 : FontWeight.w400,
              color: fg,
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
                return Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.only(right: 5),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.35 + 0.65 * wave),
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
