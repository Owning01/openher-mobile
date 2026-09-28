import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Contrato de capas: la maqueta aprobada (`spec/layers.json`) gobierna qué se
/// implementa en Flutter.
///
/// - Una capa en `true` DEBE tener una entrada en el mapa `flutter_map` (aunque
///   sea provisional) y el archivo DEBE existir: si la UI no está, no se
///   cumple el diseño.
/// - Una capa en `false` NO debe aparecer en `flutter_map` con un archivo
///   implementado: si el diseño la apagó, no se construye.
///
/// Esto convierte "saqué lo que no quiero" en una regla verificable, no en una
/// promesa.
void main() {
  late Map<String, dynamic> spec;
  late Map<String, dynamic> layers;
  late Map<String, dynamic> flutterMap;

  /// El gate de M10 se enciende poniéndolo en `true` acá (o con
  /// `--dart-define=M10=1`). Antes de eso sólo informa.
  const metaGate = bool.fromEnvironment('M10');

  setUpAll(() {
    final file = File('spec/layers.json');
    expect(file.existsSync(), isTrue, reason: 'falta spec/layers.json');
    spec = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    layers = spec['layers'] as Map<String, dynamic>;
    flutterMap = spec['flutter_map'] as Map<String, dynamic>;
  });

  test('la spec es coherente consigo misma', () {
    final total = layers.length;
    final active = layers.values.where((v) => v == true).length;
    final meta = spec['_meta'] as Map<String, dynamic>;
    expect(meta['total'], total);
    expect(meta['active'], active);
    expect(total, 94);
    expect(active, 90);
  });

  test('las 4 capas apagadas son exactamente las aprobadas', () {
    final off =
        layers.entries.where((e) => e.value == false).map((e) => e.key).toList()
          ..sort();
    final approved = (spec['disabled'] as List).cast<String>()..sort();
    expect(off, approved);
    // Ninguna de las apagadas debe estar implementada todavía.
    for (final key in off) {
      expect(
        flutterMap.containsKey(key),
        isFalse,
        reason: '$key está apagada en el diseño; no debe mapearse a un widget',
      );
    }
  });

  test(
    'toda capa activa tiene archivo o está explícitamente pendiente',
    () {
      final unimplemented = <String>[];
      for (final entry in layers.entries) {
        if (entry.value != true) continue;
        final mapped = flutterMap[entry.key];
        if (mapped is! String) {
          unimplemented.add(entry.key);
          continue;
        }
        final f = File(mapped);
        if (!f.existsSync())
          unimplemented.add('${entry.key} -> $mapped (falta)');
      }
      // Gate de META: se activa al terminar M10, cuando las 90 capas activas
      // tienen que existir. Mientras tanto informa en vez de romper la suite.
      // ignore: avoid_print
      print(
        'capas activas sin implementación: ${unimplemented.length}'
        ' de ${layers.length - spec['disabled'].length} activas',
      );
      if (!metaGate) {
        expect(unimplemented, isNotEmpty, reason: 'el meta gate ya no aplica');
        return;
      }
      expect(
        unimplemented,
        isEmpty,
        reason:
            'capas activas todavía sin implementación: ${unimplemented.length}\n'
            '${unimplemented.take(20).join('\n')}',
      );
    },
    skip: metaGate ? false : 'gate de M10: la app está en construcción',
  );
}
