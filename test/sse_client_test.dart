import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/core/network/sse_client.dart';
import 'package:openher_mobile/domain/models/event.dart';

/// Tests del parser SSE **sin server**: [parseSseChunk] es una función pura
/// sobre strings, así que cada regla del formato se testea con el frame
/// exacto que manda el server (`docs/API_CONTRACT.md` §7).

const ServerConfig kConfig = ServerConfig(
  host: '192.168.1.10',
  port: 4098,
  password: 's3cr3t',
);

void main() {
  group('parseSseChunk', () {
    test('un frame de sesión usa la clave "event" y el payload en "data"', () {
      final result = parseSseChunk(
        'data: {"id":"evt_1","event":"session.status","data":{"type":"idle"}}\n\n',
      );

      expect(result.events, hasLength(1));
      final event = result.events.single;
      expect(event.id, 'evt_1');
      expect(event.type, 'session.status');
      expect(event.data, {'type': 'idle'});
      expect(result.consumed, greaterThan(0));
      expect(result.malformed, 0);
    });

    test('": heartbeat" NO es un evento pero sí es liveness', () {
      final result = parseSseChunk(': heartbeat\n\n');

      expect(result.events, isEmpty);
      expect(result.sawComment, isTrue);
      expect(result.alive, isTrue);
      expect(result.consumed, ': heartbeat\n\n'.length);
    });

    test('un chunk con comentario + evento emite sólo el evento', () {
      final result = parseSseChunk(
        ': heartbeat\n\ndata: {"id":"evt_1","event":"session.status","data":{"type":"busy"}}\n\n',
      );

      expect(result.events, hasLength(1));
      expect(result.sawComment, isTrue);
    });

    test('el stream global (clave "type") también parsea', () {
      final result = parseSseChunk(
        'data: {"id":"evt_9","type":"session.idle","data":{"sessionID":"ses_1"}}\n\n',
      );

      expect(result.events.single.type, 'session.idle');
      expect(result.events.single.data, {'sessionID': 'ses_1'});
    });

    test('"properties" (v1) cae como fallback del payload', () {
      final result = parseSseChunk(
        'data: {"id":"evt_2","type":"message.part.updated","properties":{"text":"hola"}}\n\n',
      );

      expect(result.events.single.data, {'text': 'hola'});
    });

    test('"data" gana sobre "properties" si vienen los dos', () {
      final result = parseSseChunk(
        'data: {"id":"evt_3","type":"x","data":{"n":1},"properties":{"n":2}}\n\n',
      );

      expect(result.events.single.data, {'n': 1});
    });

    test('varios frames en un buffer => varios eventos, en orden', () {
      final result = parseSseChunk(
        'event: message\ndata: {"id":1,"event":"session.status","data":{"type":"busy"}}\n\n'
        'data: {"id":2,"event":"message.part.updated","data":{"text":"a"}}\n\n'
        ': heartbeat\n\n'
        'data: {"id":3,"event":"session.status","data":{"type":"idle"}}\n\n',
      );

      expect(result.events.map((e) => e.id), ['1', '2', '3']);
      expect(result.events.first.type, 'session.status');
      expect(result.events.last.data, {'type': 'idle'});
      expect(result.sawComment, isTrue);
      expect(
        result.maxSeq,
        3,
        reason: 'el mayor id numérico sirve para ?after=',
      );
    });

    test('un buffer a medio frame no emite nada (queda para la próxima)', () {
      const partial = 'data: {"id":"evt_1","event":"session.sta';

      final result = parseSseChunk(partial);

      expect(result.events, isEmpty);
      expect(result.consumed, 0);
      expect(result.alive, isFalse);
    });

    test('el offset evita reemitir lo ya consumido', () {
      const full =
          'data: {"id":"evt_1","event":"session.status","data":{"type":"idle"}}\n\n';

      final first = parseSseChunk(full);
      expect(first.events, hasLength(1));

      // El loop real trimmea el buffer, pero el offset es la red de seguridad:
      // si algo se reprocesa, no se vuelve a pintar el evento en la UI.
      final again = parseSseChunk(full, offset: first.consumed);

      expect(again.events, isEmpty);
      expect(again.consumed, first.consumed);
    });

    test('llegada partida: la mitad no parsea y el buffer completo sí', () {
      const full =
          'data: {"id":"evt_1","event":"session.status","data":{"type":"idle"}}\n\n';
      final cut = full.length ~/ 2;

      expect(parseSseChunk(full.substring(0, cut)).events, isEmpty);
      expect(parseSseChunk(full).events, hasLength(1));
    });

    test('data multilínea se une con \\n (spec SSE)', () {
      final result = parseSseChunk(
        'data: {"id":"evt_1",\ndata: "type":"x"}\n\n',
      );

      expect(result.events, hasLength(1));
      expect(result.events.single.type, 'x');
    });

    test('la línea "event:" del frame sirve si el JSON no trae tipo', () {
      final result = parseSseChunk(
        'event: session.status\ndata: {"id":"evt_1"}\n\n',
      );

      expect(result.events.single.type, 'session.status');
    });

    test('"event: message" (el default del server) no pisa el tipo del JSON', () {
      final result = parseSseChunk(
        'event: message\ndata: {"id":"evt_1","event":"session.status","data":{}}\n\n',
      );

      expect(result.events.single.type, 'session.status');
    });

    test('un frame con data que no es JSON se descarta sin tumbar el resto', () {
      final result = parseSseChunk(
        'data: {no json}\n\n'
        'data: {"id":"evt_2","event":"session.status","data":{"type":"idle"}}\n\n',
      );

      expect(result.events, hasLength(1));
      expect(result.events.single.id, 'evt_2');
      expect(result.malformed, 1);
    });

    test('frame vacío (línea en blanco de más) no inventa eventos', () {
      final result = parseSseChunk('\n\n\n\n');

      expect(result.events, isEmpty);
      expect(result.malformed, 0);
      expect(result.consumed, 4);
    });

    test('acepta CRLF (un server que lo mande así no rompe el parser)', () {
      final result = parseSseChunk(
        ': heartbeat\r\n\r\ndata: {"id":"evt_1","event":"session.status","data":{"type":"idle"}}\r\n\r\n',
      );

      expect(result.events, hasLength(1));
      expect(result.events.single.data, {'type': 'idle'});
      expect(result.sawComment, isTrue);
    });

    test('sin payload "data" el evento igual sale, con data vacía', () {
      final result = parseSseChunk(
        'data: {"id":"evt_1","event":"server.connected"}\n\n',
      );

      expect(result.events.single.type, 'server.connected');
      expect(result.events.single.data, isEmpty);
    });

    test('el id de la línea SSE rellena un JSON sin id', () {
      final result = parseSseChunk('id: 42\ndata: {"event":"x"}\n\n');

      expect(result.events.single.id, '42');
      expect(result.lastEventId, '42');
      expect(result.maxSeq, 42);
    });
  });

  group('predicados de evento (domain/models/event.dart)', () {
    // Codifican el contrato medido: §7.4 (fin de turno) y §7.5 (delta).
    test('isDeltaEvent: los *.delta live-only que emite :4098', () {
      // Medido en el build vivo (API_CONTRACT §7.5): el stream emite
      // `session.*.delta`, sin el prefijo `next.` del openapi más nuevo.
      expect(isDeltaEvent('session.text.delta'), isTrue);
      expect(isDeltaEvent('session.reasoning.delta'), isTrue);
      expect(isDeltaEvent('session.tool.input.delta'), isTrue);
      // El openapi más nuevo los llama `session.next.*.delta`.
      expect(isDeltaEvent('session.next.text.delta'), isTrue);
      // Un `*.ended` trae el valor completo: no es delta.
      expect(isDeltaEvent('session.text.ended'), isFalse);
      expect(isDeltaEvent('session.status'), isFalse);
      expect(isDeltaEvent(''), isFalse);
      // D1: la app es v2-only, así que el nombre v1 NO se considera delta.
      expect(
        isDeltaEvent('message.part.delta'),
        isFalse,
        reason: 'evento v1; la app móvil habla sólo v2',
      );
    });

    test('isSettledEvent: el valor completo llega en los *.ended', () {
      expect(isSettledEvent('session.text.ended'), isTrue);
      expect(isSettledEvent('session.reasoning.ended'), isTrue);
      expect(isSettledEvent('session.next.text.ended'), isTrue);
      expect(isSettledEvent('session.tool.success'), isTrue);
      expect(isSettledEvent('session.tool.failed'), isTrue);
      expect(isSettledEvent('session.step.ended'), isTrue);
      expect(isSettledEvent('session.text.delta'), isFalse);
      expect(isSettledEvent('message.part.updated'), isFalse);
    });

    test('isBusyStatus: working = busy | running | retry', () {
      for (final status in ['busy', 'running', 'retry']) {
        expect(isBusyStatus(status), isTrue, reason: status);
      }
      for (final status in ['idle', 'completed', 'done', 'error']) {
        expect(isBusyStatus(status), isFalse, reason: status);
      }
      expect(isBusyStatus(null), isFalse);
    });

    test(
      'isSettledStatus: idle = idle | completed | done | success | succeeded',
      () {
        for (final status in [
          'idle',
          'completed',
          'done',
          'success',
          'succeeded',
        ]) {
          expect(isSettledStatus(status), isTrue, reason: status);
        }
        for (final status in ['busy', 'running', 'retry']) {
          expect(isSettledStatus(status), isFalse, reason: status);
        }
      },
    );
  });

  group('SseClient: URL del stream', () {
    SseClient newClient({ServerConfig config = kConfig, String? directory}) {
      final client = SseClient(
        config: config,
        sessionId: 'ses_1',
        directory: directory,
      );
      addTearDown(client.dispose);
      return client;
    }

    test('el default es el stream GLOBAL /api/event, no el por sesión', () {
      // MEDIDO en :4098: `/api/session/{id}/event` ⇒ 404, `/api/event` ⇒ 200
      // text/event-stream. El default de la clase de red tiene que ser el que
      // anda: si fuera el por sesión, un uso directo de SseClient se caería al
      // 404 en cada reconexión y sólo funcionaría con el override del repo.
      final uri = newClient(directory: r'C:\Users\perca').streamUri();

      expect(uri.path, '/api/event');
      expect(uri.path, isNot(contains('/session/')));
      expect(
        uri.queryParameters[ServerConfig.authTokenParam],
        kConfig.authTokenQuery,
      );
      expect(
        uri.queryParameters[ServerConfig.locationParam],
        r'C:\Users\perca',
      );
    });

    test('NO manda ?after= (no hay endpoint medido que lo acepte)', () {
      // El único que aceptaría `?after=` es el stream por sesión, que da 404.
      // Un query no declarado trae un 400 del middleware, así que el cursor
      // `durable.seq` se expone (`lastSeq`) pero no se manda.
      final uri = newClient().streamUri(after: 42);

      expect(uri.queryParameters.containsKey('after'), isFalse);
    });

    test('el filtro por sesión es del cliente, no un query param', () {
      // El stream global trae TODAS las sesiones. `/api/event?sessionID=` da
      // 400 (§7.3), así que la separación tiene que ser posterior al parseo.
      final parsed = parseSseChunk(
        'data: {"id":"evt_1","type":"session.text.delta",'
        '"data":{"sessionID":"ses_1","text":"mio"}}\n\n'
        'data: {"id":"evt_2","type":"session.text.delta",'
        '"data":{"sessionID":"ses_2","text":"ajeno"}}\n\n',
        sessionId: 'ses_1',
      );

      expect(parsed.events.map((e) => e.id), ['evt_1']);
    });

    test('sin sessionId el stream global pasa entero (filtro desactivado)', () {
      final parsed = parseSseChunk(
        'data: {"id":"evt_1","type":"x","data":{"sessionID":"ses_1"}}\n\n'
        'data: {"id":"evt_2","type":"y","data":{"sessionID":"ses_2"}}\n\n',
      );

      expect(parsed.events.map((e) => e.id), ['evt_1', 'evt_2']);
    });

    test('los frames globales (sin sessionID) no se filtran', () {
      final parsed = parseSseChunk(
        'data: {"id":"evt_1","type":"server.connected"}\n\n',
        sessionId: 'ses_1',
      );

      expect(parsed.events.map((e) => e.type), ['server.connected']);
    });

    test('el filtro acepta durable.aggregateID como dueño del frame', () {
      final parsed = parseSseChunk(
        'data: {"id":"evt_1","type":"session.status",'
        '"durable":{"aggregateID":"ses_2","seq":9,"version":1}}\n\n',
        sessionId: 'ses_1',
      );

      expect(parsed.events, isEmpty);
    });

    test('NUNCA manda sessionID (el server responde 400)', () {
      final uri = newClient(directory: r'C:\p').streamUri();
      final keys = uri.queryParameters.keys.map((k) => k.toLowerCase());

      expect(keys, isNot(contains('sessionid')));
      expect(keys, containsAll(<String>['auth_token', 'location[directory]']));
    });

    test('sin auth no inventa el param', () {
      final uri = newClient(
        config: const ServerConfig(username: ''),
      ).streamUri();

      expect(
        uri.queryParameters.containsKey(ServerConfig.authTokenParam),
        isFalse,
      );
    });

    test('la URL del log sale redactada', () {
      final safe = ServerConfig.redactAuthToken(newClient().streamUri());

      expect(safe.toString().contains('s3cr3t'), isFalse);
      expect(safe.toString().contains(kConfig.authTokenQuery!), isFalse);
    });
  });

  group('SseClient: backoff', () {
    test('1s * 1.8^attempt con jitter ±30 % y tope en 30s', () {
      // Semilla fija: el jitter es aleatorio, pero acotado.
      final client = SseClient(
        config: kConfig,
        sessionId: 'ses_1',
        random: Random(7),
      );
      addTearDown(client.dispose);

      final first = client.reconnectDelay(1);
      final second = client.reconnectDelay(2);
      final capped = client.reconnectDelay(20);

      // intento 1 => 1.8s ±30 % => [1.26s, 2.34s]
      expect(first.inMilliseconds, inInclusiveRange(1260, 2340));
      // intento 2 => 3.24s ±30 % => [2.27s, 4.21s]
      expect(second.inMilliseconds, inInclusiveRange(2268, 4212));
      // intento 20 => topado en 30s ±30 % => [21s, 39s]
      expect(capped.inMilliseconds, inInclusiveRange(21000, 39000));
    });

    test(
      'el default es 5 intentos y watchdog de 45s contra heartbeats de 15s',
      () {
        final client = SseClient(config: kConfig, sessionId: 'ses_1');
        addTearDown(client.dispose);

        expect(client.maxAttempts, 5);
        expect(client.watchdog, const Duration(seconds: 45));
        expect(client.baseBackoff, const Duration(seconds: 1));
        expect(client.maxBackoff, const Duration(seconds: 30));
        expect(client.state, StreamState.polling);
      },
    );
  });

  group('cursor durable (durable.seq)', () {
    /// El frame EXACTO que manda `/api/event` en :4098.
    String durableFrame(String id, Object? seq, {String aggregate = 'ses_1'}) =>
        'data: {"id":"$id","created":1790570117526,'
        '"type":"session.text.delta",'
        '"data":{"sessionID":"$aggregate","text":"hola"},'
        '"durable":{"aggregateID":"$aggregate","seq":$seq,"version":1}}\n\n';

    test('el frame medido llena seq y createdMs del evento', () {
      final result = parseSseChunk(durableFrame('evt_0e64bb95', 431));
      final event = result.events.single;

      // El `id` medido es `evt_…`: sin leer `durable`, el cursor nunca avanza.
      expect(event.id, 'evt_0e64bb95');
      expect(event.seq, 431);
      expect(event.createdMs, 1790570117526);
      expect(event.aggregateID, 'ses_1');
      expect(result.maxSeq, 431);
    });

    test('el cursor acepta seq como string (build que serializa a mano)', () {
      final result = parseSseChunk(durableFrame('evt_a', '"88"'));

      expect(result.events.single.seq, 88);
      expect(result.maxSeq, 88);
    });

    test('maxSeq es el MAYOR seq del chunk, no el último', () {
      final result = parseSseChunk(
        durableFrame('evt_1', 431) + durableFrame('evt_2', 12),
      );

      expect(result.maxSeq, 431);
    });

    test('un frame global sin durable no inventa cursor', () {
      final result = parseSseChunk(
        'data: {"id":"evt_1","type":"server.connected"}\n\n',
      );

      expect(result.events.single.seq, isNull);
      expect(result.maxSeq, isNull);
    });

    test('el id numérico sigue sirviendo de cursor si no hay durable', () {
      // Build viejo: `id` numérico y sin bloque `durable`. No es el medido, pero
      // cuando aparece es un cursor de verdad y no debe pisarse con null.
      final result = parseSseChunk(
        'data: {"id":431,"type":"session.text.delta","data":{}}\n\n',
      );

      expect(result.maxSeq, 431);
    });

    test('durable manda sobre el id numérico si vinieran los dos', () {
      final result = parseSseChunk(
        'data: {"id":7,"type":"session.text.delta","data":{},'
        '"durable":{"aggregateID":"ses_1","seq":500,"version":1}}\n\n',
      );

      expect(result.maxSeq, 500);
    });
  });

  group('SseClient vivo: el cursor sube con los frames reales', () {
    test('lastSeq arranca en null y sigue el mayor durable.seq', () async {
      var calls = 0;
      final mock = MockClient((_) async {
        calls++;
        // Sólo la primera conexión trae el turno; después se corta, para que
        // el loop termine solo y el test no corra reconectando para siempre.
        if (calls > 1) return http.Response('', 500);
        return http.Response(
          ': heartbeat\n\n'
          'data: {"id":"evt_1","type":"session.text.delta",'
          '"data":{"sessionID":"ses_1","text":"a"},'
          '"durable":{"aggregateID":"ses_1","seq":100,"version":1}}\n\n'
          'data: {"id":"evt_2","type":"session.text.ended",'
          '"data":{"sessionID":"ses_1","text":"hola"},'
          '"durable":{"aggregateID":"ses_1","seq":431,"version":1}}\n\n',
          200,
          headers: const {'content-type': 'text/event-stream'},
        );
      });
      final sse = SseClient(
        config: kConfig,
        sessionId: 'ses_1',
        client: mock,
        maxAttempts: 2,
        baseBackoff: const Duration(milliseconds: 5),
        maxBackoff: const Duration(milliseconds: 10),
        watchdog: const Duration(seconds: 2),
      );
      addTearDown(sse.dispose);
      expect(sse.lastSeq, isNull, reason: 'nada leído todavía');

      final ids = <String>[];
      sse.events.listen((e) => ids.add(e.id));
      sse.connect();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(ids, ['evt_1', 'evt_2']);
      expect(sse.lastSeq, 431);
      // Y sigue expuesto, no enviado: la reanudación no está implementada.
      expect(sse.streamUri().queryParameters.containsKey('after'), isFalse);
    });
  });
}
