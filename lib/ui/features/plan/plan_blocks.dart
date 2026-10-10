/// Widgets de los bloques del plan: árbol de claims, decisiones, exhibits.
///
/// Cada claim lleva número (`1.2`), se abre al toque, muestra cuántas
/// decisiones cuelgan de él cuando está cerrado y un botón de comentario.
/// Los exhibits se pintan nativos con los tokens del tema.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/tokens.dart';
import '../chat/code_highlight.dart';
import 'plan_answers.dart';
import 'plan_mock.dart';
import 'plan_model.dart';
import 'plan_theme.dart';

/// Chrome del visor en el idioma del plan.
class PlanStrings {
  const PlanStrings(this.es);

  final bool es;

  String get respond => es ? 'Responder' : 'Respond';
  String get copy => es ? 'Copiar respuesta' : 'Copy response';
  String get copied => es ? 'Copiada: pegala en el chat' : 'Copied: paste it back in chat';
  String get reset => es ? 'Borrar todo' : 'Reset';
  String get decisions => es ? 'Decisiones' : 'Decisions';
  String get toAnswer => es ? 'por responder' : 'to answer';
  String get comment => es ? 'Comentar' : 'Comment';
  String get save => es ? 'Guardar' : 'Save';
  String get close => es ? 'Cerrar' : 'Close';
  String get send => es ? 'Enviar' : 'Send';
  String get skip => es ? 'Ahora no' : 'Not now';
  String get files => es ? 'archivos' : 'files';
  String get suggested => es ? 'sugerida' : 'suggested';
  String get struck => es ? 'tachada' : 'struck';
  String get strike => es ? 'tachar' : 'strike';
  String get restore => es ? 'restaurar' : 'restore';
  String get edit => es ? 'Editar' : 'Edit';
  String get changed => es ? 'cambiada' : 'changed';
  String get kept => es ? 'igual que lo propuesto' : 'kept as proposed';
  String get notOpened => es ? 'sin abrir; vale lo propuesto' : 'not opened; default kept';
}

/// Hoja para comentar cualquier cosa del plan.
Future<void> openCommentSheet(
  BuildContext context,
  PlanStrings strings, {
  required String target,
  required String initial,
  required ValueChanged<String> onSave,
}) async {
  final controller = TextEditingController(text: initial);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.md,
        right: AppSpacing.md,
        top: AppSpacing.md,
        bottom: MediaQuery.of(sheet).viewInsets.bottom + AppSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(target, style: Theme.of(sheet).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            maxLines: 4,
            minLines: 2,
            autofocus: true,
            decoration: InputDecoration(
              hintText: strings.comment,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(sheet).pop(),
                child: Text(strings.close),
              ),
              FilledButton(
                onPressed: () {
                  onSave(controller.text);
                  Navigator.of(sheet).pop();
                },
                child: Text(strings.save),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// El árbol de claims con números (`1`, `1.2`), decisiones y comentarios.
class ClaimTree extends StatelessWidget {
  const ClaimTree({
    super.key,
    required this.claims,
    required this.answers,
    required this.strings,
    required this.seenAsks,
    required this.onAskSeen,
    this.prefix = '',
    this.depth = 0,
  });

  final List<PlanClaim> claims;
  final PlanAnswers answers;
  final PlanStrings strings;
  final Set<String> seenAsks;
  final ValueChanged<String> onAskSeen;
  final String prefix;
  final int depth;

  @override
  Widget build(BuildContext context) {
    var n = 0;
    final out = <Widget>[];
    for (final claim in claims) {
      if (claim.aux.isNotEmpty) {
        out.add(_auxClaim(context, claim));
        continue;
      }
      n++;
      final number = prefix.isEmpty ? '$n' : '$prefix.$n';
      out.add(
        _ClaimTile(
          claim: claim,
          number: number,
          answers: answers,
          strings: strings,
          seenAsks: seenAsks,
          onAskSeen: onAskSeen,
          depth: depth,
        ),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, children: out);
  }

  Widget _auxClaim(BuildContext context, PlanClaim claim) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: AppRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            claim.aux == 'scope'
                ? (strings.es ? 'Fuera de alcance' : 'Out of scope')
                : (strings.es ? 'Compartido' : 'Shared'),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          _claimText(context, claim),
          if (claim.exhibit != null) ...[
            const SizedBox(height: 6),
            ExhibitView(exhibit: claim.exhibit!, answers: answers, strings: strings),
          ],
        ],
      ),
    );
  }
}

