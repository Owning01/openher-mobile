import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/data/connectivity/network_monitor.dart';
import 'package:openher_mobile/data/repositories/session_repository.dart';
import 'package:openher_mobile/ui/features/chat/chat_viewmodel.dart';

/// ## Qué es esto
///
/// Un **espejo que cuenta bytes**. Levanta un `HttpServer` local que reenvía
/// cada pedido al server real de opencode y anota los bytes de subida y bajada
/// de cada request, con su endpoint. Después maneja las **clases reales de la
/// app** (`ApiClient`, `SessionRepository`, `ChatViewModel`) contra ese espejo,
/// así que cada byte queda atribuido a la llamada que lo pidió, no estimado.
///
/// Corre como test porque el código de la app importa `dart:ui` (vía
/// `connectivity_plus`), que un `dart run` de VM no tiene:
///
///   flutter test test/data_probe_test.dart
///   # con un radio simulado:
///   $env:OPENHER_PROBE_PASSWORD = '...'
///   flutter test test/data_probe_test.dart --dart-define=PROBE_THROTTLE_KBPS=256
///
/// ## Por qué no lee `service.json`
///
/// Porque la app tampoco lo lee: las credenciales van por UI → secure storage.
/// Esta herramienta de desarrollo las toma del entorno o de `--pass` (vía
/// `PROBE_PASSWORD`) y **nunca las imprime**.

/// Un request, con lo que costó.
class Hit {
  Hit(
    this.method,
    this.path,
    this.inBytes,
    this.outBytes,
    this.ms,
    this.status,
  );

  final String method;
  final String path;
  final int inBytes;
  final int outBytes;
  final double ms;
  final int status;

  int get total => inBytes + outBytes;
}

class Meter {
  final List<Hit> hits = <Hit>[];
  final Map<String, int> byEndpoint = <String, int>{};
  final Map<String, int> countByEndpoint = <String, int>{};
  final List<double> latencies = <double>[];
  int inTotal = 0;
  int outTotal = 0;

  void add(Hit h) {
    latencies.add(h.ms);
    hits.add(h);
    inTotal += h.inBytes;
    outTotal += h.outBytes;
    final key = keyOf(h.path);
    byEndpoint[key] = (byEndpoint[key] ?? 0) + h.total;
    countByEndpoint[key] = (countByEndpoint[key] ?? 0) + 1;
  }

  /// El endpoint sin id ni query: agrupar todas las páginas de `message` junta
  /// es justo lo que se quiere ver.
  static String keyOf(String path) {
    if (path.contains('/message')) return 'GET session/{id}/message';
    if (path.endsWith('/active')) return 'GET session/active';
    if (path == '/api/session') return 'GET session (lista)';
    if (path.contains('/prompt')) return 'POST session/{id}/prompt';
    if (path == '/api/location') return 'GET location (probe)';
    if (path == '/api/event') return 'GET event (stream)';
    return path;
  }

  int bytesOf(String key) => byEndpoint[key] ?? 0;

  double get maxMs =>
      latencies.isEmpty ? 0 : latencies.reduce((a, b) => a > b ? a : b);

  double get avgMs => latencies.isEmpty
      ? 0
      : latencies.fold<double>(0, (a, b) => a + b) / latencies.length;

  void reset() {
    hits.clear();
    byEndpoint.clear();
    countByEndpoint.clear();
    latencies.clear();
    inTotal = 0;
    outTotal = 0;
  }

  int get total => inTotal + outTotal;
}

/// Espejo que reenvía al server real y cuenta.
class Mirror {
  Mirror({
    required this.upstream,
    required this.meter,
    this.throttleBytesPerSecond,
  });

  final ServerConfig upstream;
  final Meter meter;

  /// `null` = sin límite. Con un número simula una radio: no es lo mismo que
  /// contar bytes, es lo que tarda de verdad.
  final int? throttleBytesPerSecond;

