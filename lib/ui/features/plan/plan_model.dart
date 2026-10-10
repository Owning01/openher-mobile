/// Modelo de un plan html-plan + parser desde su HTML.
///
/// Lee el **mismo `plan.html`** que la skill escribe (un formato, dos visores)
/// con `package:html` y lo proyecta a objetos Dart que `plan_blocks.dart`
/// pinta de forma nativa. No inventa campos: todo atributo que no se conoce se
/// ignora, y lo que falta deja el valor por defecto documentado abajo.
///
/// Cobertura de bloques (`references/blocks.md`): `doc-plan`, `doc-claim`,
/// `doc-changes`, `doc-mock` (+`doc-pin`, `doc-shot`), `doc-machine`,
/// `doc-calls`, `doc-schema`, `doc-code`, `doc-ask` (radios, checks, texto,
/// área, rango, rank, `data-if`), `doc-quote`, `doc-note`, `doc-flow`,
/// `doc-tree`, `doc-draft`.
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// `firstOrNull` sin traer `package:collection` por un método.
extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// Un plan entero, listo para `PlanView`.
final class PlanDocument {
  const PlanDocument({
    required this.title,
    required this.lang,
    required this.changes,
    required this.threadTitle,
    required this.quotes,
    required this.open,
    required this.claims,
  });

  /// `<title>` (2-4 palabras). Si falta, el `h1`.
  final String title;

  /// `lang` del `<html>` (`es`, `en`…). Decide el idioma de la UI del visor.
  final String lang;

  /// `doc-changes` del header, o ceros si no hay.
  final PlanChanges changes;

  /// `Why · 2 requests`: el `summary` del thread.
  final String threadTitle;

  /// Las citas del thread, en sus palabras.
  final List<PlanQuote> quotes;

  /// `open` de `doc-plan`: `0`-`3` o `needs`.
  final String open;

  /// Claims de nivel 1 (+ `shared` y `scope` al final, sin número).
  final List<PlanClaim> claims;

  /// `true` si no hay nada que pintar (ni claims ni título útil).
  bool get isEmpty => claims.isEmpty && title.isEmpty;
}

/// `doc-changes`: `+5 new ~4 changed −1 deleted`.
final class PlanChanges {
  const PlanChanges({this.added = 0, this.changed = 0, this.deleted = 0});

  final int added;
  final int changed;
  final int deleted;

  int get total => added + changed + deleted;
  bool get isEmpty => total == 0;

  /// `Proposed · 9 files · +5 new · ~4 changed · −1 deleted`.
  String label(String filesWord) {
    final parts = <String>['$total $filesWord'];
    if (added > 0) parts.add('+$added new');
    if (changed > 0) parts.add('~$changed changed');
    if (deleted > 0) parts.add('−$deleted deleted');
    return parts.join(' · ');
  }
}

/// `doc-quote`: las palabras del usuario, sin parafrasear.
final class PlanQuote {
  const PlanQuote({required this.text, this.via = '', this.from = '', this.at = ''});

  final String text;
  final String via;
  final String from;
  final String at;
}

/// Un `doc-claim` con su exhibit, su decisión y sus hijos.
final class PlanClaim {
  const PlanClaim({
    required this.text,
    required this.spans,
    this.exhibit,
    this.ask,
    this.note,
    this.children = const [],
    this.conditions = const [],
    this.aux = '',
    this.at = '',
    this.id = '',
  });

  /// Claim en texto plano (para títulos y búsquedas).
  final String text;

  /// Claim con spans de `code`/`b` para el `RichText`.
  final List<InlineSpan> spans;

  /// Un solo exhibit (el segundo sería un segundo claim).
  final PlanExhibit? exhibit;

  /// La decisión que vive en este claim, si hay.
  final PlanAsk? ask;

  /// `doc-note` bajo el exhibit, si hay.
  final PlanNote? note;

  final List<PlanClaim> children;

  /// `div[data-if]`: solo se muestra bajo esa respuesta.
  final List<ConditionalBlock> conditions;

