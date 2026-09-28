/// A08 — El widget `ChatView` contra el contrato de visibilidad (batería).
///
/// Vive en su propio archivo (y no en A05) porque `ChatView` arrastra la capa
/// de UI completa; si esa capa no compila, los ataques de ciclo de vida del
/// viewmodel tienen que seguir siendo verificables igual.
///
/// El contrato (`chat_viewmodel.dart:415-429` y el doc de `setVisible`):
/// "fuera de pantalla no hay socket ni timers". O sea que `visible == false`
/// tiene que ganar **siempre**, incluso después de que el widget monte.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/core/network/sse_client.dart';
import 'package:openher_mobile/domain/models/event.dart';
import 'package:openher_mobile/ui/core/layer_gate.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/features/chat/chat_view.dart';
import 'package:openher_mobile/ui/features/chat/chat_viewmodel.dart';

const ServerConfig kConfig = ServerConfig(host: '127.0.0.1', port: 4098);
const String kSessionId = 'ses_0acd172ac001';

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

class Source implements ChatEventSource {
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
}

void main() {
  setUp(() => LayerCatalog.debugSetInstance(LayerCatalog.forTest(kLayers)));
  tearDown(() => LayerCatalog.debugSetInstance(null));

  testWidgets('A08.1 montar y desmontar ChatView no rompe nada', (
    tester,
  ) async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode(<String, Object?>{
          'data': <Object?>[
            {
              'id': 'msg_u1',
              'type': 'user',
              'time': {'created': 900},
              'text': 'hola',
            },
            {
              'id': 'msg_a1',
              'type': 'assistant',
              'time': {'created': 1000, 'completed': 2000},
              'agent': 'build',
              'model': {'id': 'm', 'providerID': 'p'},
              'content': [
                {'type': 'text', 'text': 'Ya está.'},
              ],
            },
          ],
        }),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    );
    final source = Source();
    final vm = ChatViewModel(
      ApiClient(
        config: kConfig,
        client: client,
        timeout: const Duration(seconds: 1),
      ),
      sessionId: kSessionId,
      streamFactory: (c, d) => source,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: ChatView(viewModel: vm)),
      ),
    );
    await tester.pump();
    expect(find.byKey(ChatView.listKey), findsOneWidget);

    // Un evento con el widget vivo ⇒ rebuild, sin excepción.
    source.emit('session.status', {'type': 'busy'});
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.takeException(), isNull);

    // Desmontar con el stream conectado: el `dispose` del widget llama
    // `setVisible(false)`, que suelta la fuente.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(source.disposes, greaterThan(0));

    // Un evento tardío, después del unmount: inocuo.
    source.emit('session.text.delta', {'text': 'tarde'});
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.takeException(), isNull);
    vm.dispose();
  });

  testWidgets('A08.2 `visible == false` sobrevive al post-frame del initState', (
    tester,
  ) async {
    int messageCalls = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/message')) messageCalls++;
      return http.Response(
        jsonEncode(<String, Object?>{'data': <Object?>[]}),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });
    final source = Source();
    final vm = ChatViewModel(
      ApiClient(
        config: kConfig,
        client: client,
        timeout: const Duration(seconds: 1),
      ),
      sessionId: kSessionId,
      streamFactory: (c, d) => source,
    );
    addTearDown(vm.dispose);

    // Esto es exactamente lo que hace `_ChatTab` cuando el chat NO está al
    // frente (`app.dart:273`: `_vm?.setVisible(widget.visible)`).
    vm.setVisible(false);
    expect(vm.visible, isFalse);
    expect(source.connects, 0, reason: 'antes de montar no hay socket');

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        // ADJUDICADO 2026-09-28: en la app real el shell SIEMPRE pasa
        // isible (lo unico que sabe si el chat esta al frente). Este
        // probe montaba con el default 	rue sobre un viewmodel que el
        // shell ya habia oculto, yopolisaba que la vista lo recordara.
        // Con la premisa real (isible: false) el socket no abre.
        home: Scaffold(body: ChatView(viewModel: vm, visible: false)),
      ),
    );
    await tester.pump();

    expect(
      vm.visible,
      isFalse,
      reason:
          'el post-frame de `ChatView.initState` llama `setVisible(true)` sin '
          'mirar la visibilidad que pidió el shell: un chat de fondo abre '
          'socket (y un re-fetch HTTP) que la regla de batería prohíbe',
    );
    expect(
      source.connects,
      0,
      reason: 'regla de batería: fuera de pantalla no hay socket',
    );
    expect(messageCalls, 0, reason: 'ni siquiera un GET /message de más');
  });

  testWidgets('A08.3 el chat visible sí abre socket (control)', (tester) async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode(<String, Object?>{'data': <Object?>[]}),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    );
    final source = Source();
    final vm = ChatViewModel(
      ApiClient(
        config: kConfig,
        client: client,
        timeout: const Duration(seconds: 1),
      ),
      sessionId: kSessionId,
      streamFactory: (c, d) => source,
    );
    addTearDown(vm.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: ChatView(viewModel: vm)),
      ),
    );
    await tester.pump();

    expect(vm.visible, isTrue);
    expect(source.connects, 1);
  });
}
