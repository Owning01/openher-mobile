/// Tests del **agrupado por turno**: una caja por turno, no una por mensaje de
/// assistant.
///
/// Qué se verifica acá y por qué:
///
/// * la caja se junta en el **primer** mensaje del turno y lleva las tools de
///   **todos** sus mensajes (el bug reportado: el chat lleno de líneas sueltas);
/// * un prompt nuevo abre un turno nuevo (las cajas no se mezclan);
/// * un turno sin tools ni razonamiento no produce caja (ni una fila vacía);
/// * `working` lo decide el **último** assistant del turno;
/// * un resultado de shell entra al turno pero **no** posee la caja.
///
/// La segunda mitad del archivo es la prueba end-to-end del enganche: se pintan
/// las burbujas como lo haría `chat_view` (con el agrupado calculado una vez) y
/// se cuenta cuántas cajas quedan en pantalla. Sin catálogo de capas: los
/// `LayerGate` son *fail-open* sin `LayerCatalog`, que es exactamente lo que
/// quiere este test (capas encendidas, caja visible).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/domain/models/message.dart';
import 'package:openher_mobile/domain/models/tool.dart';
import 'package:openher_mobile/domain/models/turn_activity.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/features/chat/message_bubble.dart';
import 'package:openher_mobile/ui/features/chat/tool_card.dart';
import 'package:openher_mobile/ui/features/chat/turn_activity.dart';

const ModelRef _model = ModelRef(
  id: 'deepseek-v4.1-flash',
  providerID: 'opencode-go',
);

/// Turno cerrado: `completed` **y** `finish` (API_CONTRACT §7.4: con cualquiera
/// de las dos el turno terminó).
const MessageTime _done = MessageTime(
  createdMs: 1000,
  streamedMs: 1200,
  completedMs: 4600,
);

/// Turno vivo: sin `completed` y sin `finish`.
const MessageTime _alive = MessageTime(createdMs: 1000, streamedMs: 1200);

UserMessage _user(String id, String text) =>
    UserMessage(id: id, time: _done, text: text);

/// Un assistant del turno. `complete: false` lo deja abierto.
AssistantMessage _assistant(
  String id, {
  List<AssistantContent> content = const [],
  bool complete = true,
}) => AssistantMessage(
  id: id,
  time: complete ? _done : _alive,
  agent: 'build',
  model: _model,
  finish: complete ? 'stop' : null,
  content: content,
);

/// Una tool terminada. El id es el de la llamada, que es lo que la UI usa como
/// key.
AssistantTool _tool(String callId, String name, {String output = 'ok'}) =>
    AssistantTool(
      id: callId,
      name: name,
      executed: false,
      state: ToolCompleted(
        statusName: 'completed',
        input: <String, Object?>{'command': 'flutter test'},
        content: [TextToolContent(text: output)],
      ),
    );

/// Atajo de la tool `shell`, la que más se ve.
AssistantTool _shell(String callId, {String output = 'ok'}) =>
    _tool(callId, 'shell', output: output);

ShellMessage _shellResult(String id, String command) =>
    ShellMessage(id: id, time: _done, callID: 'call_x', command: command);

