/// La caja de actividad del turno (`chat.activitybox.*`): una sola fila
/// plegable que resume el razonamiento + las tools **del turno entero**.
///
/// ## Quién la pinta
/// La caja es una por TURNO, no una por mensaje de assistant, y la monta el
/// primer mensaje del turno (justo debajo del prompt del usuario). El agrupado
/// es de `domain/models/turn_activity.dart`; esta clase sólo la pinta. Sin
/// `turnActivity` —uso suelto del widget, o una burbuja sin agrupado— el turno
/// es el mensaje mismo.
///
/// ## El rótulo
/// `Working` mientras el turno corre, con el barrido de brillo del cliente
/// React (`.shimmer-text` de `chat.css`), y `Worked` cuando terminó. Es el
/// rótulo que pidió el usuario, literal.
///
/// ## La regla de auto-colapso (importante)
/// La caja **arranca siempre cerrada** y un rebuild no la abre. En Flutter eso
/// no puede ser "cada vez que se rebuilda", porque un rebuild que no tiene nada
/// que ver (un delta de texto, la llegada de un mensaje) se comería el toggle
/// manual del usuario. La regla exacta que se implementa:
///
/// * `_open` **sólo** se escribe en [initState] (y no en ningún otro lado).
/// * Ningún otro camino lo toca, así que un abierto manual sobrevive todos los
///   rebuilds del turno.
///
/// Un rebuild con la misma [TurnActivity] **no** escribe `_open`: ése es el
/// punto entero del widget.
library;

import 'package:flutter/material.dart';

import '../../../domain/models/message.dart';
import '../../../domain/models/turn_activity.dart';
import '../../core/app_icon.dart';
import '../../core/layer_gate.dart';
import '../../core/tokens.dart';
import 'squares_spinner.dart';
import 'tool_card.dart';

class TurnActivityBox extends StatefulWidget {
  const TurnActivityBox({super.key, required this.activity, this.onOpenDiff});

  /// Lo que hizo el turno: su razonamiento, sus tools y si sigue vivo. Un
  /// [TurnActivity] vacío no se pinta nunca (el agrupador ni siquiera lo
  /// genera).
  final TurnActivity activity;

  final ValueChanged<AssistantTool>? onOpenDiff;

  /// Fila plegable. El test la apunta por key para no depender del texto.
  static const Key headKey = Key('activitybox-head');

  @override
  State<TurnActivityBox> createState() => _TurnActivityBoxState();
}

