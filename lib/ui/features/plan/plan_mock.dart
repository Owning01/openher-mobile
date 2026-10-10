/// Render de `doc-mock` y `doc-machine`.
///
/// El mock trae HTML arbitrario: sin WebView no se pinta literal, así que se
/// proyecta a bloques nativos (títulos, párrafos, botones como chips, listas,
/// terminal monoespaciado con sus colores). El marco `terminal` es exacto;
/// los demás marcos dibujan su chrome (browser/phone/desktop) con el contenido
/// simplificado adentro. Los pins van numerados sobre la esquina y abren su
/// nota al toque.
library;

import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../core/tokens.dart';
import 'plan_model.dart';

/// Pinta el HTML de un mock/terminal/pantalla de estado, simplificado.
class SimpleHtml extends StatelessWidget {
  const SimpleHtml({super.key, required this.html, this.terminal = false});

  final String html;
  final bool terminal;

  @override
  Widget build(BuildContext context) {
    final frag = html_parser.parseFragment(html);
    final scheme = Theme.of(context).colorScheme;
    final children = <Widget>[];
    for (final node in frag.nodes) {
      final w = _node(context, node, scheme, terminal);
      if (w != null) children.add(w);
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  static Widget? _node(
    BuildContext context,
    dom.Node node,
    ColorScheme scheme,
    bool terminal,
  ) {
    if (node is dom.Text) {
      final text = terminal ? node.text : node.text.trim();
      if (text.isEmpty) return null;
      return Text(
        text,
        style: terminal
            ? _mono(13, scheme.onSurface)
            : Theme.of(context).textTheme.bodyMedium,
      );
    }
    if (node is! dom.Element) return null;
    final name = node.localName;
    final cls = node.classes;
    Color fg = scheme.onSurface;
    if (terminal) {
      if (cls.contains('dim')) fg = scheme.onSurfaceVariant;
      if (cls.contains('g')) fg = Colors.green.shade700;
      if (cls.contains('r')) fg = Colors.red.shade700;
      if (cls.contains('y')) fg = Colors.amber.shade800;
      if (cls.contains('b')) fg = Colors.blue.shade700;
      if (cls.contains('m')) fg = Colors.purple.shade700;
    }
    switch (name) {
      case 'br':
        return const SizedBox(height: 4);
      case 'b':
      case 'strong':
        return Text(
          node.text,
          style: (terminal ? _mono(13, fg) : Theme.of(context).textTheme.bodyMedium)
              ?.copyWith(fontWeight: FontWeight.w700),
        );
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
        return Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Text(
            node.text.trim(),
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
        );
      case 'p':
      case 'div':
        final inner = _children(context, node, scheme, terminal);
        if (inner.isEmpty) return null;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: inner,
          ),
        );
      case 'span':
        if (cls.contains('btn')) {
          final primary = cls.contains('pri');
          return Container(
            margin: const EdgeInsets.only(right: 6, top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: primary ? scheme.primary : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(7),
              border: primary
                  ? null
                  : Border.all(color: scheme.outlineVariant),
            ),
            child: Text(
              node.text.trim(),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: primary ? scheme.onPrimary : scheme.onSurface,
              ),
            ),
          );
        }
        return Text(
          node.text,
          style: (terminal ? _mono(13, fg) : Theme.of(context).textTheme.bodySmall)
              ?.copyWith(color: cls.contains('dim') ? scheme.onSurfaceVariant : null),
        );
      case 'small':
        return Text(
          node.text.trim(),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        );
      case 'ul':
      case 'ol':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final li in node.children.where((c) => c.localName == 'li'))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text('•  ${li.text.trim()}'),
              ),
          ],
        );
      case 'style':
      case 'script':
        return null;
      default:
        final inner = _children(context, node, scheme, terminal);
        if (inner.isEmpty) {
          final text = node.text.trim();
          if (text.isEmpty) return null;
          return Text(text, style: terminal ? _mono(13, fg) : null);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: inner,
        );
    }
  }

  static List<Widget> _children(
    BuildContext context,
    dom.Element el,
    ColorScheme scheme,
    bool terminal,
  ) {
    final out = <Widget>[];
    // Los botones en línea van en fila, no uno por renglón.
    final row = <Widget>[];
    void flushRow() {
      if (row.isEmpty) return;
      out.add(
        Wrap(spacing: 0, runSpacing: 4, children: List.of(row)),
      );
      row.clear();
    }

    for (final node in el.nodes) {
      if (node is dom.Element &&
          node.localName == 'span' &&
          node.classes.contains('btn')) {
        final w = _node(context, node, scheme, terminal);
        if (w != null) row.add(w);
        continue;
      }
      flushRow();
      final w = _node(context, node, scheme, terminal);
      if (w != null) out.add(w);
    }
    flushRow();
    return out;
  }

  static TextStyle _mono(double size, Color color) => TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: const ['Courier'],
    fontSize: size,
    height: 1.45,
    color: color,
  );
}

