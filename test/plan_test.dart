/// Visor de planes: parser del `plan.html`, respuestas y entrada desde el chat.
///
/// El fixture es un plan chico que ejercita todos los bloques. La prueba
/// madre es contra el ejemplo real de la skill (`scheduled-send.html`), que
/// se lee del disco: si la skill cambia su forma, acá se nota.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/domain/models/message.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/features/chat/message_bubble.dart';
import 'package:openher_mobile/ui/features/plan/plan_answers.dart';
import 'package:openher_mobile/ui/features/plan/plan_blocks.dart';
import 'package:openher_mobile/ui/features/plan/plan_entry.dart';
import 'package:openher_mobile/ui/features/plan/plan_model.dart';
import 'package:openher_mobile/ui/features/plan/plan_view.dart';

const String kPlan = '''
<!doctype html>
<html lang="es">
<meta charset="utf-8">
<title>Plan de prueba</title>
<body>
<header>
  <h1>Enviar tarde en PostBox</h1>
  <doc-changes new="2" changed="1"></doc-changes>
  <details class="thread"><summary>Why · 1 request</summary>
    <doc-quote via="prompt" from="el usuario">quiero enviar tarde</doc-quote>
  </details>
</header>
<main>
<doc-plan>
  <doc-claim>
    <p>El usuario <code>elige</code> la hora. <b>Ojo</b>.</p>
    <doc-mock frame="terminal" w="440"><template><span class="dim">></span> enviar <span class="g">listo</span></template>
      <doc-pin ref="x" title="Listo">Sale en verde.</doc-pin>
    </doc-mock>
    <doc-claim>
      <p>Guardar <code>no</code> envía.</p>
      <doc-calls title="Llamadas">
<script type="text/plain">
~ <Composer/>                                  @ web/a.tsx:41
+   <**Menu**/>                                @ web/b.tsx:12
+     POST /api/x                              @ web/c.ts:9
-   viejo()                                    @ web/d.ts:30   -- ya no se usa
?   maybe()                                    @ web/e.ts:14   -- propuesto
</script>
      </doc-calls>
      <doc-claim at="server/r.ts:18">
        <p><b>r.ts:18</b> · crear()</p>
        <doc-code title="r.ts · sketch" lang="ts" hl="2">
<script type="text/plain">
export function crear() {
  return 1
}
</script>
        </doc-code>
      </doc-claim>
    </doc-claim>
    <doc-claim>
      <p>Tope de 50 por usuario.</p>
      <doc-schema id="tabla" lang="sql" title="mensajes" diff>
<script type="text/plain">
 CREATE TABLE mensajes (
-  estado text,
+  status text
 );
</script>
      </doc-schema>
      <doc-ask id="tope">
        <p>Cuantos por usuario?</p>
        <label><input type="radio" name="tope" value="50" checked> 50</label>
        <label><input type="radio" name="tope" value="500"> 500 <small>cuesta más</small></label>
      </doc-ask>
      <div data-if="tope=500"><doc-note tone="warn"><strong>Ojo</strong> Revisar costo.</doc-note></div>
    </doc-claim>
  </doc-claim>
  <doc-claim>
    <p>La máquina de estados.</p>
    <doc-machine name="msg" caption="Verde es propuesto.">
<script type="text/plain">
machine msg initial a
state a   # Primero.
state b final   # Listo.
| a | b |
a -go-> b : ir
+ b -back-> a : volver
</script>
      <div data-state="a"><doc-mock frame="none" w="200"><template><p>Pantalla A</p></template></doc-mock></div>
    </doc-machine>
  </doc-claim>
  <doc-claim>
    <p>El flujo.</p>
    <doc-flow>
<script type="text/plain">
api  = API / routes.ts
+ wk = Worker [green]
| api |
| wk |
api -> wk : insert
</script>
    </doc-flow>
  </doc-claim>
  <doc-claim>
    <p>Los archivos.</p>
    <doc-tree>
<script type="text/plain">
server/src/
  + scheduled/
  ~ mail/send.ts
</script>
    </doc-tree>
  </doc-claim>
  <doc-claim>
    <p>El texto.</p>
    <doc-draft id="aviso" label="Aviso">
<script type="text/plain">
Línea uno.
</script>
    </doc-draft>
  </doc-claim>
  <doc-claim aux="scope"><p>No cambia el envío normal.</p></doc-claim>
</doc-plan>
</main>
</body></html>
''';

