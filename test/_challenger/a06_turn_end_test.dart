/// A06 — La regla de fin de turno del contrato §7.4.
///
/// Contrato (API_CONTRACT.md §7.4), textual:
///
/// ```
/// working = último assistant con `time.completed == null`
///           **o** `session.status ∈ {busy, running, retry}`
/// idle    = `session.status ∈ {idle, completed, done, success, succeeded}`
///           **y** el último assistant con `time.completed != null` (o `finish != null`)
/// ```
///
/// O sea: `working` es una **OR** y `idle` exige que **las dos** evidencias
/// digan lo mismo. "Nunca por tiempo": el botón Detener se mantiene visible
/// hasta esta evidencia real.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/core/network/sse_client.dart';
import 'package:openher_mobile/domain/models/event.dart';
import 'package:openher_mobile/domain/models/message.dart';
import 'package:openher_mobile/ui/features/chat/chat_viewmodel.dart';

const ServerConfig kConfig = ServerConfig(host: '127.0.0.1', port: 4098);
const String kSessionId = 'ses_0acd172ac001';

Map<String, Object?> user(String id) => {
  'id': id,
  'type': 'user',
  'time': {'created': 900},
  'text': 'hola',
};

/// Assistant **vivo**: `time.completed` ausente.
Map<String, Object?> assistantLive({String? id, String? finish}) => {
  'id': id ?? 'msg_live',
  'type': 'assistant',
  'time': {'created': 5000, 'streamed': 5200},
  'agent': 'build',
  'model': {'id': 'm', 'providerID': 'p'},
  'content': [
    {'type': 'text', 'text': 'Estoy'},
  ],
  if (finish != null) 'finish': finish,
};

/// Assistant **terminado**: `time.completed` presente.
Map<String, Object?> assistantDone({String? id}) => {
  'id': id ?? 'msg_done',
  'type': 'assistant',
  'time': {'created': 1000, 'streamed': 1200, 'completed': 2600},
  'agent': 'build',
  'model': {'id': 'm', 'providerID': 'p'},
  'content': [
    {'type': 'text', 'text': 'Ya está.'},
  ],
  'finish': 'stop',
};

class FakeSource implements ChatEventSource {
  final _events = StreamController<OcEvent>.broadcast();
  final _states = StreamController<StreamState>.broadcast();
  int connects = 0;
  bool disposed = false;

  @override
  Stream<OcEvent> get events => _events.stream;

  @override
  Stream<StreamState> get stateChanges => _states.stream;

  @override
  StreamState get state => StreamState.polling;

  @override
  Uri streamUri({int? after}) => kConfig.api('/event');

  @override
  void connect() => connects++;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
    await _states.close();
  }

  void emit(String type, Map<String, Object?> data) {
    if (disposed) return;
    _events.add(
      OcEvent(
        id: 'evt_${type}_${data.hashCode}',
        type: type,
        data: {'sessionID': kSessionId, ...data},
      ),
    );
  }

  void status(String value) => emit('session.status', {'type': value});
}

ChatViewModel build(List<Map<String, Object?>> page, {FakeSource? source}) {
  final client = MockClient(
    (_) async => http.Response(
      jsonEncode(<String, Object?>{'data': page}),
      200,
      headers: const {'content-type': 'application/json'},
    ),
  );
  return ChatViewModel(
    ApiClient(
      config: kConfig,
      client: client,
      timeout: const Duration(seconds: 1),
    ),
    sessionId: kSessionId,
    streamFactory: (config, directory) => source ?? FakeSource(),
  );
}

