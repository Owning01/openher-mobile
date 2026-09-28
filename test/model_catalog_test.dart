/// El catálogo de modelos: parseo del JSON medido y de todo lo que puede
/// venir roto.
///
/// La regla que se ataca: los `fromJson` son **totales**. El catálogo son 102
/// modelos que manda el server; si **uno** viene sin `variants`, sin `limit` o
/// sin `cost`, la hoja de modelo igual tiene que pintar los otros 101. Un
/// `throw` acá es BLOCKER: la lista se cae entera y el usuario vuelve a
/// "elegí modelo" sin ver ninguno.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/domain/models/model_catalog.dart';

/// Un modelo real, **truncado** (los campos que la app no usa se cortan), tal
/// como lo devolvió `GET /api/model` contra el server de esta máquina.
///
/// Lo que importa acá es que el mapa literal de arriba (`capabilities`,
/// `compatibility`, `package`, `settings` del modelo) **excede** lo que la app
/// lee: los campos desconocidos no rompen el parseo.
const String kRealModel = '''
{"id":"space-bunny-free",
 "modelID":"space-bunny-free",
 "providerID":"opencode-go",
 "family":"longcat",
 "name":"Space Bunny Free",
 "compatibility":{"tool_call":true},
 "package":"@opencode-ai/plugin",
 "settings":{"temperature":0.7},
 "capabilities":{"tools":true,"input":["text","image"],"output":["text"]},
 "variants":[{"id":"low","settings":{"reasoningEffort":"low"}},
             {"id":"medium","settings":{"reasoningEffort":"medium"}},
             {"id":"high","settings":{"reasoningEffort":"high"}},
             {"id":"xhigh","settings":{"reasoningEffort":"xhigh"}},
             {"id":"max","settings":{"reasoningEffort":"max"}}],
 "time":{"released":1790294400000},
 "cost":[{"input":0,"output":0,"cache":{"read":0,"write":0}}],
 "status":"active",
 "enabled":true,
 "limit":{"context":1000000,"output":131072}}
''';

/// Un modelo real cuyo único nivel es `none`, con el `settings` completo que
/// trae ese caso: `reasoningSummary` e `include` son del provider y la app no
/// los interpreta, pero no puede perderlos.
const String kNoneVariantModel = '''
{"id":"muse-spark-1.3-contributor",
 "modelID":"muse-spark",
 "providerID":"opencode-go",
 "name":"Muse Spark 1.3",
 "capabilities":{"tools":true,"input":["text"],"output":["text"]},
 "variants":[{"id":"none","settings":{"reasoningEffort":"none",
                                     "reasoningSummary":"auto",
                                     "include":["reasoning.encrypted_content"]}}],
 "cost":[{"input":0.5,"output":1.5,"cache":{"read":0.1}}],
 "status":"beta",
 "enabled":true,
 "limit":{"context":200000,"output":64000}}
''';

ModelInfo parse(String json) =>
    ModelInfo.fromJson(jsonDecode(json) as Map<String, Object?>);