  /// `shared` / `scope`: ramas sin número al final.
  final String aux;

  /// `path:line` del nivel 3.
  final String at;

  /// Ancla para links `#id`.
  final String id;
}

/// Tramos de texto con `_code_` o `*bold*` para el claim.
final class InlineSpan {
  const InlineSpan(this.text, {this.code = false, this.bold = false});

  final String text;
  final bool code;
  final bool bold;
}

/// Exhibits. Uno por claim.
sealed class PlanExhibit {
  const PlanExhibit({this.caption = ''});

  /// Una oración: qué mirar.
  final String caption;
}

/// `doc-mock`: HTML real en un marco.
final class MockExhibit extends PlanExhibit {
  const MockExhibit({
    super.caption,
    this.frame = 'none',
    this.width = 440,
    this.height = 0,
    this.url = '',
    this.title = '',
    this.label = '',
    this.html = '',
    this.shot = '',
    this.thumbnail = false,
    this.pins = const [],
  });

  final String frame;
  final double width;
  final double height;
  final String url;
  final String title;
  final String label;
  final String html;
  final String shot;
  final bool thumbnail;
  final List<MockPin> pins;
}

/// `doc-pin`: qué notar (título corto + una oración).
final class MockPin {
  const MockPin({
    required this.ref,
    required this.title,
    this.body = '',
    this.line = 0,
    this.tone = 'info',
  });

  /// `ref` del elemento o `line` del código.
  final String ref;
  final String title;
  final String body;
  final int line;
  final String tone;
}

/// `doc-machine`: ciclo de vida con la pantalla de cada estado.
final class MachineExhibit extends PlanExhibit {
  const MachineExhibit({
    super.caption,
    required this.name,
    this.initial = '',
    this.states = const [],
    this.arrows = const [],
    this.grid = const [],
    this.screens = const {},
    this.conditions = const [],
  });

  final String name;
  final String initial;
  final List<MachineState> states;
  final List<MachineArrow> arrows;

  /// Filas de la grilla (`|` … `|`, `.` = vacío).
  final List<List<String>> grid;

  /// `data-state` → HTML de la pantalla en ese estado.
  final Map<String, String> screens;

  /// `data-if` → texto que solo sale en ese estado.
  final List<ConditionalBlock> conditions;
}

final class MachineState {
  const MachineState({required this.id, this.note = '', this.finalState = false});

  final String id;
  final String note;
  final bool finalState;
}

final class MachineArrow {
  const MachineArrow({
    required this.from,
    required this.event,
    required this.to,
    this.label = '',
    this.added = false,
    this.removed = false,
  });

  final String from;
  final String event;
  final String to;
  final String label;
  final bool added;
  final bool removed;
}

/// `div[data-if]` / `data-state` con condición `nombre=valor`.
final class ConditionalBlock {
  const ConditionalBlock({required this.condition, required this.html});

  final String condition;
  final String html;
}

/// `doc-calls`: árboles de llamadas como texto.
final class CallsExhibit extends PlanExhibit {
  const CallsExhibit({
    super.caption,
    this.title = '',
    this.rows = const [],
    this.showFiles = false,
  });

  final String title;
  final List<CallRow> rows;
  final bool showFiles;
}

/// Una línea del árbol. `mark`: `+` nueva, `-` quitada, `~` cambiada,
/// `?` propuesta, ` ` contexto.
final class CallRow {
  const CallRow({
    required this.text,
    this.mark = ' ',
    this.depth = 0,
    this.bold = false,
    this.path = '',
    this.note = '',
    this.entrypoint = false,
  });

  final String text;
  final String mark;
  final int depth;
  final bool bold;
  final String path;
  final String note;
  final bool entrypoint;
}

/// `doc-schema`: la forma en su propio lenguaje.
final class SchemaExhibit extends PlanExhibit {
  const SchemaExhibit({
    super.caption,
    this.id = '',
    this.title = '',
    required this.lang,
    this.diff = false,
    this.text = '',
  });

