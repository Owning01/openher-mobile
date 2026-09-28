/// Tarjeta de una tool del turno (`chat.toolcard.*`).
///
/// Espejo de `.toolcard` del prototipo (`prototype/mobile.html:285-308`): fila
/// de 40 px (glifo 18, nombre 12/w600, subtítulo elíptico, estado con punto) y,
/// al tocarla, un bloque de salida con `--code-bg`, alto máximo 190 px con
/// scroll interno, y un pie de chips fantasma.
///
/// La salida se lee de `ToolStateBase.content[]` (texts concatenados), **no**
/// de un `output: String`: en v2 `state.content[]` es la salida
/// (`docs/API_CONTRACT.md` §4.2). Un tool en `error` pinta borde izquierdo
/// `danger` y el `errorMessage`: es el canal B de §5 y el turno puede seguir.
///
/// ## El color del error
/// El prototipo usa `--danger` (rojo: `#E11D48` / `#FB7185`) para el borde
/// `.toolcard.err`, el punto `.dot.err` y el texto de salida de una tool que
/// falló. En `tokens.dart` ese rojo es el del scope de diffs
/// (`AppColors.diffDelOf`), y ya lo usaba el botón Detener del composer: con el
/// `danger` gris del chrome, el botón de detener era el único elemento de color
/// de la pantalla y el error de una tool no se leía como error. Acá va el del
/// prototipo, y el glifo y el subtítulo se quedan en `--muted-strong` como en
/// `.toolglyph`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../../domain/models/errors.dart';
import '../../../domain/models/message.dart';
import '../../../domain/models/tool.dart';
import '../../core/app_icon.dart';
import '../../core/layer_gate.dart';
import '../../core/tokens.dart';

class ToolCard extends StatefulWidget {
  const ToolCard({
    super.key,
    required this.tool,
    this.onOpenDiff,
    this.onCopy,
    this.live = true,
  });

  final AssistantTool tool;

  /// El turno sigue vivo. Un tool en `running` con el turno ya cerrado es
  /// un tool interrumpido que el server dejÃ³ colgado: se muestra como
  /// error, no como un spinner que gira para siempre.
  final bool live;

  /// Se dispara con el tool cuando el usuario pide "Abrir diff". El shell (o el
  /// `files`) decide qué hacer: el chat no abre archivos.
  ///
  /// `null` ⇒ **el chip no se pinta**. Antes el botón existía siempre y
  /// mostraba un Snackbar diciendo "lo abre la vista de archivos" sin que
  /// hubiera nada conectado: una acción que promete y no hace. Sin handler no
  /// hay acción.
  final ValueChanged<AssistantTool>? onOpenDiff;

  /// Override del copiado (tests, o un toast propio del shell).
  final ValueChanged<String>? onCopy;

  /// Fila principal. Permite que el test apunte al widget exacto y no a un
  /// texto que se repite entre tarjetas.
  static const Key headKey = Key('toolcard-head');

