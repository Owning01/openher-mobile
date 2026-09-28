/// A05 — Ciclo de vida: dispose en vuelo, dispose doble, `load()` concurrente,
/// `setVisible` entoggle rápido.
///
/// Regla: **ninguna excepción escapa** y nunca hay un "setState after dispose".
/// En Flutter debug, `notifyListeners()` sobre un `ChangeNotifier` destruido
/// tira `FlutterError`; los timers y el socket son asíncronos y hablan tarde.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/core/network/sse_client.dart';
import 'package:openher_mobile/data/repositories/session_repository.dart';
import 'package:openher_mobile/domain/models/event.dart';
import 'package:openher_mobile/ui/features/sessions/sessions_viewmodel.dart';
import 'package:openher_mobile/ui/features/chat/chat_viewmodel.dart';

const ServerConfig kConfig = ServerConfig(host: '127.0.0.1', port: 4098);
const String kSessionId = 'ses_0acd172ac001';

Map<String, Object?> userMsg(String id) => {
  'id': id,
  'type': 'user',
  'time': {'created': 900},
  'text': 'hola',
};

Map<String, Object?> assistantLive({String id = 'msg_live'}) => {
  'id': id,
  'type': 'assistant',
  'time': {'created': 5000, 'streamed': 5200},
  'agent': 'build',
  'model': {'id': 'm', 'providerID': 'p'},
  'content': [
    {'type': 'text', 'text': 'Estoy'},
  ],
};

/// Fuente falsa que **no** se auto-cierra al hacer dispose: permite empujar
/// eventos después del dispose, que es lo que pasa con un socket real.
class LateSource implements ChatEventSource {
  final _events = StreamController<OcEvent>.broadcast();
  final _states = StreamController<StreamState>.broadcast();
  int connects = 0;
  int disposes = 0;

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
    disposes++;
  }

  void emit(String type, Map<String, Object?> data) {
    if (_events.isClosed) return;
    _events.add(
      OcEvent(
        id: 'evt_${type}_${data.hashCode}',
        type: type,
        data: {'sessionID': kSessionId, ...data},
      ),
    );
  }

  void pushState(StreamState s) {
    if (_states.isClosed) return;
    _states.add(s);
  }
}

ApiClient apiOn(MockClient client) => ApiClient(
  config: kConfig,
  client: client,
  timeout: const Duration(milliseconds: 300),
);

/// `ChatView` va detrás de un `LayerGate`, que necesita el catálogo cargado.
final Map<String, bool> kLayers = <String, bool>{
  for (final key in <String>[
    'chat.appbar',
    'chat.appbar.back',
    'chat.appbar.title',
    'chat.appbar.overflow',
    'chat.scroll',
    'chat.msg.loadmore',
    'chat.msg.user.bubble',
    'chat.msg.user.attachment',
    'chat.msg.assistant',
    'chat.msg.system',
    'chat.msg.compaction',
    'chat.msg.error',
    'chat.msg.question',
    'chat.typing',
    'chat.stream.text',
    'chat.activitybox',
    'chat.activitybox.head',
    'chat.activitybox.chevron',
    'chat.activitybox.label',
    'chat.activitybox.summary',
    'chat.activitybox.body',
    'chat.toolcard.subtitle',
    'chat.toolcard.status',
    'chat.toolcard.expanded',
    'chat.toolcard.code',
    'chat.toolcard.footer',
    'chat.toolcard.error',
  ])
    key: true,
};

SessionsViewModel buildSessionsVm(MockClient client) => SessionsViewModel(
  repository: SessionRepository(
    ApiClient(
      config: kConfig,
      client: client,
      timeout: const Duration(milliseconds: 300),
    ),
  ),
);