void main() {
  group('agrupado por turno', () {
    test('un prompt con 3 assistants deja UNA caja, en el primero', () {
      final turns = buildTurnActivities([
        _user('u1', 'busca todo'),
        _assistant('a1', content: [_shell('c1')]),
        _assistant('a2', content: [_shell('c2')]),
        _assistant('a3', content: [_shell('c3')]),
      ]);

      expect(
        turns.boxes,
        hasLength(1),
        reason: 'una caja por turno, no por mensaje',
      );
      expect(turns.boxes.keys, [
        'a1',
      ], reason: 'la caja va en el primer mensaje del turno');
      // Las tools son las del turno entero, en orden.
      expect(turns['a1']!.toolParts.map((tool) => tool.id), ['c1', 'c2', 'c3']);
      expect(
        turns.absorbedIds,
        {'a2', 'a3'},
        reason: 'los otros dos no dibujan caja: la cedieron al dueño',
      );
    });

    test('un prompt nuevo abre otra caja y no se mezclan', () {
      final turns = buildTurnActivities([
        _user('u1', 'primero'),
        _assistant('a1', content: [_shell('c1')]),
        _user('u2', 'segundo'),
        _assistant('b1', content: [_shell('c2'), _shell('c3')]),
      ]);

      expect(turns.boxes.keys.toSet(), {'a1', 'b1'});
      expect(turns['a1']!.toolParts, hasLength(1));
      expect(
        turns['b1']!.toolParts,
        hasLength(2),
        reason: 'la caja del segundo turno',
      );
    });

    test('un turno sin tools ni razonamiento no produce caja', () {
      final turns = buildTurnActivities([
        _user('u1', 'hola'),
        _assistant('a1', content: [const AssistantText(text: 'Listo.')]),
      ]);

      expect(turns.boxes, isEmpty);
      expect(
        turns['a1'],
        isNull,
        reason: 'si fuerza una entrada, el mensaje pinta una caja vacía',
      );
      // Un turno que sólo piensa sí tiene algo que mostrar.
      final thinking = buildTurnActivities([
        _user('u1', 'hola'),
        _assistant(
          'a1',
          content: [const AssistantReasoning(text: 'veo el chat')],
        ),
      ]);
      expect(thinking.boxes, hasLength(1));
    });

    test('working lo decide el ÚLTIMO assistant del turno', () {
      // El primero cerró, el segundo sigue vivo: el turno sigue corriendo.
      final alive = buildTurnActivities([
        _user('u1', 'hola'),
        _assistant('a1', content: [_shell('c1')]),
        _assistant('a2', content: [_shell('c2')], complete: false),
      ]);
      expect(alive['a1']!.working, isTrue);

      // Terminado: `finish` en el último assistant.
      final finished = buildTurnActivities([
        _user('u1', 'hola'),
        _assistant('a1', content: [_shell('c1')]),
        _assistant('a2', content: [_shell('c2')]),
      ]);
      expect(finished['a1']!.working, isFalse);
    });

    test('time.completed sin finish también cierra el turno', () {
      final withCompletedOnly = AssistantMessage(
        id: 'a2',
        // `completed` escrito pero `finish` ausente: §7.4 dice que con
        // cualquiera de los dos el turno terminó.
        time: _done,
        agent: 'build',
        model: _model,
        content: [_shell('c2')],
      );
      final turns = buildTurnActivities([
        _user('u1', 'hola'),
        _assistant('a1', content: [_shell('c1')], complete: false),
        withCompletedOnly,
      ]);
      expect(turns['a1']!.working, isFalse);
    });

    test('el resultado de shell no posee la caja', () {
      final turns = buildTurnActivities([
        _user('u1', 'corre los tests'),
        _shellResult('sh1', 'flutter test'),
        _assistant('a1', content: [_shell('c1')]),
      ]);

      expect(
        turns.boxes.keys,
        ['a1'],
        reason: 'la caja no puede vivir adentro de la píldora del comando',
      );
      expect(
        turns.isAbsorbed('sh1'),
        isFalse,
        reason: 'la píldora no tiene caja',
      );
    });

    test('un turno sin assistant no inventa dueño', () {
      // Sólo un resultado de shell: no hay burbuja donde montar la caja, y sin
      // tools tampoco habría nada que mostrar.
      final turns = buildTurnActivities([
        _user('u1', 'hola'),
        _shellResult('sh1', 'flutter test'),
      ]);
      expect(turns.boxes, isEmpty);
    });

    test('los avisos no abren ni cierran un turno', () {
      // Una píldora de sistema en el medio del turno: el segundo assistant
      // sigue siendo parte del primer turno y no arranca uno nuevo.
      final turns = buildTurnActivities([
        _user('u1', 'hola'),
        _assistant('a1', content: [_shell('c1')]),
        const SystemMessage(
          id: 'sys1',
          time: _done,
          text: 'Instructions updated',
        ),
        _assistant('a2', content: [_shell('c2')]),
      ]);
      expect(turns.boxes, hasLength(1));
      expect(turns['a1']!.toolParts, hasLength(2));
    });
  });

  group('las burbujas pintan la caja del turno', () {
    /// Un chat con el agrupado calculado una vez, como lo hace `chat_view`.
    Widget _chat(List<SessionMessage> messages, {bool working = false}) {
      final turns = buildTurnActivities(messages);
      return MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final message in messages)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: MessageBubble(
                        key: ValueKey(message.id),
                        message: message,
                        working: working,
                        turnActivity: turns[message.id],
                        absorbedActivity: turns.isAbsorbed(message.id),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('3 assistants con tools = una sola caja, con las 3 tools', (
      tester,
    ) async {
      await tester.pumpWidget(
        _chat([
          _user('u1', 'busca todo'),
          _assistant(
            'a1',
            content: [
              const AssistantText(text: 'Empiezo por el repo.'),
              _tool('c1', 'shell'),
            ],
          ),
          _assistant('a2', content: [_tool('c2', 'read')]),
          _assistant('a3', content: [_tool('c3', 'edit')]),
        ]),
      );
      await tester.pump();

      expect(find.byKey(TurnActivityBox.headKey), findsOneWidget);
      expect(find.text('Worked'), findsOneWidget, reason: 'el turno terminó');
      expect(find.textContaining('3 herramientas'), findsOneWidget);
      // Las categorías del turno entero, no sólo las del primer mensaje.
      expect(find.text('SHELL · READ · EDIT'), findsOneWidget);

      await tester.tap(find.byKey(TurnActivityBox.headKey));
      await tester.pump();

      expect(find.byType(ToolCard), findsNWidgets(3));
      for (final name in ['shell', 'read', 'edit']) {
        expect(
          find.text(name),
          findsOneWidget,
          reason: 'las tools son del turno entero',
        );
      }
    });

    testWidgets('el segundo prompt abre su propia caja', (tester) async {
      await tester.pumpWidget(
        _chat([
          _user('u1', 'primero'),
          _assistant('a1', content: [_shell('c1')]),
          _user('u2', 'segundo'),
          _assistant('b1', content: [_shell('c2'), _shell('c3')]),
        ]),
      );
      await tester.pump();

      expect(find.byKey(TurnActivityBox.headKey), findsNWidgets(2));
      expect(find.textContaining('1 herramienta'), findsOneWidget);
      expect(find.textContaining('2 herramientas'), findsOneWidget);
    });

    testWidgets('un turno sin tools no deja una caja vacía', (tester) async {
      await tester.pumpWidget(
        _chat([
          _user('u1', 'hola'),
          _assistant('a1', content: [const AssistantText(text: 'Listo.')]),
        ]),
      );
      await tester.pump();

      expect(find.byKey(TurnActivityBox.headKey), findsNothing);
      expect(find.text('Worked'), findsNothing);
      expect(
        find.text('Listo.'),
        findsOneWidget,
        reason: 'el mensaje se pinta normal',
      );
    });

    testWidgets('mientras el último assistant está vivo dice Working', (
      tester,
    ) async {
      await tester.pumpWidget(
        _chat([
          _user('u1', 'hola'),
          _assistant('a1', content: [_shell('c1')]),
          _assistant('a2', content: [_shell('c2')], complete: false),
        ], working: true),
      );
      await tester.pump();

      expect(find.byKey(TurnActivityBox.headKey), findsOneWidget);
      expect(find.text('Working'), findsOneWidget);
      expect(find.text('Worked'), findsNothing);
      expect(find.text('· pensando'), findsOneWidget);
      expect(find.textContaining('herramientas'), findsNothing);
    });

    testWidgets('el texto de los messages del turno sigue en su burbuja', (
      tester,
    ) async {
      // La caja agrupa las tools; no se traga el texto: cada respuesta sigue
      // donde el usuario la espera, debajo de la caja.
      await tester.pumpWidget(
        _chat([
          _user('u1', 'hola'),
          _assistant(
            'a1',
            content: [
              const AssistantText(text: 'Primer tramo'),
              _shell('c1'),
            ],
          ),
          _assistant(
            'a2',
            content: [const AssistantText(text: 'Segundo tramo')],
          ),
        ]),
      );
      await tester.pump();

      expect(find.text('Primer tramo'), findsOneWidget);
      expect(find.text('Segundo tramo'), findsOneWidget);
      expect(find.byKey(TurnActivityBox.headKey), findsOneWidget);
    });
  });
}