class _TurnActivityBoxState extends State<TurnActivityBox> {
  /// **Siempre cerrada.**
  ///
  /// Antes se abría sola mientras el turno trabajan, y como hay una caja por
  /// mensaje de assistant, un chat con 30 turnos acababa con 30 cajas abiertas
  /// de 148 px cada una: 4.400 px de herramientas empujando la respuesta muy
  /// lejos del ojo. El usuario lo reportó como "las herramientas me llenan todo
  /// el chat de más altura".
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
    if (widget.activity.isEmpty) return const SizedBox.shrink();
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
      child: ConstrainedBox(
        // La caja tiene mas alto, con `minHeight` y no solo con el padding.
        // Pedido: "mas alto". Con el padding solo, el alto dependia del texto:
        // con un rotulo corto la caja quedaba de 28 px y se leia un renglon.
        // 44 px es el minimo comfortable para una fila con glifo.
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xs,
            vertical: AppSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _head(theme, text),
              if (_open) ...[const SizedBox(height: AppSpacing.xs), _body()],
            ],
          ),
        ),
      ),
    );
  }

  Widget _head(ThemeData theme, TextTheme text) {
    final scheme = theme.colorScheme;
    final working = widget.activity.working;
    // El barrido del cliente React no va si el sistema pidió menos movimiento:
    // ahí el rótulo es texto y nada más.
    final shimmer = working && !MediaQuery.disableAnimationsOf(context);
    // El spinner va al mismo criterio que el barrido: sin animaciones no se
    // anima nada, ni el texto ni el spinner.
    final spinner = working && !MediaQuery.disableAnimationsOf(context);
    final titleStyle = text.labelSmall?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: 0.66,
      // `.actlabel` (:279) es `--muted-strong`: con `--text` el rótulo
      // competía con la respuesta de arriba.
      color: theme.brightness == Brightness.dark
          ? AppColors.darkMutedStrong
          : AppColors.lightMutedStrong,
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: TurnActivityBox.headKey,
        onTap: () => setState(() => _open = !_open),
        borderRadius: AppRadius.mdAll,
        // `.acthead:hover{background:var(--surface-hover)}` (:276).
        hoverColor: scheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xs,
            vertical: AppSpacing.xs,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
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
                  // Spinner chico del encabezado: 4 cuadrados de 4 px. Es el
                  // aviso de que el turno sigue vivo con la caja plegada, que
                  // es como se la ve casi siempre. Se apaga con el turno.
                  if (spinner)
                    Padding(
                      padding: const EdgeInsets.only(right: AppSpacing.xs),
                      child: SquaresSpinner(
                        size: 4,
                        gap: 2,
                        squares: 4,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: LayerGate(
                      'chat.activitybox.label',
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: shimmer
                            ? ShimmerText(
                                text: 'Working',
                                style: titleStyle,
                                highlight: scheme.onSurface,
                              )
                            : Text(
                                working ? 'Working' : 'Worked',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: titleStyle,
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
              if (category.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                // Las categorías (`SHELL · READ · EDIT`) bajan a su propia línea:
                // en una fila con el rótulo y el resumen no cabían en un
                // teléfono angosto y se comían el uno al otro.
                LayerGate(
                  'chat.activitybox.label',
                  child: Padding(
                    padding: const EdgeInsets.only(left: AppSpacing.xxl),
                    child: Text(
                      category,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// `SHELL · READ · EDIT`: los nombres de las tools del turno, deduplicados y
  /// en orden de aparición.
  String get category => turnCategoryLabel(widget.activity.toolParts);

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
    if (widget.activity.working) {
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
    final count = widget.activity.toolParts.length;
    final tools = count == 1 ? '1 herramienta' : '$count herramientas';
    final time = widget.activity.time;
    final ms = time?.completedMs;
    final start = time?.streamedMs ?? time?.createdMs;
    final label = (ms != null && start != null && ms > start)
        ? '$tools · ${toolDurationMs(ms - start)}'
        : tools;
    return Text(label, style: style);
  }

  /// `chat.activitybox.body`: alto máximo [kToolListMaxHeight] con scroll
  /// propio, borde izquierdo como en el `.actbody` del prototipo.
  Widget _body() {
    final thinking = widget.activity.thinkingParts
        .where((part) => part.text.trim().isNotEmpty)
        .toList();
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
              // El razonamiento va arriba de las tools: es lo que el modelo
              // hizo antes de llamarlas.
              for (final part in thinking)
                  Padding(
                    padding: const EdgeInsets.only(bottom: kToolRowSpacing),
                    child: _ThinkingRow(text: part.text.trim()),
                  ),
              for (final tool in widget.activity.toolParts)
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

/// El rótulo del turno con el barrido de brillo del cliente React
/// (`.shimmer-text` de `chat.css`): una banda de luz que recorre el texto de
/// izquierda a derecha cada 2.2 s.
///
/// El barrido es un degradado **enmascarado por el texto** (`ShaderMask`), no
/// un `Text` con color animado: así el glifo no cambia de forma y el
/// resultado es el mismo que el `background-clip: text` del CSS.
class ShimmerText extends StatefulWidget {
  const ShimmerText({
    super.key,
    required this.text,
    required this.style,
    required this.highlight,
  });

  final String text;
  final TextStyle? style;

  /// El color de la banda que pasa por encima. En el CSS es el acento del
  /// chat; acá el `--text` del tema.
  final Color highlight;

  /// Un ciclo completo del barrido. Es el `2.2s` del `@keyframes
  /// shimmer-text-sweep`.
  static const Duration period = Duration(milliseconds: 2200);

  @override
  State<ShimmerText> createState() => _ShimmerTextState();
}

class _ShimmerTextState extends State<ShimmerText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: ShimmerText.period,
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final base = style?.color ?? Theme.of(context).colorScheme.onSurface;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        // La banda viaja de `-1` a `1` en el eje horizontal del degradado: en
        // 0 está fuera de la caja, en 1 al otro lado, como el `background
        // -position: -220% 0` del CSS.
        final x = -1.0 + 2.0 * _c.value;
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment(x - 0.6, 0),
            end: Alignment(x + 0.6, 0),
            colors: [base, widget.highlight, base],
            stops: const [0.42, 0.5, 0.58],
          ).createShader(bounds),
          child: Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        );
      },
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

/// El razonamiento del modelo, con la misma piel que una tool card.
///
/// Antes era un `Text` suelto dentro de la caja: se leia como un parrafo
/// suelto y no como una fila mas de la lista. Ahora comparte decorado, radio y
/// borde con `.toolcard` y queda alineado con las filas de abajo. Eso es lo
/// que "acoplado" significa: mismo componente visual, misma reticula.
///
/// El texto va en `onSurfaceVariant` con `bodySmall`, como el resto de los
/// metadatos de la caja: el razonamiento es contexto, no respuesta.
class _ThinkingRow extends StatelessWidget {
  const _ThinkingRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: AppRadius.mdAll,
        border: Border.fromBorderSide(
          BorderSide(color: theme.colorScheme.outline),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        child: Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
