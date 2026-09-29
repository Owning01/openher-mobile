import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/data/connectivity/network_monitor.dart';
import 'package:openher_mobile/ui/features/chat/chat_viewmodel.dart';

/// El botón Detener, que tiene que **desaparecer** cuando el turno termina.
///
/// ## El bug
///
/// `_fetch()` llamaba primero a `_applyTurnEndFromPage()` (que marca el assistant
/// abierto como terminado, local) y después a `_ingest()` (que pisa los mensajes
/// con la versión del server de esa misma página). Si el server todavía no
/// escribió `finish` en ese mensaje, el `finish` local se **deshacía** en el
/// mismo breath, y `working` volvía a `true`.
///
/// Es el bug de "el mensaje sin `finish` más nuevo" que se ve en el server:
/// `completed: false, finish: null` en el assistant más reciente.
void main() {
  const config = ServerConfig(
    host: '127.0.0.1',
    port: 4098,
    username: 'opencode',
    password: 'p',
  );

  /// Una página que trae: el marcador `idle` (el turno terminó) y, debajo, el
  /// assistant **sin** `finish` — el caso que dispara el bug.
  String pageWithIdleAndOpenAssistant() => jsonEncode({
    'data': [
      {
        'id': 'msg_idle',
        'type': 'idle',
        'time': {'created': 3000},
        'outcome': 'succeeded',
      },
      {
        'id': 'msg_assistant',
        'type': 'assistant',
        'time': {'created': 2000, 'completed': null},
        'content': [
          {'type': 'text', 'text': 'la respuesta'},
        ],
        'finish': null,
      },
      {
        'id': 'msg_user',
        'role': 'user',
        'time': {'created': 1000},
        'content': [
          {'type': 'text', 'text': 'la pregunta'},
        ],
      },
    ],
  });

  ChatViewModel build(String body) {
    final api = ApiClient(
      config: config,
      client: MockClient((req) async {
        if (req.url.path.endsWith('/message')) {
          return http.Response(
            body,
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          '{"data":{}}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    return ChatViewModel(
      api,
      sessionId: 'ses_1',
      // Celular: sin stream, el cierre de turno sólo puede venir por la página.
      streamFactory: null,
      policy: const DataPolicy.lowData(),
    );
  }

  test(
    'el botón Detener desaparece aunque el assistant venga sin finish',
    () async {
      final vm = build(pageWithIdleAndOpenAssistant());
      addTearDown(vm.dispose);

      await vm.load();

      expect(
        vm.working,
        isFalse,
        reason:
            'la página trae el marcador de idle: el turno terminó, más allá '
            'de que el mensaje venga sin finish. El botón Detener no puede '
            'quedarse pegado.',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'sin marcador de idle y con el assistant abierto, SÍ está trabajando',
    () async {
      // El otro lado: si no hay señal de cierre, el botón tiene que seguir ahí.
      // Un arreglo que apagara el botón a lo bruto dejaría al usuario sin forma
      // de cortar un turno largo.
      final vm = build(
        jsonEncode({
          'data': [
            {
              'id': 'msg_assistant',
              'type': 'assistant',
              'time': {'created': 2000, 'completed': null},
              'content': [
                {'type': 'text', 'text': 'todavia escribiendo'},
              ],
              'finish': null,
            },
          ],
        }),
      );
      addTearDown(vm.dispose);

      await vm.load();

      expect(vm.working, isTrue);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
