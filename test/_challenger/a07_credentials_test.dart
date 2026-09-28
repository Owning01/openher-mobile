/// A07 — Seguridad de la credencial: la password no puede filtrarse.
///
/// Regla del repo: la contraseña **sí** se persiste (es el payload cifrado de
/// `flutter_secure_storage`) pero **jamás** aparece en un `toString()`, en un
/// log ni en un texto de UI. El stream SSE la lleva en `?auth_token=` porque
/// no se puede setear un header en un `EventSource`, así que toda URL de stream
/// tiene que pasar por `redactAuthToken` antes de imprimirse
/// (`docs/API_CONTRACT.md` §1.2: los logs de Android los lee cualquiera con
/// `adb logcat`).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/core/storage/creds_store.dart';

const String kPassword = 'P4ssw0rd-de-prueba-#1';

ServerConfig withSecret() => const ServerConfig(
  host: '192.168.1.10',
  port: 4098,
  username: 'opencode',
  password: kPassword,
);

void main() {
  group('A07.1 toString()', () {
    test('ServerConfig.toString() no tiene la password', () {
      final text = withSecret().toString();
      expect(text, isNot(contains(kPassword)));
      expect(text, isNot(contains('P4ssw0rd')));
      expect(text, contains('***'));
      expect(text, contains('192.168.1.10:4098'));
    });

    test('ServerConfig.toString() no tiene ni el base64 de la password', () {
      final config = withSecret();
      final b64 = base64Encode(utf8.encode('opencode:$kPassword'));
      expect(b64, isNotEmpty);
      expect(config.toString(), isNot(contains(b64)));
    });

    test('ServerConfig.toString() no tiene la password en base64', () {
      final b64pass = base64Encode(utf8.encode(kPassword));
      expect(withSecret().toString(), isNot(contains(b64pass)));
    });

    test('CredsStore.toString() no tiene la password', () async {
      final store = CredsStore(store: InMemorySecureStore());
      await store.write(withSecret());
      final text = store.toString();
      expect(text, isNot(contains(kPassword)));
      expect(text, contains(CredsStore.storageKey));
    });

    test('el error del server con la URL en el body se puede redactar', () {
      // `redactSecret` es la última línea de defensa: un mensaje de error que
      // venga del server y traiga la URL con `auth_token` hay que poder
      // limpiarlo.
      final url = withSecret()
          .api(
            '/event',
            query: <String, String?>{'auth_token': withSecret().authTokenQuery},
          )
          .toString();
      // El carrier es el base64 de `user:pass`, no la password suelta.
      final token = withSecret().authTokenQuery!;
      expect(url, contains(token));
      expect(url, isNot(contains(kPassword)));

      final clean = redactSecret(url, token);
      expect(clean, isNot(contains(token)));
    });
  });

  group('A07.2 redactAuthToken', () {
    test('saca el token de la URL del stream', () {
      final url = withSecret().api(
        '/event',
        query: <String, String?>{
          'auth_token': withSecret().authTokenQuery,
          'after': '431',
        },
      );
      final redacted = ServerConfig.redactAuthToken(url);
      expect(redacted.queryParameters['auth_token'], 'REDACTED');
      expect(
        redacted.toString(),
        isNot(contains(base64Encode(utf8.encode('opencode:$kPassword')))),
      );
      // El resto de la query sobrevive: la URL sigue siendo accionable.
      expect(redacted.queryParameters['after'], '431');
      expect(redacted.path, '/api/event');
    });

    test('una URL sin auth_token no cambia', () {
      final url = const ServerConfig().api('/session');
      expect(ServerConfig.redactAuthToken(url), url);
    });

    test('sin usuario (server sin password) no hay auth_token', () {
      const sinAuth = ServerConfig(username: '');
      expect(sinAuth.authTokenQuery, isNull);
      expect(sinAuth.basicAuthHeader, isNull);
      final url = sinAuth.api('/event', query: const {});
      expect(url.queryParameters.containsKey('auth_token'), isFalse);
    });

    test('redactSecret con secreto vacío no parte la cadena', () {
      expect(redactSecret('hola', ''), 'hola');
      expect(redactSecret('', ''), '');
    });

    test('redactSecret limpia todas las apariciones', () {
      expect(redactSecret('aXbXc', 'X'), 'a***b***c');
    });
  });

  group(
    'A07.3 el header y el query llevan la credencial, no la password cruda',
    () {
      test('basicAuthHeader es base64(user:pass)', () {
        final header = withSecret().basicAuthHeader!;
        expect(header, startsWith('Basic '));
        final decoded = utf8.decode(
          base64Decode(header.substring('Basic '.length)),
        );
        expect(decoded, 'opencode:$kPassword');
      });

      test('authTokenQuery NO es la password suelta', () {
        expect(withSecret().authTokenQuery, isNot(kPassword));
        expect(withSecret().authTokenQuery, isNotEmpty);
      });

      test('una password con caracteres no-ASCII no rompe el header', () {
        const unicode = ServerConfig(
          username: 'usuario',
          password: 'contraseña-ñ-🔑',
        );
        final header = unicode.basicAuthHeader!;
        expect(header, startsWith('Basic '));
        expect(
          utf8.decode(base64Decode(header.substring('Basic '.length))),
          'usuario:contraseña-ñ-🔑',
        );
      });

      test('una password con `&`, `=` y espacios sobrevive al query del SSE', () {
        const raro = ServerConfig(username: 'a b', password: 'x&y=z w+v');
        final url = raro.api(
          '/event',
          query: <String, String?>{
            'auth_token': raro.authTokenQuery,
            'location[directory]': 'C:/con espacio & ampersand',
          },
        );
        // El server decodifica con decodeURIComponent: tiene que volver igual.
        final raw = url.query.split('&');
        final tokenPart = raw.firstWhere(
          (p) => p.startsWith('${ServerConfig.authTokenParam}='),
        );
        final value = Uri.decodeComponent(
          tokenPart.split('=').skip(1).join('='),
        );
        expect(value, raro.authTokenQuery);
        // Round-trip del `deepObject`: la clave llega como `location[directory]`
        // aunque el wire la mande `%5B…%5D` (medido, §8).
        expect(
          url.queryParameters['location[directory]'],
          'C:/con espacio & ampersand',
        );
      });

      test('la clave deepObject NO viaja literal en el wire', () {
        // La doc de `ServerConfig.api` dice a la vez que "las claves se emiten
        // literales" y que "`Uri` los re-codifica a `%5B…%5D`". Lo segundo es lo
        // que pasa. Sólo importa que el round-trip de `Uri` conserve el nombre.
        final url = const ServerConfig().api(
          '/session',
          query: const {'location[directory]': '/x'},
        );
        expect(url.query, contains('%5B'), reason: 'el wire va escapado');
        expect(
          url.queryParameters['location[directory]'],
          '/x',
          reason: 'y el nombre del deepObject se preserva',
        );
      });
    },
  );

  group('A07.4 CredsStore: payload cifrado y corrupción', () {
    test(
      'lo que se guarda incluye la password (es lo que hay que cifrar)',
      () async {
        final backend = InMemorySecureStore();
        final store = CredsStore(store: backend);
        await store.write(withSecret());

        final raw = backend.values[CredsStore.storageKey]!;
        expect(raw, contains(kPassword), reason: 'el payload sí la lleva');
        expect(backend.writes, 1);
      },
    );

    test('`load()` memoiza: no relee la Keystore', () async {
      final backend = InMemorySecureStore();
      final store = CredsStore(store: backend);
      await store.write(withSecret());
      final a = await store.load();
      final b = await store.load();
      expect(identical(a, b), isTrue);
    });

    test('un payload corrupto NO revienta el arranque', () async {
      // Requisito: `read()` nunca tira. El valor (null vs defaults) depende de
      // si el JSON es un objeto.
      for (final raw in <String>[
        'no soy json',
        '[]',
        'null',
        '"texto"',
        '{}',
        '{"port":"no-es-un-numero"}',
        '{"port":null}',
        '{"port":4098.7}',
      ]) {
        final store = CredsStore(
          store: InMemorySecureStore(<String, String>{
            CredsStore.storageKey: raw,
          }),
        );
        await expectLater(
          store.read(),
          completes,
          reason: 'read() no debe lanzar con un payload corrupto',
        );
      }
    });

    test('JSON que no es un objeto ⇒ null (= conectar de nuevo)', () async {
      for (final raw in <String>[
        'no soy json',
        '[]',
        'null',
        '"texto"',
        '42',
      ]) {
        final store = CredsStore(
          store: InMemorySecureStore(<String, String>{
            CredsStore.storageKey: raw,
          }),
        );
        expect(await store.read(), isNull, reason: 'raw=$raw');
      }
    });

    test('objeto con campos raros ⇒ defaults, nunca null', () async {
      for (final raw in <String>[
        '{}',
        '{"port":"no-es-un-numero"}',
        '{"port":null}',
        '{"port":4098.7}',
        '{"host":42,"username":null}',
      ]) {
        final store = CredsStore(
          store: InMemorySecureStore(<String, String>{
            CredsStore.storageKey: raw,
          }),
        );
        final config = await store.read();
        expect(config, isNotNull, reason: 'raw=$raw');
        expect(config!.port, greaterThan(0), reason: 'el default de port');
        expect(config.host, isNotEmpty);
      }
    });

    test('read() de una clave inexistente ⇒ null', () async {
      final store = CredsStore(store: InMemorySecureStore());
      expect(await store.read(), isNull);
    });

    test(
      'el toString de una config con password vacía no dice "(none)" mal',
      () {
        expect(const ServerConfig(username: '').toString(), contains('(none)'));
      },
    );
  });
}
