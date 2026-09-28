/// A04 — Parser SSE: chunks partiños, basura y la evidencia de reanudación.
///
/// Trampas medidas (`docs/API_CONTRACT.md` §7.2):
/// * el heartbeat v2 es un **comentario** `: heartbeat`, no un evento;
/// * el frame es `{id, type, data}` con `id` del tipo `evt_…` (string) y el
///   cursor numérico en `durable.seq` (D3bis: "se usa `durable.seq` para saber
///   hasta dónde se leyó");
/// * no hay `Last-Event-ID`: la reanudación es `?after=<seq>`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/core/network/sse_client.dart';

const ServerConfig kConfig = ServerConfig(
  host: '127.0.0.1',
  port: 4098,
  username: 'opencode',
  password: 's3cr3t',
);

/// Frame v2 **medido**: `id` string `evt_…`, cursor numérico en `durable.seq`.
String frame(
  Object? id, {
  String? type = 'session.text.delta',
  Map<String, Object?>? data,
  int? seq,
  bool durable = true,
}) {
  final json = <String, Object?>{
    'id': id,
    'created': 1790570117526,
    'type': type,
    'data': data ?? const <String, Object?>{'sessionID': 'ses_1'},
    if (durable)
      'durable': <String, Object?>{
        'aggregateID': 'ses_1',
        'seq': seq ?? 1,
        'version': 1,
      },
  };
  return 'event: message\ndata: ${jsonEncode(json)}\n\n';
}

/// `MockClient` no sirve para SSE: su handler devuelve `Response`, no
/// `StreamedResponse`. Éste sí, y además deja **partir** el body en chunks,
/// que es justo lo que hay que atacar (frames a medio llegar).
class ChunkedSseClient extends http.BaseClient {
  ChunkedSseClient(
    this.chunks, {
    this.status = 200,
    this.contentType,
    this.keepOpen = false,
  });

  /// Cada elemento es un chunk del body (se entregan uno por uno).
  final List<String> chunks;
  final int status;
  final String? contentType;

  /// Si es `true` el stream **nunca** se cierra (un stream sano de SSE no
  /// termina nunca). Con `false` el body termina ⇒ el cliente reconecta, que es
  /// justo lo que hay que atacar.
  final bool keepOpen;

  /// Peticiones servidas (para contar reconexiones).
  int sends = 0;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    final controller = StreamController<List<int>>();
    closed = true;
    // Cada chunk con su propio `add` ⇒ el `Utf8Decoder` del SseClient ve
    // fronteras de chunk reales.
    scheduleMicrotask(() async {
      for (final chunk in chunks) {
        if (controller.isClosed) return;
        controller.add(utf8.encode(chunk));
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      if (!controller.isClosed && !keepOpen) await controller.close();
    });
    return http.StreamedResponse(
      controller.stream,
      status,
      headers: {if (contentType != null) 'content-type': contentType!},
    );
  }
}

