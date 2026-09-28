/// El repositorio del catálogo: qué pega, qué cachea y qué tira.
///
/// La regla que se ataca: **un criterio de caché, el TTL**. Mientras el
/// catálogo está en memoria no se vuelve a pegarle al server; pasado el TTL se
/// relee. Y lo que se cachea nunca es un fallo: si el server no respondió, la
/// siguiente llamada reintenta (si no, la hoja se queda "sin modelos" hasta que
/// venza el TTL).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/data/repositories/catalog_repository.dart';
import 'package:openher_mobile/domain/models/errors.dart';
import 'package:openher_mobile/domain/models/model_catalog.dart';

const ServerConfig kConfig = ServerConfig(
  host: '127.0.0.1',
  port: 4098,
  password: 's3cr3t',
);

/// El catch-all del SPA: todo path desconocido devuelve HTML 200.
const String kSpaHtml =
    '<!doctype html><html><head><title>opencode</title></head><body></body>'
    '</html>';

/// Un modelo del catálogo, en la forma medida.
String modelJson({
  String id = 'space-bunny-free',
  String modelID = 'space-bunny-free',
  String providerID = 'opencode-go',
  String name = 'Space Bunny Free',
  bool withVariants = true,
}) => jsonEncode({
  'id': id,
  'modelID': modelID,
  'providerID': providerID,
  'name': name,
  if (withVariants)
    'variants': [
      {
        'id': 'low',
        'settings': {'reasoningEffort': 'low'},
      },
      {
        'id': 'max',
        'settings': {'reasoningEffort': 'max'},
      },
    ],
  'cost': [
    {'input': 0, 'output': 0},
  ],
  'status': 'active',
  'enabled': true,
  'limit': {'context': 1000000, 'output': 131072},
});

/// El sobre real de `/api/model`: `{location, data}`.
String catalogJson(List<Object?> models) => jsonEncode({
  'location': {'directory': 'G:/code/openher-mobile'},
  'data': models,
});

http.Response json(
  String body, {
  int status = 200,
  String type = 'application/json',
}) => http.Response(body, status, headers: {'content-type': type});

/// Un server falso que **cuenta** los requests: la caché se asserta por
/// cantidad de requests, no por reloj.
class FakeServer {
  FakeServer(this.respond);

  final Future<http.Response> Function(http.Request request) respond;
  final List<http.Request> requests = <http.Request>[];

  int get calls => requests.length;

  late final http.Client client = MockClient((request) {
    requests.add(request);
    return respond(request);
  });
}

CatalogRepository repoWith(
  FakeServer server, {
  Duration ttl = CatalogRepository.defaultTtl,
  DateTime Function()? now,
}) => CatalogRepository(
  ApiClient(
    config: kConfig,
    client: server.client,
    // Sin espera real entre reintentos: la política se asserta en otro lado.
    backoff: (_) => Duration.zero,
  ),
  ttl: ttl,
  now: now,
);