/// Un `doc-mock` con su marco, título, caption y pins.
class MockView extends StatelessWidget {
  const MockView({
    super.key,
    required this.mock,
    this.onComment,
  });

  final MockExhibit mock;
  final VoidCallback? onComment;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final terminal = mock.frame == 'terminal';
    Widget content;
    if (mock.shot.isNotEmpty) {
      content = Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: AppRadius.mdAll,
        ),
        child: Text(
          'Captura: ${mock.shot}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    } else {
      content = Container(
        padding: EdgeInsets.all(terminal ? AppSpacing.sm : AppSpacing.md),
        decoration: BoxDecoration(
          color: terminal ? const Color(0xFF141310) : scheme.surface,
          borderRadius: AppRadius.mdAll,
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: SimpleHtml(html: mock.html, terminal: terminal),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (mock.label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              mock.label,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        _frame(context, content),
        if (mock.pins.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var i = 0; i < mock.pins.length; i++)
                  _pinChip(context, i, mock.pins[i]),
              ],
            ),
          ),
        if (mock.caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              mock.caption,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  Widget _frame(BuildContext context, Widget content) {
    final scheme = Theme.of(context).colorScheme;
    switch (mock.frame) {
      case 'browser':
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: 6,
              ),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Row(
                children: [
                  _dot(scheme, 0),
                  _dot(scheme, 1),
                  _dot(scheme, 2),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: scheme.surface,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        mock.url.isNotEmpty ? mock.url : 'plan',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
              ),
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
                child: content,
              ),
            ),
          ],
        );
      case 'phone':
        return Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 300),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: scheme.outline, width: 2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: content,
            ),
          ),
        );
      case 'desktop':
      case 'terminal':
        return content;
      default:
        return content;
    }
  }

  Widget _dot(ColorScheme scheme, int i) => Container(
    width: 8,
    height: 8,
    margin: const EdgeInsets.only(right: 4),
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: [scheme.outline, scheme.outlineVariant, scheme.outline][i],
    ),
  );

  Widget _pinChip(BuildContext context, int i, MockPin pin) => ActionChip(
    label: Text('${i + 1} · ${pin.title}'),
    onPressed: () => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${i + 1} · ${pin.title}'),
        content: pin.body.isEmpty ? null : Text(pin.body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    ),
  );
}

/// Un `doc-machine`: diagrama por grilla + pantalla del estado actual.
class MachineView extends StatelessWidget {
  const MachineView({
    super.key,
    required this.machine,
    required this.current,
    required this.onSelect,
    this.conditions = const [],
    this.answers,
  });

  final MachineExhibit machine;
  final String current;
  final ValueChanged<String> onSelect;
  final List<ConditionalBlock> conditions;

  /// Para evaluar `data-if` de pantallas (puede ser null).
  final dynamic answers;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cur = current.isEmpty ? machine.initial : current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _diagram(context, cur),
        const SizedBox(height: 6),
        if (cur.isNotEmpty) ...[
          Text(
            _stateNote(cur),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
        ],
        if (machine.screens[cur] != null &&
            machine.screens[cur]!.trim().isNotEmpty)
          Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: AppRadius.mdAll,
            ),
            child: SimpleHtml(html: machine.screens[cur]!),
          ),
        if (machine.caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              machine.caption,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  String _stateNote(String id) {
    final s = machine.states.where((e) => e.id == id).firstOrNull;
    if (s == null) return id;
    return s.note.isEmpty ? s.id : '${s.id} — ${s.note}';
  }

  Widget _diagram(BuildContext context, String cur) {
    final rows = machine.grid.isEmpty ? _autoGrid() : machine.grid;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in rows)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final cell in row)
                if (cell == '.' || cell.isEmpty)
                  const SizedBox(width: 92, height: 34)
                else
                  Padding(
                    padding: const EdgeInsets.all(3),
                    child: _stateChip(context, cell, cell == cur),
                  ),
            ],
          ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: [
            for (final a in machine.arrows.where((e) => e.from == cur))
              ActionChip(
                label: Text(
                  a.label.isEmpty ? a.event : '${a.event} · ${a.label}',
                  style: const TextStyle(fontSize: 12),
                ),
                onPressed: () => onSelect(a.to),
              ),
          ],
        ),
      ],
    );
  }

  List<List<String>> _autoGrid() {
    final ids = [for (final s in machine.states) s.id];
    return [ids];
  }

  Widget _stateChip(BuildContext context, String id, bool active) {
    final scheme = Theme.of(context).colorScheme;
    final isFinal = machine.states
        .where((s) => s.id == id)
        .firstOrNull
        ?.finalState ??
        false;
    return InkWell(
      onTap: () => onSelect(id),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          border: isFinal && !active
              ? Border.all(color: scheme.primary, width: 1.5)
              : null,
        ),
        child: Text(
          id,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: active ? scheme.onPrimary : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