void main() {
  group('A04.1 heartbeat como comentario', () {
    test('`: heartbeat\\n\\n` ⇒ sawComment, cero eventos', () {
      final r = parseSseChunk(': heartbeat\n\n');
      expect(r.events, isEmpty);
      expect(r.sawComment, isTrue);
      expect(r.alive, isTrue);
      expect(r.malformed, 0);
      expect(r.consumed, ': heartbeat\n\n'.length);
    });

    test('un comentario con más texto y sin blank line final no emite', () {
      final r = parseSseChunk(': heartbeat');
      expect(r.events, isEmpty);
      expect(r.sawComment, isFalse, reason: 'frame a medias: no se consume');
      expect(r.consumed, 0);
    });

    test('comentario mezclado con un frame real en el mismo buffer', () {
      final r = parseSseChunk(
        ': heartbeat\n\n${frame('evt_a', seq: 5)}\n: heartbeat\n\n',
      );
      expect(r.events, hasLength(1));
      expect(r.sawComment, isTrue);
    });
  });

  group('A04.2 data partido entre chunks', () {
    test('mitad y mitad con offset ⇒ un solo evento', () {
      final full = frame('evt_a', seq: 7);
      final cut = full.length ~/ 2;
      final first = parseSseChunk(full.substring(0, cut));
      expect(first.events, isEmpty);
      expect(first.consumed, 0, reason: 'nada se consume hasta el blank line');

      final rest = full.substring(cut);
      final second = parseSseChunk('$first'.isEmpty ? rest : full, offset: 0);
      expect(second.events, hasLength(1));
      expect(second.events.single.data['sessionID'], 'ses_1');
    });

    test('carácter a carácter: un evento al final, ninguno antes', () {
      final full = frame('evt_b', seq: 9);
      var buffer = '';
      final seen = <String>[];
      for (var i = 0; i < full.length; i++) {
        buffer += full[i];
        final r = parseSseChunk(buffer);
        buffer = buffer.substring(r.consumed);
        seen.addAll(r.events.map((e) => e.id));
      }
      expect(seen, ['evt_b'], reason: 'exactamente un evento, sin duplicados');
    });

    test('el frame partido justo en el `\\n\\n` no se parte en dos', () {
      final full = frame('evt_c', seq: 11);
      final upto = full.length - 1; // deja un solo `\n`
      final r1 = parseSseChunk(full.substring(0, upto));
      expect(r1.events, isEmpty);
      expect(r1.consumed, 0);
      final r2 = parseSseChunk(full);
      expect(r2.events, hasLength(1));
    });
  });

  group('A04.3 frames raros', () {
    test('frame sin `data:` ⇒ ni evento ni malformed', () {
      final r = parseSseChunk('event: message\nid: 42\n\n');
      expect(r.events, isEmpty);
      expect(r.malformed, 0);
      expect(r.lastEventId, '42');
    });

    test('`data` como array JSON ⇒ malformado, no crashea', () {
      final r = parseSseChunk('data: [1,2,3]\n\n');
      expect(r.events, isEmpty);
      expect(r.malformed, 1);
    });

    test('`data` como string JSON ⇒ malformado', () {
      final r = parseSseChunk('data: "hola"\n\n');
      expect(r.events, isEmpty);
      expect(r.malformed, 1);
    });

    test('`data` con JSON truncado ⇒ malformado, el buffer sigue', () {
      final r = parseSseChunk('data: {"id":"a"\n\ndata: {"id":"b"}\n\n');
      expect(r.events.single.id, 'b');
      expect(r.malformed, 1);
    });

    test('tres frames en un buffer ⇒ tres eventos, en orden', () {
      final r = parseSseChunk(
        '${frame(1, durable: false)}${frame(2, durable: false)}'
        '${frame(3, durable: false)}',
      );
      expect(r.events.map((e) => e.id), ['1', '2', '3']);
      expect(r.maxSeq, 3);
      expect(r.malformed, 0);
    });

    test('tres frames con id "evt_…" ⇒ tres eventos (el id no es cursor)', () {
      final r = parseSseChunk(
        '${frame('evt_1', seq: 1)}${frame('evt_2', seq: 2)}'
        '${frame('evt_3', seq: 3)}',
      );
      expect(r.events.map((e) => e.id), ['evt_1', 'evt_2', 'evt_3']);
      expect(r.malformed, 0);
    });

    test('basura antes del primer `data:` ⇒ el evento se rescata', () {
      final r = parseSseChunk(
        'HTTP/1.1 200 OK\r\ngarbage\r\n${frame('evt_x')}',
      );
      expect(r.events.single.id, 'evt_x');
    });

    test('`data:` sin valor (línea vacía de datos) ⇒ no emite', () {
      final r = parseSseChunk('data:\ndata:\n\n');
      expect(r.events, isEmpty);
      expect(r.malformed, 0);
    });

    test('`data:` repetido se une con `\\n` (spec SSE)', () {
      final r = parseSseChunk('data: {"id":"a",\ndata: "type":"x"}\n\n');
      expect(r.events.single.id, 'a');
      expect(r.events.single.type, 'x');
    });

    test(
      'sin `type` y con `event:` de la línea ⇒ usa el nombre de la línea',
      () {
        final r = parseSseChunk('event: session.status\ndata: {"id":"a"}\n\n');
        expect(r.events.single.type, 'session.status');
      },
    );

    test('`event: message` (el que manda el server) NO pisa al `type`', () {
      final r = parseSseChunk(frame('evt_1', type: 'session.step.ended'));
      expect(r.events.single.type, 'session.step.ended');
    });

    test('`data` no-mapa (string) ⇒ payload vacío, no crashea', () {
      final r = parseSseChunk('data: {"id":"a","data":"texto"}\n\n');
      expect(r.events.single.data, isEmpty);
    });

    test('buffer vacío ⇒ nada', () {
      final r = parseSseChunk('');
      expect(r.events, isEmpty);
      expect(r.consumed, 0);
      expect(r.alive, isFalse);
    });
  });

  group('A04.4 línea larguísima (ataque de memoria)', () {
    test('data de 5 MB se parsea en tiempo acotado', () {
      final huge = 'y' * 5000000;
      final buffer =
          'data: ${jsonEncode(<String, Object?>{
            'id': 'evt_big',
            'type': 'session.text.delta',
            'data': <String, Object?>{'text': huge},
          })}\n\n';
      final sw = Stopwatch()..start();
      final r = parseSseChunk(buffer);
      sw.stop();
      expect(r.events.single.data['text'], huge);
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('1000 frames de 10 KB ⇒ tiempo acotado (sin O(n²))', () {
      final chunk = frame(
        'evt_x',
        data: <String, Object?>{'text': 'z' * 10000},
      );
      final buffer = chunk * 1000;
      final sw = Stopwatch()..start();
      final r = parseSseChunk(buffer);
      sw.stop();
      expect(r.events, hasLength(1000));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('A04.5 cursor de reanudación (?after=) — D3bis', () {
    test('maxSeq sale de `id`, no de `durable.seq`', () {
      // El frame MEDIDO trae `id: "evt_…"` (string) y el cursor en
      // `durable.seq` (número). D3bis dice que el cursor es `durable.seq`.
      final r = parseSseChunk(frame('evt_0e64bb95', seq: 431));
      expect(
        r.maxSeq,
        431,
        reason:
            'el cursor de reanudación es durable.seq; con id="evt_…" el '
            'cliente nunca manda ?after= y reconecta desde cero',
      );
    });

    test('el id numérico (build viejo) sí da cursor', () {
      final r = parseSseChunk(frame(431, durable: false));
      expect(r.maxSeq, 431);
    });

    test('el evento entregado trae `seq` de durable', () {
      final r = parseSseChunk(frame('evt_a', seq: 88));
      expect(
        r.events.single.seq,
        88,
        reason: 'OcEvent.seq existe en el modelo y nunca se llena desde el SSE',
      );
    });

    test('el evento entregado trae `createdMs`', () {
      final r = parseSseChunk(frame('evt_a', seq: 1));
      expect(
        r.events.single.createdMs,
        1790570117526,
        reason: 'created viaja en el frame y OcEvent lo tiene: no se propaga',
      );
    });
  });

  group('A04.6 SseClient vivo: html 200, 4xx, dispose y reconexión', () {
    SseClient build(
      http.Client client, {
      int maxAttempts = 2,
      void Function(int)? onFallback,
    }) => SseClient(
      config: kConfig,
      sessionId: 'ses_1',
      client: client,
      maxAttempts: maxAttempts,
      baseBackoff: const Duration(milliseconds: 10),
      maxBackoff: const Duration(milliseconds: 20),
      watchdog: const Duration(seconds: 2),
      connectTimeout: const Duration(milliseconds: 500),
      onPollFallback: onFallback,
    );

    test('HTML 200 (catch-all) ⇒ no cuelga, cae a polling', () async {
      final client = MockClient(
        (_) async => http.Response(
          '<!doctype html><html></html>',
          200,
          headers: const {'content-type': 'text/html'},
        ),
      );
      var attempts = 0;
      final sse = build(client, onFallback: (a) => attempts = a);
      addTearDown(sse.dispose);
      sse.connect();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(attempts, greaterThan(0), reason: 'tiene que rendirse y avisar');
      expect(sse.state, StreamState.polling);
    });

    test('401 ⇒ no cuelga, cae a polling', () async {
      final client = MockClient((_) async => http.Response('', 401));
      var attempts = 0;
      final sse = build(client, onFallback: (a) => attempts = a);
      addTearDown(sse.dispose);
      sse.connect();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(attempts, greaterThan(0));
    });

    test('stream sano (nunca cierra): los eventos llegan una vez', () async {
      final client = ChunkedSseClient(
        [frame('evt_1', seq: 1), ': heartbeat\n\n', frame('evt_2', seq: 2)],
        contentType: 'text/event-stream',
        keepOpen: true,
      );
      final sse = build(client);
      addTearDown(sse.dispose);
      final got = <String>[];
      sse.events.listen((e) => got.add(e.id));
      sse.connect();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(got, ['evt_1', 'evt_2']);
      expect(sse.state, StreamState.streaming);
      expect(client.sends, 1, reason: 'un stream sano no reconecta');
    });

    test(
      'RECONEXIÓN: sin `?after=` el server re-emite todo y el texto se duplica',
      () async {
        // El server durable re-sirve desde el principio si no recibe `?after=`.
        // Como el `id` medido es `evt_…` (string), el parser nunca arma el
        // cursor ⇒ cada reconexión duplica todos los deltas del turno.
        final client = ChunkedSseClient([
          frame('evt_1', seq: 1, data: {'text': 'hola'}),
        ], contentType: 'text/event-stream');
        final sse = build(client, maxAttempts: 3);
        addTearDown(sse.dispose);
        final got = <String>[];
        sse.events.listen((e) => got.add(e.id));
        sse.connect();
        await Future<void>.delayed(const Duration(milliseconds: 400));

        expect(got, [
          'evt_1',
        ], reason: 'al reconectar no se re-emite un evento ya entregado');
        // ADJUDICADO 2026-09-28: el stream global /api/event NO declara un query
        // 'after'; mandarlo es un query no declarado y el server responde 400
        // (medido). El unico endpoint que lo aceptaba (/api/session/{id}/event)
        // da 404 en este build. La defensa real contra la re-emision es el
        // filtro por id de arriba, no un cursor en la URL.
        expect(
          sse.streamUri().queryParameters.containsKey('after'),
          isFalse,
          reason: 'el stream global no declara after: mandarlo da 400',
        );
        expect(sse.lastSeq, 1, reason: 'el cursor durable avanza igual');
      },
    );

    test(
      'frames partidos en chunks chicos: llega el evento entero, una vez',
      () async {
        final full = frame('evt_partido', seq: 42, data: {'text': 'hola' * 50});
        final chunks = <String>[
          for (var i = 0; i < full.length; i += 7)
            full.substring(i, (i + 7).clamp(0, full.length)),
        ];
        final client = ChunkedSseClient(
          chunks,
          contentType: 'text/event-stream',
          keepOpen: true,
        );
        final sse = build(client);
        addTearDown(sse.dispose);
        final got = <String>[];
        sse.events.listen((e) => got.add(e.id));
        sse.connect();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(got, [
          'evt_partido',
        ], reason: 'ningún evento duplicado ni perdido al partir el frame');
      },
    );

    test('el cursor de reanudación se actualiza con frames reales', () async {
      final client = ChunkedSseClient(
        [frame('evt_1', seq: 100), frame('evt_2', seq: 431)],
        contentType: 'text/event-stream',
        keepOpen: true,
      );
      final sse = build(client);
      addTearDown(sse.dispose);
      sse.connect();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        sse.lastSeq,
        431,
        reason:
            'con el id="evt_…" medido el cursor nunca avanza, así que al '
            'reconectar no se manda ?after= (D3bis pide durable.seq)',
      );
      // Ver arriba: lastSeq avanza (el cursor durable se lee del frame),
      // pero no se manda en la URL del stream global. Mismo motivo.
      expect(sse.streamUri().queryParameters.containsKey('after'), isFalse);
    });

    test('dispose() antes de connect() no tira', () async {
      final sse = build(MockClient((_) async => http.Response('', 500)));
      await sse.dispose();
      sse.connect();
      expect(() => sse.connect(), returnsNormally);
    });

    test('dispose() dos veces no tira', () async {
      final sse = build(MockClient((_) async => http.Response('', 500)));
      await sse.dispose();
      await expectLater(sse.dispose(), completes);
    });

    test(
      'dispose() en pleno reconnect no deja eventos ni excepciones',
      () async {
        final client = MockClient(
          (_) async => throw http.ClientException('sin red'),
        );
        final sse = build(client, maxAttempts: 50);
        var seen = 0;
        sse.events.listen((_) => seen++);
        sse.connect();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await sse.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(seen, 0);
      },
    );

    test('la URL del stream redacta el auth_token en logs', () {
      final sse = build(MockClient((_) async => http.Response('', 500)));
      addTearDown(sse.dispose);
      final uri = sse.streamUri(after: 3);
      expect(uri.queryParameters[ServerConfig.authTokenParam], isNotNull);
      final redacted = ServerConfig.redactAuthToken(uri).toString();
      expect(redacted, contains('auth_token=REDACTED'));
      expect(redacted, isNot(contains('s3cr3t')));
      // Y el base64 tampoco puede estar.
      expect(redacted, isNot(contains('czNjcjN0')));
    });
  });
}
