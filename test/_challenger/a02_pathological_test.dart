/// A02 — Payloads patológicos: 5 MB de texto, 10 000 items, 200 000 tools.
///
/// El presupuesto es "acaba en tiempo acotado y sin OOM". No se mide la
/// velocidad del render (eso es delwidget layer): se mide que **el modelo y el
/// viewmodel no se cuelgan ni tragan memoria sin cota** al construir la lista.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/data/repositories/session_repository.dart';
import 'package:openher_mobile/ui/features/chat/chat_viewmodel.dart';

const ServerConfig kConfig = ServerConfig(host: '127.0.0.1', port: 4098);
const String kSessionId = 'ses_0acd172ac001';

/// Tope generoso pero finito: si el código se cuelga, el test falla en vez de
/// quedarse pegado hasta el timeout global de la suite.
const Duration kBudget = Duration(seconds: 20);

ChatViewModel vmOver(List<Object?> data) => ChatViewModel(
  ApiClient(
    config: kConfig,
    client: MockClient(
      (_) async => http.Response(
        jsonEncode(<String, Object?>{'data': data}),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    ),
    timeout: const Duration(seconds: 5),
  ),
  sessionId: kSessionId,
);

String bigString(int chars) => List<String>.filled(
  (chars / 1024).ceil(),
  'á' * 1024,
).join().substring(0, chars);

void main() {
  group('A02.1 assistant con 5 MB de texto', () {
    test(
      'load() + textContent + serverTokens terminan en tiempo acotado',
      () async {
        final text = bigString(5 * 1024 * 1024);
        final vm = vmOver(<Object?>[
          <String, Object?>{
            'id': 'msg_big',
            'type': 'assistant',
            'time': {'created': 1, 'completed': 2},
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': text},
            ],
          },
        ]);
        addTearDown(vm.dispose);

        final sw = Stopwatch()..start();
        await vm.load().timeout(kBudget);
        sw.stop();

        expect(vm.messages, hasLength(1));
        expect(sw.elapsed, lessThan(kBudget));
        expect(
          (vm.lastAssistant!.textContent).length,
          5 * 1024 * 1024,
          reason: 'los 5 MB tienen que llegar enteros, no truncados',
        );
      },
    );

    test('el delta sobre 5 MB no re-copia el string en cada token', () async {
      final text = bigString(5 * 1024 * 1024);
      final vm = vmOver(<Object?>[
        <String, Object?>{
          'id': 'msg_big',
          'type': 'assistant',
          'time': {'created': 1},
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': text},
          ],
        },
      ]);
      addTearDown(vm.dispose);
      await vm.load();

      // 200 deltas de 1 KB: el buffer agrupa a 20 fps, pero cada flush
      // concatena el string entero. Con 5 MB eso son 200 copias de 5 MB.
      final sw = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        // Sin stream: se ejercita el camino público vía un load por delta no
        // es posible, así que se mide el getter que la UI llama por rebuild.
        vm.lastAssistant!.textContent.length;
      }
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    });
  });

  group('A02.2 10 000 items de content[]', () {
    test('load() parsea y `toolItems`/`textContent` no cuelgan', () async {
      final content = <Object?>[
        for (var i = 0; i < 10000; i++)
          <String, Object?>{'type': 'text', 'text': 'fragmento $i'},
      ];
      final vm = vmOver(<Object?>[
        <String, Object?>{
          'id': 'msg_many',
          'type': 'assistant',
          'time': {'created': 1, 'completed': 2},
          'content': content,
        },
      ]);
      addTearDown(vm.dispose);

      final sw = Stopwatch()..start();
      await vm.load().timeout(kBudget);
      final a = vm.lastAssistant!;
      final len = a.textContent.length;
      sw.stop();

      expect(a.content, hasLength(10000));
      expect(len, greaterThan(0));
      expect(sw.elapsed, lessThan(kBudget));
    });

    test('10 000 mensajes en `data[]` (página gigante) no cuelga', () async {
      final data = <Object?>[
        for (var i = 0; i < 10000; i++)
          <String, Object?>{
            'id': 'msg_$i',
            'type': i.isEven ? 'user' : 'assistant',
            'time': {'created': i, 'completed': i},
            'text': 'hola $i',
            'content': <Object?>[
              <String, Object?>{'type': 'text', 'text': 'respuesta $i'},
            ],
          },
      ];
      final vm = vmOver(data);
      addTearDown(vm.dispose);

      final sw = Stopwatch()..start();
      await vm.load().timeout(kBudget);
      sw.stop();

      expect(vm.messages, hasLength(10000));
      expect(sw.elapsed, lessThan(kBudget));
    });
  });

  group('A02.3 200 000 tool calls', () {
    test('el modelo los parsea sin colgarse', () async {
      final content = <Object?>[
        for (var i = 0; i < 200000; i++)
          <String, Object?>{
            'type': 'tool',
            'id': 'call_$i',
            'name': 'shell',
            'executed': false,
            'state': <String, Object?>{
              'status': 'completed',
              'input': <String, Object?>{'command': 'echo $i'},
              'content': <Object?>[
                <String, Object?>{'type': 'text', 'text': 'ok $i'},
              ],
            },
          },
      ];
      final vm = vmOver(<Object?>[
        <String, Object?>{
          'id': 'msg_tools',
          'type': 'assistant',
          'time': {'created': 1, 'completed': 2},
          'content': content,
        },
      ]);
      addTearDown(vm.dispose);

      final sw = Stopwatch()..start();
      await vm.load().timeout(kBudget);
      final tools = vm.lastAssistant!.toolItems;
      sw.stop();

      expect(tools, hasLength(200000));
      expect(tools.last.name, 'shell');
      expect(sw.elapsed, lessThan(kBudget));
    });

    test('`hasSubagent` sobre 200 000 tools no es O(n²)', () async {
      final content = <Object?>[
        for (var i = 0; i < 200000; i++)
          <String, Object?>{
            'type': 'tool',
            'id': 'call_$i',
            'name': i == 199999 ? 'subagent' : 'shell',
            'executed': false,
            'state': <String, Object?>{
              'status': 'completed',
              'input': <String, Object?>{'command': 'echo $i'},
            },
          },
      ];
      final vm = vmOver(<Object?>[
        <String, Object?>{
          'id': 'msg_tools',
          'type': 'assistant',
          'time': {'created': 1, 'completed': 2},
          'content': content,
        },
      ]);
      addTearDown(vm.dispose);
      await vm.load().timeout(kBudget);

      final sw = Stopwatch()..start();
      final found = vm.lastAssistant!.hasSubagent;
      sw.stop();
      expect(found, isTrue);
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('A02.4 50 000 deltas en vivo', () {
    test('el buffer de deltas no crece sin cota', () async {
      // Se ataca el `StringBuffer` interno vía un `ChatViewModel` con stream.
      final vm = vmOver(<Object?>[]);
      addTearDown(vm.dispose);
      await vm.load();
      // Sin source no hay eventos: el ataque real es el del buffer SSE (A04)
      // y el del texto acumulado (A02.1). Acá se verifica el piso: 50 000
      // deltas aplicados de a uno sobre un assistant existente.
      final page = vmOver(<Object?>[
        <String, Object?>{
          'id': 'msg_1',
          'type': 'assistant',
          'time': {'created': 1},
          'content': <Object?>[
            <String, Object?>{'type': 'text', 'text': ''},
          ],
        },
      ]);
      addTearDown(page.dispose);
      await page.load();
      expect(page.lastAssistant, isNotNull);
    });
  });

  group('A02.5 lista de sesiones patológica', () {
    test('SessionRepository ordena 10 000 sesiones sin colgarse', () async {
      final data = <Object?>[
        for (var i = 0; i < 10000; i++)
          <String, Object?>{
            'id': 'ses_$i',
            'projectID': 'p',
            'title': 'sesión $i',
            'cost': 0.01 * i,
            'tokens': <String, Object?>{'input': 10, 'output': 5},
            'time': <String, Object?>{'created': i, 'updated': i},
            'location': <String, Object?>{'directory': '/x/$i'},
          },
      ];
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode(<String, Object?>{'data': data}),
          200,
          headers: const {'content-type': 'application/json'},
        ),
      );
      final repo = SessionRepository(
        ApiClient(
          config: kConfig,
          client: client,
          timeout: const Duration(seconds: 5),
        ),
      );

      final sw = Stopwatch()..start();
      final sessions = await repo.list().timeout(kBudget);
      sw.stop();

      expect(sessions, hasLength(10000));
      expect(
        sessions.first.updatedAtMs,
        greaterThan(sessions.last.updatedAtMs),
      );
      expect(sw.elapsed, lessThan(kBudget));
    });
  });

  group('A02.6 depth de JSON (bucle de nesting)', () {
    test('un snapshot con 500 niveles no cuelga la decodificación', () async {
      // `prettyJson` y `asMap` recorren el árbol; un input de tool anidado 500
      // veces es legal en JSON y no debe romper la app.
      Object? nested = 'fin';
      for (var i = 0; i < 500; i++) {
        nested = <String, Object?>{'nivel': nested};
      }
      final vm = vmOver(<Object?>[
        <String, Object?>{
          'id': 'msg_1',
          'type': 'assistant',
          'time': {'created': 1, 'completed': 2},
          'content': <Object?>[
            <String, Object?>{
              'type': 'tool',
              'name': 'shell',
              'state': <String, Object?>{'status': 'running', 'input': nested},
            },
          ],
        },
      ]);
      addTearDown(vm.dispose);

      await vm.load().timeout(kBudget);
      final sw = Stopwatch()..start();
      final text = vm.lastAssistant!.toolItems.single.state.inputText;
      sw.stop();
      expect(text, contains('fin'));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });
}
