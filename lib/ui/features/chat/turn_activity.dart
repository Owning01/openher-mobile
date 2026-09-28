/// La caja de actividad del turno (`chat.activitybox.*`): una sola fila
/// plegable que resume el razonamiento + las tools del assistant.
///
/// ## La regla de auto-colapso (importante)
/// El prototipo abre el turno mientras trabaja y lo cierra cuando termina. En
/// Flutter eso NO puede ser "cada vez que se rebuilda", porque un rebuild que
/// no tiene nada que ver (un delta de texto, la llegada de un mensaje) se
/// comería el toggle manual del usuario. La regla exacta que se implementa:
///
/// * `_open` **sólo** se escribe en tres lugares: [initState],
///   [didUpdateWidget] con un cambio de `working`, y [didUpdateWidget] con un
///   cambio de `thinkingDefault`.
/// * Ningún otro camino lo toca, así que un abierto manual sobrevive todos los
///   rebuilds del turno.
///
/// Un rebuild con los mismos `working`/`thinkingDefault` **no** escribe
/// `_open`: ése es el punto entero del widget.
library;

import 'package:flutter/material.dart';

import '../../../domain/models/message.dart';
import '../../core/app_icon.dart';
import '../../core/layer_gate.dart';
import '../../core/tokens.dart';
import 'tool_card.dart';

class TurnActivityBox extends StatefulWidget {
  const TurnActivityBox({
    super.key,
    required this.tools,
    required this.working,
    this.time,
    this.thinkingDefault = true,
    this.onOpenDiff,
  });

  final List<AssistantTool> tools;

  /// Hay un turno en curso sobre este assistant.
  final bool working;

  /// `message.time` del assistant. Sólo se usa para el resumen `N herramientas ·
  /// X.Xs`: sin `time.completed` no hay duración que mentir.
  final MessageTime? time;

  /// Preferencia del usuario: "el razonamiento arranca abierto". Se lee desde
  /// Ajustes; mientras working sea `true` manda `true`.
  final bool thinkingDefault;

  final ValueChanged<AssistantTool>? onOpenDiff;

  /// Fila plegable. El test la apunta por key para no depender del texto.
  static const Key headKey = Key('activitybox-head');

  @override
  State<TurnActivityBox> createState() => _TurnActivityBoxState();
}

class _TurnActivityBoxState extends State<TurnActivityBox> {
  late bool _open = widget.working && widget.thinkingDefault;

  @override
  void didUpdateWidget(TurnActivityBox old) {
    super.didUpdateWidget(old);
    if (widget.working != old.working) {
      // El turno arrancó ⇒ se abre para que se vea trabajar; terminó ⇒ se
      // cierra para dejar lugar a la respuesta.
      _open = widget.working ? widget.thinkingDefault : false;
      return;
    }
    if (widget.thinkingDefault != old.thinkingDefault) {
      _open = widget.working && widget.thinkingDefault;
    }
    // Cualquier otro rebuild deja `_open` como está.
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tools.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: AppRadius.mdAll,
        border: Border.all(color: scheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _head(scheme, text),
            if (_open) ...[const SizedBox(height: AppSpacing.xs), _body()],
          ],
        ),
      ),
    );
  }

  Widget _head(ColorScheme scheme, TextTheme text) {
    final label = turnCategoryLabel(widget.tools);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: TurnActivityBox.headKey,
        onTap: () => setState(() => _open = !_open),
        child: SizedBox(
          height: 32,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: Row(
              children: [
                LayerGate(
                  'chat.activitybox.chevron',
                  child: AnimatedRotation(
                    turns: _open ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: AppIcon(
                      _open ? 'chevron-down' : 'chevron-right',
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: LayerGate(
                    'chat.activitybox.label',
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.66,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ),
                LayerGate(
                  'chat.activitybox.summary',
                  child: _summary(scheme, text),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Derecha de la fila: `N herramientas · X.Xs` si el turno terminó, o el
  /// spinner de 12 px si sigue trabajando (el prototipo escribe "pensando"
  /// al lado; acá alcanza con el spinner, que es el dato que no miente).
  Widget _summary(ColorScheme scheme, TextTheme text) {
    if (widget.working) {
      return SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(
          strokeWidth: 1.5,
          color: scheme.onSurfaceVariant,
        ),
      );
    }
    final count = widget.tools.length;
    final tools = count == 1 ? '1 herramienta' : '$count herramientas';
    final ms = widget.time?.completedMs;
    final start = widget.time?.streamedMs ?? widget.time?.createdMs;
    final label = (ms != null && start != null && ms > start)
        ? '$tools · ${toolDurationMs(ms - start)}'
        : tools;
    return Text(
      label,
      style: text.bodySmall?.copyWith(
        fontSize: 12,
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  /// `chat.activitybox.body`: alto máximo 180 px con scroll propio, borde
  /// izquierdo como en el `.actbody` del prototipo.
  Widget _body() {
    return LayerGate(
      'chat.activitybox.body',
      child: Container(
        constraints: const BoxConstraints(maxHeight: 180),
        margin: const EdgeInsets.only(left: 10),
        padding: const EdgeInsets.only(left: AppSpacing.sm),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: Theme.of(context).colorScheme.outline),
          ),
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final tool in widget.tools)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: ToolCard(
                    key: ValueKey('tool-${tool.id}'),
                    tool: tool,
                    onOpenDiff: widget.onOpenDiff,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Las categorías de la fila: el nombre de la tool en mayúsculas, deduplicado
/// y en el orden de aparición. Es lo que el prototipo escribe a mano
/// (`SHELL · READ · EDIT`).
String turnCategoryLabel(List<AssistantTool> tools) {
  final seen = <String>{};
  final out = <String>[];
  for (final tool in tools) {
    final category = toolCategory(tool.name);
    if (seen.add(category)) out.add(category);
  }
  return out.join(' · ');
}

/// Una tool → la categoría que muestra la caja. Lo que no está en la lista
/// pasa con su propio nombre en mayúsculas: una tool nueva no puede romper ni
/// quedar sin etiqueta.
String toolCategory(String name) => switch (name) {
  'shell' || 'bash' || 'powershell' => 'SHELL',
  'read' || 'notebookread' => 'READ',
  'edit' || 'multiedit' => 'EDIT',
  'write' || 'create' => 'WRITE',
  'glob' || 'grep' || 'list' => 'SEARCH',
  'subagent' || 'task' => 'SUBAGENT',
  'skill' => 'SKILL',
  'question' || 'ask' => 'QUESTION',
  _ => name.toUpperCase(),
};