  HttpServer? _server;
  int get port => _server!.port;
  ServerConfig local(String user, String pass) => ServerConfig(
    host: '127.0.0.1',
    port: port,
    username: user,
    password: pass,
  );

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_serve());
  }

  Future<void> _serve() async {
    final s = _server;
    if (s == null) return;
    await for (final req in s) {
      unawaited(_handle(req));
    }
  }

  Future<void> _handle(HttpRequest req) async {
    // El stream SSE se reenvía crudo: si no, la app no ve el stream y el
    // escenario "normal" estaría midiendo en realidad el de cellular.
    if (req.uri.path == '/api/event') return _proxySse(req);

    final body = await _readBody(req);
    final started = DateTime.now();
    var status = 0;
    var outBytes = 0;

    try {
      final client = HttpClient();
      final proxied = await client.openUrl(
        req.method,
        Uri.parse(
          '${upstream.baseUrl}${req.uri.path}'
          '${req.uri.hasQuery ? '?${req.uri.query}' : ''}',
        ),
      );
      proxied.headers.set(
        HttpHeaders.authorizationHeader,
        req.headers.value(HttpHeaders.authorizationHeader) ?? '',
      );
      final ct = req.headers.contentType;
      if (ct != null) proxied.headers.contentType = ct;
      if (body.isNotEmpty) proxied.add(body);
      final res = await proxied.close();
      status = res.statusCode;
      final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      await _throttled(req.response, bytes);
      outBytes = bytes.length;
      await req.response.close();
      client.close(force: true);
    } on Object catch (error) {
      status = 599;
      req.response.statusCode = 502;
      req.response.write('espejo: $error');
      await req.response.close();
    }

    meter.add(
      Hit(
        req.method,
        req.uri.path,
        body.length,
        outBytes,
        DateTime.now().difference(started).inMicroseconds / 1000,
        status,
      ),
    );
  }

  Future<void> _proxySse(HttpRequest req) async {
    final started = DateTime.now();
    final client = HttpClient();
    try {
      final proxied = await client.openUrl(
        'GET',
        Uri.parse('${upstream.baseUrl}/api/event'),
      );
      proxied.headers.set(
        HttpHeaders.authorizationHeader,
        req.headers.value(HttpHeaders.authorizationHeader) ?? '',
      );
      final res = await proxied.close();
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType('text', 'event-stream');
      req.response.bufferOutput = false;

      var count = 0;
      await for (final chunk in res) {
        count += chunk.length;
        req.response.add(chunk);
        await req.response.flush();
        final bps = throttleBytesPerSecond;
        if (bps != null && bps > 0) {
          await Future<void>.delayed(
            Duration(microseconds: (chunk.length / bps * 1e6).ceil()),
          );
        }
      }
      meter.add(
        Hit(
          'GET',
          '/api/event',
          0,
          count,
          DateTime.now().difference(started).inMicroseconds / 1000,
          200,
        ),
      );
    } on Object {
      meter.add(Hit('GET', '/api/event', 0, 0, 0, 599));
    } finally {
      await req.response.close();
      client.close(force: true);
    }
  }

  /// Escribe a pedazos de ~1 MTU para simular el ancho de banda de verdad.
  Future<void> _throttled(HttpResponse res, List<int> bytes) async {
    final bps = throttleBytesPerSecond;
    if (bps == null || bps <= 0) {
      res.add(bytes);
      return;
    }
    const chunk = 1400;
    for (var i = 0; i < bytes.length; i += chunk) {
      final end = (i + chunk) < bytes.length ? (i + chunk) : bytes.length;
      res.add(bytes.sublist(i, end));
      await res.flush();
      await Future<void>.delayed(
        Duration(microseconds: (chunk / bps * 1e6).ceil()),
      );
    }
  }

  static Future<List<int>> _readBody(HttpRequest req) async {
    final out = <int>[];
    await for (final c in req) {
      out.addAll(c);
    }
    return out;
  }

  Future<void> stop() async => _server?.close(force: true);
}

/// Deja que los hits en vuelo terminen de anotarse.
///
/// **Por qué hace falta**: el espejo anota cada request **asíncronamente**, así
/// que un `meter.reset()` seguido de otro request puede capturar el hit del
/// request anterior. Sin esta pausa el "poll de una sesión" se media con dos
/// requests encima y el número del cursor salía con la página de otro lado
/// (172 KB dondeiban 50 B). Es un error de la sonda, no de la app.
Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 400));

// ------------------------------------------------------------------- reportes

