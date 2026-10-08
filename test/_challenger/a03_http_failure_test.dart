/// A03 — Modos de falla HTTP con `MockClient` (`package:http/testing.dart`).
///
/// Trampas medidas del server (`docs/API_CONTRACT.md` §1.6, §5):
/// * **todo path desconocido devuelve HTML 200** (catch-all del SPA);
/// * un 401 v1 tiene cuerpo **vacío**; el v2 manda `{_tag:"UnauthorizedError"}`;
/// * `content-type: application/json` no garantiza JSON válido (sierra del
///   proxy, kill -9 del server, captura de WAF).
///
/// Ningún caso puede dejar el chat sin estado: siempre tiene que haber un
/// [OchError] tipado con mensaje en español para pintar.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/domain/models/errors.dart';
import 'package:openher_mobile/ui/features/chat/chat_viewmodel.dart';

const ServerConfig kConfig = ServerConfig(host: '127.0.0.1', port: 4098);
const String kSessionId = 'ses_0acd172ac001';

/// Respuesta con un cuerpo crudo y control total de headers/status.
MockClient raw(http.Response Function() build, {Duration? delay}) =>
    MockClient((_) async {
      if (delay != null) await Future<void>.delayed(delay);
      return build();
    });

ApiClient api(MockClient client) => ApiClient(
  config: kConfig,
  client: client,
  timeout: const Duration(milliseconds: 300),
);

ChatViewModel vm(MockClient client) =>
    ChatViewModel(api(client), sessionId: kSessionId);

