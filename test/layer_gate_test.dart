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
