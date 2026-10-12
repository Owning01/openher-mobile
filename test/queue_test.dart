/// Regresión de la cola de mensajes (`pendingSend`).
///
/// Dos fallos medidos en uso real, en este orden de gravedad:
///
/// 1. **El pendiente se evaporaba.** `_ingest` dedupea el eco optimista por
///    texto: si el server ya tiene ese texto en el historial, el `local_…` se
///    tira. Pero un pendiente **nunca se POSTeó**, así que una coincidencia de
///    texto no puede ser su eco: es otro mensaje viejo igual ("dale", "seguí").
///    Cada refresh/poll con ese texto en la página borraba lo encolado en
///    silencio.
/// 2. **Confirmar a mitad de turno desviaba el turno.** `confirmSend` POSTeaba
///    sin mirar `working`, y el server contesta 200 `delivery: steer`: redirige
///    el turno en curso en vez de encolar. Todo el diseño de la cola ("frenar
///    antes del POST") quedaba burlado por el propio botón Enviar del pendiente.
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

const _kConfig = ServerConfig(host: '127.0.0.1', port: 4098);
const _kSessionId = 'ses_0acd172ac001';

Map<String, Object?> _assistantWorking() => {
  'id': 'msg_assistant_live',
  'type': 'assistant',
  'time': {'created': 5000, 'streamed': 5200},
  'agent': 'build',
  'model': {'id': 'm', 'providerID': 'p'},
  'content': [
    {'type': 'text', 'text': 'Estoy'},
  ],
};

Map<String, Object?> _user(String id, String text) => {
  'id': id,
  'type': 'user',
  'time': {'created': 900},
  'text': text,
  'files': <Object?>[],
};

class _FakeSource implements ChatEventSource {
  final _events = StreamController<OcEvent>.broadcast();
  final _states = StreamController<StreamState>.broadcast();

  @override
  Stream<OcEvent> get events => _events.stream;

  @override
  Stream<StreamState> get stateChanges => _states.stream;

  @override
  StreamState get state => StreamState.polling;

  @override
  Uri streamUri({int? after}) => _kConfig.api('/event');

  @override
  void connect() {}

  @override
  Future<void> dispose() async {
    await _events.close();
    await _states.close();
  }
}

void main() {
  group('cola de mensajes', () {
    test(
      'el pendiente sobrevive al refresh aunque el server ya tenga ese texto',
      () async {
        // `desc`: lo nuevo primero. El historial ya trae un "dale" viejo.
        final page = {
          'data': [_assistantWorking(), _user('msg_u1', 'dale')],
        };
        final vm = ChatViewModel(
          ApiClient(
            config: _kConfig,
            client: MockClient((request) async {
              if (request.url.path.endsWith('/prompt')) {
                return http.Response(jsonEncode({'data': {}}), 200);
              }
              return http.Response(
                jsonEncode(page),
                200,
                headers: const {'content-type': 'application/json'},
              );
            }),
            timeout: const Duration(seconds: 1),
          ),
          sessionId: _kSessionId,
          streamFactory: (config, directory) => _FakeSource(),
        );
        addTearDown(vm.dispose);

        await vm.load();
        expect(vm.working, isTrue);

        await vm.send('dale');
        expect(vm.pendings, hasLength(1));

        // El poll/refresh trae la misma página: el "dale" del server es el
        // viejo, no el eco del pendiente (que nunca se POSTeó).
        await vm.refresh();
        expect(
          vm.pendings,
          hasLength(1),
          reason: 'un pendiente nunca se POSTeó: el texto igual del server '
              'no es su eco y no lo puede borrar',
        );
      },
    );

    test('confirmar a mitad de turno no hace POST (no desvía)', () async {
      final prompts = <Uri>[];
      final page = {
        'data': [_assistantWorking(), _user('msg_u1', 'dale')],
      };
      final vm = ChatViewModel(
        ApiClient(
          config: _kConfig,
          client: MockClient((request) async {
            if (request.url.path.endsWith('/prompt')) {
              prompts.add(request.url);
              return http.Response(jsonEncode({'data': {}}), 200);
            }
            return http.Response(
              jsonEncode(page),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }),
          timeout: const Duration(seconds: 1),
        ),
        sessionId: _kSessionId,
        streamFactory: (config, directory) => _FakeSource(),
      );
      addTearDown(vm.dispose);

      await vm.load();
      await vm.send('dale');
      final id = vm.pendings.single.id;
      expect(prompts, isEmpty);

      await vm.confirmSend(id);
      expect(
        prompts,
        isEmpty,
        reason: 'mandar a mitad de turno vuelve como steer y desvía el turno '
            'en curso: la cola frena antes del POST',
      );
      expect(vm.pendings, hasLength(1));
    });

    test('el eco normal sin pendiente se sigue dedupeando', () async {
      // Guardia del arreglo: el dedup por texto sigue valiendo para el mensaje
      // recién mandado (no pendiente), o el chat mostraría duplicados.
      var posted = false;
      final vm = ChatViewModel(
        ApiClient(
          config: _kConfig,
          client: MockClient((request) async {
            if (request.url.path.endsWith('/prompt')) {
              posted = true;
              return http.Response(jsonEncode({'data': {}}), 200);
            }
            return http.Response(
              jsonEncode({
                'data': posted ? [_user('msg_srv', 'hola')] : <Object?>[],
              }),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }),
          timeout: const Duration(seconds: 1),
        ),
        sessionId: _kSessionId,
        streamFactory: (config, directory) => _FakeSource(),
      );
      addTearDown(vm.dispose);

      await vm.load();
      expect(vm.working, isFalse);
      await vm.send('hola');
      expect(posted, isTrue);
      await vm.refresh();

      final holas = [
        for (final m in vm.messages)
          if (m is UserMessage && m.text == 'hola') m,
      ];
      expect(holas, hasLength(1));
      expect(holas.single.id, 'msg_srv');
    });
  });
}
