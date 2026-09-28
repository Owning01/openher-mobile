/// Tests de **chrome y markdown** de la burbuja: se monta el [MessageBubble]
/// real, sin el `ChatView` alrededor, y se mide lo que sale.
///
/// Por qué no pasan por `ChatView`: esta suite es el contrato de la burbuja con
/// la maqueta aprobada (`prototype/mobile.html`). Montarla sola deja ese
/// contrato legible —"la burbuja del usuario es `primary` a la derecha con la
/// esquina de 4, la del asistente no tiene caja, el bloque de código scrollea y
/// no se ensancha"— y no lo ata al scroll ni al viewmodel.
///
/// Los assertions son de **estilo y de geometría**, no de existencia: un test
/// que sólo comprueba que un widget aparece pasa aunque la burbuja se pinte del
/// color equivocado o reviente el ancho.
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/domain/models/errors.dart';
import 'package:openher_mobile/domain/models/message.dart';
import 'package:openher_mobile/domain/models/tool.dart';
import 'package:openher_mobile/ui/core/layer_gate.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/core/tokens.dart';
import 'package:openher_mobile/ui/features/chat/message_bubble.dart';
import 'package:openher_mobile/ui/features/chat/tool_card.dart';
import 'package:openher_mobile/ui/features/chat/turn_activity.dart';

/// Ancho del área de chat en el test. 360 es el teléfono angosto; 400 deja
/// ver los dos bordes de la burbuja sin que el texto del ejemplo se parta.
const double kWidth = 400;

const MessageTime kDone = MessageTime(createdMs: 1000, completedMs: 4600);
const MessageTime kAlive = MessageTime(createdMs: 1000);
const ModelRef kModel = ModelRef(
  id: 'deepseek-v4.1-flash',
  providerID: 'opencode-go',
);

/// Sólo las capas que toca la burbuja. `LayerCatalog.isOn` devuelve `false`
/// para una clave que no está en el mapa, así que acá van todas las que
/// construye [MessageBubble] y sus hijas.
final Map<String, bool> kLayers = <String, bool>{
  'chat.msg.user.bubble': true,
  'chat.msg.user.attachment': true,
  'chat.msg.assistant': true,
  'chat.msg.system': true,
  'chat.msg.error': true,
  'chat.msg.question': true,
  'chat.stream.text': true,
  'chat.typing': true,
  'chat.activitybox.chevron': true,
  'chat.activitybox.label': true,
  'chat.activitybox.summary': true,
  'chat.activitybox.body': true,
  'chat.toolcard.subtitle': true,
  'chat.toolcard.status': true,
  'chat.toolcard.footer': true,
};

UserMessage userMessage(String text) =>
    UserMessage(id: 'msg_u', time: kDone, text: text);

AssistantMessage assistantMessage(
  String text, {
  List<AssistantContent> content = const [],
  bool complete = true,
  OcErrorInfo? error,
}) => AssistantMessage(
  id: 'msg_a',
  time: complete ? kDone : kAlive,
  agent: 'build',
  model: kModel,
  finish: complete ? 'stop' : null,
  error: error,
  content: [
    if (text.isNotEmpty) AssistantText(text: text),
    ...content,
  ],
);

/// Un tool `shell` terminado con salida.
AssistantTool shellTool({String id = 'call_1', String output = 'ok'}) =>
    AssistantTool(
      id: id,
      name: 'shell',
      executed: false,
      state: ToolCompleted(
        statusName: 'completed',
        input: <String, Object?>{'command': 'flutter test'},
        content: [TextToolContent(text: output)],
      ),
    );

