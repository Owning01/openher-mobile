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
  /// **Siempre cerrada.**
  ///
  /// Antes se abría sola mientras el turno trabajan (`working &&
  /// thinkingDefault`), y como hay una caja por mensaje de assistant, un chat
  /// con 30 turnos acababa con 30 cajas abiertas de 180 px cada una: 5.400 px
  /// de herramientas empujando la respuesta muy lejos del ojo. El usuario lo
  /// reportó como "las herramientas me llenan todo el chat de más altura".
  ///
  /// Ahora la regla es una sola: la caja es un resumen de una línea que se
  /// abre si el usuario la abre. El rótulo del encabezado ya dice si el turno
  /// está trabajando, así que no se pierde el feedback de "está haciendo algo".
  late bool _open = false;

  @override
  void didUpdateWidget(TurnActivityBox old) {
    super.didUpdateWidget(old);
    // Un rebuild (un delta más, un poll) no la abre ni la cierra: si el
    // usuario la plegó, se queda plegada aunque el turno siga corriendo. Era
    // justo el otro motivo por el que las cajas se acumulaban.
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tools.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        // `.actbox` (:274): `--r3` (8), no `--r2`.
        color: scheme.surfaceContainerLow,
        borderRadius: AppRadius.lgAll,
        border: Border.all(color: scheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _head(theme, text),
            if (_open) ...[const SizedBox(height: AppSpacing.xs), _body()],
          ],
        ),
      ),
    );
  }

  Widget _head(ThemeData theme, TextTheme text) {
    final scheme = theme.colorScheme;
    final label = turnCategoryLabel(widget.tools);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: TurnActivityBox.headKey,
        onTap: () => setState(() => _open = !_open),
        borderRadius: AppRadius.mdAll,
        // `.acthead:hover{background:var(--surface-hover)}` (:276).
        hoverColor: scheme.surfaceContainerHigh,
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
                        // `.actlabel` (:279) es `--muted-strong`: con `--text`
                        // el rótulo competía con la respuesta de arriba.
                        color: theme.brightness == Brightness.dark
                            ? AppColors.darkMutedStrong
                            : AppColors.lightMutedStrong,
                      ),
                    ),
                  ),
                ),
                LayerGate(
                  'chat.activitybox.summary',
                  child: _summary(theme, text),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Derecha de la fila: `N herramientas · X.Xs` si el turno terminó, o el
  /// spinner de 12 px **con el "· pensando"** del prototipo (:974) si sigue
  /// trabajando. El texto no es adorno: dice que el turno vive, que el spinner
  /// solo puede insinuar.
  Widget _summary(ThemeData theme, TextTheme text) {
    final scheme = theme.colorScheme;
    final style = text.bodySmall?.copyWith(
      fontSize: 12,
      color: scheme.onSurfaceVariant,
    );
    if (widget.working) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        // `.actsum{gap:6px}`.
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          Text('· pensando', style: style),
        ],
      );
    }
    final count = widget.tools.length;
    final tools = count == 1 ? '1 herramienta' : '$count herramientas';
    final ms = widget.time?.completedMs;
    final start = widget.time?.streamedMs ?? widget.time?.createdMs;
    final label = (ms != null && start != null && ms > start)
        ? '$tools · ${toolDurationMs(ms - start)}'
        : tools;
    return Text(label, style: style);
  }

  /// `chat.activitybox.body`: alto máximo 180 px con scroll propio, borde
  /// izquierdo como en el `.actbody` del prototipo.
  Widget _body() {
    return LayerGate(
      'chat.activitybox.body',
      child: Container(
        constraints: const BoxConstraints(maxHeight: kToolListMaxHeight),
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
                  padding: const EdgeInsets.only(bottom: kToolRowSpacing),
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
///
/// La tabla de nombres vive en [kToolInfo] (`tool_card.dart`): acá sólo se
/// recorre, no se decide la categoría.
String turnCategoryLabel(List<AssistantTool> tools) {
  final seen = <String>{};
  final out = <String>[];
  for (final tool in tools) {
    final category = toolCategory(tool.name);
    if (seen.add(category)) out.add(category);
  }
  return out.join(' · ');
}

/// Altura fija de la lista de herramientas cuando la caja está abierta.
///
/// Es un tope, no un mínimo: con 40 llamadas a herramientas el chat no crece 40
/// filas, crece **esta** caja y adentro scrollea. Un número con nombre en vez
/// de un `180` suelto porque es el que define la altura del chat y cualquier
/// cambio tiene que ser deliberado.
const double kToolListMaxHeight = 148;

/// Padding de la fila de herramientas, para que la última no quede pegada al
/// borde de la caja.
const double kToolRowSpacing = 6;
