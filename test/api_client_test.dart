import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/domain/models/errors.dart';

/// Config de la máquina de desarrollo. `pass` no existe: el test no la necesita
/// para la API, sólo para probar el header y el token.
const ServerConfig kConfig = ServerConfig(
  host: '127.0.0.1',
  port: 4098,
  password: 's3cr3t',
);

/// Envoltura v2 medida contra el server real (`API_CONTRACT.md` §2).
const String kSessionList = '''
{"data":[{"id":"ses_1","title":"uno","agent":"build"},
         {"id":"ses_2","title":"dos","agent":"plan"}],
 "cursor":{"previous":"eyJpZCI6InNlcy0xIn0=","next":"eyJpZCI6InNlcy0yIn0="}}
''';

ApiClient clientWith(
  MockClient mock, {
  ServerConfig config = kConfig,
  Duration? timeout,
  Backoff? backoff,
}) => ApiClient(
  config: config,
  client: mock,
  timeout: timeout,
  // Sin espera real en los tests: la política se asserta aparte.
  backoff: backoff ?? ((_) => Duration.zero),
);

http.Response json(
  String body, {
  int status = 200,
  String type = 'application/json',
}) => http.Response(body, status, headers: {'content-type': type});

const String kSpaHtml =
    '<!doctype html><html><head><title>opencode</title></head><body></body></html>';