  @override
  State<ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<ToolCard> {
  bool _expanded = false;

  AssistantTool get _tool => widget.tool;

  ToolState get _state => _tool.state;

  bool get _isError => _state is ToolError;

  /// Sólo `edit` y `write` dejan un diff que se pueda abrir.
  bool get _hasDiff {
    const withDiff = {'edit', 'write', 'patch'};
    return withDiff.contains(_tool.name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    // `--danger` del prototipo: el mismo rojo que el botón Detener del
    // composer y la card de error del assistant (ver el §"color del error" del
    // doc de este archivo).
    final danger = AppColors.diffDelOf(theme.brightness);
    final border = scheme.outline;

    return DecoratedBox(
      // `.toolcard.err` (:286): borde `danger` y **izquierdo** de 2 px (no se
      // nota si sólo se pinta el borde de 1 px, que es el shim que la web
      // descarta). `.toolcard` a secas es `--border` con `--r2`.
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: AppRadius.mdAll,
        border: Border.fromBorderSide(
          _isError
              ? BorderSide(color: danger, width: 2)
              : BorderSide(color: border),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _head(context, text, theme.brightness),
          if (_expanded) _output(context, text),
        ],
      ),
    );
  }

  Widget _head(BuildContext context, TextTheme text, Brightness brightness) {
    final scheme = Theme.of(context).colorScheme;
    final mutedStrong = brightness == Brightness.dark
        ? AppColors.darkMutedStrong
        : AppColors.lightMutedStrong;
    final danger = AppColors.diffDelOf(brightness);
    final state = _state;
    final isError = _isError;

    return Semantics(
      button: true,
      expanded: _expanded,
      child: InkWell(
        key: ToolCard.headKey,
        onTap: () => setState(() => _expanded = !_expanded),
        // `.toolhead:hover{background:var(--surface-subtle)}` (:288).
        hoverColor: scheme.surfaceContainerLow,
        child: SizedBox(
          height: 40,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: Row(
              children: [
                // `.toolglyph` es `--muted-strong` también en una tool que
                // falló: lo que va en `danger` es el borde y el punto.
                AppIcon(toolIcon(_tool.name), size: 18, color: mutedStrong),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  _tool.name,
                  style: text.bodyMedium!.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isError ? danger : scheme.onSurface,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: LayerGate(
                    'chat.toolcard.subtitle',
                    child: Text(
                      toolSubtitle(_tool),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                LayerGate(
                  'chat.toolcard.status',
                  child: _status(context, state, text, brightness),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _status(
    BuildContext context,
    ToolState state,
    TextTheme text,
    Brightness brightness,
  ) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final label = Text(switch (state) {
      final ToolError _ => 'Error',
      final ToolRunning r => r.title ?? 'Ejecutando',
      final ToolPending _ => 'Pendiente',
      _ => toolDurationLabel(state) ?? '',
    }, style: text.labelSmall?.copyWith(color: muted));

    // `.dot.err` del prototipo es `--danger`, el resto del estado (`ok`,
    // `warn`) también es color: el punto es el único acento de la fila.
    final dot = switch (state) {
      ToolError() => _Dot(color: AppColors.diffDelOf(brightness)),
      // Con el turno ya cerrado no hay nada corriendo: un tool en
      // `running` ahi es uno interrumpido que el server dejo colgado,
      // y el spinner se quedaba girando para siempre (lo reporto el
      // usuario). Se ve solo el rotulo.
      ToolRunning() => widget.live ? const _Spinner() : const SizedBox.shrink(),
      ToolPending() => _Dot(color: AppColors.warnOf(brightness)),
      _ => _Dot(color: AppColors.diffAddOf(brightness)),
    };

    return Row(mainAxisSize: MainAxisSize.min, children: [label, dot]);
  }

  /// `chat.toolcard.expanded` + `chat.toolcard.code`: bloque monoespaciado con
  /// `--code-bg`, alto máximo 190 px y scroll propio (el body de la lista de
  /// tools también scrollea: son dos scrolls, como en el prototipo).
  Widget _output(BuildContext context, TextTheme text) {
    final code = _outputText();
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final mutedStrong = brightness == Brightness.dark
        ? AppColors.darkMutedStrong
        : AppColors.lightMutedStrong;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: brightness == Brightness.dark
            ? AppColors.darkCodeBg
            : AppColors.lightCodeBg,
        // `.toolexp{border-top:1px solid var(--border)}`: el borde del tema, no
        // un color fijo — con `lightBorder` el filete quedaba claro sobre el
        // fondo oscuro.
        border: Border(top: BorderSide(color: scheme.outline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 190),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: SelectableText(
                  code,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    height: 1.55,
                    color: _isError
                        ? AppColors.diffDelOf(brightness)
                        : mutedStrong,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.sm,
              0,
              AppSpacing.sm,
              AppSpacing.sm,
            ),
            child: LayerGate(
              'chat.toolcard.footer',
              child: Row(
                children: [
                  _ChipButton(
                    icon: 'copy',
                    label: 'Copiar',
                    onTap: () => _copy(code),
                  ),
                  if (_hasDiff && widget.onOpenDiff != null) ...[
                    const SizedBox(width: AppSpacing.sm),
                    _ChipButton(
                      icon: 'git-branch',
                      label: 'Abrir diff',
                      onTap: () => widget.onOpenDiff?.call(_tool),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _copy(String text) {
    final handler = widget.onCopy;
    if (handler != null) {
      handler(text);
      return;
    }
    unawaited(Clipboard.setData(ClipboardData(text: text)));
  }

  /// Qué se imprime como salida: el `content[]` del server, el `errorMessage`
  /// si falló, o el `input` si todavía no hay salida (pending/running).
  String _outputText() {
    final state = _state;
    if (state case final ToolError e) {
      final detail = e.errorMessage.isEmpty
          ? e.error.toString()
          : e.errorMessage;
      return detail;
    }
    final out = state.textContent.trim();
    if (out.isNotEmpty) return out;
    final input = state.inputText.trim();
    return input.isEmpty ? '(sin salida)' : input;
  }
}

/// Lo que la UI sabe de un nombre de tool: el glifo de la card y la categoría
/// que muestra la caja de actividad.
///
/// `category == null` ⇒ la fila de la caja usa el **nombre en mayúsculas**
/// (`turnCategoryLabel`), que es lo que pasaba con las tools que no estaban en
/// ninguna de las dos listas: agregar un nombre nuevo no obliga a inventarle
/// una categoría.
final class ToolInfo {
  const ToolInfo(this.icon, [this.category]);

  final String icon;
  final String? category;
}

/// **La** tabla de tools. Antes había dos mapas paralelos —`toolIcon` acá y
/// `toolCategory` en `turn_activity.dart`— con nombres superpuestos
/// (`shell|bash|powershell`, `read|notebookread`, …): agregar una tool obligaba
/// a acordarse de los dos y se olvidaba la mitad de las veces.
///
/// Los glifos son los SVG que existen en `assets/icons/`; una tool que no está
/// en la tabla cae en `terminal`, que es el glifo genérico de "el agente corrió
/// algo".
const Map<String, ToolInfo> kToolInfo = <String, ToolInfo>{
  'shell': ToolInfo('terminal', 'SHELL'),
  'bash': ToolInfo('terminal', 'SHELL'),
  'powershell': ToolInfo('terminal', 'SHELL'),
  'read': ToolInfo('book', 'READ'),
  'notebookread': ToolInfo('book', 'READ'),
  'edit': ToolInfo('edit', 'EDIT'),
  'multiedit': ToolInfo('edit', 'EDIT'),
  'write': ToolInfo('file', 'WRITE'),
  'create': ToolInfo('file', 'WRITE'),
  'glob': ToolInfo('search', 'SEARCH'),
  'grep': ToolInfo('search', 'SEARCH'),
  'list': ToolInfo('search', 'SEARCH'),
  'subagent': ToolInfo('user', 'SUBAGENT'),
  'task': ToolInfo('user', 'SUBAGENT'),
  'question': ToolInfo('message-square', 'QUESTION'),
  'ask': ToolInfo('message-square', 'QUESTION'),
  'skill': ToolInfo('sparkles', 'SKILL'),
  // Sin categoría a propósito: el nombre en mayúsculas ya dice la categoría
  // (`PATCH`, `PLAN`, `TODOWRITE`…) y es lo que se veía antes.
  'patch': ToolInfo('edit'),
  'plan': ToolInfo('list-checks'),
  'todowrite': ToolInfo('list-checks'),
  'todoread': ToolInfo('list-checks'),
  'webfetch': ToolInfo('download'),
  'websearch': ToolInfo('download'),
};

/// Glifo de una tool. Sale de [kToolInfo].
String toolIcon(String name) => kToolInfo[name]?.icon ?? 'terminal';

/// La categoría que muestra la caja de actividad. Sale de [kToolInfo] y cae en
/// el nombre en mayúsculas si la tool no está.
String toolCategory(String name) =>
    kToolInfo[name]?.category ?? name.toUpperCase();

/// Una línea: el comando o el resumen de la tool. Sale del `input` crudo, que
/// es `String` en `pending` y mapa en el resto (`tool.dart`); por eso el
/// fallback es [ToolStateBase.inputText] y no un cast.
String toolSubtitle(AssistantTool tool) {
  final input = asMap(tool.state.input);
  final raw = switch (tool.name) {
    'shell' ||
    'bash' ||
    'powershell' => asStr(input?['command']) ?? asStr(input?['cmd']),
    'subagent' || 'task' => asStr(input?['description']),
    'read' || 'write' || 'edit' || 'multiedit' || 'patch' =>
      asStr(input?['filePath']) ??
          asStr(input?['path']) ??
          asStr(input?['file']),
    'grep' || 'glob' => asStr(input?['pattern']) ?? asStr(input?['query']),
    _ => null,
  };
  final text = (raw ?? tool.state.inputText)
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.length <= kSubtitleMaxChars) return text;
  return '${text.substring(0, kSubtitleMaxChars - 1)}…';
}

/// Tope del subtítulo: más que esto no entra en una línea de 40 px y elipses
/// es lo mismo que cortar.
const int kSubtitleMaxChars = 90;

/// La duración de un tool, si el server la mandó en `state.metadata`
/// (`{"duration":1234}`, en ms). `null` si no vino: la card muestra sólo el
/// punto, igual que el prototipo.
String? toolDurationLabel(ToolState state) {
  final raw = state.metadata['duration'];
  if (raw is! num || raw <= 0) return null;
  return toolDurationMs(raw.toInt());
}

/// `1234` → `1.2s`. Sólo para duraciones de tools.
String toolDurationMs(int ms) =>
    ms < 1000 ? '${ms}ms' : '${(ms / 1000).toStringAsFixed(1)}s';

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 6,
    height: 6,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// 12 px, como el `.spin` del prototipo.
class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 12,
    height: 12,
    child: CircularProgressIndicator(
      strokeWidth: 1.5,
      color: Theme.of(context).colorScheme.onSurface,
    ),
  );
}

/// Chip fantasma del pie (`.chipbtn`, `:307-308`): 26 px de alto, borde 1 px,
/// 11.5 px y `--muted-strong` en el glifo y en el texto.
class _ChipButton extends StatelessWidget {
  const _ChipButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final String icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final mutedStrong = theme.brightness == Brightness.dark
        ? AppColors.darkMutedStrong
        : AppColors.lightMutedStrong;
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.mdAll,
        side: BorderSide(color: scheme.outline),
      ),
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 26,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(icon, size: 12, color: mutedStrong),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(fontSize: 11.5, color: mutedStrong),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