void main() {
  group('el request', () {
    test('pega a GET /api/model con la credencial', () async {
      final server = FakeServer(
        (_) async => json(catalogJson([jsonDecode(modelJson())])),
      );
      final repo = repoWith(server);

      await repo.models();

      expect(server.calls, 1);
      expect(server.requests.single.method, 'GET');
      expect(server.requests.single.url.path, '/api/model');
      // Sin credencial el server responde 401: la hoja quedaría en error
      // siempre.
      expect(
        server.requests.single.headers['authorization'],
        startsWith('Basic '),
      );
    });

    test('mapea los modelos del sobre y descarta lo que no es mapa', () async {
      final server = FakeServer(
        (_) async => json('{"data":[${modelJson()},null,42,"x"]}'),
      );
      final repo = repoWith(server);

      final List<ModelInfo> models = await repo.models();

      expect(models, hasLength(1));
      expect(models.single.id, 'space-bunny-free');
      expect(models.single.providerID, 'opencode-go');
      expect(models.single.variants.map((v) => v.id), ['low', 'max']);
      expect(models.single.contextLimit, 1000000);
    });

    test('`data` que no es una lista: catálogo vacío, sin tirar', () async {
      final repo = repoWith(
        FakeServer((_) async => json('{"data":{"id":"no-soy-una-lista"}}')),
      );

      expect(await repo.models(), isEmpty);
    });
  });

  group('la caché', () {
    test('dentro del TTL no se vuelve a pegar al server', () async {
      var clock = DateTime(2026, 9, 28, 12);
      final server = FakeServer(
        (_) async => json(catalogJson([jsonDecode(modelJson())])),
      );
      final repo = repoWith(server, now: () => clock);

      expect(await repo.models(), hasLength(1));
      expect(await repo.models(), hasLength(1));
      expect(await repo.models(), hasLength(1));
      expect(server.calls, 1);

      // 4:59: todavía dentro.
      clock = clock.add(const Duration(minutes: 4, seconds: 59));
      await repo.models();
      expect(server.calls, 1);
    });

    test('pasado el TTL se relee', () async {
      var clock = DateTime(2026, 9, 28, 12);
      final server = FakeServer(
        (_) async => json(catalogJson([jsonDecode(modelJson())])),
      );
      final repo = repoWith(server, now: () => clock);

      await repo.models();
      clock = clock.add(const Duration(minutes: 5));
      await repo.models();

      expect(server.calls, 2);
    });

    test('el TTL son 5 minutos por defecto', () {
      expect(CatalogRepository.defaultTtl, const Duration(minutes: 5));
    });

    test('dos llamadas en vuelo comparten un solo request', () async {
      final server = FakeServer(
        (_) async => json(catalogJson([jsonDecode(modelJson())])),
      );
      final repo = repoWith(server);

      final first = repo.models();
      final second = repo.models();
      final [a, b] = await Future.wait([first, second]);

      expect(server.calls, 1);
      // La misma lista: la segunda llamada no armó la suya.
      expect(identical(a, b), isTrue);
    });

    test('un fallo NO se cachea: la siguiente llamada reintenta', () async {
      var fail = true;
      final server = FakeServer((_) async {
        if (fail) return json('{"message":"se rompió"}', status: 500);
        return json(catalogJson([jsonDecode(modelJson())]));
      });
      final repo = repoWith(server);

      await expectLater(repo.models(), throwsA(isA<ApiError>()));
      fail = false;

      // Si el error quedara cacheado, esta llamada volvería a fallar sin tocar
      // la red y la hoja quedaría "sin modelos" hasta que venza el TTL.
      expect(await repo.models(), hasLength(1));
      expect(server.calls, 2);
    });
  });

  group('los errores de red llegan tipados', () {
    test('500 es ApiError', () async {
      final repo = repoWith(FakeServer((_) async => json('nope', status: 500)));
      await expectLater(
        repo.models(),
        throwsA(isA<ApiError>().having((e) => e.statusCode, 'statusCode', 500)),
      );
    });

    test('401 es AuthError (credenciales, no catálogo vacío)', () async {
      final repo = repoWith(
        FakeServer((_) async => json('{"message":"no"}', status: 401)),
      );
      await expectLater(repo.models(), throwsA(isA<AuthError>()));
    });

    test(
      'el catch-all del SPA es HtmlFallbackError, no un jsonDecode roto',
      () async {
        final repo = repoWith(
          FakeServer((_) async => json(kSpaHtml, type: 'text/html')),
        );
        await expectLater(
          repo.models(),
          throwsA(
            isA<HtmlFallbackError>().having((e) => e.path, 'path', '/model'),
          ),
        );
      },
    );

    test('findModel también propaga el error (no devuelve null)', () async {
      final repo = repoWith(FakeServer((_) async => json('nope', status: 500)));
      // Devolver null haría creer que el modelo no existe en el catálogo: es un
      // "no sé", no un "no".
      await expectLater(
        repo.findModel(providerId: 'opencode-go', modelId: 'space-bunny-free'),
        throwsA(isA<ApiError>()),
      );
    });
  });

  group('findModel', () {
    late FakeServer server;
    late CatalogRepository repo;

    setUp(() {
      server = FakeServer(
        (_) async => json(
          catalogJson([
            jsonDecode(modelJson(id: 'space-bunny-free')),
            jsonDecode(
              modelJson(
                id: 'muse-spark',
                modelID: 'muse-spark-1.3',
                providerID: 'opencode-zen',
                name: 'Muse Spark',
              ),
            ),
            jsonDecode(
              modelJson(
                id: 'sin-variantes',
                modelID: 'gpt-5.1',
                providerID: 'openai',
                name: 'GPT 5.1',
                withVariants: false,
              ),
            ),
          ]),
        ),
      );
      repo = repoWith(server);
    });

    test('encuentra por el par provider/id', () async {
      final found = await repo.findModel(
        providerId: 'opencode-go',
        modelId: 'space-bunny-free',
      );
      expect(found?.name, 'Space Bunny Free');
      expect(found?.hasVariants, isTrue);
    });

    test('cae al `modelID` si el id del catálogo no está', () async {
      final found = await repo.findModel(
        providerId: 'opencode-zen',
        modelId: 'muse-spark-1.3',
      );
      expect(found?.id, 'muse-spark');
    });

    test('un modelo sin niveles se encuentra igual', () async {
      final found = await repo.findModel(
        providerId: 'openai',
        modelId: 'sin-variantes',
      );
      expect(found?.id, 'sin-variantes');
      expect(found?.variants, isEmpty);
    });

    test('otro provider con el mismo id no cuenta', () async {
      // `space-bunny-free` existe, pero en `opencode-go`: pedirlo en `openai`
      // no es el mismo modelo.
      expect(
        await repo.findModel(providerId: 'openai', modelId: 'space-bunny-free'),
        isNull,
      );
    });

    test('un id que no existe devuelve null, no tira', () async {
      expect(
        await repo.findModel(providerId: 'openai', modelId: 'no-existe'),
        isNull,
      );
      expect(await repo.findModel(providerId: '', modelId: ''), isNull);
    });

    test('catálogo vacío: null, no una excepción', () async {
      final empty = repoWith(FakeServer((_) async => json('{"data":[]}')));
      expect(
        await empty.findModel(
          providerId: 'opencode-go',
          modelId: 'space-bunny-free',
        ),
        isNull,
      );
    });

    test('reusa la caché: buscar no es un request extra', () async {
      await repo.findModel(
        providerId: 'opencode-go',
        modelId: 'space-bunny-free',
      );
      await repo.findModel(
        providerId: 'opencode-go',
        modelId: 'space-bunny-free',
      );
      expect(server.calls, 1);
    });
  });

  group('cuando el id de un modelo es el modelID de otro', () {
    test('gana el id exacto (es el que se manda al crear la sesión)', () async {
      final repo = repoWith(
        FakeServer(
          (_) async => json(
            catalogJson([
              // Este modelo se llama `b` en el provider...
              jsonDecode(
                modelJson(id: 'a', modelID: 'b', providerID: 'openai'),
              ),
              // ...y éste se llama `a`.
              jsonDecode(
                modelJson(id: 'b', modelID: 'a', providerID: 'openai'),
              ),
            ]),
          ),
        ),
      );

      final found = await repo.findModel(providerId: 'openai', modelId: 'b');
      expect(found?.id, 'b');
    });
  });
}