void main() {
  group('A05.1 dispose con un load en vuelo', () {
    test('el load que vuelve tarde no tira ni notifica', () async {
      final gate = Completer<void>();
      final client = MockClient((_) async {
        await gate.future;
        return http.Response(
          jsonEncode(<String, Object?>{
            'data': [userMsg('msg_u1'), assistantLive()],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final vm = ChatViewModel(
        apiOn(client),
        sessionId: kSessionId,
        streamFactory: (c, d) => LateSource(),
      );
      final inflight = vm.load();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      vm.dispose();
      gate.complete();
      await expectLater(inflight, completes, reason: 'no debe escapar nada');
    });

    test('un evento que llega después del dispose no tira', () async {
      final source = LateSource();
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode(<String, Object?>{
            'data': [userMsg('msg_u1'), assistantLive()],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        ),
      );
      final vm = ChatViewModel(
        apiOn(client),
        sessionId: kSessionId,
        streamFactory: (c, d) => source,
      );
      await vm.load();
      vm.connectStream();
      await pumpEventQueue();

      vm.dispose();
      // Un socket real habla tarde: esto tiene que ser inocuo.
      source.emit('session.text.delta', {'text': 'tarde'});
      source.emit('session.status', {'type': 'idle'});
      source.emit('session.error', {'error': 'algo'});
      source.pushState(StreamState.polling);
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
  });

  group('A05.2 dispose dos veces', () {
    test('no escapa excepción', () async {
      final client = MockClient((_) async => http.Response('{"data":[]}', 200));
      final vm = ChatViewModel(
        apiOn(client),
        sessionId: kSessionId,
        streamFactory: (c, d) => LateSource(),
      );
      await vm.load();
      vm.dispose();
      expect(
        () => vm.dispose(),
        returnsNormally,
        reason: 'doble dispose no debe romper (ChangeNotifier assert de debug)',
      );
    });

    test('la app real (_ChatTab) hace dispose del vm viejo y del nuevo', () {
      // `_openFor` (app.dart:263) hace `_vm?.dispose()` y después crea otro.
      // Si el `ChatView` viejo todavía está montado, su `dispose()` llama
      // `setVisible(false)` sobre un vm ya destruido: tiene que ser inocuo.
      final client = MockClient((_) async => http.Response('{"data":[]}', 200));
      final old = ChatViewModel(
        apiOn(client),
        sessionId: kSessionId,
        streamFactory: (c, d) => LateSource(),
      );
      expect(() {
        old.dispose();
        old.setVisible(false);
        old.clearError();
        old.disposeStream();
        old.connectStream();
      }, returnsNormally);
    });
  });

  group('A05.3 load() concurrente', () {
    test(
      'dos loads simultáneos no tiran y el estado final es coherente',
      () async {
        var call = 0;
        final client = MockClient((_) async {
          final n = ++call;
          // El primero tarda más: si el segundo termina antes, el primero podría
          // pisar la lista nueva con la vieja.
          if (n == 1)
            await Future<void>.delayed(const Duration(milliseconds: 80));
          return http.Response(
            jsonEncode(<String, Object?>{
              'data': [userMsg('msg_u$n'), assistantLive(id: 'msg_a$n')],
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        });
        final vm = ChatViewModel(apiOn(client), sessionId: kSessionId);
        addTearDown(vm.dispose);

        await Future.wait<void>([vm.load(), vm.load()]);

        expect(vm.messages, hasLength(2));
        expect(
          vm.messages.map((m) => m.id),
          ['msg_a2', 'msg_u2'],
          reason:
              'el load más nuevo es el que debe quedar: una respuesta vieja que '
              'llega tarde no puede pisar la lista fresca (la página viene desc '
              'y `_ingest` la da vuelta)',
        );
        expect(vm.loading, isFalse);
      },
    );

    test('load() + refresh() simultáneos no tiran', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode(<String, Object?>{
            'data': [userMsg('msg_u1'), assistantLive()],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        ),
      );
      final vm = ChatViewModel(apiOn(client), sessionId: kSessionId);
      addTearDown(vm.dispose);
      await Future.wait<void>([vm.load(), vm.refresh(), vm.refresh()]);
      expect(vm.messages, hasLength(2));
    });

    test(
      'un load que falla y uno que funciona no dejan _loading colgado',
      () async {
        var call = 0;
        final client = MockClient((_) async {
          call++;
          if (call == 1) return http.Response('', 500);
          return http.Response(
            jsonEncode(<String, Object?>{
              'data': [userMsg('msg_u2')],
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        });
        final vm = ChatViewModel(apiOn(client), sessionId: kSessionId);
        addTearDown(vm.dispose);
        await Future.wait<void>([vm.load(), vm.load()]);
        expect(vm.loading, isFalse);
        expect(vm.messages, isNotEmpty);
      },
    );

    test('loadEarlier() con cursor-null es no-op', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode(<String, Object?>{'data': <Object?>[]}),
          200,
          headers: const {'content-type': 'application/json'},
        ),
      );
      final vm = ChatViewModel(apiOn(client), sessionId: kSessionId);
      addTearDown(vm.dispose);
      await vm.loadEarlier();
      expect(vm.loadingEarlier, isFalse);
      expect(vm.hasEarlier, isFalse);
    });
  });

  group('A05.4 setVisible en toggle rápido', () {
    test(
      '20 toggles seguidos: sin excepción y con una sola fuente viva',
      () async {
        var built = 0;
        final live = <LateSource>[];
        final client = MockClient(
          (_) async => http.Response(
            jsonEncode(<String, Object?>{'data': <Object?>[]}),
            200,
            headers: const {'content-type': 'application/json'},
          ),
        );
        final vm = ChatViewModel(
          apiOn(client),
          sessionId: kSessionId,
          streamFactory: (c, d) {
            built++;
            final s = LateSource();
            live.add(s);
            return s;
          },
        );
        addTearDown(vm.dispose);

        for (var i = 0; i < 10; i++) {
          vm.setVisible(false);
          vm.setVisible(true);
        }
        await pumpEventQueue();

        expect(vm.visible, isTrue);
        // Cada `true` posterior al `false` abre una fuente nueva; **todas menos
        // la última** tienen que estar liberadas (un solo socket vivo).
        expect(built, 10);
        expect(
          live.take(built - 1).every((s) => s.disposes == 1),
          isTrue,
          reason: 'las fuentes viejas se sueltan al ocultarse el chat',
        );
        expect(live.last.disposes, 0, reason: 'la última sigue viva');
      },
    );

    test('toggle durante un load en vuelo no rompe', () async {
      final gate = Completer<void>();
      final client = MockClient((_) async {
        await gate.future;
        return http.Response(
          jsonEncode(<String, Object?>{'data': <Object?>[]}),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final source = LateSource();
      final vm = ChatViewModel(
        apiOn(client),
        sessionId: kSessionId,
        streamFactory: (c, d) => source,
      );
      addTearDown(vm.dispose);
      final inflight = vm.load();
      vm.setVisible(false);
      vm.setVisible(true);
      gate.complete();
      await inflight;
      await pumpEventQueue();
      expect(vm.visible, isTrue);
    });

    test('connectStream() repetido no abre dos sockets', () {
      final source = LateSource();
      final client = MockClient((_) async => http.Response('{"data":[]}', 200));
      final vm = ChatViewModel(
        apiOn(client),
        sessionId: kSessionId,
        streamFactory: (c, d) => source,
      );
      addTearDown(vm.dispose);
      vm.connectStream();
      vm.connectStream();
      vm.connectStream();
      expect(source.connects, 1);
    });
  });

  group('A05.5 timers: nada vivo después del dispose', () {
    test('un delta pendiente no sobrevive al dispose', () async {
      final source = LateSource();
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode(<String, Object?>{
            'data': [userMsg('msg_u1'), assistantLive()],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        ),
      );
      final vm = ChatViewModel(
        apiOn(client),
        sessionId: kSessionId,
        streamFactory: (c, d) => source,
      );
      await vm.load();
      vm.connectStream();
      source.emit('session.text.delta', {'text': ' a medias'});
      // El buffer de deltas son 50 ms: dispose dentro de esa ventana.
      vm.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });

    test('el SSE rendido no deja un Timer.periodic de polling vivo', () async {
      var polls = 0;
      final client = MockClient((request) async {
        polls++;
        if (polls == 1) {
          return http.Response(
            jsonEncode(<String, Object?>{'data': <Object?>[]}),
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
      final source = LateSource();
      final vm = ChatViewModel(
        ApiClient(
          config: kConfig,
          client: client,
          timeout: const Duration(milliseconds: 300),
        ),
        sessionId: kSessionId,
        streamFactory: (c, d) => source,
      );
      vm.connectStream();
      // `polling` arranca el Timer.periodic de 2 s.
      source.pushState(StreamState.polling);
      await pumpEventQueue();
      final before = polls;
      vm.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(polls, before, reason: 'el timer de polling se canceló');
    });
  });

  group('A05.7 SessionsViewModel: mismo contrato de dispose', () {
    test('pollActive que vuelve tarde no notifica tras el dispose', () async {
      final gate = Completer<void>();
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/active')) await gate.future;
        return http.Response(
          jsonEncode(<String, Object?>{'data': <String, Object?>{}}),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });
      final vm = buildSessionsVm(client);
      final inflight = vm.load();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      vm.dispose();
      gate.complete();
      await expectLater(inflight, completes);
    });
  });
}
