/// Tests del [ChatViewModel] con un `MockClient` de `package:http/testing` y un
/// [ChatEventSource] falso: no hay server, no hay socket, no hay timers vivos.
///
/// Los JSON son los **medidos** contra `:4098` (`docs/API_CONTRACT.md` §4, §7),
/// no inventados: el `{"data":[…]}` de `listMessages`, el `content[]` embebido
/// del assistant, y los frames `{id, type, data}` del stream global.
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

/// Assistant **terminado**: `time.completed` presente ⇒ el turno no está
/// trabajando.
Map<String, Object?> assistantDone() => {
  'id': 'msg_assistant_done',
  'type': 'assistant',
  'time': {'created': 1000, 'streamed': 1200, 'completed': 2600},
  'agent': 'build',
  'model': {'id': 'deepseek-v4.1-flash', 'providerID': 'opencode-go'},
  'content': [
    {'type': 'text', 'text': 'Ya está.'},
    {
      'type': 'tool',
      'id': 'call_1',
      'name': 'shell',
      'executed': false,
      'state': {
        'status': 'completed',
        'input': {'command': 'Get-ChildItem lib'},
        'content': [
          {'type': 'text', 'text': 'chat_view.dart'},
        ],
      },
    },
  ],
  'finish': 'stop',
  'cost': 0.011,
  'tokens': {
    'input': 14200,
    'output': 300,
    'reasoning': 0,
    'cache': {'read': 9000, 'write': 0},
  },
};

/// Assistant **a medio hacer**: sin `time.completed` ⇒ trabajando.
Map<String, Object?> assistantWorking() => {
  'id': 'msg_assistant_live',
  'type': 'assistant',
  'time': {'created': 5000, 'streamed': 5200},
  'agent': 'build',
  'model': {'id': 'deepseek-v4.1-flash', 'providerID': 'opencode-go'},
  'content': [
    {'type': 'text', 'text': 'Estoy'},
  ],
};

Map<String, Object?> userMessage(String id, String text) => {
  'id': id,
  'type': 'user',
  'time': {'created': 900},
  'text': text,
  'files': <Object?>[],
};

/// Un `MockClient` que responde con el JSON que devuelve el handler.
MockClient jsonClient(
  Map<String, Object?> Function(http.Request request) handler,
) => MockClient((request) async {
  final body = handler(request);
  return http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json'},
  );
});

/// Fuente de eventos falsa: empuja frames a mano y registra si se disposal.
class FakeEventSource implements ChatEventSource {
  final _events = StreamController<OcEvent>.broadcast();
  final _states = StreamController<StreamState>.broadcast();
  int connects = 0;
  int _seq = 0;
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
        // Un id **por frame**, como el server: el viewmodel dedupea por `id`
        // (§7.1), así que dos `session.status` con el mismo id se comen el
        // segundo y el test mide el dedupe en vez de lo que quiere medir.
        id: 'evt_${++_seq}_$type',
        type: type,
        data: {'sessionID': kSessionId, ...data},
      ),
    );
  }

  /// Un evento de **otra** sesión: el stream es global, el filtro es nuestro.
  void emitOther(String type, [Map<String, Object?> data = const {}]) {
    _events.add(
      OcEvent(
        id: 'evt_other',
        type: type,
        data: {'sessionID': 'ses_otra', ...data},
      ),
    );
  }
}

/// `ApiClient` sobre el mock. El `http.Client` inyectado **no** lo cierra el
/// cliente al hacer `close()` (no es suyo), así que el test no filtra sockets.
ApiClient api(MockClient client) => ApiClient(
  config: kConfig,
  client: client,
  timeout: const Duration(seconds: 1),
);

ChatViewModel buildVm(
  MockClient client, {
  FakeEventSource? source,
  String sessionId = kSessionId,
}) => ChatViewModel(
  api(client),
  sessionId: sessionId,
  streamFactory: (config, directory) => source ?? FakeEventSource(),
);

