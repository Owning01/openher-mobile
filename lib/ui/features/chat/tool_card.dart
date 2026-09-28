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
  const ToolCard({super.key, required this.tool, this.onOpenDiff, this.onCopy});

  final AssistantTool tool;

  /// Se dispara con el tool cuando el usuario pide "Abrir diff". El shell (o el
  /// `files`) decide qué hacer: el chat no abre archivos.
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
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final brightness = Theme.of(context).brightness;
    final danger = AppColors.diffDelOf(brightness);
    final border = scheme.outline;

    return DecoratedBox(
      // `.toolcard.err`: borde `danger` y **izquierdo** de 2px (no se nota si
      // sólo se pinta el borde de 1px, que es el shim que la web descarta).
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: AppRadius.mdAll,
        border: Border.all(color: _isError ? danger : border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _head(context, text, brightness),
          if (_expanded) _output(context, text),
        ],
      ),
    );
  }

  Widget _head(BuildContext context, TextTheme text, Brightness brightness) {
    final scheme = Theme.of(context).colorScheme;
    final danger = AppColors.diffDelOf(brightness);
    final state = _state;
    final isError = _isError;

    return Semantics(
      button: true,
      expanded: _expanded,
      child: InkWell(
        key: ToolCard.headKey,
        onTap: () => setState(() => _expanded = !_expanded),
        child: SizedBox(
          height: 40,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: Row(
              children: [
                AppIcon(
                  toolIcon(_tool.name),
                  size: 18,
                  color: isError ? danger : Theme.of(context).iconTheme.color,
                ),
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

    final dot = switch (state) {
      ToolError() => _Dot(color: AppColors.diffDelOf(brightness)),
      ToolRunning() => const _Spinner(),
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppColors.darkCodeBg
            : AppColors.lightCodeBg,
        border: const Border(top: BorderSide(color: AppColors.lightBorder)),
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
                        ? AppColors.diffDelOf(Theme.of(context).brightness)
                        : Theme.of(context).colorScheme.onSurfaceVariant,
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
                  if (_hasDiff) ...[
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

/// Glifo de una tool. Los nombres son los que existen en `assets/icons/`: si
/// el server manda una tool que no está en la lista cae en `terminal`, que es
/// el glifo genérico de "el agente corrió algo".
String toolIcon(String name) => switch (name) {
  'shell' || 'bash' || 'powershell' => 'terminal',
  'read' || 'notebookread' => 'book',
  'edit' || 'multiedit' || 'patch' => 'edit',
  'write' || 'create' => 'file',
  'glob' || 'grep' || 'list' => 'search',
  'todowrite' || 'todoread' => 'list-checks',
  'subagent' || 'task' => 'user',
  'webfetch' || 'websearch' => 'download',
  'question' || 'ask' => 'message-square',
  'skill' => 'sparkles',
  'plan' => 'list-checks',
  _ => 'terminal',
};

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

/// Chip fantasma del pie (`.chipbtn`): 26 px de alto, borde 1 px, 11.5 px.
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
    final scheme = Theme.of(context).colorScheme;
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
                AppIcon(icon, size: 12, color: scheme.onSurfaceVariant),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