void main() {
  group('envoltura {data, cursor}', () {
    test('GET devuelve la lista y el cursor', () async {
      final api = clientWith(MockClient((_) async => json(kSessionList)));

      final body = await api.getJson('/session', query: {'limit': '2'});
      final data = ApiClient.unwrapData(body) as List<dynamic>;

      expect(data, hasLength(2));
      expect((data.first as Map<String, dynamic>)['id'], 'ses_1');
      expect(ApiClient.readCursor(body), 'eyJpZCI6InNlcy0yIn0=');
      expect(
        ApiClient.readCursor(body, direction: 'previous'),
        'eyJpZCI6InNlcy0xIn0=',
      );
    });

    test('listSessions devuelve items + cursores', () async {
      final api = clientWith(MockClient((_) async => json(kSessionList)));

      final page = await api.listSessions(limit: 2);

      expect(page.data, hasLength(2));
      expect(page.next, 'eyJpZCI6InNlcy0yIn0=');
      expect(page.previous, 'eyJpZCI6InNlcy0xIn0=');
      expect(page.hasMore, isTrue);
    });

    test('unwrapData sin sobre devuelve el cuerpo entero', () {
      expect(ApiClient.unwrapData({'sessions': <int>[]}), {
        'sessions': <int>[],
      });
      expect(ApiClient.unwrapData(null), isNull);
    });

    test('readCursor tolera sobres sin cursor', () {
      expect(ApiClient.readCursor({'data': <int>[]}), isNull);
      expect(ApiClient.readCursor(<int>[]), isNull);
      expect(ApiClient.readCursor({'cursor': <String, dynamic>{}}), isNull);
    });
  });

  group('mapeo de errores', () {
    test('401 => AuthError', () async {
      final api = clientWith(
        MockClient(
          (_) async => json(
            '{"_tag":"UnauthorizedError","message":"Authentication required"}',
            status: 401,
          ),
        ),
      );

      await expectLater(api.getJson('/session'), throwsA(isA<AuthError>()));
    });

    test(
      'el catch-all HTML 200 => HtmlFallbackError (la trampa clave)',
      () async {
        final api = clientWith(
          MockClient(
            (_) async => json(kSpaHtml, type: 'text/html; charset=utf-8'),
          ),
        );

        await expectLater(
          api.getJson('/api/health'),
          throwsA(isA<HtmlFallbackError>()),
        );
      },
    );

    test(
      'HTML sin content-type html también se detecta por el cuerpo',
      () async {
        final api = clientWith(
          MockClient((_) async => json(kSpaHtml, type: 'application/json')),
        );

        await expectLater(
          api.getJson('/ruta/inventada'),
          throwsA(isA<HtmlFallbackError>()),
        );
      },
    );

    test('500 => ApiError con el status', () async {
      var calls = 0;
      final api = clientWith(
        MockClient((_) async {
          calls++;
          return json('{"message":"boom"}', status: 500);
        }),
      );

      await expectLater(
        api.getJson('/session'),
        throwsA(isA<ApiError>().having((e) => e.statusCode, 'statusCode', 500)),
      );
      // Un 5xx es determinístico: reintentar sólo alarga la espera del error.
      expect(calls, 1);
    });

    test('excepción de red => NetworkError', () async {
      final api = clientWith(
        MockClient(
          (_) async => throw const SocketException('connection refused'),
        ),
      );

      await expectLater(api.getJson('/session'), throwsA(isA<NetworkError>()));
    });

    test('ClientException => NetworkError', () async {
      final api = clientWith(
        MockClient((_) async => throw http.ClientException('sin ruta')),
      );

      await expectLater(api.getJson('/session'), throwsA(isA<NetworkError>()));
    });

    test('deadline exceeded => NetworkError con detalle "timeout"', () async {
      final api = clientWith(
        MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return json('{}');
        }),
        timeout: const Duration(milliseconds: 40),
      );

      await expectLater(
        api.getJson('/session'),
        throwsA(
          // `message` es para el usuario (español); el detalle técnico va en
          // `detail`. Los dos tienen que ser consistentes.
          isA<NetworkError>()
              .having((e) => e.detail, 'detail', 'timeout')
              .having((e) => e.retriable, 'retriable', isTrue),
        ),
      );
    });

    test('JSON roto => ApiError, no FormatException', () async {
      final api = clientWith(
        MockClient((_) async => json('{"data": [', type: 'application/json')),
      );

      await expectLater(api.getJson('/session'), throwsA(isA<ApiError>()));
    });
  });

  group('retry', () {
    test('GET reintenta una vez ante un fallo transitorio', () async {
      var calls = 0;
      final api = clientWith(
        MockClient((_) async {
          calls++;
          if (calls == 1) throw const SocketException('reset');
          return json(kSessionList);
        }),
      );

      final body = await api.getJson('/session');

      expect(calls, 2);
      expect(ApiClient.unwrapData(body), hasLength(2));
    });

    test('GET no reintenta un tercer intento', () async {
      var calls = 0;
      final api = clientWith(
        MockClient((_) async {
          calls++;
          throw const SocketException('reset');
        }),
      );

      await expectLater(api.getJson('/session'), throwsA(isA<NetworkError>()));
      expect(calls, ApiClient.maxRetries + 1);
    });

    test(
      'POST NUNCA reintenta (un prompt repetido duplica el turno)',
      () async {
        var calls = 0;
        final api = clientWith(
          MockClient((_) async {
            calls++;
            throw const SocketException('reset');
          }),
        );

        await expectLater(
          api.postJson(
            '/session/ses_1/prompt',
            body: {
              'prompt': {'text': 'hola'},
            },
          ),
          throwsA(isA<NetworkError>()),
        );
        expect(calls, 1);
      },
    );

    test('la curva de backoff es 1s * 0.8^attempt con tope en 2s', () {
      expect(ApiClient.defaultBackoff(0), const Duration(milliseconds: 1000));
      expect(ApiClient.defaultBackoff(1), const Duration(milliseconds: 800));
      expect(ApiClient.defaultBackoff(2), const Duration(milliseconds: 640));
      // Tope: 1s * 0.8^n nunca pasa de 1s, pero el clamp queda por si cambia.
      expect(
        ApiClient.defaultBackoff(3).inMilliseconds,
        lessThanOrEqualTo(2000),
      );
    });
  });

  group('auth', () {
    test('los requests normales mandan Authorization: Basic', () async {
      late http.Request seen;
      final api = clientWith(
        MockClient((request) async {
          seen = request;
          return json('{"data":[]}');
        }),
      );

      await api.getJson('/session');

      expect(
        seen.headers['authorization'],
        'Basic ${base64Encode(utf8.encode('opencode:s3cr3t'))}',
      );
      expect(seen.headers['accept'], 'application/json');
    });

    test('basicAuthHeader es null sin usuario => server sin auth', () {
      const noUser = ServerConfig(host: '10.0.0.5', port: 4098, username: '');
      expect(noUser.basicAuthHeader, isNull);
      expect(noUser.authTokenQuery, isNull);
    });

    test('sin usuario no se manda header de auth', () async {
      late http.Request seen;
      final api = clientWith(
        MockClient((request) async {
          seen = request;
          return json('{"data":[]}');
        }),
        config: const ServerConfig(username: ''),
      );

      await api.getJson('/session');

      expect(seen.headers.containsKey('authorization'), isFalse);
    });

    test('authTokenQuery es base64(user:pass)', () {
      expect(
        kConfig.authTokenQuery,
        base64Encode(utf8.encode('opencode:s3cr3t')),
      );
      expect(kConfig.basicAuthHeader, 'Basic ${kConfig.authTokenQuery}');
    });

    test('toString NO contiene la password', () {
      final text = kConfig.toString();
      expect(text.contains('s3cr3t'), isFalse);
      expect(
        text.contains(base64Encode(utf8.encode('opencode:s3cr3t'))),
        isFalse,
      );
      expect(text, contains('opencode'));
      expect(text, contains('127.0.0.1:4098/api'));
    });

    test('toJson persiste la password (va cifrado a secure storage)', () {
      expect(kConfig.toJson()['password'], 's3cr3t');
    });

    test('redactAuthToken limpia el token de la URL', () {
      final uri = kConfig.api(
        '/session/ses_1/event',
        query: {
          'after': '12',
          ServerConfig.authTokenParam: kConfig.authTokenQuery,
        },
      );

      final safe = ServerConfig.redactAuthToken(uri);

      expect(
        uri.queryParameters[ServerConfig.authTokenParam],
        kConfig.authTokenQuery,
      );
      expect(safe.queryParameters[ServerConfig.authTokenParam], 'REDACTED');
      expect(safe.toString().contains('s3cr3t'), isFalse);
      // El resto del query sobrevive: la URL sigue siendo diagnosticable.
      expect(safe.queryParameters['after'], '12');
    });

    test('round-trip de config', () {
      expect(
        ServerConfig.fromJson(kConfig.toJson()).toJson(),
        kConfig.toJson(),
      );
      expect(ServerConfig.fromJson(const {}).port, ServerConfig.defaultPort);
      expect(ServerConfig.fromJson(const {'port': '5000'}).port, 5000);
    });
  });

  group('probe de versión', () {
    test('{"directory": …} => soportado', () async {
      final api = clientWith(
        MockClient((request) async {
          expect(request.url.path, '/api/location');
          expect(request.url.query, isEmpty);
          return json(
            '{"directory":"C:\\\\Users\\\\perca","project":{"id":"p1"}}',
          );
        }),
      );

      final location = await api.probeServer();

      expect(location['directory'], r'C:\Users\perca');
    });

    test('HTML => UnsupportedServerError (no es opencode v2)', () async {
      final api = clientWith(
        MockClient((_) async => json(kSpaHtml, type: 'text/html')),
      );

      await expectLater(
        api.probeServer(),
        throwsA(isA<UnsupportedServerError>()),
      );
    });

    test('404 => UnsupportedServerError', () async {
      final api = clientWith(
        MockClient((_) async => json('{"message":"not found"}', status: 404)),
      );

      await expectLater(
        api.probeServer(),
        throwsA(isA<UnsupportedServerError>()),
      );
    });

    test(
      '401 => UnsupportedServerError que menciona las credenciales',
      () async {
        final api = clientWith(
          MockClient((_) async => json('{"message":"nope"}', status: 401)),
        );

        await expectLater(
          api.probeServer(),
          throwsA(
            isA<UnsupportedServerError>().having(
              (e) => e.message,
              'message',
              contains('credenciales'),
            ),
          ),
        );
      },
    );

    test('JSON sin "directory" => UnsupportedServerError', () async {
      final api = clientWith(MockClient((_) async => json('{"data":[]}')));

      await expectLater(
        api.probeServer(),
        throwsA(isA<UnsupportedServerError>()),
      );
    });

    test('el probe NO reintenta (3s de deadline, un solo intento)', () async {
      var calls = 0;
      final api = clientWith(
        MockClient((_) async {
          calls++;
          throw const SocketException('sin server');
        }),
      );

      await expectLater(
        api.probeServer(),
        throwsA(isA<UnsupportedServerError>()),
      );
      expect(calls, 1);
    });
  });

  group('endpoints v2', () {
    late List<Uri> seen;
    late List<http.Request> bodies;
    late ApiClient api;

    setUp(() {
      seen = <Uri>[];
      bodies = <http.Request>[];
      api = clientWith(
        MockClient((request) async {
          seen.add(request.url);
          bodies.add(request);
          // Sobre válido: los tests de este grupo assertan URL y body, no el parseo.
          return json('{"data":{}}');
        }),
      );
    });

    test('listSessions', () async {
      await api.listSessions(
        limit: 30,
        order: 'desc',
        search: 'chat',
        cursor: 'abc',
      );

      expect(seen.single.path, '/api/session');
      expect(seen.single.queryParameters['limit'], '30');
      expect(seen.single.queryParameters['order'], 'desc');
      expect(seen.single.queryParameters['search'], 'chat');
      expect(seen.single.queryParameters['cursor'], 'abc');
    });

    test('createSession manda model {id, providerID, variant?}', () async {
      await api.createSession(
        agent: 'build',
        modelId: 'gpt-5',
        providerId: 'openai',
        variant: 'max',
      );

      final body = jsonDecode(bodies.single.body) as Map<String, dynamic>;
      expect(seen.single.path, '/api/session');
      expect(body['agent'], 'build');
      expect(body['model'], {
        'id': 'gpt-5',
        'providerID': 'openai',
        'variant': 'max',
      });
    });

    test('createSession sin modelo no manda la clave model', () async {
      await api.createSession(agent: 'plan');

      final body = jsonDecode(bodies.single.body) as Map<String, dynamic>;
      expect(body.containsKey('model'), isFalse);
    });

    test('activeSessions', () async {
      await api.activeSessions();

      expect(seen.single.path, '/api/session/active');
    });

    test('listMessages', () async {
      await api.listMessages('ses_1', limit: 30, order: 'desc', cursor: 'c1');

      expect(seen.single.path, '/api/session/ses_1/message');
      expect(seen.single.queryParameters['limit'], '30');
      expect(seen.single.queryParameters['cursor'], 'c1');
    });

    test('sendPrompt devuelve el "admitido", no el turno', () async {
      late http.Request seen2;
      final api2 = clientWith(
        MockClient((request) async {
          seen2 = request;
          return json('{"data":{"id":"msg_1","admittedSeq":9}}');
        }),
      );

      final admitted = await api2.sendPrompt('ses_1', text: 'hola');

      expect(seen2.method, 'POST');
      expect(seen2.url.path, '/api/session/ses_1/prompt');
      expect(admitted, {'id': 'msg_1', 'admittedSeq': 9});
    });

    test('sendPrompt: shape del body', () async {
      await api.sendPrompt(
        'ses_1',
        text: 'hola',
        id: 'prt_1',
        delivery: 'steer',
        files: const [
          {'uri': 'file:///a.png', 'name': 'a.png'},
        ],
      );

      final body = jsonDecode(bodies.single.body) as Map<String, dynamic>;
      expect(seen.single.path, '/api/session/ses_1/prompt');
      expect(body['id'], 'prt_1');
      expect(body['delivery'], 'steer');
      expect(body['prompt']['text'], 'hola');
      expect(body['prompt']['files'], [
        {'uri': 'file:///a.png', 'name': 'a.png'},
      ]);
    });

    test('interrupt es POST y tolera 204', () async {
      late http.Request seen2;
      final api2 = clientWith(
        MockClient((request) async {
          seen2 = request;
          return http.Response('', 204);
        }),
      );

      await api2.interrupt('ses_1');

      expect(seen2.method, 'POST');
      expect(seen2.url.path, '/api/session/ses_1/interrupt');
    });

    test('fs/list y fs/find mandan location[directory]', () async {
      await api.listDirectory(directory: r'C:\Users\perca', path: 'web/src');
      await api.findFiles(
        directory: r'C:\Users\perca',
        query: 'api',
        type: 'file',
        limit: 20,
      );

      expect(seen[0].path, '/api/fs/list');
      expect(seen[0].queryParameters['path'], 'web/src');
      expect(
        seen[0].queryParameters[ServerConfig.locationParam],
        r'C:\Users\perca',
      );
      expect(seen[1].path, '/api/fs/find');
      expect(seen[1].queryParameters['query'], 'api');
      expect(seen[1].queryParameters['type'], 'file');
      expect(seen[1].queryParameters['limit'], '20');
    });

    test('location usa el deepObject de v2', () async {
      await api.location(directory: r'C:\Users\perca');

      expect(seen.single.path, '/api/location');
      expect(
        seen.single.queryParameters[ServerConfig.locationParam],
        r'C:\Users\perca',
      );
      // El deepObject va literal en la URL (el server lo parsea por nombre).
      expect(
        seen.single.toString().contains('location%5Bdirectory%5D='),
        isTrue,
      );
    });

    test('sin directory no se manda location[directory]', () async {
      await api.listSessions();

      expect(
        seen.single.queryParameters.containsKey(ServerConfig.locationParam),
        isFalse,
      );
    });

    test('nunca se manda sessionID (el server responde 400)', () async {
      await api.listSessions();
      await api.listMessages('ses_1');
      await api.sendPrompt('ses_1', text: 'x');

      for (final uri in seen) {
        expect(
          uri.queryParameters.keys.map((k) => k.toLowerCase()),
          isNot(contains('sessionid')),
        );
      }
    });

    test('valores con espacios yreserved sobreviven el round-trip', () {
      final uri = kConfig.api(
        '/fs/list',
        query: {ServerConfig.locationParam: r'C:\mi carpeta\a+b&c'},
      );

      expect(
        uri.queryParameters[ServerConfig.locationParam],
        r'C:\mi carpeta\a+b&c',
      );
    });

    test(
      'un endpoint que promete objeto y devuelve otra cosa => ApiError',
      () async {
        final api2 = clientWith(
          MockClient((_) async => json('{"data":[1,2,3]}')),
        );

        await expectLater(
          api2.createSession(agent: 'build'),
          throwsA(isA<ApiError>()),
        );
      },
    );
  });
}