void main() {
  group('parsePlan: el fixture', () {
    late PlanDocument doc;

    setUpAll(() {
      doc = parsePlan(kPlan);
    });

    test('título, idioma y cambios', () {
      expect(doc.title, 'Plan de prueba');
      expect(doc.lang, 'es');
      expect(doc.changes.total, 3);
      expect(doc.changes.added, 2);
      expect(doc.threadTitle, 'Why · 1 request');
      expect(doc.quotes.single.from, 'el usuario');
    });

    test('árbol con exhibits y niveles', () {
      expect(doc.claims, hasLength(6));
      final first = doc.claims.first;
      expect(first.children, hasLength(2));
      expect(first.exhibit, isA<MockExhibit>());
      final mock = first.exhibit! as MockExhibit;
      expect(mock.frame, 'terminal');
      expect(mock.html, contains('enviar'));
      expect(mock.pins.single.title, 'Listo');
      // Spans: code + bold.
      expect(
        first.spans.where((s) => s.code).single.text,
        'elige',
      );
      expect(first.spans.where((s) => s.bold).single.text, 'Ojo');
    });

    test('calls con marcas, paths y notas', () {
      final calls =
          doc.claims.first.children.first.exhibit! as CallsExhibit;
      expect(calls.title, 'Llamadas');
      expect(calls.rows.map((r) => r.mark), ['~', '+', '+', '-', '?']);
      expect(calls.rows[1].bold, isTrue);
      expect(calls.rows[1].path, 'web/b.tsx:12');
      expect(calls.rows[3].note, 'ya no se usa');
      expect(calls.rows[0].entrypoint, isTrue);
    });

    test('code con highlights y nivel 3 con at', () {
      final leaf = doc.claims.first.children.first.children.single;
      expect(leaf.at, 'server/r.ts:18');
      final code = leaf.exhibit! as CodeExhibit;
      expect(code.lang, 'ts');
      expect(code.highlights, [2]);
      expect(code.text, contains('export function crear'));
    });

    test('schema, ask y data-if', () {
      final tope = doc.claims.first.children[1];
      final schema = tope.exhibit! as SchemaExhibit;
      expect(schema.lang, 'sql');
      expect(schema.diff, isTrue);
      expect(schema.id, 'tabla');
      final ask = tope.ask!;
      expect(ask.id, 'tope');
      expect(ask.controls.single.kind, 'radio');
      expect(ask.controls.single.options.map((o) => o.value), ['50', '500']);
      expect(ask.controls.single.options.first.checked, isTrue);
      expect(ask.controls.single.options[1].detail, 'cuesta más');
      expect(tope.conditions.single.condition, 'tope=500');
    });

    test('machine, flow, tree, draft y scope', () {
      final machine = doc.claims[1].exhibit! as MachineExhibit;
      expect(machine.name, 'msg');
      expect(machine.initial, 'a');
      expect(machine.states.map((s) => s.id), ['a', 'b']);
      expect(machine.states.last.finalState, isTrue);
      expect(machine.grid, [
        ['a', 'b'],
      ]);
      expect(machine.arrows, hasLength(2));
      expect(machine.arrows.last.added, isTrue);
      expect(machine.screens['a'], contains('Pantalla A'));

      final flow = doc.claims[2].exhibit! as FlowExhibit;
      expect(flow.nodes.map((n) => n.id), ['api', 'wk']);
      expect(flow.nodes.last.added, isTrue);
      expect(flow.edges.single.label, 'insert');

      final tree = doc.claims[3].exhibit! as TreeExhibit;
      expect(tree.lines[1].mark, '+');
      expect(tree.lines[1].depth, 1);

      final draft = doc.claims[4].exhibit! as DraftExhibit;
      expect(draft.id, 'aviso');

      expect(doc.claims.last.aux, 'scope');
    });
  });

  group('el ejemplo real de la skill', () {
    test('parsea título, claims y decisiones', () {
      final path =
          'C:\\Users\\perca\\.agents\\skills\\html-plan\\examples\\scheduled-send.html';
      final html = File(path).readAsStringSync();
      final doc = parsePlan(html);
      expect(doc.title, 'Scheduled Send Plan');
      expect(doc.claims.length, greaterThan(2));
      expect(doc.changes.total, 9);
      final asks = PlanAnswers.allAsksOf(doc);
      expect(asks, isNotEmpty);
      // Cada decisión trae default marcado.
      for (final entry in asks) {
        final radios = entry.ask.controls.where((c) => c.kind == 'radio');
        for (final radio in radios) {
          expect(
            radio.options.where((o) => o.checked),
            hasLength(1),
            reason: entry.ask.id,
          );
        }
      }
    });
  });

  group('respuestas', () {
    test('defaults, elección y markdown con el formato de la skill', () {
      final doc = parsePlan(kPlan);
      final answers = PlanAnswers(planKey: 'test');
      addTearDown(answers.dispose);
      final ask = PlanAnswers.allAsksOf(doc).single.ask;
      answers.applyDefaults(ask);
      expect(answers.valuesOf(ask.id, ask.controls.single), ['50']);

      answers.setValues(ask.id, ask.controls.single, ['500']);
      answers.setComment('claim:1', 'revisar tope');
      answers.toggleStrike('calls:3');

      final md = answers.buildResponse(doc, {'tope'});
      expect(md, startsWith('# Re: Plan de prueba\n## Decisions\n'));
      expect(md, contains('[1.2]'));
      expect(md, contains('**500** `500` _(kept as proposed)_'));
      expect(md, contains('## Struck from the plan'));
      expect(md, contains('## Comments'));
      expect(md, contains('> revisar tope'));

      expect(answers.conditionHolds('tope=500'), isTrue);
      expect(answers.conditionHolds('tope=50'), isFalse);
    });
  });

  group('entrada desde el chat', () {
    test('detecta absoluta, relativa y nada', () {
      expect(
        findPlanPath('mirá C:/docs/plan.html que dejé'),
        'C:/docs/plan.html',
      );
      expect(
        findPlanPath(r'ver G:\x\plan.packed.html ya'),
        r'G:\x\plan.packed.html',
      );
      expect(findPlanPath('abrí docs/plan.html'), 'docs/plan.html');
      expect(findPlanPath('hola cómo andás'), isNull);
      expect(findPlanPath('foto.png'), isNull);
    });

    test('separa carpeta y nombre', () {
      expect(
        splitPlanTarget('C:/docs/plan.html'),
        (directory: 'C:/docs', name: 'plan.html'),
      );
      expect(
        splitPlanTarget(r'G:\x\plan.packed.html'),
        (directory: 'G:/x', name: 'plan.packed.html'),
      );
      expect(
        splitPlanTarget('docs/plan.html'),
        (directory: null, name: 'docs/plan.html'),
      );
    });
  });

  group('entrada desde la burbuja', () {    AssistantMessage assistantCon(String text) => AssistantMessage(
      id: 'msg_a',
      time: const MessageTime(createdMs: 1, completedMs: 2),
      agent: 'build',
      model: const ModelRef(id: 'm', providerID: 'p'),
      content: [AssistantText(text: text)],
      finish: 'stop',
    );

    Future<void> pumpBubble(
      WidgetTester tester,
      SessionMessage message, {
      void Function(String path)? onOpenPlan,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: MessageBubble(
              message: message,
              working: false,
              onOpenPlan: onOpenPlan,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('con ruta al plan sale Ver plan y entrega la ruta', (
      tester,
    ) async {
      final abiertas = <String>[];
      await pumpBubble(
        tester,
        assistantCon('listo, mirá C:/docs/plan.html'),
        onOpenPlan: abiertas.add,
      );

      await tester.tap(find.byKey(MessageBubble.planButtonKey('msg_a')));
      await tester.pump();

      expect(abiertas, ['C:/docs/plan.html']);
    });

    testWidgets('sin ruta no hay botón aunque haya canal', (tester) async {
      await pumpBubble(
        tester,
        assistantCon('listo, sin archivos'),
        onOpenPlan: (_) {},
      );

      expect(
        find.byKey(MessageBubble.planButtonKey('msg_a')),
        findsNothing,
      );
    });

    testWidgets('sin canal no hay botón aunque haya ruta', (tester) async {
      await pumpBubble(tester, assistantCon('mirá C:/docs/plan.html'));

      expect(
        find.byKey(MessageBubble.planButtonKey('msg_a')),
        findsNothing,
      );
    });
  });

  group('links en el chat', () {
    test('solo http/https salen al navegador', () {
      expect(isWebLink('https://x.com/a'), isTrue);
      expect(isWebLink('http://192.168.1.22:4098/doc'), isTrue);
      expect(isWebLink('file:///C:/a.html'), isFalse);
      expect(isWebLink('file://server/x'), isFalse);
      expect(isWebLink('ftp://x/y'), isFalse);
      expect(isWebLink('C:/docs/plan.html'), isFalse);
      expect(isWebLink(null), isFalse);
      expect(isWebLink(''), isFalse);
    });

    test('encuentra la primera URL suelta', () {
      expect(
        findWebLink('mirá https://x.com/a y http://y.org/b'),
        'https://x.com/a',
      );
      expect(findWebLink('sin links'), isNull);
      expect(findWebLink('solo C:/docs/plan.html'), isNull);
    });

    testWidgets('tocar un link del markdown avisa con su href', (
      tester,
    ) async {
      final abiertas = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: MessageBubble(
              message: AssistantMessage(
                id: 'msg_a',
                time: const MessageTime(createdMs: 1, completedMs: 2),
                agent: 'build',
                model: const ModelRef(id: 'm', providerID: 'p'),
                content: const [
                  AssistantText(text: 'mirá [la doc](https://x.com/a)'),
                ],
                finish: 'stop',
              ),
              working: false,
              onOpenLink: abiertas.add,
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.textContaining('la doc', findRichText: true));
      await tester.pump();

      expect(abiertas, ['https://x.com/a']);
    });

    testWidgets('un file:// en el markdown no sale', (tester) async {
      final abiertas = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: MessageBubble(
              message: AssistantMessage(
                id: 'msg_a',
                time: const MessageTime(createdMs: 1, completedMs: 2),
                agent: 'build',
                model: const ModelRef(id: 'm', providerID: 'p'),
                content: const [
                  AssistantText(text: 'abrí [esto](file:///C:/a.html)'),
                ],
                finish: 'stop',
              ),
              working: false,
              onOpenLink: abiertas.add,
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.textContaining('esto', findRichText: true));
      await tester.pump();

      expect(abiertas, isEmpty);
    });

    testWidgets('URL suelta del usuario lleva botón Abrir enlace', (
      tester,
    ) async {
      final abiertas = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: MessageBubble(
              message: const UserMessage(
                id: 'msg_u',
                time: MessageTime(createdMs: 1, completedMs: 2),
                text: 'mirá https://x.com/a',
              ),
              working: false,
              onOpenLink: abiertas.add,
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(MessageBubble.linkButtonKey('msg_u')));
      await tester.pump();

      expect(abiertas, ['https://x.com/a']);
    });
  });

  group('PlanView widget', () {    Future<void> pumpPlan(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: PlanView(
            sourceBytes: utf8.encode(kPlan),
            fileName: 'plan-test',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('pinta título, claims y la decisión', (tester) async {
      await pumpPlan(tester);
      expect(find.text('Plan de prueba'), findsOneWidget);
      expect(find.byKey(const ValueKey('plan-claim-1')), findsOneWidget);
      expect(find.text('Cuantos por usuario?'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('plan-claim-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('plan-claim-1.2')));
      await tester.pump();
      expect(find.text('Cuantos por usuario?'), findsOneWidget);
    });

    testWidgets('responder muestra el markdown para copiar', (tester) async {
      await pumpPlan(tester);
      await tester.tap(find.text('Responder'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Tu respuesta'), findsOneWidget);
      expect(find.textContaining('# Re: Plan de prueba'), findsOneWidget);
      expect(find.text('Copiar respuesta'), findsOneWidget);
    });
  });
}
