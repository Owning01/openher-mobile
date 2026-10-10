/// Visor de planes html-plan: el árbol, las decisiones y la hoja Respond.
///
/// Entra con los bytes de un `plan.html` (bajados del server) y lo pinta
/// nativo: título, tamaño del cambio, hilo del porqué y claims numerados. El
/// botón **Responder** abre la hoja con la respuesta markdown lista para
/// copiar y pegar en el chat.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/tokens.dart';
import 'plan_answers.dart';
import 'plan_blocks.dart';
import 'plan_mock.dart';
import 'plan_model.dart';

/// Pantalla del plan. `sourceBytes` es el `plan.html` tal cual lo sirve el
/// server (empaquetado o no).
class PlanView extends StatefulWidget {
  const PlanView({super.key, required this.sourceBytes, this.fileName = ''});

  final List<int> sourceBytes;
  final String fileName;

  @override
  State<PlanView> createState() => _PlanViewState();
}

class _PlanViewState extends State<PlanView> {
  late final PlanDocument _doc;
  late final PlanAnswers _answers;
  late final PlanStrings _strings;
  final Set<String> _seenAsks = {};
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    final html = utf8.decode(widget.sourceBytes, allowMalformed: true);
    _doc = parsePlan(html);
    _strings = PlanStrings(!_doc.lang.startsWith('en'));
    _answers = PlanAnswers(planKey: widget.fileName.isEmpty ? _doc.title : widget.fileName);
    _answers.addListener(_onAnswers);
    _answers.load().then((_) {
      if (mounted) setState(() => _ready = true);
    });
    for (final entry in PlanAnswers.allAsksOf(_doc)) {
      _answers.applyDefaults(entry.ask);
    }
    _ready = true;
  }

  @override
  void dispose() {
    _answers.removeListener(_onAnswers);
    _answers.dispose();
    super.dispose();
  }

  void _onAnswers() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final asks = PlanAnswers.allAsksOf(_doc);
    final pending = _answers.unanswered(asks, _seenAsks);
    return Scaffold(
      appBar: AppBar(
        title: Text(_doc.title.isEmpty ? 'Plan' : _doc.title),
        actions: [
          if (pending > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    border: Border.all(color: scheme.primary, width: 1.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$pending ${_strings.toAnswer}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: !_ready
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _doc.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Text(
                  _strings.es
                      ? 'Esto no es un plan html-plan: no tiene árbol de claims.'
                      : 'This is not an html-plan: it has no claim tree.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                96,
              ),
              children: [
                if (!_doc.changes.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      _doc.changes.label(_strings.files),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (_doc.threadTitle.isNotEmpty || _doc.quotes.isNotEmpty)
                  _thread(context),
                ClaimTree(
                  claims: _doc.claims,
                  answers: _answers,
                  strings: _strings,
                  seenAsks: _seenAsks,
                  onAskSeen: (id) {
                    if (_seenAsks.add(id)) setState(() {});
                  },
                ),
              ],
            ),
      floatingActionButton: _doc.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openRespond(context, asks),
              label: Text(_strings.respond),
              icon: const Icon(Icons.reply, size: 18),
            ),
    );
  }

  Widget _thread(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: AppRadius.mdAll,
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        title: Text(
          _doc.threadTitle.isEmpty ? 'Why' : _doc.threadTitle,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        children: [
          for (final q in _doc.quotes)
            Container(
              margin: const EdgeInsets.fromLTRB(
                AppSpacing.sm,
                0,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: scheme.primary, width: 3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(q.text),
                  if (q.from.isNotEmpty || q.via.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        [q.from, q.via, q.at]
                            .where((s) => s.isNotEmpty)
                            .join(' · '),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
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

  Future<void> _openRespond(
    BuildContext context,
    List<({PlanAsk ask, String number})> asks,
  ) async {
    final markdown = _answers.buildResponse(_doc, _seenAsks);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        builder: (ctx, scroll) => Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _strings.es ? 'Tu respuesta' : 'Your response',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  controller: scroll,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < asks.length; i++)
                        _decisionLine(ctx, i, asks[i]),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        decoration: BoxDecoration(
                          color: Theme.of(ctx).colorScheme.surfaceContainerLow,
                          borderRadius: AppRadius.mdAll,
                        ),
                        child: SelectableText(
                          markdown,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: () {
                      _answers.reset();
                      Navigator.of(ctx).pop();
                    },
                    child: Text(
                      _strings.reset,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    icon: const Icon(Icons.copy, size: 16),
                    label: Text(_strings.copy),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: markdown));
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(content: Text(_strings.copied)),
                        );
                        Navigator.of(ctx).pop();
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _decisionLine(
    BuildContext context,
    int i,
    ({PlanAsk ask, String number}) entry,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final seen = _seenAsks.contains(entry.ask.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: seen ? scheme.surfaceContainerHighest : scheme.primary,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '${i + 1}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: seen ? scheme.onSurfaceVariant : scheme.onPrimary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('[${entry.number}] ${entry.ask.question}'),
                Text(
                  seen ? _strings.kept : _strings.notOpened,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