void main() {
  group('un modelo real, truncado', () {
    late ModelInfo model;
    setUp(() => model = parse(kRealModel));

    test('identidad y nombre', () {
      expect(model.id, 'space-bunny-free');
      expect(model.modelID, 'space-bunny-free');
      expect(model.providerID, 'opencode-go');
      expect(model.family, 'longcat');
      expect(model.name, 'Space Bunny Free');
      expect(model.ref, 'opencode-go/space-bunny-free');
    });

    test('los cinco niveles, en el orden del server, con su etiqueta', () {
      expect(model.variants.map((v) => v.id), [
        'low',
        'medium',
        'high',
        'xhigh',
        'max',
      ]);
      expect(model.variants.map((v) => v.label), [
        'Bajo',
        'Medio',
        'Alto',
        'Muy alto',
        'Máximo',
      ]);
      expect(model.variants.first.reasoningEffort, 'low');
      expect(model.hasVariants, isTrue);
    });

    test('los límites y las modalidades de entrada', () {
      expect(model.contextLimit, 1000000);
      expect(model.outputLimit, 131072);
      expect(model.inputModalities, ['text', 'image']);
    });

    test('precio 0 en los dos lados no inventa un precio', () {
      expect(model.inputCost, 0);
      expect(model.outputCost, 0);
      expect(model.priceLabel, isEmpty);
    });

    test('status y enabled', () {
      expect(model.status, 'active');
      expect(model.enabled, isTrue);
      expect(model.isAvailable, isTrue);
    });
  });

  group('el nivel `none` con su settings completo', () {
    late ModelInfo model;
    setUp(() => model = parse(kNoneVariantModel));

    test('el effort y el settings crudo se leen', () {
      expect(model.variants.single.id, 'none');
      expect(model.variants.single.reasoningEffort, 'none');
      expect(model.variants.single.label, 'Sin razonamiento');
      // Lo que la app no interpreta no se tira: queda para el día que el server
      // lo use.
      expect(model.variants.single.settings['reasoningSummary'], 'auto');
      expect(model.variants.single.settings['include'], [
        'reasoning.encrypted_content',
      ]);
    });

    test('el precio de un modelo que sí lo declara', () {
      expect(model.inputCost, 0.5);
      expect(model.outputCost, 1.5);
      expect(model.priceLabel, r'$0.50 / $1.50');
    });

    test('`beta` no es `deprecated`: el modelo se puede elegir', () {
      expect(model.status, 'beta');
      expect(model.isAvailable, isTrue);
    });
  });

  group('lo que falta, no rompe', () {
    test('sin `variants`: lista vacía, el resto intacto', () {
      final model = parse(
        '{"id":"gpt-5.1-codex","providerID":"openai","name":"GPT 5.1 Codex",'
        '"limit":{"context":400000,"output":128000}}',
      );
      expect(model.variants, isEmpty);
      expect(model.hasVariants, isFalse);
      expect(model.contextLimit, 400000);
    });

    test('sin `limit`: los límites en 0, no en infinito', () {
      final model = parse('{"id":"m","providerID":"openai","name":"M"}');
      expect(model.contextLimit, 0);
      expect(model.outputLimit, 0);
      // Y el formato no inventa una ventana: '' hace que la fila la omita.
      expect(formatLimit(model.contextLimit), isEmpty);
    });

    test('sin `cost`: precio 0, y sin precio no se muestra nada', () {
      final model = parse('{"id":"m","providerID":"openai","name":"M"}');
      expect(model.inputCost, 0);
      expect(model.outputCost, 0);
      expect(model.priceLabel, isEmpty);
    });

    test('`cost: []` es lo mismo que sin cost', () {
      final model = parse('{"id":"m","cost":[]}');
      expect(model.priceLabel, isEmpty);
    });

    test('sin `capabilities`: sin modalidades, sin romper', () {
      final model = parse('{"id":"m","name":"M"}');
      expect(model.inputModalities, isEmpty);
    });

    test('sin `name`: se muestra el id (una fila muda no sirve)', () {
      expect(parse('{"id":"muse-spark"}').name, 'muse-spark');
      expect(parse('{"id":"muse-spark","name":""}').name, 'muse-spark');
    });

    test('sin `enabled`: no se da por deshabilitado', () {
      final model = parse('{"id":"m","name":"M"}');
      expect(model.enabled, isTrue);
      expect(model.isAvailable, isTrue);
    });

    test('`{}` no tira y no afirma nada', () {
      final model = parse('{}');
      expect(model.id, '');
      expect(model.providerID, '');
      expect(model.name, '');
      expect(model.variants, isEmpty);
      expect(model.contextLimit, 0);
      expect(model.priceLabel, isEmpty);
      expect(model.ref, isEmpty);
    });
  });

  group('formas hostiles', () {
    test('`variants` que no es una lista', () {
      for (final raw in <String>[
        '"low"',
        '42',
        '{"id":"low"}',
        'null',
        'true',
      ]) {
        final model = parse('{"id":"m","variants":$raw}');
        expect(model.variants, isEmpty, reason: 'variants: $raw');
      }
    });

    test('`variants` con junk mezclado: sólo pasan los que se pueden pedir', () {
      final model = parse(
        '{"id":"m","variants":[null,42,"high",{},'
        '{"id":"high","settings":{"reasoningEffort":"high"}}]}',
      );
      // Un `{}` (sin id) no se puede mandar como `model.variant`: no se ofrece.
      expect(model.variants.map((v) => v.id), ['high']);
    });

    test('`limit` de otro tipo, o con campos de otro tipo', () {
      expect(parse('{"id":"m","limit":"nope"}').contextLimit, 0);
      expect(parse('{"id":"m","limit":42}').outputLimit, 0);
      expect(parse('{"id":"m","limit":{}}').contextLimit, 0);
      expect(parse('{"id":"m","limit":{"context":null}}').contextLimit, 0);
      // Un string numérico sí se lee (mismo criterio que el resto del dominio:
      // un campo que llegó como string en un build no es motivo para perderlo).
      expect(
        parse('{"id":"m","limit":{"context":"200000"}}').contextLimit,
        200000,
      );
      expect(parse('{"id":"m","limit":{"context":1.5}}').contextLimit, 1);
    });

    test('`cost` con junk: un precio que no es número no se castea', () {
      // Se trata como "no declarado" (0) en vez de inventar un número.
      final model = parse('{"id":"m","cost":[null,42,"0.50"],"enabled":true}');
      expect(model.inputCost, 0);
      expect(model.outputCost, 0);
      expect(model.priceLabel, isEmpty);
    });

    test('`capabilities.input` con junk se filtra', () {
      final model = parse(
        '{"id":"m","capabilities":{"input":["text",42,null,{"a":1},"image"]}}',
      );
      expect(model.inputModalities, ['text', 'image']);
    });

    test('`enabled: "false"` (string) no es un false', () {
      // `asBool` no castea: un string no es un booleano, así que el default
      // (no deshabilitado) manda. Castear "false" a true sería peor.
      final model = parse('{"id":"m","enabled":"false"}');
      expect(model.enabled, isTrue);
    });

    test('`enabled: false` sí deshabilita, y `deprecated` también', () {
      expect(parse('{"id":"m","enabled":false}').isAvailable, isFalse);
      expect(parse('{"id":"m","status":"deprecated"}').isAvailable, isFalse);
    });

    test('un nivel sin `reasoningEffort` muestra su id tal cual', () {
      final model = parse('{"id":"m","variants":[{"id":"turbo"},{"id":"x"}]}');
      expect(model.variants.map((v) => v.label), ['turbo', 'x']);
      expect(model.variants.first.reasoningEffort, isNull);
      expect(model.variants.first.settings, isEmpty);
    });

    test('`settings` de otro tipo no rompe el nivel', () {
      final model = parse(
        '{"id":"m","variants":[{"id":"high","settings":"x"}]}',
      );
      expect(model.variants.single.reasoningEffort, isNull);
      expect(model.variants.single.label, 'high');
    });
  });

  group('reasoningEffort → español', () {
    test('los seis niveles medidos', () {
      expect(thinkingLabel('none'), 'Sin razonamiento');
      expect(thinkingLabel('low'), 'Bajo');
      expect(thinkingLabel('medium'), 'Medio');
      expect(thinkingLabel('high'), 'Alto');
      expect(thinkingLabel('xhigh'), 'Muy alto');
      expect(thinkingLabel('max'), 'Máximo');
    });

    test('un nivel que la app no conoce se muestra tal cual', () {
      // El server puede agregar un nivel después: ponerle un nombre inventado
      // mentiría sobre lo que se está eligiendo.
      expect(thinkingLabel('ultra'), 'ultra');
      expect(thinkingLabel('HIGH'), 'HIGH');
      expect(thinkingLabel(''), isEmpty);
    });
  });

  group('formatLimit', () {
    test('los límites de los modelos reales', () {
      expect(formatLimit(1000000), '1M');
      expect(formatLimit(200000), '200k');
      expect(formatLimit(131072), '131k');
      expect(formatLimit(400000), '400k');
    });

    test('un decimal sólo cuando aporta', () {
      expect(formatLimit(16000), '16k');
      expect(formatLimit(15500), '15.5k');
      expect(formatLimit(1200), '1.2k');
    });

    test('sin límite declarado no inventa uno', () {
      expect(formatLimit(0), isEmpty);
      expect(formatLimit(-1), isEmpty);
    });

    test('menos de 1000 se muestra entero', () {
      expect(formatLimit(999), '999');
      expect(formatLimit(1), '1');
    });
  });

  group('formatPrice', () {
    test(r'precio de suscripción: vacío, no "$0.00"', () {
      expect(formatPrice(0), isEmpty);
    });

    test(r'dos decimales, como el prototipo ($0.50 / $1.50)', () {
      expect(formatPrice(0.5), r'$0.50');
      expect(formatPrice(10), r'$10.00');
    });

    test('debajo de un centavo no se redondea a cero', () {
      expect(formatPrice(0.0005), r'$0.0005');
    });
  });
}