String _kb(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(2)} MB';
  return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
}

String _bar(int bytes, int max) {
  if (max <= 0) return '';
  const width = 26;
  return '█' * (bytes / max * width).round().clamp(0, width);
}

void report(Meter m, String title) {
  // ignore: avoid_print
  print('\n  $title\n  ${'─' * 76}');
  final entries = m.byEndpoint.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  if (entries.isEmpty) {
    // ignore: avoid_print
    print('    (sin tráfico)');
    return;
  }
  final max = entries.first.value;
  for (final e in entries) {
    final n = m.countByEndpoint[e.key] ?? 0;
    // ignore: avoid_print
    print(
      '  ${e.key.padRight(26).substring(0, 26)} '
      '${_kb(e.value).padLeft(10)}  ×${n.toString().padLeft(3)}  ${_bar(e.value, max)}',
    );
  }
  // ignore: avoid_print
  print(
    '  ${'─' * 76}\n'
    '  ${'TOTAL'.padRight(26)} ${_kb(m.total).padLeft(10)}  ×${m.hits.length}\n'
    '  ${'  bajada (respuestas)'.padRight(26)} ${_kb(m.outTotal).padLeft(10)}\n'
    '  ${'  subida (requests)'.padRight(26)} ${_kb(m.inTotal).padLeft(10)}\n'
    '  ${'  latencia media / maxima'.padRight(26)} '
    '${m.avgMs.toStringAsFixed(0).padLeft(8)} ms / '
    '${m.maxMs.toStringAsFixed(0).padLeft(6)} ms',
  );
}

// ---------------------------------------------------------------------- tests