  final String id;
  final String title;
  final String lang;
  final bool diff;
  final String text;
}

/// `doc-code`: fragmento con pins por línea.
final class CodeExhibit extends PlanExhibit {
  const CodeExhibit({
    super.caption,
    this.title = '',
    this.lang = '',
    this.text = '',
    this.diff = false,
    this.file = '',
    this.start = 1,
    this.highlights = const [],
    this.wrap = false,
    this.collapsed = false,
    this.pins = const [],
  });

  final String title;
  final String lang;
  final String text;
  final bool diff;
  final String file;
  final int start;
  final List<int> highlights;
  final bool wrap;
  final bool collapsed;
  final List<MockPin> pins;
}

/// `doc-flow`: partes y cómo conectan.
final class FlowExhibit extends PlanExhibit {
  const FlowExhibit({
    super.caption,
    this.nodes = const [],
    this.grid = const [],
    this.edges = const [],
  });

  final List<FlowNode> nodes;
  final List<List<String>> grid;
  final List<FlowEdge> edges;
}

final class FlowNode {
  const FlowNode({required this.id, this.label = '', this.added = false});

  final String id;
  final String label;
  final bool added;
}

final class FlowEdge {
  const FlowEdge({required this.from, required this.to, this.label = ''});

  final String from;
  final String to;
  final String label;
}

/// `doc-tree`: qué archivos existen.
final class TreeExhibit extends PlanExhibit {
  const TreeExhibit({super.caption, this.lines = const []});

  final List<TreeLine> lines;
}

final class TreeLine {
  const TreeLine({required this.text, this.depth = 0, this.mark = ' '});

  final String text;
  final int depth;
  final String mark;
}

/// `doc-draft`: texto largo que el lector edita.
final class DraftExhibit extends PlanExhibit {
  const DraftExhibit({super.caption, this.id = '', this.label = '', this.text = ''});

  final String id;
  final String label;
  final String text;
}

/// `doc-note`: riesgo u observación con tono.
final class PlanNote extends PlanExhibit {
  const PlanNote({super.caption, this.tone = 'info', this.text = ''});

  final String tone;
  final String text;
}

/// `doc-ask`: una decisión (es un formulario).
final class PlanAsk {
  const PlanAsk({required this.id, required this.question, this.controls = const []});

  final String id;
  final String question;
  final List<AskControl> controls;
}

/// Controles. `kind`: radio, check, text, area, range, rank.
final class AskControl {
  const AskControl({
    required this.kind,
    required this.name,
    this.options = const [],
    this.min = 0,
    this.max = 100,
    this.value = '',
    this.checked = false,
    this.inline = false,
  });

  final String kind;
  final String name;
  final List<AskOption> options;
  final double min;
  final double max;
  final String value;
  final bool checked;
  final bool inline;
}

final class AskOption {
  const AskOption({
    required this.value,
    required this.label,
    this.detail = '',
    this.checked = false,
  });

  final String value;
  final String label;
  final String detail;
  final bool checked;
}

/// Parsea un `plan.html` (empaquetado o no) a [PlanDocument].
PlanDocument parsePlan(String html) {
  final doc = html_parser.parse(html);
  final title =
      doc.querySelector('title')?.text.trim() ??
      doc.querySelector('h1')?.text.trim() ??
      '';
  final lang =
      doc.querySelector('html')?.attributes['lang']?.trim().toLowerCase() ??
      'en';
  final changesEl = doc.querySelector('doc-changes');
  final changes = PlanChanges(
    added: _intOf(changesEl?.attributes['new']),
    changed: _intOf(changesEl?.attributes['changed']),
    deleted: _intOf(changesEl?.attributes['deleted']),
  );
  final thread = doc.querySelector('details.thread');
  final threadTitle = thread?.querySelector('summary')?.text.trim() ?? '';
  final quotes = [
    for (final q in doc.querySelectorAll('doc-quote'))
      PlanQuote(
        text: q.text.trim(),
        via: q.attributes['via'] ?? '',
        from: q.attributes['from'] ?? '',
        at: q.attributes['at'] ?? '',
      ),
  ];
  final plan = doc.querySelector('doc-plan');
  final claims = [
    for (final el in plan?.children ?? <dom.Element>[])
      if (el.localName == 'doc-claim') _claim(el),
  ];
  return PlanDocument(
    title: title,
    lang: lang,
    changes: changes,
    threadTitle: threadTitle,
    quotes: quotes,
    open: plan?.attributes['open'] ?? '0',
    claims: claims,
  );
}

