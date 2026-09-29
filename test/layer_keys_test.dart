import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Ningún `LayerGate` puede usar una clave que no esté en la spec.
///
/// ## Por qué este test existe
///
/// `LayerCatalog.isOn` es `_overrides[key] ?? _defaults[key] ?? false`: una clave
/// **desconocida devuelve `false`**, sin warning ni error. O sea que un
/// `LayerGate('sessions.appbar.subagents')` con un typo, o una capa usada antes
/// de agregarse a la spec, deja el control **invisible**: la app compila, pasa
/// los tests y anda, el botón simplemente no está.
///
/// Ya pasó varias veces en este repo (el pill de agente, el micrófono) y una con
/// este caso exacto: el botón de subagentes quedó invisible porque la clave
/// `sessions.appbar.subagents` no estaba en la spec. Es un fallo silencioso por
/// naturaleza, así que lo único que lo frena es un gate que compare el código
/// contra la spec.
///
/// La spec tiene 94 claves en `layers` (las cuenta `layer_contract_test.dart`);
/// este test no las cuenta, sólo verifica que **el código no invente claves**.
void main() {
  final root = Directory.current;
  final sep = Platform.pathSeparator;
  final specFile = File('${root.path}$sep'
      'spec${sep}layers.json');

  /// Las 94 claves de la spec. El archivo tiene cuatro secciones (`_meta`,
  /// `disabled`, `layers`, `flutter_map`); la que manda es `layers`.
  Set<String> specKeys() {
    final decoded =
        jsonDecode(specFile.readAsStringSync()) as Map<String, Object?>;
    final layers = decoded['layers'] as Map<String, Object?>;
    return layers.keys.toSet();
  }

  test('la spec existe y expone la sección `layers`', () {
    expect(specFile.existsSync(), isTrue, reason: 'falta spec/layers.json');
    expect(specKeys(), isNotEmpty);
  });

  test('ningún LayerGate ni isOn usa una clave que no esté en la spec', () {
    final known = specKeys();
    final unknown = <String, List<String>>{};

    // Se buscan **literales**: una clave armada por concatenación no se puede
    // comparar contra la spec y queda fuera del alcance de este test (no hay
    // ninguna hoy).
    final patterns = <RegExp>[
      RegExp(r"LayerGate\(\s*'([^']+)'", multiLine: true),
      RegExp(r"isOn\(\s*'([^']+)'", multiLine: true),
    ];

    for (final file
        in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final rel = file.path.replaceAll('${root.path}$sep', '');
      final src = file.readAsStringSync();
      for (final pattern in patterns) {
        for (final match in pattern.allMatches(src)) {
          final key = match.group(1)!;
          if (known.contains(key)) continue;
          unknown.putIfAbsent(key, () => <String>[]).add(rel);
        }
      }
    }

    expect(
      unknown,
      isEmpty,
      reason:
          'Estas claves no están en spec/layers.json, así que LayerGate las apaga '
          'en silencio (isOn devuelve false) y el control no aparece nunca:\n'
          '${unknown.entries.map((e) => '  ${e.key}  en ${e.value.join(', ')}').join('\n')}',
    );
  });
}