class _ClaimTile extends StatefulWidget {
  const _ClaimTile({
    required this.claim,
    required this.number,
    required this.answers,
    required this.strings,
    required this.seenAsks,
    required this.onAskSeen,
    required this.depth,
  });

  final PlanClaim claim;
  final String number;
  final PlanAnswers answers;
  final PlanStrings strings;
  final Set<String> seenAsks;
  final ValueChanged<String> onAskSeen;
  final int depth;

  @override
  State<_ClaimTile> createState() => _ClaimTileState();
}

class _ClaimTileState extends State<_ClaimTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final decisions = _countAsks(widget.claim);
    final commented = widget.answers.comments.containsKey('claim:${widget.number}');
    return Container(
      key: ValueKey('plan-claim-${widget.number}'),
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: AppRadius.mdAll,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: AppRadius.mdAll,
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: _open ? scheme.primary : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      widget.number,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _open ? scheme.onPrimary : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: _claimText(context, widget.claim)),
                  if (!_open && decisions > 0)
                    Container(
                      margin: const EdgeInsets.only(left: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        border: Border.all(color: scheme.primary, width: 1.5),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$decisions',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                  IconButton(
                    iconSize: 16,
                    constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      commented ? Icons.comment : Icons.add_comment_outlined,
                      color: commented ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                    tooltip: widget.strings.comment,
                    onPressed: () => openCommentSheet(
                      context,
                      widget.strings,
                      target: '${widget.strings.comment} · ${widget.number}',
                      initial: widget.answers.comments['claim:${widget.number}'] ?? '',
                      onSave: (text) =>
                          widget.answers.setComment('claim:${widget.number}', text),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.sm,
                0,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.claim.exhibit != null)
                    ExhibitView(
                      exhibit: widget.claim.exhibit!,
                      answers: widget.answers,
                      strings: widget.strings,
                    ),
                  if (widget.claim.ask != null) ...[
                    const SizedBox(height: 6),
                    AskView(
                      ask: widget.claim.ask!,
                      claimNumber: widget.number,
                      answers: widget.answers,
                      strings: widget.strings,
                      seenAsks: widget.seenAsks,
                      onAskSeen: widget.onAskSeen,
                    ),
                  ],
                  for (final cond in widget.claim.conditions)
                    if (widget.answers.conditionHolds(cond.condition))
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: SimpleHtml(html: cond.html),
                      ),
                  if (widget.claim.note != null) ...[
                    const SizedBox(height: 6),
                    ExhibitView(
                      exhibit: widget.claim.note!,
                      answers: widget.answers,
                      strings: widget.strings,
                    ),
                  ],
                  if (widget.claim.children.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    ClaimTree(
                      claims: widget.claim.children,
                      answers: widget.answers,
                      strings: widget.strings,
                      seenAsks: widget.seenAsks,
                      onAskSeen: widget.onAskSeen,
                      prefix: widget.number,
                      depth: widget.depth + 1,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  int _countAsks(PlanClaim claim) {
    var n = claim.ask == null ? 0 : 1;
    for (final c in claim.children) {
      n += _countAsks(c);
    }
    return n;
  }
}

Widget _claimText(BuildContext context, PlanClaim claim) {
  final base = Theme.of(context).textTheme.bodyMedium!;
  return SelectableText.rich(
    TextSpan(
      children: [
        for (final s in claim.spans)
          TextSpan(
            text: s.text,
            style: s.code
                ? base.copyWith(
                    fontFamily: 'monospace',
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                  )
                : s.bold
                ? base.copyWith(fontWeight: FontWeight.w700)
                : null,
          ),
      ],
      style: base,
    ),
  );
}

/// Un exhibit cualquiera.
class ExhibitView extends StatelessWidget {
  const ExhibitView({
    super.key,
    required this.exhibit,
    required this.answers,
    required this.strings,
  });

  final PlanExhibit exhibit;
  final PlanAnswers answers;
  final PlanStrings strings;

  @override
  Widget build(BuildContext context) {
    final e = exhibit;
    return switch (e) {
      MockExhibit() => MockView(mock: e),
      MachineExhibit() => MachineView(
        machine: e,
        current: answers.machineStates[e.name] ?? e.initial,
        onSelect: (s) => answers.setMachineState(e.name, s),
      ),
      CallsExhibit() => CallsView(calls: e, answers: answers, strings: strings),
      SchemaExhibit() => CodeView(
        title: e.title,
        lang: e.lang,
        text: e.text,
        diff: e.diff,
        caption: e.caption,
        editableId: e.id.isEmpty ? null : e.id,
        answers: answers,
        strings: strings,
      ),
      CodeExhibit() => CodeView(
        title: e.title,
        lang: e.lang,
        text: e.text,
        diff: e.diff,
        start: e.start,
        highlights: e.highlights,
        caption: e.caption,
        pins: e.pins,
        answers: answers,
        strings: strings,
      ),
      FlowExhibit() => FlowView(flow: e),
      TreeExhibit() => TreeView(tree: e),
      DraftExhibit() => DraftView(draft: e, answers: answers, strings: strings),
      PlanNote() => NoteView(note: e),
    };
  }
}

/// `doc-ask`: radios, checks, texto, área, rango y rank.
class AskView extends StatefulWidget {
  const AskView({
    super.key,
    required this.ask,
    required this.claimNumber,
    required this.answers,
    required this.strings,
    required this.seenAsks,
    required this.onAskSeen,
  });

  final PlanAsk ask;
  final String claimNumber;
  final PlanAnswers answers;
  final PlanStrings strings;
  final Set<String> seenAsks;
  final ValueChanged<String> onAskSeen;

  @override
  State<AskView> createState() => _AskViewState();
}

class _AskViewState extends State<AskView> {
  @override
  void initState() {
    super.initState();
    widget.answers.applyDefaults(widget.ask);
    // Visto = pintado, pero avisar en build revienta (`setState` durante el
    // build): al próximo frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onAskSeen(widget.ask.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.primary, width: 1.5),
        borderRadius: AppRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.ask.question,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          for (final c in widget.ask.controls) _control(context, c),
        ],
      ),
    );
  }

  Widget _control(BuildContext context, AskControl c) {
    final values = widget.answers.valuesOf(widget.ask.id, c);
    switch (c.kind) {
      case 'radio':
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in c.options)
              _radioRow(context, c, o, values.contains(o.value)),
          ],
        );
      case 'check':
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in c.options)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(o.label),
                subtitle: o.detail.isEmpty ? null : Text(o.detail),
                value: values.contains(o.value),
                onChanged: (v) {
                  final next = List.of(values);
                  if (v == true) {
                    next.add(o.value);
                  } else {
                    next.remove(o.value);
                  }
                  widget.answers.setValues(widget.ask.id, c, next);
                },
              ),
          ],
        );
      case 'text':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: TextFormField(
            initialValue: values.isEmpty ? '' : values.single,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            onChanged: (v) => widget.answers.setValues(widget.ask.id, c, [v]),
          ),
        );
      case 'area':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: TextFormField(
            initialValue: values.isEmpty ? '' : values.single,
            maxLines: 3,
            minLines: 2,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            onChanged: (v) => widget.answers.setValues(widget.ask.id, c, [v]),
          ),
        );
      case 'range':
        final v = double.tryParse(values.isEmpty ? '' : values.single) ?? c.min;
        return Row(
          children: [
            Expanded(
              child: Slider(
                min: c.min,
                max: c.max,
                value: v.clamp(c.min, c.max),
                onChanged: (nv) => widget.answers.setValues(
                  widget.ask.id,
                  c,
                  [nv.toStringAsFixed(nv == nv.roundToDouble() ? 0 : 1)],
                ),
              ),
            ),
            SizedBox(
              width: 48,
              child: Text(v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)),
            ),
          ],
        );
      case 'rank':
        return ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          onReorder: (a, b) {
            final next = List.of(values);
            if (a < b) b -= 1;
            final item = next.removeAt(a);
            next.insert(b, item);
            widget.answers.setValues(widget.ask.id, c, next);
          },
          children: [
            for (final v in values)
              ListTile(
                key: ValueKey('${widget.ask.id}:$v'),
                dense: true,
                leading: const Icon(Icons.drag_handle, size: 18),
                title: Text(
                  c.options
                      .where((o) => o.value == v)
                      .firstOrNull
                      ?.label ??
                      v,
                ),
              ),
          ],
        );
    }
    return const SizedBox.shrink();
  }

  Widget _radioRow(BuildContext context, AskControl c, AskOption o, bool picked) {
    final scheme = Theme.of(context).colorScheme;
    final def = o.checked;
    return InkWell(
      onTap: () => widget.answers.setValues(widget.ask.id, c, [o.value]),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              picked ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18,
              color: picked ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    children: [
                      Text(
                        o.label,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (def)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            widget.strings.suggested,
                            style: TextStyle(fontSize: 11, color: scheme.onPrimaryContainer),
                          ),
                        ),
                    ],
                  ),
                  if (o.detail.isNotEmpty)
                    Text(
                      o.detail,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
}