int _intOf(String? raw) => int.tryParse(raw ?? '') ?? 0;

/// Texto con `<code>` y `<b>` como spans (lo demás, texto plano).
List<InlineSpan> inlineSpans(dom.Element el) {
  final out = <InlineSpan>[];
  for (final node in el.nodes) {
    if (node is dom.Text) {
      if (node.text.isNotEmpty) out.add(InlineSpan(node.text));
    } else if (node is dom.Element) {
      final name = node.localName;
      if (name == 'code') {
        out.add(InlineSpan(node.text, code: true));
      } else if (name == 'b' || name == 'strong') {
        out.add(InlineSpan(node.text, bold: true));
      } else if (name == 'br') {
        out.add(const InlineSpan('\n'));
      } else {
        out.add(InlineSpan(node.text));
      }
    }
  }
  final merged = out.where((s) => s.text.isNotEmpty).toList();
  return merged.isEmpty ? const [InlineSpan('')] : merged;
}

PlanClaim _claim(dom.Element el) {
  PlanExhibit? exhibit;
  PlanAsk? ask;
  PlanNote? note;
  final children = <PlanClaim>[];
  final conditions = <ConditionalBlock>[];
  for (final child in el.children) {
    switch (child.localName) {
      case 'p':
        break;
      case 'doc-ask':
        ask ??= _ask(child);
      case 'doc-note':
        note ??= _note(child);
      case 'doc-claim':
        children.add(_claim(child));
      case 'div':
        final cond = child.attributes['data-if'];
        if (cond != null && cond.isNotEmpty) {
          conditions.add(ConditionalBlock(condition: cond, html: child.innerHtml));
        } else {
          exhibit ??= _exhibit(child);
        }
      default:
        exhibit ??= _exhibit(child);
    }
  }
  // El claim es el primer `<p>`; sin él, el nombre del archivo (`at`).
  final p = el.children.where((c) => c.localName == 'p').firstOrNull;
  final at = el.attributes['at'] ?? '';
  final text = p?.text.trim() ?? at.split('/').lastOrNull ?? '';
  return PlanClaim(
    text: text,
    spans: p == null ? [InlineSpan(text)] : inlineSpans(p),
    exhibit: exhibit,
    ask: ask,
    note: note,
    children: children,
    conditions: conditions,
    aux: el.attributes['aux'] ?? '',
    at: at,
    id: el.attributes['id'] ?? '',
  );
}

PlanExhibit? _exhibit(dom.Element el) {
  switch (el.localName) {
    case 'doc-mock':
      return _mock(el);
    case 'doc-machine':
      return _machine(el);
    case 'doc-calls':
      return _calls(el);
    case 'doc-schema':
      return _schema(el);
    case 'doc-code':
      return _code(el);
    case 'doc-flow':
      return _flow(el);
    case 'doc-tree':
      return _tree(el);
    case 'doc-draft':
      return _draft(el);
    case 'doc-note':
      return _note(el);
  }
  return null;
}

/// Texto fuente del bloque: el primer `<script type="text/plain">`.
String _sourceOf(dom.Element el) {
  for (final s in el.querySelectorAll('script')) {
    if (s.attributes['type'] == 'text/plain') return s.text;
  }
  return '';
}

/// HTML del `<template>` del mock (el contenido vive en su fragmento).
String _templateHtml(dom.Element mock) {
  final tpl = mock.querySelector('template');
  if (tpl == null) return '';
  final inner = tpl.innerHtml.trim();
  if (inner.isNotEmpty) return inner;
  return tpl.nodes.map((n) => n.toString()).join().trim();
}