void main() {
  group('A06.1 status idle + assistant SIN completed', () {
    test('el contrato: working sigue en true (assistant incompleto)', () async {
      final source = FakeSource();
      final vm = build([user('msg_u1'), assistantLive()], source: source);
      addTearDown(vm.dispose);
      await vm.load();
      expect(vm.working, isTrue);
      expect(source.connects, 0);

      vm.connectStream();
      source.status('idle');
      await pumpEventQueue();

      // §7.4: `working` es la OR de las dos evidencias. Con el assistant sin
      // `time.completed` el turno sigue vivo aunque el status diga idle: el
      // botón Detener NO puede desaparecer todavía.
      expect(
        vm.working,
        isTrue,
        reason:
            'idle sin `time.completed` en el último assistant no es evidencia '
            'de fin de turno (API_CONTRACT §7.4: working = ... **o** ...)',
      );
    });
  });

  group('A06.2 status busy + assistant CON completed', () {
    test('el contrato: working en true (la OR manda)', () async {
      final source = FakeSource();
      final vm = build([user('msg_u1'), assistantDone()], source: source);
      addTearDown(vm.dispose);
      await vm.load();
      expect(vm.working, isFalse);

      vm.connectStream();
      source.status('busy');
      await pumpEventQueue();

      expect(
        vm.working,
        isTrue,
        reason:
            'la OR del §7.4: status busy ⇒ trabajando, aunque haya completed',
      );
    });
  });

  group('A06.3 assistant con `finish` pero sin `time.completed`', () {
    test('sin status, `finish:"stop"` alcanza para cerrar el turno', () async {
      // §7.4: idle = status idle **y** (completed != null **o** finish != null).
      // Cuando el SSE no está (o el build viejo no manda `session.status`),
      // la única evidencia es el mensaje, y `finish` vale.
      final vm = build([user('msg_u1'), assistantLive(finish: 'stop')]);
      addTearDown(vm.dispose);
      await vm.load();

      expect(
        vm.working,
        isFalse,
        reason:
            '`finish:"stop"` es evidencia de fin de turno por §7.4; sin ella '
            'el botón Detener queda pegado para siempre',
      );
    });

    test('con status idle también cierra (doble evidencia)', () async {
      final source = FakeSource();
      final vm = build([
        user('msg_u1'),
        assistantLive(finish: 'stop'),
      ], source: source);
      addTearDown(vm.dispose);
      await vm.load();
      vm.connectStream();
      source.status('idle');
      await pumpEventQueue();
      expect(vm.working, isFalse);
    });

    test('`finish:"error"` también cierra el turno (no working)', () async {
      final vm = build([user('msg_u1'), assistantLive(finish: 'error')]);
      addTearDown(vm.dispose);
      await vm.load();
      expect(
        vm.working,
        isFalse,
        reason: 'un assistant con finish (stop/error/length) terminó su turno',
      );
    });
  });

  group('A06.4 sin status: decide el assistant', () {
    test('assistant incompleto ⇒ working', () async {
      final vm = build([user('msg_u1'), assistantLive()]);
      addTearDown(vm.dispose);
      await vm.load();
      expect(vm.working, isTrue);
    });

    test('assistant completo ⇒ not working', () async {
      final vm = build([user('msg_u1'), assistantDone()]);
      addTearDown(vm.dispose);
      await vm.load();
      expect(vm.working, isFalse);
    });

    test('un status DESCONOCIDO no afirma nada', () async {
      final source = FakeSource();
      final vm = build([user('msg_u1'), assistantLive()], source: source);
      addTearDown(vm.dispose);
      await vm.load();
      vm.connectStream();
      source.status('weird');
      await pumpEventQueue();
      expect(
        vm.working,
        isTrue,
        reason: 'un status que no se conoce no puede cerrar el turno',
      );
    });

    test('status como OBJETO {type:"busy"} también cuenta', () async {
      final source = FakeSource();
      final vm = build([user('msg_u1'), assistantDone()], source: source);
      addTearDown(vm.dispose);
      await vm.load();
      vm.connectStream();
      source.emit('session.status', {
        'status': <String, Object?>{'type': 'busy'},
      });
      await pumpEventQueue();
      expect(vm.working, isTrue);
    });
  });

  group(
    'A06.5 la regla de §7.4 con el caso inverso: idle sin doble evidencia',
    () {
      test('status idle + assistant completed ⇒ working false', () async {
        final source = FakeSource();
        final vm = build([user('msg_u1'), assistantDone()], source: source);
        addTearDown(vm.dispose);
        await vm.load();
        vm.connectStream();
        source.status('idle');
        await pumpEventQueue();
        expect(vm.working, isFalse);
      });

      test('prompt enviado + status idle antes del assistant ⇒ idle', () async {
        final source = FakeSource();
        final client = MockClient((request) async {
          if (request.method == 'POST') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'data': <String, Object?>{'id': 'msg_1'},
              }),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{'data': <Object?>[]}),
            200,
            headers: const {'content-type': 'application/json'},
          );
        });
        final vm = ChatViewModel(
          ApiClient(
            config: kConfig,
            client: client,
            timeout: const Duration(seconds: 1),
          ),
          sessionId: kSessionId,
          streamFactory: (config, directory) => source,
        );
        addTearDown(vm.dispose);
        vm.connectStream();
        await vm.send('hola');
        expect(vm.working, isTrue, reason: 'esperando el assistant');

        source.status('idle');
        await pumpEventQueue();
        expect(vm.working, isFalse);
      });
    },
  );

  group('A06.6 idempotencia del status', () {
    test('busy, busy, idle, idle ⇒ no queda pegado', () async {
      final source = FakeSource();
      final vm = build([user('msg_u1'), assistantDone()], source: source);
      addTearDown(vm.dispose);
      await vm.load();
      vm.connectStream();
      source.status('busy');
      await pumpEventQueue();
      source.status('busy');
      await pumpEventQueue();
      expect(vm.working, isTrue);
      source.status('idle');
      await pumpEventQueue();
      source.status('idle');
      await pumpEventQueue();
      expect(vm.working, isFalse);
    });

    test('`session.idle` (nombre de evento) también cierra', () async {
      final source = FakeSource();
      final vm = build([user('msg_u1'), assistantDone()], source: source);
      addTearDown(vm.dispose);
      await vm.load();
      vm.connectStream();
      source.emit('session.idle', {'status': 'completed'});
      await pumpEventQueue();
      expect(vm.working, isFalse);
    });
  });

  group(
    'A06.7 el status NO debe ganarle al evidence del assistant (inverso)',
    () {
      test('status busy con lista vacía ⇒ working', () async {
        final source = FakeSource();
        final vm = build(<Map<String, Object?>>[], source: source);
        addTearDown(vm.dispose);
        await vm.load();
        vm.connectStream();
        source.status('busy');
        await pumpEventQueue();
        expect(vm.working, isTrue);
      });

      test('el status se resetea al mandar un prompt nuevo', () async {
        final source = FakeSource();
        final client = MockClient((request) async {
          if (request.method == 'POST') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'data': <String, Object?>{'id': 'm'},
              }),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{'data': <Object?>[]}),
            200,
            headers: const {'content-type': 'application/json'},
          );
        });
        final vm = ChatViewModel(
          ApiClient(
            config: kConfig,
            client: client,
            timeout: const Duration(seconds: 1),
          ),
          sessionId: kSessionId,
          streamFactory: (config, directory) => source,
        );
        addTearDown(vm.dispose);
        vm.connectStream();
        source.status('idle');
        await pumpEventQueue();
        expect(vm.working, isFalse);

        await vm.send('otro prompt');
        expect(
          vm.working,
          isTrue,
          reason: 'el status viejo no puede cerrar el turno nuevo',
        );
      });
    },
  );

  group('A06.8 AssistantMessage.isComplete (la evidencia de §7.4)', () {
    test('completed presente ⇒ completo', () {
      expect(
        SessionMessage.fromJson(assistantDone()) is AssistantMessage,
        isTrue,
      );
      final a = SessionMessage.fromJson(assistantDone()) as AssistantMessage;
      expect(a.isComplete, isTrue);
    });

    test('finish presente sin completed ⇒ ¿completo?', () {
      final a =
          SessionMessage.fromJson(assistantLive(finish: 'stop'))
              as AssistantMessage;
      expect(
        a.isComplete,
        isTrue,
        reason: '§7.4 acepta `finish != null` como evidencia de fin de turno',
      );
    });
  });
}