/// `doc-calls`: filas con marca, sangría, tachado y comentario.
class CallsView extends StatelessWidget {
  const CallsView({
    super.key,
    required this.calls,
    required this.answers,
    required this.strings,
  });

  final CallsExhibit calls;
  final PlanAnswers answers;
  final PlanStrings strings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (calls.title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              calls.title,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: AppRadius.mdAll,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < calls.rows.length; i++)
                _row(context, i, calls.rows[i]),
            ],
          ),
        ),
        if (calls.caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              calls.caption,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  Widget _row(BuildContext context, int i, CallRow row) {
    final scheme = Theme.of(context).colorScheme;
    final pal = PlanPalette.of(context);
    final key = 'calls:$i';
    final struck = answers.strikes.contains(key);
    final commented = answers.comments.containsKey(key);
    Color? markColor;
    if (row.mark == '+') {
      markColor = pal.green;
    } else if (row.mark == '-') {
      markColor = pal.red;
    } else if (row.mark == '~') {
      markColor = pal.amber;
    } else if (row.mark == '?') {
      markColor = scheme.primary;
    }
    return Padding(
      padding: EdgeInsets.only(left: row.depth * 14.0, top: row.entrypoint && i > 0 ? 6 : 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 14,
            child: Text(
              row.mark == ' ' ? '' : row.mark,
              style: TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700,
                color: markColor,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SelectableText.rich(
                  TextSpan(
                    text: row.text,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      fontWeight: row.bold ? FontWeight.w700 : null,
                      decoration: struck ? TextDecoration.lineThrough : null,
                      color: struck ? scheme.onSurfaceVariant : null,
                    ),
                  ),
                ),
                if (row.path.isNotEmpty || row.note.isNotEmpty)
                  Text(
                    [row.path, row.note].where((s) => s.isNotEmpty).join(' — '),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (commented)
            Icon(Icons.comment, size: 14, color: scheme.primary),
          if (row.mark != ' ')
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => answers.toggleStrike(key),
              child: Text(
                struck ? strings.restore : strings.strike,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          IconButton(
            iconSize: 14,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            padding: EdgeInsets.zero,
            icon: Icon(
              Icons.add_comment_outlined,
              color: scheme.onSurfaceVariant,
            ),
            onPressed: () => openCommentSheet(
              context,
              strings,
              target: row.text,
              initial: answers.comments[key] ?? '',
              onSave: (text) => answers.setComment(key, text),
            ),
          ),
        ],
      ),
    );
  }
}

/// `doc-schema` y `doc-code`: monoespaciado con diff, highlights y pins.
class CodeView extends StatefulWidget {
  const CodeView({
    super.key,
    this.title = '',
    this.lang = '',
    required this.text,
    this.diff = false,
    this.start = 1,
    this.highlights = const [],
    this.caption = '',
    this.pins = const [],
    this.editableId,
    required this.answers,
    required this.strings,
  });

  final String title;
  final String lang;
  final String text;
  final bool diff;
  final int start;
  final List<int> highlights;
  final String caption;
  final List<MockPin> pins;
  final String? editableId;
  final PlanAnswers answers;
  final PlanStrings strings;

  @override
  State<CodeView> createState() => _CodeViewState();
}

class _CodeViewState extends State<CodeView> {
  bool _editing = false;
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final edited = widget.editableId == null
        ? null
        : widget.answers.edits[widget.editableId];
    final text = edited ?? widget.text;
    final lines = text.split('\n');
    final base = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Courier'],
      fontSize: 12.5,
      height: 1.5,
      color: scheme.onSurface,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                if (edited != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      widget.strings.changed,
                      style: TextStyle(fontSize: 11, color: scheme.onPrimaryContainer),
                    ),
                  ),
                if (widget.editableId != null)
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () {
                      setState(() {
                        _editing = !_editing;
                        _controller.text = text;
                      });
                    },
                    child: Text(
                      widget.strings.edit,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        if (_editing && widget.editableId != null) ...[
          TextField(
            controller: _controller,
            maxLines: null,
            minLines: 4,
            style: base,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: () {
                widget.answers.setEdit(widget.editableId!, _controller.text);
                setState(() => _editing = false);
              },
              child: Text(widget.strings.save),
            ),
          ),
        ] else
          Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: AppRadius.mdAll,
            ),
            child: SelectableText.rich(
              TextSpan(
                children: [
                  for (var i = 0; i < lines.length; i++)
                    _line(context, lines, i, base, dark),
                ],
                style: base,
              ),
            ),
          ),
        if (widget.pins.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final pin in widget.pins)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: pin.line > 0 ? 'L${pin.line} · ' : '',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          TextSpan(text: pin.title),
                          if (pin.body.isNotEmpty)
                            TextSpan(
                              text: ' — ${pin.body}',
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                        ],
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        if (widget.caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              widget.caption,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  TextSpan _line(
    BuildContext context,
    List<String> lines,
    int i,
    TextStyle base,
    bool dark,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final pal = PlanPalette.of(context);
    final raw = lines[i];
    final number = widget.start + i;
    final isHl = widget.highlights.contains(number);
    Color? bg;
    var text = raw;
    if (widget.diff && raw.startsWith('+') && !raw.startsWith('++')) {
      bg = pal.green.withValues(alpha: dark ? 0.22 : 0.12);
    } else if (widget.diff && raw.startsWith('-') && !raw.startsWith('--')) {
      bg = pal.red.withValues(alpha: dark ? 0.22 : 0.12);
    } else if (isHl) {
      bg = scheme.primaryContainer.withValues(alpha: 0.5);
    }
    final highlighted = CodeHighlighter.spanFor(
      text.isEmpty ? ' ' : text,
      widget.lang.isEmpty ? null : widget.lang,
      base,
    );
    return TextSpan(
      children: [
        TextSpan(
          text: '$number  ',
          style: base.copyWith(color: scheme.onSurfaceVariant, backgroundColor: bg),
        ),
        TextSpan(children: [highlighted], style: base.copyWith(backgroundColor: bg)),
        if (i != lines.length - 1) const TextSpan(text: '\n'),
      ],
    );
  }
}