/// Monta la burbuja sola, con el tema de la app y el ancho de un teléfono.
///
/// El cuerpo va en un `SingleChildScrollView` como en el chat real: así un
/// mensaje largo no desborda la pantalla del test y el ancho disponible sigue
/// siendo el de la columna de mensajes.
Future<void> pumpBubble(
  WidgetTester tester,
  SessionMessage message, {
  bool working = false,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
      home: Scaffold(
        body: SizedBox(
          width: kWidth,
          child: SingleChildScrollView(
            child: MessageBubble(message: message, working: working),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Las cajas pintadas con un color exacto, sean `Container` o `DecoratedBox`.
///
/// Es la forma de preguntar "¿qué caja tiene el color X?" sin depender de qué
/// widget se eligió para pintarla: lo que se verifica es el color, no el tipo.
/// Se deduplica porque un `Container` con decoración construye un `DecoratedBox`
/// con **la misma** instancia, y contarlo dos veces mentiría.
List<BoxDecoration> boxesWithColor(WidgetTester tester, Color color) {
  final out = <BoxDecoration>{};
  for (final w in tester.allWidgets) {
    final Decoration? decoration = switch (w) {
      final Container c => c.decoration,
      final DecoratedBox c => c.decoration,
      _ => null,
    };
    if (decoration is BoxDecoration && decoration.color == color) {
      out.add(decoration);
    }
  }
  return out.toList();
}

/// El estilo con el que se está pintando un texto.
///
/// El texto del asistente es seleccionable, y un `SelectableText` de Flutter
/// monta un `EditableText` adentro: el mismo fragmento puede aparecer como
/// `Text` (el bloque de código, la línea de streaming) o como `EditableText`
/// (el cuerpo del markdown). El test tiene que leer los dos igual, y un
/// `Text.rich` lleva el estilo en el span y no en el widget.
TextStyle styleOf(WidgetTester tester, String text) {
  final w = tester.widget(find.text(text));
  return switch (w) {
    final Text t => t.style ?? t.textSpan?.style ?? const TextStyle(),
    final EditableText t => t.style,
    final SelectableText t => t.style ?? t.textSpan?.style ?? const TextStyle(),
    _ => fail('el fragmento "$text" no se pintó como texto'),
  };
}

void main() {
  setUp(() => LayerCatalog.debugSetInstance(LayerCatalog.forTest(kLayers)));
  tearDown(() => LayerCatalog.debugSetInstance(null));

  group('chrome', () {
    testWidgets(
      'el usuario es una burbuja `primary` a la derecha y el asistente no',
      (tester) async {
        final scheme = AppTheme.light().colorScheme;

        // ── usuario ──
        await pumpBubble(tester, userMessage('hola'));
        expect(
          boxesWithColor(tester, scheme.primary),
          hasLength(1),
          reason: 'la burbuja del usuario es el único `primary` de la pantalla',
        );
        // `.bubble` (:246-250): pegada a la derecha y con la esquina inferior
        // derecha cerrada a 4, que es lo que la hace "la última".
        final align = tester.widget<Align>(
          find
              .ancestor(of: find.text('hola'), matching: find.byType(Align))
              .first,
        );
        expect(align.alignment, Alignment.centerRight);
        final bubble = tester.getSize(
          find
              .ancestor(of: find.text('hola'), matching: find.byType(Container))
              .first,
        );
        // `max-width:88%`: es un tope. Un "hola" de 4 letras no puede ocupar el
        // 88% del ancho (que es lo que pasaba con `FractionallySizedBox`).
        expect(bubble.width, lessThan(kWidth * 0.88));
        expect(bubble.width, greaterThan(0));

        // ── asistente ──
        await pumpBubble(tester, assistantMessage('Listo.'));
        expect(
          boxesWithColor(tester, scheme.primary),
          isEmpty,
          reason:
              'el asistente no lleva caja: `.ai` es texto pelado sobre el fondo',
        );
        expect(
          find.ancestor(of: find.text('Listo.'), matching: find.byType(Align)),
          findsNothing,
          reason: 'sólo el usuario se alinea a la derecha',
        );
      },
    );

    testWidgets('el tope del 88% se respeta con un texto largo', (
      tester,
    ) async {
      final long = 'palabra ' * 200;
      await pumpBubble(tester, userMessage(long));
      final bubble = tester.getSize(
        find
            .ancestor(of: find.text(long), matching: find.byType(Container))
            .first,
      );
      expect(bubble.width, lessThanOrEqualTo(kWidth * 0.88));
    });

    testWidgets(
      'el texto del asistente y el de la burbuja usan el cuerpo de 13',
      (tester) async {
        await pumpBubble(tester, assistantMessage('Cuerpo'));
        final body = styleOf(tester, 'Cuerpo');
        expect(body.fontSize, 13);
        expect(body.height, 1.5);
      },
    );
  });

  group('markdown', () {
    /// Una línea de código más ancha que la burbuja: si el bloque no scrollea,
    /// la línea se corta o el bloque se ensancha.
    const longLine =
        'final answer = widgetState.transitionReason.pumpAndSettle(tester, timeout);';

    testWidgets('el código inline es el chip con borde y el bloque scrollea', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        assistantMessage('''
Padding de `lib/ui/core/tokens.dart` y el error sale de `flutter_test`.

```dart
$longLine
```
'''),
      );

      // ── código inline: el chip, no texto mono pelado ──
      final chip = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('lib/ui/core/tokens.dart'),
              matching: find.byType(Container),
            )
            .first,
      );
      final chipDecoration = chip.decoration! as BoxDecoration;
      expect(
        chipDecoration.border,
        isA<Border>()
            .having((b) => b.isUniform, 'uniforme', isTrue)
            .having((b) => b.top.width, 'grosor', 1),
        reason: '`code.chip` lleva borde de 1 px (:261)',
      );
      expect(chipDecoration.borderRadius, AppRadius.smAll);
      expect(chipDecoration.color, AppColors.lightCodeBg);

      // ── bloque de código: mono, 11.5, con tope de alto y scroll ──
      final code = tester.widget<Text>(find.text(longLine));
      expect(code.style?.fontFamily, 'monospace');
      expect(code.style?.fontSize, 11.5);
      expect(code.style?.height, 1.55);
      expect(code.softWrap, isFalse, reason: 'sin soft wrap la línea scrollea');

      final horizontal = tester
          .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .where((s) => s.scrollDirection == Axis.horizontal)
          .toList();
      expect(horizontal, hasLength(1), reason: 'el bloque scrollea a lo ancho');
      final blockWidth = tester.getSize(find.byWidget(horizontal.single)).width;
      expect(
        blockWidth,
        lessThanOrEqualTo(kWidth),
        reason: 'el bloque no se ensancha más que la burbuja',
      );
      // Y la línea larga sigue siendo más ancha que el bloque: no se cortó.
      expect(
        tester.getSize(find.text(longLine)).width,
        greaterThan(blockWidth),
      );
      // Tope de alto: 40 líneas no estiran la lista de mensajes. El `pre` del
      // CSS corta en 190 px (:302).
      await pumpBubble(
        tester,
        assistantMessage('```\n${List.filled(40, 'linea').join('\n')}\n```'),
      );
      expect(
        tester.getSize(find.byType(MarkdownText)).height,
        lessThanOrEqualTo(200),
      );
    });

    testWidgets(
      'encabezados, listas y citas usan los tokens, no los defaults',
      (tester) async {
        await pumpBubble(
          tester,
          assistantMessage('''
# Titulo

- uno
- dos

> una cita

| a | b |
|---|---|
| 1 | 2 |
'''),
        );
        // Un `#` tiene que ser un título: con el tema de la app (que colapsa
        // display/headline/title a 14 px) salía del mismo tamaño que el cuerpo.
        final heading = styleOf(tester, 'Titulo');
        final body = styleOf(tester, 'uno');
        expect(heading.fontSize, greaterThan(body.fontSize!));
        expect(heading.fontWeight, FontWeight.w700);

        // La viñeta es el punto de 4 px del prototipo, no el `•` de Material.
        final dots = find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).shape == BoxShape.circle &&
              w.constraints?.maxWidth == 4,
        );
        expect(
          dots,
          findsNWidgets(2),
          reason: 'una viñeta por ítem de la lista',
        );
      },
    );

    testWidgets(
      'mientras el turno escribe va texto plano y al terminar markdown',
      (tester) async {
        // Es lo que hace el cliente desktop: parsear markdown en cada delta
        // hacía parpadear los títulos y las listas a medio construir.
        await pumpBubble(
          tester,
          assistantMessage('# Titulo\n\nsigo escribiendo', complete: false),
          working: true,
        );
        expect(find.byType(MarkdownBody), findsNothing);
        expect(find.textContaining('# Titulo'), findsOneWidget);

        await pumpBubble(
          tester,
          assistantMessage('# Titulo\n\nsigo escribiendo'),
        );
        expect(find.byType(MarkdownBody), findsOneWidget);
        expect(find.text('Titulo'), findsOneWidget);
      },
    );

    testWidgets('el texto se puede seleccionar, como en el escritorio', (
      tester,
    ) async {
      await pumpBubble(tester, assistantMessage('copiame esto'));
      expect(
        find.byType(SelectableText),
        findsWidgets,
        reason: 'copiar un fragmento es el uso real de un chat de agente',
      );
    });
  });

  group('actividad y error', () {
    testWidgets('la caja de actividad colapsa y expande las ToolCards', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        assistantMessage(
          'Listo.',
          content: [
            shellTool(id: 'call_1', output: 'primer resultado'),
            shellTool(id: 'call_2', output: 'segundo resultado'),
          ],
        ),
      );

      // Plegada: sólo la fila con la categoría y el resumen del turno.
      expect(find.byKey(TurnActivityBox.headKey), findsOneWidget);
      expect(find.text('SHELL'), findsOneWidget);
      expect(find.textContaining('2 herramientas'), findsOneWidget);
      expect(find.byType(ToolCard), findsNothing);

      await tester.tap(find.byKey(TurnActivityBox.headKey));
      await tester.pump();

      expect(find.byType(ToolCard), findsNWidgets(2));
      expect(find.text('Listo.'), findsOneWidget, reason: 'el texto no se va');

      // Y la salida de una tool se abre al tocarla, con su pie.
      await tester.tap(find.byType(ToolCard).first);
      await tester.pump();
      expect(find.text('primer resultado'), findsOneWidget);
      expect(find.text('Copiar'), findsOneWidget);
      // Sin `onOpenDiff` no hay chip: una acción sin handler no se ofrece.
      expect(find.text('Abrir diff'), findsNothing);
    });

    testWidgets('el turno trabajando muestra el spinner con "· pensando"', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        assistantMessage('', content: [shellTool()], complete: false),
        working: true,
      );
      expect(find.text('· pensando'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Y con el turno vivo la caja arranca abierta: se ve trabajar.
      expect(find.byType(ToolCard), findsOneWidget);
    });

    testWidgets('el error del proveedor se pinta con el color de la maqueta', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        assistantMessage(
          'Me cortó el rate limit.',
          error: const OcErrorInfo(
            name: 'provider.auth',
            message: 'Upstream request failed (status 429)',
          ),
        ),
      );

      // `.errcard` (:269): borde `--danger`, fondo `--danger-soft`, `--r3`.
      final cards = boxesWithColor(tester, AppColors.diffDelSoft);
      expect(
        cards,
        hasLength(1),
        reason: 'el fondo es `danger-soft`, no un gris',
      );
      expect(cards.single.borderRadius, AppRadius.lgAll);
      final border = cards.single.border! as Border;
      expect(border.top.color, AppColors.diffDel, reason: 'borde de 1 px');
      expect(border.top.width, 1);

      expect(find.text('Error del proveedor'), findsOneWidget);
      expect(
        find.text('provider.auth: Upstream request failed (status 429)'),
        findsOneWidget,
      );
      // El texto parcial que quedó sigue debajo.
      expect(find.text('Me cortó el rate limit.'), findsOneWidget);
    });

    testWidgets('en oscuro el error también usa el rojo del prototipo', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        assistantMessage(
          'Cortado.',
          error: const OcErrorInfo(name: 'provider.auth', message: '429'),
        ),
        brightness: Brightness.dark,
      );
      expect(boxesWithColor(tester, AppColors.diffDelSoftDark), hasLength(1));
    });

    testWidgets(
      'una tool en error lleva el borde rojo de 2 px a la izquierda',
      (tester) async {
        final failed = AssistantTool(
          id: 'call_err',
          name: 'subagent',
          executed: false,
          state: ToolError(
            statusName: 'error',
            input: <String, Object?>{'description': 'Mapear endpoints'},
            error: const OcErrorInfo(message: 'Tool execution was interrupted'),
          ),
        );
        await pumpBubble(
          tester,
          assistantMessage('Parcial.', content: [failed], complete: false),
          working: true,
        );

        final card = boxesWithColor(tester, AppColors.lightSurface);
        expect(card, hasLength(1));
        final border = card.single.border! as Border;
        expect(border.left.width, 2, reason: '`.toolcard.err` (`:286`)');
        expect(border.left.color, AppColors.diffDel);
        expect(find.text('Error'), findsOneWidget);
      },
    );
  });
}
