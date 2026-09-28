import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/ui/core/layer_gate.dart';

void main() {
  // Defaults de la spec aprobada: 4 apagadas que NO se construyen.
  const defaults = <String, bool>{
    'chat.appbar.title': true,
    'chat.appbar.subtitle': false,
    'chat.composer.send': true,
    'chat.composer.tsl': false,
    'sessions.row.cost': true,
  };

  setUp(() => LayerCatalog.debugSetInstance(null));
  tearDown(() => LayerCatalog.debugSetInstance(null));

  testWidgets('LayerGate muestra lo activo y saca lo apagado', (tester) async {
    LayerCatalog.debugSetInstance(LayerCatalog.forTest(defaults));
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(
          children: [
            LayerGate('chat.appbar.title', child: Text('TITULO')),
            LayerGate('chat.appbar.subtitle', child: Text('SUBTITULO')),
            LayerGate('chat.composer.tsl', child: Text('TSL')),
            LayerGate('sessions.row.cost', child: Text('COST')),
          ],
        ),
      ),
    );
    expect(find.text('TITULO'), findsOneWidget);
    expect(find.text('COST'), findsOneWidget);
    // Las 2 capas apagadas por diseño no existen en pantalla.
    expect(find.text('SUBTITULO'), findsNothing);
    expect(find.text('TSL'), findsNothing);
  });

  testWidgets('apagar una capa en runtime la saca de la pantalla', (
    tester,
  ) async {
    final catalog = LayerCatalog.forTest(defaults);
    LayerCatalog.debugSetInstance(catalog);
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(
          children: [LayerGate('sessions.row.cost', child: Text('COST'))],
        ),
      ),
    );
    expect(find.text('COST'), findsOneWidget);
    await catalog.toggle('sessions.row.cost', false);
    await tester.pump();
    expect(find.text('COST'), findsNothing);
  });

  test('toggle sobreescribe el default y reset lo restaura', () async {
    final catalog = LayerCatalog.forTest(defaults);
    LayerCatalog.debugSetInstance(catalog);
    // Prender una capa apagada por diseño la sobreescribe.
    await catalog.toggle('chat.composer.tsl', true);
    expect(catalog.isOn('chat.composer.tsl'), isTrue);
    // Apagar una que la spec tiene activa.
    await catalog.toggle('chat.appbar.title', false);
    expect(catalog.isOn('chat.appbar.title'), isFalse);
    // Reset deja todo como el diseño aprobado.
    await catalog.resetAll();
    expect(catalog.isOn('chat.composer.tsl'), isFalse);
    expect(catalog.isOn('chat.appbar.title'), isTrue);
  });

  test('toggle de una capa desconocida lanza ArgumentError', () {
    final catalog = LayerCatalog.forTest(defaults);
    expect(() => catalog.toggle('no.existe', true), throwsArgumentError);
  });

  testWidgets('apagada, la appBar no reserva altura', (tester) async {
    final catalog = LayerCatalog.forTest(defaults);
    LayerCatalog.debugSetInstance(catalog);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // El contrato del gate: apagada, la altura preferida es 0. Antes
          // devolvía la del hijo y el Scaffold reservaba 56px de barra vacía.
          appBar: LayerGate(
            'chat.appbar.subtitle',
            child: AppBar(title: const Text('NO DEBE OCUPAR')),
          ),
          body: const Text('CUERPO'),
        ),
      ),
    );
    expect(
      tester.widget<LayerGate>(find.byType(LayerGate)).preferredSize,
      Size.zero,
    );
    expect(tester.getSize(find.byType(Scaffold).first).height, greaterThan(0));
    // Y el texto de la app bar apagada no existe en el árbol pintado.
    expect(find.text('NO DEBE OCUPAR'), findsNothing);
  });

  testWidgets('encendida, la appBar conserva la altura del hijo', (
    tester,
  ) async {
    LayerCatalog.debugSetInstance(LayerCatalog.forTest(defaults));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: LayerGate(
            'chat.appbar.title',
            child: AppBar(title: const Text('T')),
          ),
          body: const Text('CUERPO'),
        ),
      ),
    );
    expect(
      tester.widget<LayerGate>(find.byType(LayerGate)).preferredSize.height,
      kToolbarHeight,
    );
  });

  test('el asset de la spec tiene las 94 capas y las 4 apagadas', () {
    final f = File('assets/spec/layers.json');
    expect(f.existsSync(), isTrue, reason: 'falta assets/spec/layers.json');
    final raw = f.readAsStringSync();
    for (final off in const [
      'chat.appbar.subtitle',
      'chat.composer.counter',
      'chat.composer.tsl',
      'chat.header.progress',
    ]) {
      expect(raw.contains('"$off": false'), isTrue, reason: off);
    }
    expect(raw.contains('"active": 90'), isTrue);
    expect(raw.contains('"total": 94'), isTrue);
  });
}