void main() {
  final password =
      Platform.environment['OPENHER_PROBE_PASSWORD'] ??
      const String.fromEnvironment('PROBE_PASSWORD');
  final port =
      int.tryParse(Platform.environment['OPENHER_PROBE_PORT'] ?? '') ?? 4098;
  final throttleKbps = int.tryParse(
    const String.fromEnvironment('PROBE_THROTTLE_KBPS'),
  );

  late ServerConfig upstream;
  late Meter meter;
  late Mirror mirror;
  bool ready = false;

  /// El motivo para omitir, decidido **antes** de declarar los tests.
  ///
  /// Importa que sea `skip:` en la declaración y no un `markTestSkipped` dentro
  /// del cuerpo: `markTestSkipped` registra el skip pero **no detiene la
  /// ejecución**, así que el cuerpo seguía y moría en el primer `late` sin
  /// inicializar (5 fallos en vez de 5 skips).
  final skipReason = password.isEmpty
      ? 'Falta OPENHER_PROBE_PASSWORD (la app tampoco lee service.json).'
      : null;

  setUpAll(() async {
    if (skipReason != null) return;
    upstream = ServerConfig(
      host: '127.0.0.1',
      port: port,
      username: 'opencode',
      password: password,
    );
    meter = Meter();
    mirror = Mirror(
      upstream: upstream,
      meter: meter,
      throttleBytesPerSecond: throttleKbps == null
          ? null
          : throttleKbps * 1024 ~/ 8,
    );
    await mirror.start();
    ready = true;
  });

  // El `tearDownAll` corre siempre, y sin password el espejo nunca se armó:
  // cerrarlo revienta el suite entero por un problema de entorno.
  tearDownAll(() async {
    if (ready) await mirror.stop();
  });

  test('tamaño real de cada endpoint', skip: skipReason,
    () async {
    // ignore: avoid_print
    print('\n══ Sonda de datos de OpenHer Mobile');
    // ignore: avoid_print
    print(
      '  server ${upstream.host}:${upstream.port}  ·  espejo local :${mirror.port}'
      '${throttleKbps == null ? '' : '  ·  radio simulada ${throttleKbps}kbps'}',
    );

    final api = ApiClient(
      config: mirror.local(upstream.username, upstream.password),
    );
    await settle();
    meter.reset();
    await api.probeServer();
    // El repositorio es el que tipa: `ApiPage.data` son mapas crudos y
    // `listSessions` no devuelve `SessionInfo`.
    final sessions = await SessionRepository(api).list(limit: 30);
    if (sessions.isEmpty) {
      markTestSkipped('el server no devolvió sesiones');
      return;
    }
    final id = sessions.first.id;
    final m30 = await api.listMessages(id, limit: 30, order: 'desc');
    final m15 = await api.listMessages(id, limit: 15, order: 'desc');
    await settle();
    report(meter, '1. Qué pesa cada endpoint (payloads reales del server)');
    // ignore: avoid_print
    print(
      '  la página de 30 mensajes trajo ${m30.data.length}, '
      'la de 15 trajo ${m15.data.length}',
    );

    // Que el espejo haya visto **algo**: un 0 acá significa que el contador
    // falló, no que el server no contesta.
    expect(meter.hits.length, greaterThanOrEqualTo(3));
    expect(meter.bytesOf('GET location (probe)'), lessThan(2048));
    expect(meter.bytesOf('GET session/{id}/message'), greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'un poll idle en cellular: cuanto cuesta de verdad',
    skip: skipReason,
    () async {
        final api = ApiClient(
        config: mirror.local(upstream.username, upstream.password),
      );
      final sessions = await SessionRepository(api).list();
      if (sessions.isEmpty) {
        markTestSkipped('el server no devolvió sesiones');
        return;
      }
      final busy = sessions.first;

      // La conversación más larga entre las primeras, que es la que peor se
      // porta. Se recorre midiendo, pero **fuera** del contador final: un hit que
      // llega tarde después del `reset()` se cuela en la medición y multiplica
      // por dos el número (pasó en la primera corrida).
      var worst = busy;
      var worstBytes = 0;
      for (final s in sessions.take(6)) {
        await settle();
        meter.reset();
        final page = await api.listMessages(s.id, limit: 15, order: 'desc');
        if (page.data.isNotEmpty && meter.total > worstBytes) {
          worstBytes = meter.total;
          worst = s;
        }
      }
      // Se deja asentar lo que quedó en vuelo antes de medir en serio.
      await settle();

      await settle();
      meter.reset();
      await api.listMessages(worst.id, limit: 15, order: 'desc');
      await settle();
      final refetchBytes = meter.total;
      final refetchHits = meter.hits.length;
      report(meter, '2. Un poll en cellular: GET message?limit=15&order=desc');

      final every = const DataPolicy.lowData().pollInterval.inSeconds;
      final perPoll = refetchBytes ~/ (refetchHits == 0 ? 1 : refetchHits);
      final perHour = perPoll * 3600 ~/ every;
      // ignore: avoid_print
      print(
        '\n  con el chat abierto y quieto, en cellular (poll cada $every s):\n'
        '    ${_kb(perPoll)} por poll  =>  ${_kb(perHour)} por hora\n'
        '    y si el chat queda abierto 6 h: ${_kb(perHour * 6)}\n'
        '    (el poll se midió sobre la conversación más larga de las 6 primeras: '
        'es el peor caso)',
      );

      // Exactamente un request: si el espejo vio más, es que algo quedó en vuelo
      // y el número no es de un poll.
      expect(refetchHits, 1, reason: 'un poll es UN request a message');
      expect(perPoll, greaterThan(0));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'el stream es global: cuántos bytes son de sesiones que no se están mirando',
    skip: skipReason,
    () async {
        // `/api/event` es **global**: trae los eventos de todas las sesiones del
      // server, y el filtrado por sesión es del cliente, o sea que los bytes de
      // las sesiones ajenas **ya se descargaron** para después tirarlos.
      //
      // Este test mide esa proporción con eventos reales del server, agrupando
      // por `sessionID`. Con el server quieto el stream es sólo heartbeat (~0), así
      // que no se puede fijar un número absoluto: lo que se mide es el reparto.
      const seconds = 20;
      final config = mirror.local(upstream.username, upstream.password);
      final client = HttpClient();
      final req = await client.openUrl(
        'GET',
        Uri.parse(
          '${config.baseUrl}/api/event?auth_token=${config.authTokenQuery}',
        ),
      );
      req.headers.set(
        HttpHeaders.authorizationHeader,
        config.basicAuthHeader ?? '',
      );
      final res = await req.close();

      final total = <String, int>{}; // sessionID -> bytes de sus eventos
      var totalBytes = 0;
      var heartbeats = 0;
      final other = <String, int>{};
      final pending = StringBuffer();
      final deadline = DateTime.now().add(const Duration(seconds: seconds));

      void consume(String line) {
        final raw = line.trim();
        if (raw.isEmpty) return;
        if (raw.startsWith(':')) {
          // `: heartbeat` no lleva sessionID: es el piso de la conexión.
          heartbeats++;
          return;
        }
        if (!raw.startsWith('data:')) return;
        totalBytes += raw.length;
        final body = raw.substring(5).trim();
        final sid = RegExp(
          r'"sessionID":"(ses_[a-zA-Z0-9]+)"',
        ).firstMatch(body)?.group(1);
        if (sid == null) {
          other['(sin sessionID)'] =
              (other['(sin sessionID)'] ?? 0) + raw.length;
          return;
        }
        total[sid] = (total[sid] ?? 0) + raw.length;
      }

      try {
        await for (final chunk in res) {
          for (final line in const LineSplitter().convert(
            String.fromCharCodes(chunk),
          )) {
            if (line.isEmpty) {
              consume(pending.toString());
              pending.clear();
            } else {
              pending.write(line);
            }
          }
          if (DateTime.now().isAfter(deadline)) break;
        }
      } on Object {
        // El server no cierra el stream nunca: el corte es normal.
      }
      await res
          .detachSocket()
          .then((x) => x.destroy())
          .catchError((Object _) {});
      client.close(force: true);

      // ignore: avoid_print
      print(
        '\n  4. El stream global, $seconds s de eventos reales\n'
        '  ${'─' * 76}\n'
        '    ${_kb(totalBytes)} de eventos + $heartbeats heartbeats\n'
        '    repartidos en ${total.length} sesiones:',
      );
      final entries = total.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in entries.take(8)) {
        // ignore: avoid_print
        print(
          '      ${e.key.padRight(28)} ${_kb(e.value).padLeft(9)}  '
          '${_bar(e.value, totalBytes)}',
        );
      }
      if (entries.length > 8) {
        // ignore: avoid_print
        print('      ... y ${entries.length - 8} más');
      }
      // ignore: avoid_print
      print(
        '\n    Con más de una sesión corriendo, el teléfono descarga los deltas de\n'
        '    TODAS para descartar en el cliente las que no está mirando.',
      );

      // No se puede fijar un total: depende de la actividad del server. Lo que sí
      // es invariante es que los eventos traigan `sessionID` para poder
      // repartirse, y que el stream no se cierre solo.
      expect(
        totalBytes + heartbeats,
        greaterThan(0),
        reason: 'en $seconds s de stream debería haber algo',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'el timer real del ChatViewModel: cada cuánto poll y qué cuesta',
    skip: skipReason,
    () async {
        // Acá no se supone nada: se levanta el **viewmodel de verdad** con la
      // política de cellular y se lo deja correr. El intervalo sale del
      // `DataPolicy` y el timer es `_startPolling`, o sea el código que corre en
      // el teléfono.
      const seconds = 26; // 2 intervals de 12 s + margen
      final config = mirror.local(upstream.username, upstream.password);
      final api = ApiClient(config: config);
      final sessions = await SessionRepository(api).list();
      if (sessions.isEmpty) {
        markTestSkipped('el server no devolvió sesiones');
        return;
      }

      for (final (label, policy) in <(String, DataPolicy)>[
        (
          'CELULAR  (streaming off, poll 12 s, pag 15)',
          const DataPolicy.lowData(),
        ),
        ('NORMAL  (streaming on,  sin poll)', const DataPolicy.normal()),
      ]) {
        await settle();
        meter.reset();
        final vm = ChatViewModel(
          api,
          sessionId: sessions.first.id,
          // Sin factory de stream: el VM no abre `/api/event` y arranca el
          // polling, que es exactamente lo que pasa con datos móviles.
          streamFactory: null,
          policy: policy,
        );
        // `setVisible(true)` es lo que llama la vista (`chat_view.dart` en su
        // `initState`) y lo que **arranca el polling**: `_startPolling` sólo se
        // dispara desde `connectStream`/`_onStreamState`, no desde `load()`.
        //
        // La primera corrida de esta sonda dio 0 polls y parecía un bug de la
        // app; era que faltaba esta llamada. El comentario queda para que nadie
        // lo lea como "el polling no arranca solo".
        vm.setVisible(true);
        await vm.load();
        await settle();
        final afterLoad = meter.hits.length;
        meter.reset();

        await Future<void>.delayed(Duration(seconds: seconds));
        await settle();

        final polls = meter.hits
            .where((h) => h.path.contains('/message'))
            .length;
        final bytes = meter.total;
        final expected = policy.streamingEnabled
            ? 0
            : (seconds / policy.pollInterval.inSeconds).floor();

        // ignore: avoid_print
        print(
          '\n  5. El timer real del viewmodel — $label\n'
          '  ${'─' * 76}\n'
          '    carga inicial: $afterLoad request(s)\n'
          '    $seconds s quieto: $polls poll(s)  =>  ${_kb(bytes)}\n'
          '    esperado por la politica: $expected\n'
          '    ${_kb(polls == 0 ? 0 : bytes ~/ polls)} por poll',
        );

        if (policy.streamingEnabled) {
          // Con streaming el VM **no** pollatea: es el diseño
          // (`if (!_policy.streamingEnabled) _startPolling()`).
          expect(polls, 0, reason: 'con streaming no debe haber polling');
        } else {
          expect(
            polls,
            greaterThanOrEqualTo(1),
            reason: 'el timer tiene que pollar',
          );
          // Un poll de más o de menos y la proyección de la tabla queda falsa.
          expect(
            polls,
            inInclusiveRange(expected - 1, expected + 1),
            reason: 'la cadencia real no es la de DataPolicy ($expected)',
          );
        }

        vm.setVisible(false);
        vm.disposeStream();
        vm.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'la optimización: pedir con cursor en vez de refetch de la página',
    skip: skipReason,
    () async {
        final api = ApiClient(
        config: mirror.local(upstream.username, upstream.password),
      );
      final sessions = await SessionRepository(api).list();
      if (sessions.isEmpty) {
        markTestSkipped('el server no devolvió sesiones');
        return;
      }
      final id = sessions.first.id;

      await settle();
      meter.reset();
      final full = await api.listMessages(id, limit: 15, order: 'desc');
      await settle();
      final refetchBytes = meter.total;
      final refetchCount = full.data.length;
      final refetchHits = meter.hits.length;

      final previous = full.previous;
      if (previous == null) {
        markTestSkipped('la página no trajo cursor.previous');
        return;
      }
      await settle();
      meter.reset();
      final withCursor = await api.listMessages(
        id,
        cursor: previous,
        limit: 15,
      );
      await settle();
      final cursorBytes = meter.total;
      final cursorHits = meter.hits.length;

      // ignore: avoid_print
      print(
        '\n  3. La diferencia entre las dos formas de preguntar lo mismo\n'
        '  ${'─' * 76}\n'
        '    refetch (lo que hace la app): ${_kb(refetchBytes).padLeft(10)}  '
        '$refetchCount mensajes  ($refetchHits request)\n'
        '    con cursor.previous:         ${_kb(cursorBytes).padLeft(10)}  '
        '${withCursor.data.length} mensajes  ($cursorHits request)',
      );
      if (withCursor.data.isEmpty) {
        // ignore: avoid_print
        print(
          '\n    Un cursor con 0 mensajes significa "no hay nada nuevo", que es\n'
          '    exactamente la respuesta de un poll cuando el chat está quieto.',
        );
      }

      // Primero que el espejo haya contado **los dos**: sin esto un 0 por un
      // request no registrado pasaría por una medición excelente.
      expect(refetchHits, greaterThanOrEqualTo(1));
      expect(
        cursorHits,
        greaterThanOrEqualTo(1),
        reason:
            'el espejo no vio el request con cursor: el 0 no es una medición',
      );

      // Ésta es la cifra que hay que proteger: si algún día el poll idle vuelve a
      // traer la página entera, este test lo dice.
      expect(
        cursorBytes,
        lessThan(refetchBytes ~/ 10),
        reason:
            'un poll sin novedades debe costar una fracción de la página, '
            'no la página entera',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