void main() {
  group('load()', () {
    test(
      'parsea el sobre {"data":[…]} y working sale de time.completed',
      () async {
        final requests = <Uri>[];
        final vm = buildVm(
          jsonClient((request) {
            requests.add(request.url);
            // El server con `order=desc` devuelve la página **nueva→vieja**;
            // el mock lo replica para no mentirle al viewmodel.
            return {
              'data': [assistantDone(), userMessage('msg_u1', 'hola')],
            };
          }),
        );
        addTearDown(vm.dispose);

        await vm.load();

        // `limit=30` y `order=desc`: la primera página trae los ÚLTIMOS
        // mensajes y el viewmodel los da vuelta para dejar la lista en orden
        // cronológico. El cursor `previous` es el de "Cargar 30 anteriores".
        expect(requests.single.queryParameters['limit'], '30');
        expect(requests.single.queryParameters['order'], 'desc');
        expect(requests.single.path, '/api/session/$kSessionId/message');

        expect(vm.messages, hasLength(2));
        expect(vm.messages.first, isA<UserMessage>());
        expect(vm.messages.last, isA<AssistantMessage>());
        final assistant = vm.messages.last as AssistantMessage;
        expect(assistant.textContent, 'Ya está.');
        expect(assistant.toolItems.single.name, 'shell');
        // `time.completed` presente ⇒ turno terminado.
        expect(vm.working, isFalse);
        expect(vm.error, isNull);
        // El resumen sale de los tokens del assistant (no hay SessionInfo).
        expect(vm.serverTokens, 14500);
        expect(vm.serverCost, closeTo(0.011, 1e-9));
      },
    );

    test(
      'el último assistant sin time.completed deja working en true',
      () async {
        final vm = buildVm(
          jsonClient(
            (_) => {
              'data': [userMessage('msg_u1', 'hola'), assistantWorking()],
            },
          ),
        );
        addTearDown(vm.dispose);

        await vm.load();

        expect(vm.working, isTrue);
      },
    );

    test(
      'el cursor "previous" del server enciende "Cargar 30 anteriores"',
      () async {
        var call = 0;
        final vm = buildVm(
          jsonClient((_) {
            call++;
            if (call == 1) {
              return {
                'data': [userMessage('msg_u1', 'hola')],
                'cursor': {'previous': 'eyJpZCI6Im1zZ19uMSJ9'},
              };
            }
            return {
              'data': [userMessage('msg_u0', 'anterior')],
            };
          }),
        );
        addTearDown(vm.dispose);

        await vm.load();
        expect(vm.hasEarlier, isTrue);
        expect(vm.messages, hasLength(1));

        await vm.loadEarlier();
        expect(vm.messages.map((m) => m.id), ['msg_u0', 'msg_u1']);
        // La segunda página no trae cursor: el botón desaparece.
        expect(vm.hasEarlier, isFalse);
      },
    );
  });

  group('send()', () {
    test('manda el body de §4 y agrega la burbuja optimista', () async {
      String? body;
      Uri? uri;
      final vm = buildVm(
        jsonClient((request) {
          uri = request.url;
          body = request.body;
          // `sendPrompt` espera un objeto en `data`; `listMessages`, una lista.
          return request.method == 'POST'
              ? {
                  'data': {'id': 'msg_1'},
                }
              : {'data': <Object?>[]};
        }),
      );
      addTearDown(vm.dispose);
      await vm.load();

      await vm.send(
        'diseñá las vistas',
        files: const [
          {'uri': 'file:///c.png', 'name': 'c.png', 'mime': 'image/png'},
        ],
      );

      expect(uri!.path, '/api/session/$kSessionId/prompt');
      final decoded = jsonDecode(body!) as Map<String, Object?>;
      final prompt = decoded; // text en la raiz (medido: anidado da 400)
      expect(prompt['text'], 'diseñá las vistas');
      expect(prompt['files'], [
        {'uri': 'file:///c.png', 'name': 'c.png', 'mime': 'image/png'},
      ]);

      final local = vm.messages.single as UserMessage;
      expect(local.id, startsWith('local_'));
      expect(local.text, 'diseñá las vistas');
      expect(local.files.single.mime, 'image/png');
      // Un prompt admitido ⇒ esperando el assistant ⇒ trabajando.
      expect(vm.working, isTrue);
      expect(vm.error, isNull);
    });

    test(
      'un 429 saca la burbuja optimista y muestra el error de transporte',
      () async {
        final failing = ChatViewModel(
          api(
            MockClient(
              (_) async => http.Response('{"message":"rate limit"}', 429),
            ),
          ),
          sessionId: kSessionId,
        );
        addTearDown(failing.dispose);

        await failing.send('hola');

        expect(failing.messages, isEmpty);
        expect(failing.error, contains('429'));
        expect(failing.working, isFalse);
      },
    );
  });

  group('eventos del stream', () {
    test('session.status idle termina el turno', () async {
      final source = FakeEventSource();
      final vm = buildVm(
        jsonClient(
          (_) => {
            'data': [userMessage('msg_u1', 'hola'), assistantDone()],
          },
        ),
        source: source,
      );
      addTearDown(vm.dispose);

      // El assistant ya cerró (`time.completed` + `finish`): ahora el status
      // es lo único que puede mover la aguja, así que el test mide el status y
      // no el mensaje.
      await vm.load();
      expect(
        vm.working,
        isFalse,
        reason: 'el ultimo assistant esta cerrado: no hay trabajo',
      );

      vm.connectStream();
      expect(source.connects, 1);

      source.emit('session.status', {'type': 'busy'});
      await pumpEventQueue();
      expect(
        vm.working,
        isTrue,
        reason: 'un busy con el mensaje cerrado prueba que el status manda',
      );

      source.emit('session.status', {'type': 'idle'});
      await pumpEventQueue();
      expect(
        vm.working,
        isFalse,
        reason: 'status idle manda sobre el assistant ya cerrado',
      );
    });

    test(
      'un idle con el assistant sin cerrar NO termina el turno (§7.4)',
      () async {
        // §7.4 textual: `idle` = status idle **y** el último assistant con
        // `time.completed`. Un `idle` solo no puede esconder el botón Detener
        // mientras el mensaje siga abierto.
        final source = FakeEventSource();
        final vm = buildVm(
          jsonClient(
            (_) => {
              'data': [userMessage('msg_u1', 'hola'), assistantWorking()],
            },
          ),
          source: source,
        );
        addTearDown(vm.dispose);

        await vm.load();
        expect(vm.working, isTrue);

        vm.connectStream();
        source.emit('session.status', {'type': 'idle'});
        await pumpEventQueue();

        expect(vm.working, isTrue, reason: 'el mensaje sigue sin cerrar');
      },
    );

    test('session.text.delta agrega al texto del último assistant', () async {
      final source = FakeEventSource();
      final vm = buildVm(
        jsonClient(
          (_) => {
            'data': [userMessage('msg_u1', 'hola'), assistantWorking()],
          },
        ),
        source: source,
      );
      addTearDown(vm.dispose);

      await vm.load();
      vm.connectStream();

      // El buffer de deltas agrupa 50 ms: se vacía recién después.
      source.emit('session.text.delta', {
        'messageID': 'msg_assistant_live',
        'text': ' leyendo',
      });
      expect(
        (vm.lastAssistant!.textContent),
        'Estoy',
        reason: 'el delta todavía está en el buffer',
      );

      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(vm.lastAssistant!.textContent, 'Estoy leyendo');
      expect(vm.working, isTrue);
    });

    test(
      'un evento de otra sesión se descarta (el stream es global)',
      () async {
        final source = FakeEventSource();
        final vm = buildVm(
          jsonClient(
            (_) => {
              'data': [userMessage('msg_u1', 'hola'), assistantWorking()],
            },
          ),
          source: source,
        );
        addTearDown(vm.dispose);

        await vm.load();
        vm.connectStream();

        source.emitOther('session.status', {'type': 'idle'});
        source.emitOther('session.text.delta', {'text': 'NO'});
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(vm.lastAssistant!.textContent, 'Estoy');
        expect(
          vm.working,
          isTrue,
          reason: 'el idle de otra sesión no cierra este turno',
        );
      },
    );

    test('session.error levanta el banner del canal C', () async {
      final source = FakeEventSource();
      final vm = buildVm(
        jsonClient(
          (_) => {
            'data': [userMessage('msg_u1', 'hola'), assistantDone()],
          },
        ),
        source: source,
      );
      addTearDown(vm.dispose);

      await vm.load();
      vm.connectStream();

      source.emit('session.error', {
        'error': {'type': 'plugin.reload', 'message': 'el plugin falló'},
      });
      await pumpEventQueue();

      expect(vm.error, 'plugin.reload: el plugin falló');
    });
  });

  test('un text/html levanta HtmlFallbackError y no revienta', () async {
    final vm = ChatViewModel(
      api(
        MockClient(
          (_) async => http.Response(
            '<!doctype html><html><body>index</body></html>',
            200,
            headers: const {'content-type': 'text/html'},
          ),
        ),
      ),
      sessionId: kSessionId,
    );
    addTearDown(vm.dispose);

    await vm.load();

    expect(vm.messages, isEmpty);
    expect(vm.working, isFalse);
    expect(vm.error, isNotNull);
    expect(vm.error, contains('HTML'));
  });

  test('setVisible(false) para el stream; volver lo reabre', () async {
    final source = FakeEventSource();
    var loads = 0;
    final vm = buildVm(
      jsonClient((_) {
        loads++;
        return {
          'data': [userMessage('msg_u1', 'hola'), assistantWorking()],
        };
      }),
      source: source,
    );
    addTearDown(vm.dispose);

    await vm.load();
    expect(loads, 1);

    vm.connectStream();
    expect(source.connects, 1);

    vm.setVisible(false);
    expect(source.disposed, isTrue, reason: 'sin socket fuera de pantalla');
    expect(vm.visible, isFalse);

    // Un evento que llega después no debe tocar el estado.
    source.emit('session.text.delta', {'text': 'No debe aparecer'});
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(vm.lastAssistant!.textContent, 'Estoy');

    vm.setVisible(true);
    expect(vm.visible, isTrue);
    // Al volver se re-snapshotéa, porque los deltas son live-only (§7.5).
    await pumpEventQueue();
    expect(loads, 2);
  });

  test('el stream es el GLOBAL /api/event, no el por sesión (404 medido)', () {
    // API_CONTRACT §7.1: `/api/session/{id}/event` da 404 en el build medido.
    // La URL es parte del contrato, así que se verifica, no se supone.
    final source = GlobalSseSource(
      config: const ServerConfig(
        host: '192.168.1.10',
        port: 4098,
        password: 's3cr3t',
      ),
      directory: 'C:/Proyectos/openher',
    );

    final uri = source.streamUri(after: 431);

    expect(uri.path, '/api/event');
    expect(uri.path, isNot(contains('/session/')));
    expect(uri.queryParameters['after'], '431');
    expect(
      uri.queryParameters[ServerConfig.locationParam],
      'C:/Proyectos/openher',
    );
    // §7.3: mandar `sessionID` en la query es un 400 del middleware.
    expect(uri.queryParameters.containsKey('sessionID'), isFalse);
    // La credencial viaja en `auth_token` y se redacta antes de loguearse.
    expect(uri.queryParameters[ServerConfig.authTokenParam], isNotNull);
    expect(
      ServerConfig.redactAuthToken(uri).toString(),
      contains('auth_token=REDACTED'),
    );
  });

  test('dispose() no tira y no deja timers vivos', () async {
    final vm = buildVm(
      jsonClient(
        (_) => {
          'data': [userMessage('msg_u1', 'hola'), assistantWorking()],
        },
      ),
    );
    await vm.load();
    vm.connectStream();
    // Notificar o tocar el stream después de dispose no debe romper: el socket
    // es asíncrono y puede hablar tarde.
    vm.dispose();
    vm.setVisible(false);
    vm.clearError();
  });

  // ─────────────────────────── helpers de pregunta ──────────────────────────

  /// `question.asked` medido: el `id` es el `requestID` del reply y `tool`
  /// ancla la pregunta a un mensaje y a un `callID`.
  Map<String, Object?> questionAsked() => {
    'id': 'que_42',
    'questions': [
      {
        'question': 'Donde vive la lista de sesiones?',
        'header': 'Arquitectura',
        'options': [
          {'label': 'App Flutter mobile nueva', 'description': 'Android/iOS'},
          {'label': 'Modulo dentro de OpenHer'},
        ],
        'multiple': false,
        'custom': true,
      },
    ],
    'tool': {'messageID': 'msg_assistant_live', 'callID': 'call_q'},
  };

  /// Server de laboratorio para la pregunta: responde la lista de mensajes, el
  /// `POST /prompt` y — según [replyStatus]— el `POST …/question/{id}/reply`.
  ///
  /// 204 = existe el endpoint. 404 = el build medido en `:4098`, donde ese path
  /// no está (y el reply tiene que caer al prompt).
  MockClient questionClient({
    required List<String> calls,
    required int Function() replyStatus,
    String? Function(String)? onReplyBody,
    String? Function(String)? onPromptBody,
  }) => MockClient((request) async {
    final path = request.url.path;
    calls.add('${request.method} $path');
    if (path.endsWith('/reply')) {
      final status = replyStatus();
      if (status != 204) {
        return http.Response(
          jsonEncode({'message': 'not found'}),
          status,
          headers: const {'content-type': 'application/json'},
        );
      }
      onReplyBody?.call(request.body);
      return http.Response('', 204);
    }
    if (path.endsWith('/prompt')) {
      onPromptBody?.call(request.body);
      return http.Response(
        jsonEncode({
          'data': {'id': 'msg_1'},
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    return http.Response(
      jsonEncode({
        'data': [userMessage('msg_u1', 'hola'), assistantWorking()],
      }),
      200,
      headers: const {'content-type': 'application/json'},
    );
  });

  // ───────────────────────── preguntas (API_CONTRACT §6) ────────────────────

  group('preguntas', () {
    test(
      'el endpoint de reply es el del protocolo y no manda prompt',
      () async {
        final calls = <String>[];
        String? replyBody;
        final source = FakeEventSource();
        final vm = buildVm(
          questionClient(
            calls: calls,
            replyStatus: () => 204,
            onReplyBody: (b) => replyBody = b,
          ),
          source: source,
        );
        addTearDown(vm.dispose);

        await vm.load();
        vm.connectStream();
        source.emit('question.asked', questionAsked());
        await pumpEventQueue();

        expect(vm.awaitingAnswer, isTrue);
        expect(vm.pendingQuestion!.requestId, 'que_42');
        expect(vm.pendingQuestion!.questions, hasLength(1));
        // El `callID` del tool es lo que ata la card al `requestID`.
        expect(vm.requestIdFor('call_q'), 'que_42');
        expect(vm.requestIdFor('call_otra'), isNull);

        final path = await vm.answerQuestion(
          vm.requestIdFor('call_q'),
          answers: [
            ['App Flutter mobile nueva'],
          ],
        );

        expect(path, QuestionReplyPath.api);
        expect(vm.questionReplyViaApi, isTrue);
        expect(
          calls,
          contains('POST /api/session/$kSessionId/question/que_42/reply'),
        );
        // `{answers: [[...]]}`: un array por pregunta, en el orden en que se
        // hicieron (Question.Reply del protocolo).
        expect(jsonDecode(replyBody!), {
          'answers': [
            ['App Flutter mobile nueva'],
          ],
        });
        expect(
          calls.where((c) => c.contains('/prompt')),
          isEmpty,
          reason: 'si el endpoint existe no se manda un prompt de más',
        );
        // Respondió: la card no queda pidiendo algo ya contestado.
        expect(vm.awaitingAnswer, isFalse);
      },
    );

    test('un 404 en el reply cae al prompt y lo dice', () async {
      final calls = <String>[];
      String? promptBody;
      final source = FakeEventSource();
      final vm = buildVm(
        questionClient(
          calls: calls,
          replyStatus: () => 404,
          onPromptBody: (b) => promptBody = b,
        ),
        source: source,
      );
      addTearDown(vm.dispose);

      await vm.load();
      vm.connectStream();
      source.emit('question.asked', questionAsked());
      await pumpEventQueue();

      final path = await vm.answerQuestion(
        'que_42',
        answers: [
          ['Modulo dentro de OpenHer'],
        ],
      );

      expect(path, QuestionReplyPath.prompt);
      expect(vm.questionReplyViaApi, isFalse);
      expect(
        calls,
        contains('POST /api/session/$kSessionId/question/que_42/reply'),
      );
      expect(calls, contains('POST /api/session/$kSessionId/prompt'));
      expect(
        (jsonDecode(promptBody!) as Map<String, Object?>)['text'],
        'Modulo dentro de OpenHer',
      );
      // Un 404 del endpoint NO es un error del usuario: no hay banner.
      expect(vm.error, isNull);
    });

    test(
      'el "Ahora no" (lista vacía) sale como prompt con el texto de siempre',
      () async {
        final calls = <String>[];
        String? promptBody;
        final vm = buildVm(
          questionClient(
            calls: calls,
            replyStatus: () => 404,
            onPromptBody: (b) => promptBody = b,
          ),
        );
        addTearDown(vm.dispose);
        await vm.load();

        final path = await vm.answerQuestion('que_42', answers: [<String>[]]);

        expect(path, QuestionReplyPath.prompt);
        expect(
          (jsonDecode(promptBody!) as Map<String, Object?>)['text'],
          'Ahora no.',
        );
      },
    );

    test('sin requestID no hay a quién preguntar: directo al prompt', () async {
      final calls = <String>[];
      String? promptBody;
      final vm = buildVm(
        questionClient(
          calls: calls,
          replyStatus: () => 204,
          onPromptBody: (b) => promptBody = b,
        ),
      );
      addTearDown(vm.dispose);
      await vm.load();

      expect(vm.requestIdFor('call_q'), isNull);
      final path = await vm.answerQuestion(
        null,
        answers: [
          ['A'],
        ],
      );

      expect(path, QuestionReplyPath.prompt);
      expect(calls.where((c) => c.contains('/reply')), isEmpty);
      expect((jsonDecode(promptBody!) as Map<String, Object?>)['text'], 'A');
    });

    test('question.replied de otra request no cierra la que espera', () async {
      final source = FakeEventSource();
      final vm = buildVm(
        questionClient(calls: <String>[], replyStatus: () => 204),
        source: source,
      );
      addTearDown(vm.dispose);

      await vm.load();
      vm.connectStream();
      source.emit('question.asked', questionAsked());
      await pumpEventQueue();
      expect(vm.awaitingAnswer, isTrue);

      source.emit('question.replied', {'requestID': 'que_otra'});
      await pumpEventQueue();
      expect(vm.awaitingAnswer, isTrue, reason: 'es otra request');

      source.emit('question.replied', {
        'requestID': 'que_42',
        'answers': [
          ['Modulo dentro de OpenHer'],
        ],
      });
      await pumpEventQueue();
      expect(vm.awaitingAnswer, isFalse);
      expect(vm.pendingQuestion, isNull);
    });

    test(
      'question.rejected también cierra la pendiente (con y sin .v2)',
      () async {
        for (final prefix in const ['question.', 'question.v2.']) {
          final source = FakeEventSource();
          final vm = buildVm(
            questionClient(calls: <String>[], replyStatus: () => 204),
            source: source,
          );
          await vm.load();
          vm.connectStream();

          source.emit('${prefix}asked', questionAsked());
          await pumpEventQueue();
          expect(vm.awaitingAnswer, isTrue, reason: prefix);

          source.emit('${prefix}rejected', {'requestID': 'que_42'});
          await pumpEventQueue();
          expect(vm.awaitingAnswer, isFalse, reason: prefix);
          vm.dispose();
        }
      },
    );
  });

  group('deltas por id', () {
    test(
      'el delta va al assistantMessageID que nombra, no al último',
      () async {
        final source = FakeEventSource();
        final vm = buildVm(
          jsonClient(
            (_) => {
              'data': [
                userMessage('msg_u1', 'hola'),
                assistantDone(),
                assistantWorking(),
              ],
            },
          ),
          source: source,
        );
        addTearDown(vm.dispose);

        await vm.load();
        vm.connectStream();

        // Un frame tarde del turno viejo: su texto va a SU mensaje, no al
        // último de la lista (que es el del turno nuevo).
        source.emit('session.text.delta', {
          'assistantMessageID': 'msg_assistant_done',
          'delta': ' (tarde)',
        });
        await Future<void>.delayed(const Duration(milliseconds: 80));

        final byId = {for (final m in vm.messages) m.id: m};
        // El turno viejo es [texto, tool], así que el delta abre un item de
        // texto nuevo detrás del tool: `textContent` los une con una linea en
        // blanco. Lo que importa es que cayó acá y no en el otro mensaje.
        expect(
          (byId['msg_assistant_done']! as AssistantMessage).textItems.length,
          2,
        );
        expect(
          (byId['msg_assistant_done']! as AssistantMessage).textContent,
          'Ya está.\n\n (tarde)',
        );
        expect(
          (byId['msg_assistant_live']! as AssistantMessage).textContent,
          'Estoy',
          reason: 'el turno nuevo no se contamina con el frame del viejo',
        );
      },
    );

    test(
      'si el id todavía no llegó, el delta va al assistant incompleto',
      () async {
        final source = FakeEventSource();
        final vm = buildVm(
          jsonClient(
            (_) => {
              'data': [userMessage('msg_u1', 'hola'), assistantWorking()],
            },
          ),
          source: source,
        );
        addTearDown(vm.dispose);

        await vm.load();
        vm.connectStream();

        // El mensaje del turno todavía no entró a la lista: el único que puede
        // seguir creciendo es el que no tiene `time.completed`.
        source.emit('session.text.delta', {
          'assistantMessageID': 'msg_aun_no_llego',
          'text': ' 이어',
        });
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(vm.lastAssistant!.textContent, 'Estoy 이어');
      },
    );
  });

  group('refresh() mergea', () {
    test('no tira lo que loadEarlier() trajo', () async {
      var call = 0;
      final vm = buildVm(
        jsonClient((_) {
          call++;
          if (call == 1) {
            // Página inicial en `desc`: la más nueva primero.
            return {
              'data': [
                userMessage('msg_u3', 'tercero'),
                userMessage('msg_u2', 'segundo'),
              ],
              'cursor': {'previous': 'cur1'},
            };
          }
          if (call == 2) {
            // `loadEarlier` en `asc`: la más vieja primero.
            return {
              'data': [
                userMessage('msg_u0', 'cero'),
                userMessage('msg_u1', 'primero'),
              ],
            };
          }
          // El re-fetch del `*.ended`: la última página, con un mensaje nuevo.
          return {
            'data': [
              userMessage('msg_u4', 'cuarto'),
              userMessage('msg_u3', 'tercero'),
              userMessage('msg_u2', 'segundo'),
            ],
          };
        }),
      );
      addTearDown(vm.dispose);

      await vm.load();
      expect(vm.messages.map((m) => m.id), ['msg_u2', 'msg_u3']);

      await vm.loadEarlier();
      expect(vm.messages.map((m) => m.id), [
        'msg_u0',
        'msg_u1',
        'msg_u2',
        'msg_u3',
      ]);

      // Antes `refresh() => load()` y `_ingest` borraba todo: la lista se
      // encogía sola debajo del que estaba scrolleando hacia arriba.
      await vm.refresh();
      expect(vm.messages.map((m) => m.id), [
        'msg_u0',
        'msg_u1',
        'msg_u2',
        'msg_u3',
        'msg_u4',
      ]);
    });

    test('una página vacía no borra lo que ya está', () async {
      var call = 0;
      final vm = buildVm(
        jsonClient((_) {
          call++;
          return call == 1
              ? {
                  'data': [userMessage('msg_u1', 'hola')],
                }
              : {'data': <Object?>[]};
        }),
      );
      addTearDown(vm.dispose);

      await vm.load();
      expect(vm.messages, hasLength(1));
      await vm.refresh();
      expect(vm.messages, hasLength(1));
    });

    test('el prompt optimista dura hasta que el server lo confirma', () async {
      var persisted = false;
      final vm = buildVm(
        jsonClient((request) {
          if (request.method == 'POST') {
            return {
              'data': {'id': 'msg_1'},
            };
          }
          // Página en `desc`: el prompt persistido va primero.
          return {
            'data': [
              if (persisted) userMessage('msg_u1', 'hola'),
              userMessage('msg_u0', 'anterior'),
            ],
          };
        }),
      );
      addTearDown(vm.dispose);

      await vm.load();
      await vm.send('hola');
      expect(vm.messages.last.id, startsWith('local_'));

      // El server todavía no lo trae: la burbuja optimista no puede parpadear.
      await vm.refresh();
      expect(vm.messages.map((m) => m.id), ['msg_u0', 'local_1']);

      // Cuando aparece con id real, la optimista se cae sola: el merge la
      // reconoce por el texto, no por el id.
      persisted = true;
      await vm.refresh();
      expect(vm.messages.map((m) => m.id), ['msg_u0', 'msg_u1']);
    });
  });

  group('status del turno', () {
    test('kChatStatusEvents lista los eventos que el server REAL manda', () {
      // Adjudicado 2026-09-28. Este test decía lo contrario y tenía razón en
      // seemingarlo: afirmaba que `session.execution.*` "no está en el
      // protocolo" y que escucharlo era "afirmar evidencia de turno que nadie
      // manda".
      //
      // Se capturó el stream global (`GET /api/event`) durante un turno
      // completo contra `:4098` y estos son los tipos que llegaron, textuales:
      //
      //   session.execution.started    x1   {"sessionID":"ses_…"}
      //   session.execution.succeeded  x1   {"sessionID":"ses_…"}
      //   session.step.started/streamed/ended, session.text.*, session.reasoning.*,
      //   session.tool.*, session.usage.updated, session.renamed, …
      //
      // `session.status` e `session.idle` NO aparecen ni una vez. La premisa
      // del test era falsa, y creerla era exactamente lo que congelaba el
      // botón Detener para siempre: el VM esperaba un evento que nunca venía.
      //
      // Se conservan los nombres v1 en el conjunto a propósito: si algún build
      // los emitiera, son la misma señal. Un conjunto con nombres de más no
      // rompe nada; uno con nombres de menos sí.
      expect(kChatStatusEvents, contains('session.execution.started'));
      expect(kChatStatusEvents, contains('session.execution.succeeded'));
      // La evidencia de que los v1 no llegan: no hay ni uno en la captura.
      expect(kChatStatusEvents, contains('session.status'));
      expect(kChatStatusEvents, contains('session.idle'));
    });

    // El cierre del turno, medido de punta a punta sobre el stream real.
    for (final pair in <(String, bool)>[
      ('session.execution.started', true),
      ('session.execution.succeeded', false),
    ]) {
      test('${pair.$1} deja working = ${pair.$2}', () async {
        final source = FakeEventSource();
        final vm = buildVm(
          questionClient(calls: <String>[], replyStatus: () => 204),
          source: source,
        );
        addTearDown(vm.dispose);

        await vm.load();
        vm.connectStream();

        source.emit('session.execution.started', {'sessionID': kSessionId});
        await pumpEventQueue();
        expect(vm.working, isTrue, reason: 'el turno arrancó');

        source.emit('session.execution.succeeded', {'sessionID': kSessionId});
        await pumpEventQueue();
        expect(vm.working, isFalse, reason: 'el turno terminó: vuelve Enviar');
      });
    }

    test('el mensaje type:"idle" no se pinta como burbuja', () async {
      // El server lo inserta en la página al cerrar cada turno. Sin el filtro
      // caía en el `default` de `SessionMessage.fromJson` como SystemMessage
      // vacío: una burbuja en blanco por turno.
      final vm = buildVm(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'msg_x',
                  'time': {'created': 1},
                  'type': 'idle',
                  'outcome': 'idle',
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      addTearDown(vm.dispose);
      await vm.load();
      expect(vm.messages, isEmpty);
    });

    test(
      'un status retry con action dice en cuántos segundos reintenta',
      () async {
        final source = FakeEventSource();
        final vm = buildVm(
          questionClient(calls: <String>[], replyStatus: () => 204),
          source: source,
        );
        addTearDown(vm.dispose);

        await vm.load();
        vm.connectStream();

        source.emit('session.status', {
          'status': {
            'type': 'retry',
            'attempt': 1,
            'message': 'rate limited',
            'next': 8000,
            'action': {
              'reason': 'rate_limit',
              'provider': 'opencode-go',
              'title': 'Cuota del provider agotada',
              'message': 'Se reintenta solo en unos segundos.',
              'label': 'Ver limites',
              'link': 'https://example.test/limits',
            },
          },
        });
        await pumpEventQueue();

        // `retry` es un `busy`: el turno sigue, pero ahora se dice por qué.
        expect(vm.working, isTrue);
        expect(
          vm.retryNotice,
          'Reintentando en 8s — Cuota del provider agotada',
        );

        source.emit('session.status', {
          'status': {'type': 'busy'},
        });
        await pumpEventQueue();
        expect(vm.retryNotice, isNull, reason: 'un busy no inventa un motivo');

        source.emit('session.status', {
          'status': {
            'type': 'retry',
            'next': 30000,
            'action': {'title': 'Sigo sin red'},
          },
        });
        await pumpEventQueue();
        expect(vm.retryNotice, 'Reintentando en 30s — Sigo sin red');

        source.emit('session.status', {
          'status': {'type': 'idle'},
        });
        await pumpEventQueue();
        expect(vm.retryNotice, isNull);
      },
    );
  });
}