MockExhibit _mock(dom.Element el) => MockExhibit(
  caption: el.attributes['caption'] ?? '',
  frame: el.attributes['frame'] ?? 'none',
  width: double.tryParse(el.attributes['w'] ?? '') ?? 440,
  height: double.tryParse(el.attributes['h'] ?? '') ?? 0,
  url: el.attributes['url'] ?? '',
  title: el.attributes['title'] ?? '',
  label: el.attributes['label'] ?? '',
  html: _templateHtml(el),
  shot: el.attributes['src'] ?? '',
  thumbnail: el.attributes.containsKey('thumbnail'),
  pins: [
    for (final p in el.querySelectorAll('doc-pin'))
      MockPin(
        ref: p.attributes['ref'] ?? '',
        title: p.attributes['title'] ?? '',
        body: p.text.trim(),
      ),
  ],
);

MachineExhibit _machine(dom.Element el) {
  final states = <MachineState>[];
  final arrows = <MachineArrow>[];
  final grid = <List<String>>[];
  var name = el.attributes['name'] ?? '';
  var initial = '';
  for (final raw in _sourceOf(el).split('\n')) {
    final line = raw.trimRight();
    if (line.trim().isEmpty) continue;
    var rest = line.trim();
    var added = false;
    if (rest.startsWith('+ ') || rest.startsWith('- ')) {
      added = rest.startsWith('+ ');
      rest = rest.substring(2);
    }
    if (rest.startsWith('machine ')) {
      final parts = rest.split(RegExp(r'\s+'));
      if (parts.length > 1) name = parts[1];
      final i = parts.indexOf('initial');
      if (i >= 0 && i + 1 < parts.length) initial = parts[i + 1];
    } else if (rest.startsWith('state ')) {
      final hash = rest.indexOf('#');
      final head = (hash >= 0 ? rest.substring(0, hash) : rest).trim();
      final note = hash >= 0 ? rest.substring(hash + 1).trim() : '';
      final parts = head.split(RegExp(r'\s+'));
      if (parts.length > 1) {
        states.add(
          MachineState(
            id: parts[1],
            note: note,
            finalState: parts.contains('final'),
          ),
        );
      }
    } else if (rest.startsWith('|')) {
      grid.add(
        rest.split('|').map((c) => c.trim()).where((c) => c.isNotEmpty).toList(),
      );
    } else if (rest.contains('->')) {
      final arrow = RegExp(
        r'^(\S+)\s+(-\S+->)\s+(\S+)(?:\s*:\s*(.*))?$',
      ).firstMatch(rest);
      if (arrow != null) {
        arrows.add(
          MachineArrow(
            from: arrow.group(1)!,
            event: arrow.group(2)!,
            to: arrow.group(3)!,
            label: (arrow.group(4) ?? '').trim(),
            added: added,
          ),
        );
      }
    }
  }
  final screens = <String, String>{};
  final conditions = <ConditionalBlock>[];
  for (final div in el.querySelectorAll('div')) {
    final state = div.attributes['data-state'];
    if (state != null && state.isNotEmpty) {
      final mock = div.querySelector('doc-mock');
      screens[state] = mock == null ? div.innerHtml : _templateHtml(mock);
    }
    final cond = div.attributes['data-if'];
    if (cond != null && cond.isNotEmpty) {
      conditions.add(ConditionalBlock(condition: cond, html: div.innerHtml));
    }
  }
  return MachineExhibit(
    caption: el.attributes['caption'] ?? '',
    name: name,
    initial: initial,
    states: states,
    arrows: arrows,
    grid: grid,
    screens: screens,
    conditions: conditions,
  );
}

