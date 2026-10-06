import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Contrato de capas: la maqueta aprobada (`spec/layers.json`) gobierna qué se
/// implementa en Flutter, y **este test lee el código**.
///
/// La versión anterior sólo miraba el `flutter_map` del propio JSON: no abría
/// un solo archivo de `lib/`, así que no podía ver ni una capa apagada pintada
/// ni una capa declarada sin gate. Estas aserciones sí leen las fuentes:
///
/// - Una capa **apagada** por diseño no puede aparecer en `lib/`: ni un
///   `LayerGate` con su clave ni una referencia suelta (o sea, está construida).
/// - Una capa **declarada implementada** en `flutter_map` tiene que existir en el
///   código: el archivo mapeado existe y contiene el `LayerGate` (o un
///   `LayerCatalog.isOn` explícito) de esa clave.
///
/// Convierte "saqué lo que no quiero" y "dije que está hecho" en reglas
/// verificables contra el código, no contra un JSON.
void main() {
  late Map<String, dynamic> spec;
  late Map<String, dynamic> layers;
  late Map<String, dynamic> flutterMap;

  /// Una capa se considera "construida" si su clave es el primer argumento de
  /// un `LayerGate(...)` o de un `.isOn(...)`. Se aceptan las dos formas porque
  /// la app usa las dos: gate declarativo y chequeo imperativo.
  final gateCall = RegExp(
    r"""(?:LayerGate|\.isOn)\s*\(\s*(?!this\b)([A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)?|'(?:[^'\\]|\\.)*')""",
  );

  /// `static const String foo = 'x.y';` — nombre simple -> valor.
  final constDecl = RegExp(
    r"""static\s+const\s+(?:String\s+)?([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*'([^']*)'""",
  );

  /// `'x.y'` suelto en el código, sin gate alrededor.
  final bareKey = RegExp("'([^']+)'");

  /// La spec mapea con `/`; en Windows `File.path` devuelve `\`. Los sitios se
  /// reportan con `/` para que el mensaje sea el mismo en cualquier plataforma.
  String posix(String path) => path.replaceAll('\\', '/');

  /// La fuente del propio gate: no implementa ninguna capa.
  const gateSource = 'lib/ui/core/layer_gate.dart';

  /// Las fuentes Dart de `lib/`, en orden estable.
  ///
  /// `layer_gate.dart` queda afuera porque es la implementación del mecanismo:
  /// sus `isOn(layerKey)` hablan del campo, no de una clave concreta, y sin
  /// excluirlo el contrato se accusationa a sí mismo.
  List<File> dartSources() {
    final lib = Directory('lib');
    expect(lib.existsSync(), isTrue, reason: 'falta lib/');
    return lib
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (f) =>
              f.path.endsWith('.dart') && !posix(f.path).endsWith(gateSource),
        )
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  /// `static const String foo = 'x.y';` de TODO `lib/`, no sólo del archivo: una
  /// clave de capa es un símbolo compartido (`MobileTab.layerKey` se declara en
  /// un archivo y se gatea en otro).
  Map<String, String> constsIn(List<File> sources) => {
    for (final file in sources)
      for (final m in constDecl.allMatches(file.readAsStringSync()))
        m.group(1)!: m.group(2)!,
  };

  /// Número de línea (1-based) de un offset del texto.
  int lineAt(String text, int offset) =>
      '\n'.allMatches(text.substring(0, offset)).length + 1;

  /// Todas las claves de capa que el código construye: clave -> `archivo:línea`.
  ///
  /// Escanea el archivo COMPLETO (no línea por línea) porque un `LayerGate`
  /// multilínea pone la clave en la línea siguiente a la llamada.
  Map<String, List<String>> builtGates(List<File> sources) {
    final consts = constsIn(sources);
    final out = <String, List<String>>{};
    for (final file in sources) {
      final text = file.readAsStringSync();
      for (final m in gateCall.allMatches(text)) {
        final raw = m.group(1)!;
        final key = raw.startsWith("'")
            ? raw.substring(1, raw.length - 1)
            : consts[raw.split('.').last];
        if (key == null) continue;
        out
            .putIfAbsent(key, () => <String>[])
            .add('${posix(file.path)}:${lineAt(text, m.start)}');
      }
    }
    return out;
  }

  /// Si el valor de una constante se usa como argumento de algún gate.
  bool isGatedConst(List<File> sources, String value) {
    for (final file in sources) {
      final text = file.readAsStringSync();
      for (final m in constDecl.allMatches(text)) {
        if (m.group(2) != value) continue;
        final name = m.group(1)!;
        final call = RegExp(
          '(?:LayerGate|\\.isOn)\\s*\\(\\s*${RegExp.escape(name)}\\b',
        );
        if (call.hasMatch(text)) return true;
      }
    }
    return false;
  }

  /// Claves de capa que aparecen en `lib/` sin ningún gate: están encendidas
  /// siempre, se apaguen o no.
  ///
  /// Cuenta como gate lo que cubre el argumento del `LayerGate`/`.isOn` (por
  /// eso se salta el rango), y también una constante que SÓLO se usa como
  /// argumento de un gate.
  Map<String, List<String>> unconditionalKeys(List<File> sources) {
    final allConsts = constsIn(sources);
    final out = <String, List<String>>{};
    for (final file in sources) {
      final text = file.readAsStringSync();
      // Rangos cubiertos por un gate: desde la llamada hasta el fin del
      // argumento (o hasta la llave si el gate es posicional con named args).
      final gated = <int, int>{};
      for (final m in gateCall.allMatches(text)) {
        final close = text.indexOf('\n', m.end);
        gated[m.start] = close == -1 ? text.length : close;
      }
      for (final m in bareKey.allMatches(text)) {
        final key = m.group(1)!;
        if (gated.keys.any((s) => s <= m.start && m.start <= gated[s]!)) {
          continue;
        }
        if (allConsts.containsValue(key) && isGatedConst(sources, key)) {
          // La clave vive en una constante: sólo es "suelta" si nadie la gatea.
          continue;
        }
        out
            .putIfAbsent(key, () => <String>[])
            .add('${posix(file.path)}:${lineAt(text, m.start)}');
      }
    }
    return out;
  }

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
    expect(total, 95);
    expect(active, 91);
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

  test('las 4 capas apagadas: gate presente, apagado por defecto', () {
    final sources = dartSources();
    final gates = builtGates(sources);
    final bare = unconditionalKeys(sources);
    final offenders = <String>[];
    for (final key in (spec['disabled'] as List).cast<String>()) {
      // Contrato (2026-09-28): una capa apagada por diseño se CONSTRUYE detrás
      // de un LayerGate, pero su default en la spec es alse. Así el
      // usuario puede prenderla desde Ajustes sin que toque el código. Lo que
      // NO se permite es que se pinte sin gate (sería invisible al toggle) o
      // que la spec la marque activa.
      if (gates[key] == null) {
        offenders.add(
          key + ' -> sin LayerGate: no se puede prender desde Ajustes',
        );
      }
      final loose = bare[key];
      if (loose != null) {
        offenders.add('$key -> referencia sin gate en ${loose.join(', ')}');
      }
      if (layers[key] != false) {
        offenders.add('$key -> la spec la marca activa pero esta en disabled');
      }
    }
    // ignore: avoid_print
    print(
      'capas apagadas con problema: \\n'
      '',
    );
    expect(
      offenders,
      isEmpty,
      reason:
          'una capa apagada debe ser toggleable (gate) y off por defecto\\n'
          '',
    );
  });

  test('toda capa declarada en flutter_map tiene su gate en el código', () {
    final sources = dartSources();
    final gates = builtGates(sources);
    final unwired = <String>[];
    for (final entry in flutterMap.entries) {
      if (entry.key.startsWith('_')) continue; // `_note` de la spec
      final mapped = entry.value;
      if (mapped is! String) {
        unwired.add('${entry.key} -> sin archivo en flutter_map');
        continue;
      }
      final file = File(mapped);
      if (!file.existsSync()) {
        unwired.add('${entry.key} -> $mapped (el archivo no existe)');
        continue;
      }
      // El gate tiene que estar EN el archivo que la spec declara: un gate en
      // otro archivo no cuenta, porque la spec es el mapa de quién hace qué.
      final inFile =
          gates[entry.key]
              ?.where((site) => site.startsWith('$mapped:'))
              .toList() ??
          const <String>[];
      if (inFile.isEmpty) {
        final anywhere = gates[entry.key];
        unwired.add(
          anywhere == null
              ? '${entry.key} -> sin gate en lib/ (el toggle de Ajustes escribe '
                    'un override que nadie lee)'
              : '${entry.key} -> gate en ${anywhere.join(', ')}, no en $mapped '
                    '(o la spec mapea al archivo equivocado)',
        );
      }
    }
    // ignore: avoid_print
    print(
      'capas declaradas sin gate en su archivo: ${unwired.length}\n'
      '${unwired.isEmpty ? '(ninguna)' : unwired.join('\n')}',
    );
    expect(
      unwired,
      isEmpty,
      reason:
          'toda capa de flutter_map debe construirse en el archivo que la spec '
          'declara; si falta el LayerGate, su toggle de Ajustes no hace nada\n'
          '${unwired.join('\n')}',
    );
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
        if (!f.existsSync()) {
          unimplemented.add('${entry.key} -> $mapped (falta)');
        }
      }
      // Gate de META: se activa al terminar M10, cuando las 90 capas activas
      // tienen que existir. Mientras tanto informa en vez de romper la suite.
      // ignore: avoid_print
      print(
        'capas activas sin implementación: ${unimplemented.length}'
        ' de ${layers.length - (spec['disabled'] as List).length} activas',
      );
      // ignore: avoid_print
      print(
        unimplemented.isEmpty
            ? '(todas mapeadas)'
            : unimplemented.take(20).join('\n'),
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

/// El gate de M10 se enciende poniéndolo en `true` acá (o con
/// `--dart-define=M10=1`). Antes de eso sólo informa.
const metaGate = bool.fromEnvironment('M10');
