import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/ui/core/app_icon.dart';
import 'package:openher_mobile/ui/core/layer_gate.dart';
import 'package:openher_mobile/ui/features/chat/composer.dart';

/// El bug reportado: el pill de agente usaba `onPickModel`, así que los dos
/// abrian la hoja de modelo y no había forma de elegir un agente. Estos tests
/// fijan que cada pill vaya a su callback, y que el rótulo sea el que se le
/// pasó en vez de "Elegir".
void main() {
  setUp(() {
    LayerCatalog.debugSetInstance(
      LayerCatalog.forTest({
        'chat.composer.agent': true,
        'chat.composer.model': true,
        'chat.composer.modelbar': true,
        'chat.composer.input': true,
        'chat.composer.attach': true,
        'chat.composer.mic': true,
        'chat.composer.send': true,
        'chat.composer.ctx': true,
      }),
    );
  });
  tearDown(() => LayerCatalog.debugSetInstance(null));

  Future<void> pumpComposer(
    WidgetTester tester, {
    required VoidCallback onPickModel,
    required VoidCallback onPickAgent,
    String? modelLabel,
    String? agentLabel,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            working: false,
            canSend: false,
            modelLabel: modelLabel,
            agentLabel: agentLabel,
            onPickModel: onPickModel,
            onPickAgent: onPickAgent,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('el pill de modelo abre la hoja de modelo', (tester) async {
    var models = 0;
    var agents = 0;
    await pumpComposer(
      tester,
      onPickModel: () => models++,
      onPickAgent: () => agents++,
      modelLabel: 'space-bunny-free',
    );
    await tester.tap(find.byKey(ChatComposer.modelPillKey));
    await tester.pump();
    expect(models, 1);
    expect(agents, 0);
  });

  testWidgets('el pill de agente abre la hoja de AGENTE, no la de modelo', (
    tester,
  ) async {
    var models = 0;
    var agents = 0;
    await pumpComposer(
      tester,
      onPickModel: () => models++,
      onPickAgent: () => agents++,
      agentLabel: 'Plan',
    );
    await tester.tap(find.byKey(ChatComposer.agentPillKey));
    await tester.pump();
    expect(agents, 1, reason: 'este es el bug: los dos iban al mismo lado');
    expect(models, 0);
  });

  testWidgets('los rótulos muestran lo elegido, no "Elegir"', (tester) async {
    await pumpComposer(
      tester,
      onPickModel: () {},
      onPickAgent: () {},
      modelLabel: 'space-bunny-free',
      agentLabel: 'Plan',
    );
    expect(find.text('space-bunny-free'), findsOneWidget);
    expect(find.text('Plan'), findsOneWidget);
  });

  testWidgets('sin elección, los rótulos inviting a elegir', (tester) async {
    await pumpComposer(tester, onPickModel: () {}, onPickAgent: () {});
    expect(find.text('Elegir modelo'), findsOneWidget);
    expect(find.text('Elegir agente'), findsOneWidget);
  });

  group('áreas táctiles de 48 (glifo igual)', () {
    Future<void> pumpConAdjunto(WidgetTester tester) async {
      // La tira de adjuntos vive tras su propio gate: sin él no hay X.
      LayerCatalog.debugSetInstance(
        LayerCatalog.forTest({
          'chat.composer.agent': true,
          'chat.composer.model': true,
          'chat.composer.modelbar': true,
          'chat.composer.input': true,
          'chat.composer.attach': true,
          'chat.composer.attachments': true,
          'chat.composer.mic': true,
          'chat.composer.send': true,
          'chat.composer.ctx': true,
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatComposer(
              working: false,
              canSend: true,
              attachments: const [
                ComposerAttachment(name: 'foto.png', uri: 'data:x'),
              ],
              onRemoveAttachment: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('adjuntar y micrófono miden 48 con glifo de 20', (
      tester,
    ) async {
      await pumpConAdjunto(tester);
      expect(
        tester.widget<AppIconButton>(find.byKey(ChatComposer.attachKey)).tapSize,
        48,
      );
      expect(
        tester.widget<AppIconButton>(find.byKey(ChatComposer.micKey)).tapSize,
        48,
      );
      expect(
        tester.widget<AppIconButton>(find.byKey(ChatComposer.attachKey)).size,
        20,
      );
    });

    testWidgets('enviar mide 48 con glifo de 16', (tester) async {
      await pumpConAdjunto(tester);
      expect(tester.getSize(find.byKey(ChatComposer.sendKey)), const Size(48, 48));
    });

    testWidgets('la X del adjunto es caja de 48 con nombre', (tester) async {
      await pumpConAdjunto(tester);
      final etiqueta = find.bySemanticsLabel('Quitar adjunto foto.png');
      expect(etiqueta, findsOneWidget);
      expect(tester.getSize(etiqueta), const Size(48, 48));
    });
  });
}