void main() {
  group('A03.1 401 con cuerpo vacío (v1 medido)', () {
    test('da AuthError, no FormatException', () async {
      final client = raw(
        () => http.Response(
          '',
          401,
          headers: const {'www-authenticate': 'Basic realm="opencode"'},
        ),
      );
      await expectLater(
        api(client).listMessages(kSessionId),
        throwsA(
          isA<AuthError>().having((e) => e.retriable, 'retriable', isFalse),
        ),
      );
    });

    test('el chat muestra un mensaje, no una lista vacía sin error', () async {
      final v = vm(raw(() => http.Response('', 401)));
      addTearDown(v.dispose);
      await v.load();
      expect(v.error, isNotNull);
      expect(v.error, contains('redenciales'));
      expect(v.messages, isEmpty);
      expect(v.loading, isFalse);
    });
  });

  group('A03.2 401 v2 con {_tag:UnauthorizedError}', () {
    test('da AuthError (el body no se parsea para decidir)', () async {
      final client = raw(
        () => http.Response(
          jsonEncode(<String, Object?>{'_tag': 'UnauthorizedError'}),
          401,
          headers: const {'content-type': 'application/json'},
        ),
      );
      await expectLater(
        api(client).listMessages(kSessionId),
        throwsA(isA<AuthError>()),
      );
    });
  });

  group('A03.3 HTML 200 del catch-all (§1.6)', () {
    test('da HtmlFallbackError con el path para poder actuar', () async {
      final client = raw(
        () => http.Response(
          '<!doctype html><html><body>openher</body></html>',
          200,
          headers: const {'content-type': 'text/html; charset=utf-8'},
        ),
      );
      try {
        await api(client).listMessages(kSessionId);
        fail('debía lanzar');
      } on HtmlFallbackError catch (e) {
        // El mensaje dice QUÉ ruta no existe: sin path no es accionable
        // (API_CONTRACT §1.6 dice que el 404 NO es la señal).
        expect(
          e.path,
          isNotNull,
          reason:
              'el error tiene que decir qué path falló (/session/{id}/message)',
        );
        expect(e.message, contains('/session/'));
        expect(e.retriable, isFalse);
      }
    });

    test('el chat sobrevive al catch-all (ya cubierto, se confirma)', () async {
      final v = vm(
        raw(
          () => http.Response(
            '<!doctype html><html></html>',
            200,
            headers: const {'content-type': 'text/html'},
          ),
        ),
      );
      addTearDown(v.dispose);
      await v.load();
      expect(v.error, contains('HTML'));
      expect(v.working, isFalse);
    });
  });

  group('A03.4 500 con página HTML de error', () {
    test('¿se clasifica como 5xx reintentable o como "no existe"?', () async {
      final client = raw(
        () => http.Response(
          '<!doctype html><html><body>502 Bad Gateway</body></html>',
          500,
          headers: const {'content-type': 'text/html'},
        ),
      );
      try {
        await api(client).listMessages(kSessionId);
        fail('debía lanzar');
      } on OchError catch (e) {
        // Un 502/503 de un reverse proxy es HTML y **sí** es reintentable.
        // Clasificarlo como HtmlFallbackError (retriable:false) le dice al
        // usuario "esa ruta no existe" y mata el reintento.
        expect(
          e.retriable,
          isTrue,
          reason:
              'un 5xx con HTML es un fallo transitorio, no un 404 disfrazado',
        );
        expect(e, isNot(isA<HtmlFallbackError>()));
      }
    });
  });

  group('A03.5 JSON truncado con content-type application/json', () {
    test('no revienta con FormatException crudo', () async {
      final client = raw(
        () => http.Response(
          '{"data":[',
          200,
          headers: const {'content-type': 'application/json'},
        ),
      );
      try {
        await api(client).listMessages(kSessionId);
        fail('debía lanzar');
      } on OchError catch (e) {
        expect(e, isA<ApiError>());
        expect(e.message, isNotEmpty);
      } on Object catch (e) {
        fail('un JSON truncado no debe escapar como $e');
      }
    });

    test('el chat no se queda colgado con JSON truncado', () async {
      final v = vm(
        raw(
          () => http.Response(
            '{"data":[{"id":"msg_1"',
            200,
            headers: const {'content-type': 'application/json'},
          ),
        ),
      );
      addTearDown(v.dispose);
      await v.load();
      expect(v.loading, isFalse);
      expect(v.error, isNotNull);
    });
  });

  group('A03.6 200 con `data` que no es lista', () {
    test('data como mapa ⇒ lista vacía, sin throw', () async {
      final page = await api(
        raw(
          () => http.Response(
            jsonEncode(<String, Object?>{
              'data': <String, Object?>{'oops': true},
            }),
            200,
            headers: const {'content-type': 'application/json'},
          ),
        ),
      ).listMessages(kSessionId);
      expect(page.data, isEmpty);
    });

    test('data: null ⇒ lista vacía, sin throw', () async {
      final page = await api(
        raw(
          () => http.Response(
            '{"data":null}',
            200,
            headers: const {'content-type': 'application/json'},
          ),
        ),
      ).listMessages(kSessionId);
      expect(page.data, isEmpty);
    });

    test(
      'data con items basura (null, "x", 7) ⇒ se descartan, sin throw',
      () async {
        final v = vm(
          raw(
            () => http.Response(
              jsonEncode(<String, Object?>{
                'data': <Object?>[
                  null,
                  'x',
                  7,
                  <Object?>['a'],
                ],
              }),
              200,
              headers: const {'content-type': 'application/json'},
            ),
          ),
        );
        addTearDown(v.dispose);
        await v.load();
        expect(v.messages, isEmpty);
        expect(v.error, isNull);
        expect(v.loading, isFalse);
      },
    );

    test('cursor como string en vez de objeto ⇒ sin cursor, sin throw', () {
      expect(ApiClient.readCursor(<String, Object?>{'cursor': 'x'}), isNull);
    });
  });

  group('A03.7 failures de transporte', () {
    test('SocketException ⇒ NetworkError reintentable', () async {
      final client = MockClient(
        (_) async => throw const SocketException('Connection refused'),
      );
      try {
        await api(client).listMessages(kSessionId);
        fail('debía lanzar');
      } on NetworkError catch (e) {
        expect(e.retriable, isTrue);
        expect(e.message, contains('conectar'));
      }
    });

    test('timeout ⇒ NetworkError reintentable y NO cuelga el chat', () async {
      final client = raw(
        () => http.Response('{}', 200),
        delay: const Duration(seconds: 5),
      );
      final v = vm(client);
      addTearDown(v.dispose);
      await v.load().timeout(const Duration(seconds: 8));
      expect(v.loading, isFalse);
      expect(v.error, contains('conectar'));
    });

    test(
      'un error de handshake TLS (HandshakeException) ⇒ NetworkError',
      () async {
        final client = MockClient(
          (_) async => throw const HandshakeException('cert bad'),
        );
        await expectLater(
          api(client).listMessages(kSessionId),
          throwsA(isA<NetworkError>()),
        );
      },
    );

    test('el GET reintenta UNA vez; el POST nunca', () async {
      var gets = 0;
      final client = MockClient((request) async {
        gets++;
        throw const SocketException('boom');
      });
      await expectLater(
        api(client).listMessages(kSessionId),
        throwsA(isA<NetworkError>()),
      );
      expect(gets, 2, reason: '1 intento + 1 reintento');

      var posts = 0;
      final clientPost = MockClient((request) async {
        posts++;
        throw const SocketException('boom');
      });
      await expectLater(
        api(clientPost).sendPrompt(kSessionId, text: 'hola'),
        throwsA(isA<NetworkError>()),
      );
      expect(posts, 1, reason: 'un POST reintentado duplica el prompt');
    });
  });

  group('A03.8 204 / cuerpo vacío', () {
    test('204 ⇒ null, sin throw', () async {
      final page = await api(
        raw(() => http.Response('', 204)),
      ).listMessages(kSessionId);
      expect(page.data, isEmpty);
    });

    test('200 con cuerpo vacío ⇒ lista vacía', () async {
      final page = await api(
        raw(() => http.Response('', 200)),
      ).listMessages(kSessionId);
      expect(page.data, isEmpty);
    });

    test('POST de interrupt con 204 no tira', () async {
      await expectLater(
        api(raw(() => http.Response('', 204))).interrupt(kSessionId),
        completes,
      );
    });
  });

  group('A03.9 probeServer()', () {
    test(
      '401 en el probe ⇒ UnsupportedServerError con la causa real',
      () async {
        final client = raw(
          () => http.Response(
            '',
            401,
            headers: const {'www-authenticate': 'Basic realm="x"'},
          ),
        );
        try {
          await api(client).probeServer();
          fail('debía lanzar');
        } on UnsupportedServerError catch (e) {
          expect(e.reason, contains('credenciales'));
        }
      },
    );

    test('HTML en el probe ⇒ UnsupportedServerError', () async {
      final client = raw(
        () => http.Response(
          '<!doctype html><html></html>',
          200,
          headers: const {'content-type': 'text/html'},
        ),
      );
      await expectLater(
        api(client).probeServer(),
        throwsA(isA<UnsupportedServerError>()),
      );
    });

    test('JSON sin `directory` en el probe ⇒ UnsupportedServerError', () async {
      final client = raw(
        () => http.Response(
          '{"data":{"otro":"valor"}}',
          200,
          headers: const {'content-type': 'application/json'},
        ),
      );
      await expectLater(
        api(client).probeServer(),
        throwsA(isA<UnsupportedServerError>()),
      );
    });

    test('timeout en el probe (3 s) ⇒ NetworkError, no UnsupportedServerError', () async {
      // **Adjudicado 2026-10-07.** El timeout es falta de respuesta, no
      // veredicto de versión: antes se envolvía en `UnsupportedServerError` y
      // la UI decía "no es v2" contra un server caído o inalcanzable.
      final client = raw(
        () => http.Response('{}', 200),
        delay: const Duration(seconds: 8),
      );
      final c = ApiClient(
        config: kConfig,
        client: client,
        timeout: ApiClient.probeTimeout,
      );
      await expectLater(
        c.probeServer().timeout(const Duration(seconds: 6)),
        throwsA(isA<NetworkError>()),
      );
    });
  });

  group('A03.10 detail del ApiError no filtra secretos ni se rompe', () {
    test('el detail de un 4xx con cuerpo raro es corto y no rompe', () async {
      final client = raw(
        () => http.Response(
          'x' * 5000,
          400,
          headers: const {'content-type': 'text/plain'},
        ),
      );
      try {
        await api(client).listMessages(kSessionId);
        fail('debía lanzar');
      } on ApiError catch (e) {
        expect(e.statusCode, 400);
        expect(e.detail!.length, lessThan(200));
      }
    });

    test('`message` del 4xx manda sobre el cuerpo crudo', () async {
      final client = raw(
        () => http.Response(
          jsonEncode(<String, Object?>{
            'message': 'prompt muy largo',
            'detail': 'ignorame',
          }),
          400,
          headers: const {'content-type': 'application/json'},
        ),
      );
      try {
        await api(client).sendPrompt(kSessionId, text: 'x');
        fail('debía lanzar');
      } on ApiError catch (e) {
        expect(e.detail, 'prompt muy largo');
      }
    });
  });
}