CallsExhibit _calls(dom.Element el) {
  final rows = <CallRow>[];
  var entrypoint = true;
  for (final raw in _sourceOf(el).split('\n')) {
    if (raw.trim().isEmpty) {
      entrypoint = true;
      continue;
    }
    final mark = raw.isNotEmpty ? raw[0] : ' ';
    final kept = '+-~? '.contains(mark) ? raw.substring(1) : raw;
    final indent = kept.length - kept.trimLeft().length;
    var text = kept.trim();
    var path = '';
    var note = '';
    final at = text.lastIndexOf('@');
    if (at >= 0) {
      final tail = text.substring(at + 1).trim();
      final dash = tail.indexOf('--');
      if (dash >= 0) {
        path = tail.substring(0, dash).trim();
        note = tail.substring(dash + 2).trim();
      } else {
        path = tail;
      }
      text = text.substring(0, at).trim();
    }
    var bold = false;
    if (text.contains('**')) {
      bold = true;
      text = text.replaceAll('**', '');
    }
    rows.add(
      CallRow(
        text: text,
        mark: '+-~?'.contains(mark) ? mark : ' ',
        depth: indent ~/ 2,
        bold: bold,
        path: path,
        note: note,
        entrypoint: entrypoint,
      ),
    );
    entrypoint = false;
  }
  return CallsExhibit(
    caption: el.attributes['caption'] ?? '',
    title: el.attributes['title'] ?? '',
    rows: rows,
    showFiles: el.attributes.containsKey('files'),
  );
}

SchemaExhibit _schema(dom.Element el) => SchemaExhibit(
  caption: el.attributes['caption'] ?? '',
  id: el.attributes['id'] ?? '',
  title: el.attributes['title'] ?? '',
  lang: el.attributes['lang'] ?? '',
  diff: el.attributes.containsKey('diff'),
  text: _sourceOf(el).trim(),
);

/// `hl="4-5,9"` → [4, 5, 9] (números de línea tal como se muestran).
List<int> parseHighlights(String raw) {
  final out = <int>[];
  for (final part in raw.split(',')) {
    final p = part.trim();
    if (p.isEmpty) continue;
    final dash = p.indexOf('-');
    if (dash < 0) {
      final n = int.tryParse(p);
      if (n != null) out.add(n);
    } else {
      final a = int.tryParse(p.substring(0, dash)) ?? 0;
      final b = int.tryParse(p.substring(dash + 1)) ?? 0;
      for (var n = a; n <= b && n > 0; n++) {
        out.add(n);
      }
    }
  }
  return out;
}

CodeExhibit _code(dom.Element el) => CodeExhibit(
  caption: el.attributes['caption'] ?? '',
  title: el.attributes['title'] ?? '',
  lang: el.attributes['lang'] ?? '',
  text: _sourceOf(el).trim(),
  diff: el.attributes.containsKey('diff'),
  file: el.attributes['file'] ?? '',
  start: int.tryParse(el.attributes['start'] ?? '') ?? 1,
  highlights: parseHighlights(el.attributes['hl'] ?? ''),
  wrap: el.attributes.containsKey('wrap'),
  collapsed: el.attributes.containsKey('collapsed'),
  pins: [
    for (final p in el.querySelectorAll('doc-pin'))
      MockPin(
        ref: '',
        title: p.attributes['title'] ?? '',
        body: p.text.trim(),
        line: int.tryParse(p.attributes['line'] ?? '') ?? 0,
        tone: p.attributes['tone'] ?? 'info',
      ),
  ],
);

FlowExhibit _flow(dom.Element el) {
  final nodes = <FlowNode>[];
  final grid = <List<String>>[];
  final edges = <FlowEdge>[];
  for (final raw in _sourceOf(el).split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('|')) {
      grid.add(
        line.split('|').map((c) => c.trim()).where((c) => c.isNotEmpty).toList(),
      );
      continue;
    }
    if (line.contains('->')) {
      final m = RegExp(r'^(\S+)\s*->\s*(\S+)(?:\s*:\s*(.*))?$').firstMatch(line);
      if (m != null) {
        edges.add(
          FlowEdge(from: m.group(1)!, to: m.group(2)!, label: (m.group(3) ?? '').trim()),
        );
      }
      continue;
    }
    final m = RegExp(r'^(\+?)\s*(\S+)\s*=\s*(.*)$').firstMatch(line);
    if (m != null) {
      nodes.add(
        FlowNode(id: m.group(2)!, label: m.group(3)!.trim(), added: m.group(1) == '+'),
      );
    }
  }
  return FlowExhibit(
    caption: el.attributes['caption'] ?? '',
    nodes: nodes,
    grid: grid,
    edges: edges,
  );
}