/// `doc-flow`: nodos por grilla + aristas.
class FlowView extends StatelessWidget {
  const FlowView({super.key, required this.flow});

  final FlowExhibit flow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labels = {for (final n in flow.nodes) n.id: n};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in flow.grid)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final cell in row)
                if (cell == '.' || cell.isEmpty)
                  const SizedBox(width: 80, height: 30)
                else
                  Container(
                    margin: const EdgeInsets.all(3),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: (labels[cell]?.added ?? false)
                          ? scheme.primaryContainer
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      labels[cell]?.label.isNotEmpty ?? false
                          ? '${labels[cell]!.id}\n${labels[cell]!.label}'
                          : cell,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
            ],
          ),
        if (flow.edges.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              children: [
                for (final e in flow.edges)
                  Text(
                    '${e.from} → ${e.to}${e.label.isEmpty ? '' : ' : ${e.label}'}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// `doc-tree`: archivos con marcas.
class TreeView extends StatelessWidget {
  const TreeView({super.key, required this.tree});

  final TreeExhibit tree;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pal = PlanPalette.of(context);
    Color? markColor(String mark) {
      if (mark == '+') return pal.green;
      if (mark == '~') return pal.amber;
      if (mark == '-') return pal.red;
      return null;
    }

    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: AppRadius.mdAll,
      ),
      child: SelectableText.rich(
        TextSpan(
          children: [
            for (final line in tree.lines)
              TextSpan(
                children: [
                  if (line.mark != ' ')
                    TextSpan(
                      text: '${line.mark} ',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700,
                        color: markColor(line.mark),
                      ),
                    ),
                  TextSpan(
                    text: '${'  ' * line.depth}${line.text}\n',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
                  ),
                ],
              ),
          ],
          style: TextStyle(color: scheme.onSurface),
        ),
      ),
    );
  }
}