TreeExhibit _tree(dom.Element el) {
  final lines = <TreeLine>[];
  for (final raw in _sourceOf(el).split('\n')) {
    if (raw.trim().isEmpty) continue;
    final indent = raw.length - raw.trimLeft().length;
    var text = raw.trim();
    var mark = ' ';
    if ((text.startsWith('+ ') || text.startsWith('~ ')) && text.length > 2) {
      mark = text[0];
      text = text.substring(2);
    }
    lines.add(TreeLine(text: text, depth: indent ~/ 2, mark: mark));
  }
  return TreeExhibit(caption: el.attributes['caption'] ?? '', lines: lines);
}

DraftExhibit _draft(dom.Element el) => DraftExhibit(
  caption: el.attributes['caption'] ?? '',
  id: el.attributes['id'] ?? '',
  label: el.attributes['label'] ?? '',
  text: _sourceOf(el).trim(),
);

PlanNote _note(dom.Element el) => PlanNote(
  caption: '',
  tone: el.attributes['tone'] ?? 'info',
  text: el.text.trim(),
);

PlanAsk _ask(dom.Element el) {
  final controls = <AskControl>[];
  final question = el.querySelector('p')?.text.trim() ?? '';
  for (final label in el.querySelectorAll('label')) {
    final input = label.querySelector('input');
    final area = label.querySelector('textarea');
    if (input != null) {
      final type = (input.attributes['type'] ?? 'radio').toLowerCase();
      final name = input.attributes['name'] ?? '';
      final value = input.attributes['value'] ?? label.text.trim();
      final detail = label.querySelector('small')?.text.trim() ?? '';
      final checked = input.attributes.containsKey('checked');
      final labelText = label.text.replaceAll(detail, '').trim();
      if (type == 'checkbox') {
        final group = controls.where((c) => c.kind == 'check' && c.name == name).firstOrNull;
        final option = AskOption(value: value, label: labelText, detail: detail, checked: checked);
        if (group == null) {
          controls.add(AskControl(kind: 'check', name: name, options: [option]));
        } else {
          group.options.add(option);
        }
      } else if (type == 'text') {
        controls.add(
          AskControl(kind: 'text', name: name, value: input.attributes['value'] ?? ''),
        );
      } else if (type == 'range') {
        controls.add(
          AskControl(
            kind: 'range',
            name: name,
            min: double.tryParse(input.attributes['min'] ?? '') ?? 0,
            max: double.tryParse(input.attributes['max'] ?? '') ?? 100,
            value: input.attributes['value'] ?? '',
          ),
        );
      } else {
        final group = controls.where((c) => c.kind == 'radio' && c.name == name).firstOrNull;
        final option = AskOption(value: value, label: labelText, detail: detail, checked: checked);
        if (group == null) {
          controls.add(
            AskControl(
              kind: 'radio',
              name: name,
              options: [option],
              inline: el.querySelector('.opts-row') != null,
            ),
          );
        } else {
          group.options.add(option);
        }
      }
    } else if (area != null) {
      controls.add(
        AskControl(kind: 'area', name: area.attributes['name'] ?? '', value: area.text),
      );
    }
  }
  for (final ol in el.querySelectorAll('ol.rank')) {
    controls.add(
      AskControl(
        kind: 'rank',
        name: ol.attributes['data-name'] ?? '',
        options: [
          for (final li in ol.querySelectorAll('li'))
            AskOption(value: li.attributes['data-value'] ?? li.text.trim(), label: li.text.trim()),
        ],
      ),
    );
  }
  return PlanAsk(id: el.attributes['id'] ?? '', question: question, controls: controls);
}