/// `doc-draft`: texto editable que vuelve como diff.
class DraftView extends StatefulWidget {
  const DraftView({super.key, required this.draft, required this.answers, required this.strings});

  final DraftExhibit draft;
  final PlanAnswers answers;
  final PlanStrings strings;

  @override
  State<DraftView> createState() => _DraftViewState();
}

class _DraftViewState extends State<DraftView> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final edited = widget.answers.edits[widget.draft.id];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.draft.label.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              widget.draft.label,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: AppRadius.mdAll,
          ),
          child: TextField(
            controller: TextEditingController(text: edited ?? widget.draft.text),
            maxLines: null,
            minLines: 3,
            onChanged: (v) => widget.answers.setEdit(widget.draft.id, v),
            style: Theme.of(context).textTheme.bodyMedium,
            decoration: null,
          ),
        ),
      ],
    );
  }
}

/// `doc-note`: riesgo u observación.
class NoteView extends StatelessWidget {
  const NoteView({super.key, required this.note});

  final PlanNote note;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pal = PlanPalette.of(context);
    final color = switch (note.tone) {
      'warn' || 'risk' => pal.amber,
      'ok' => pal.green,
      'idea' => scheme.primary,
      _ => scheme.onSurfaceVariant,
    };
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: SelectableText(
        note.text,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}

/// Botón para copiar la respuesta al portapapeles.
class CopyResponseButton extends StatelessWidget {
  const CopyResponseButton({
    super.key,
    required this.markdown,
    required this.strings,
  });

  final String markdown;
  final PlanStrings strings;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    icon: const Icon(Icons.copy, size: 16),
    label: Text(strings.copy),
    onPressed: () async {
      await Clipboard.setData(ClipboardData(text: markdown));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.copied)),
        );
      }
    },
  );
}
