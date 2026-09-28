/// Tests de **render** del chat: se monta el [ChatView] real con un
/// [ChatViewModel] sobre datos fijos y se toca la pantalla como un usuario.
///
/// Los fixtures son los mismos JSON medidos que en `chat_viewmodel_test.dart`,
/// así que el árbol de widgets que se verifica es el que produce el server, no
/// uno inventado para que el test pase.
///
/// Nota de técnica: los `pump()` son a mano y **no** `pumpAndSettle` porque la
/// caja de actividad de un turno working tiene el spinner de 12 px del
/// prototipo (animación infinita por diseño): con `pumpAndSettle` el test nunca
/// converge.
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
import 'package:openher_mobile/domain/models/message.dart';
import 'package:openher_mobile/domain/models/session.dart';
import 'package:openher_mobile/ui/core/layer_gate.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/features/chat/chat_view.dart';
import 'package:openher_mobile/ui/features/chat/chat_viewmodel.dart';
import 'package:openher_mobile/ui/features/chat/composer.dart';
import 'package:openher_mobile/ui/features/chat/message_bubble.dart';
import 'package:openher_mobile/ui/features/chat/tool_card.dart';
import 'package:openher_mobile/ui/features/chat/turn_activity.dart';

const ServerConfig kConfig = ServerConfig(host: '127.0.0.1', port: 4098);
const String kSessionId = 'ses_render';

/// Defaults de la spec aprobada, recortados a las claves que el chat toca.
/// Las 4 apagadas de la spec están en `false` **y** el test igual verifica que
/// no se pintan: el punto es que el `LayerGate` existe, no que falte el widget.
final Map<String, bool> kLayers = <String, bool>{
  'chat.appbar': true,
  'chat.appbar.back': true,
  'chat.appbar.title': true,
  'chat.appbar.subtitle': false,
  'chat.appbar.overflow': true,
  'chat.header.progress': false,
  'chat.scroll': true,
  'chat.msg.loadmore': true,
  'chat.msg.user.bubble': true,
  'chat.msg.user.attachment': true,
  'chat.msg.assistant': true,
  'chat.msg.system': true,
  'chat.msg.compaction': true,
  'chat.msg.error': true,
  'chat.msg.question': true,
  'chat.typing': true,
  'chat.stream.text': true,
  'chat.activitybox': true,
  'chat.activitybox.head': true,
  'chat.activitybox.chevron': true,
  'chat.activitybox.label': true,
  'chat.activitybox.summary': true,
  'chat.activitybox.body': true,
  'chat.toolcard.subtitle': true,
  'chat.toolcard.status': true,
  'chat.toolcard.expanded': true,
  'chat.toolcard.code': true,
  'chat.toolcard.footer': true,
  'chat.toolcard.error': true,
  'chat.fab.jump': true,
  'chat.composer': true,
  'chat.composer.attachments': true,
  'chat.composer.input': true,
  'chat.composer.attach': true,
  'chat.composer.mic': true,
  'chat.composer.send': true,
  'chat.composer.textarea': true,
  'chat.composer.modelbar': true,
  'chat.composer.model': true,
  'chat.composer.agent': true,
  'chat.composer.tsl': false,
  'chat.composer.counter': false,
  'chat.composer.ctx': true,
  'surfaces.sheet.actions': true,
  'surfaces.sheet.model': true,
  'surfaces.model.agent': true,
  'surfaces.model.item': true,
};

const SessionInfo kSession = SessionInfo(
  id: kSessionId,
  projectID: 'prj_1',
  title: 'Disena las vistas mobile',
  cost: 0.38,
  tokens: TokenUsage(input: 14200, cacheRead: 9000),
  time: SessionTime(createdMs: 1, updatedMs: 2),
  agent: 'build',
  model: ModelRef(id: 'deepseek-v4.1-flash', providerID: 'opencode-go'),
);

Map<String, Object?> userJson(String id, String text) => {
  'id': id,
  'type': 'user',
  'time': {'created': 900},
  'text': text,
  'files': <Object?>[],
};

Map<String, Object?> toolJson({
  required String id,
  required String name,
  String status = 'completed',
  String? output,
  String? errorMessage,
  Object? input,
}) => {
  'type': 'tool',
  'id': id,
  'name': name,
  'executed': false,
  'state': {
    'status': status,
    'input': input ?? <String, Object?>{},
    if (output != null)
      'content': [
        {'type': 'text', 'text': output},
      ],
    if (errorMessage != null)
      'error': {'type': 'tool.execution', 'message': errorMessage},
  },
};

Map<String, Object?> assistantJson({
  required String id,
  bool complete = true,
  List<Map<String, Object?>> content = const [],
}) => {
  'id': id,
  'type': 'assistant',
  'time': {'created': 1000, 'streamed': 1200, if (complete) 'completed': 4600},
  'agent': 'build',
  'model': {'id': 'deepseek-v4.1-flash', 'providerID': 'opencode-go'},
  'content': content,
  'finish': 'stop',
  'cost': 0.011,
  'tokens': {'input': 14200, 'output': 300, 'reasoning': 0},
};

/// Un turno terminado con shell + read + edit + una tool que fallo.
/// `completed: 4600` con `streamed: 1200` da el `3.4s` del resumen.
Map<String, Object?> richTurn() => assistantJson(
  id: 'msg_turn_rich',
  content: [
    toolJson(
      id: 'call_shell',
      name: 'shell',
      output: 'chat_view.dart\ncomposer.dart',
      input: {'command': 'Get-ChildItem lib/ui/features/chat'},
    ),
    toolJson(
      id: 'call_read',
      name: 'read',
      output: '# plan\n\nlinea 1\nlinea 2',
      input: {'filePath': 'docs/plan-matriz-v2.md'},
    ),
    toolJson(
      id: 'call_edit',
      name: 'edit',
      output:
          '  Widget build() {\n-   return ListView();\n+   return ChatView();\n  }',
      input: {'filePath': 'lib/ui/features/chat/chat_view.dart'},
    ),
    toolJson(
      id: 'call_sub',
      name: 'subagent',
      status: 'error',
      errorMessage: 'Explore agent aborted: Tool execution was interrupted',
      input: {'description': 'Map HTTP endpoints'},
    ),
  ],
);

/// Fuente de eventos que nunca emite: el render test no necesita stream y si
/// necesita que no queden timers vivos.
class SilentSource implements ChatEventSource {
  final _events = StreamController<OcEvent>();
  final _states = StreamController<StreamState>();

  @override
  Stream<OcEvent> get events => _events.stream;

  @override
  Stream<StreamState> get stateChanges => _states.stream;

  @override
  StreamState get state => StreamState.streaming;

  @override
  Uri streamUri({int? after}) => kConfig.api('/event');

  @override
  void connect() {}

  @override
  Future<void> dispose() async {
    await _events.close();
    await _states.close();
  }
}

/// Fuente de eventos manejable a mano, para probar la regla de auto-colapso.
class ControllableSource implements ChatEventSource {
  final _events = StreamController<OcEvent>.broadcast();
  final _states = StreamController<StreamState>.broadcast();

  @override
  Stream<OcEvent> get events => _events.stream;

  @override
  Stream<StreamState> get stateChanges => _states.stream;

  @override
  StreamState get state => StreamState.streaming;

  @override
  Uri streamUri({int? after}) => kConfig.api('/event');

  @override
  void connect() {}

  @override
  Future<void> dispose() async {
    await _events.close();
    await _states.close();
  }

  void emit(String type, Map<String, Object?> data) => _events.add(
    OcEvent(
      id: 'evt_$type',
      type: type,
      data: {'sessionID': kSessionId, ...data},
    ),
  );
}

/// ViewModel con la sesion real y los mensajes del fixture, servidos por el
/// mismo camino que en produccion: `GET /api/session/{id}/message`. Nada de
/// setters de test sobre el VM.
ChatViewModel vmFor(List<Map<String, Object?>> messages) => ChatViewModel(
  ApiClient(
    config: kConfig,
    client: MockClient(
      (_) async => http.Response(
        jsonEncode({'data': messages}),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    ),
  ),
  sessionId: kSessionId,
  sessionInfo: kSession,
  streamFactory: (config, directory) => SilentSource(),
);

/// Igual que [vmFor] pero ya cargado: los tests de render necesitan los
/// mensajes en el VM antes del primer `pumpWidget`.
Future<ChatViewModel> loadedVm(List<Map<String, Object?>> messages) async {
  final vm = vmFor(messages);
  await vm.load();
  return vm;
}

/// Igual que [loadedVm] pero con una fuente de eventos a mano.
Future<ChatViewModel> liveVm(
  List<Map<String, Object?>> messages,
  ChatEventSource source,
) async {
  final vm = ChatViewModel(
    ApiClient(
      config: kConfig,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'data': messages}),
          200,
          headers: const {'content-type': 'application/json'},
        ),
      ),
    ),
    sessionId: kSessionId,
    sessionInfo: kSession,
    streamFactory: (config, directory) => source,
  );
  await vm.load();
  vm.connectStream();
  return vm;
}

/// Pump del chat completo, con el tema de la app (no el de test).
Future<void> pumpChat(WidgetTester tester, ChatViewModel vm) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: ChatView(viewModel: vm)),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() => LayerCatalog.debugSetInstance(LayerCatalog.forTest(kLayers)));
  tearDown(() => LayerCatalog.debugSetInstance(null));

  testWidgets('la caja de actividad muestra la fila plegada con su categoria', (
    tester,
  ) async {
    final vm = await loadedVm([userJson('msg_u1', 'hola'), richTurn()]);
    addTearDown(vm.dispose);
    await pumpChat(tester, vm);

    expect(find.byKey(TurnActivityBox.headKey), findsOneWidget);
    expect(find.text('SHELL · READ · EDIT · SUBAGENT'), findsOneWidget);
    // Plegada: se ve el resumen con la duracion del turno, pero ninguna tool.
    expect(find.text('4 herramientas · 3.4s'), findsOneWidget);
    expect(find.byType(ToolCard), findsNothing);
  });

  testWidgets('tocar la fila abre las ToolCards', (tester) async {
    final vm = await loadedVm([userJson('msg_u1', 'hola'), richTurn()]);
    addTearDown(vm.dispose);
    await pumpChat(tester, vm);

    await tester.tap(find.byKey(TurnActivityBox.headKey));
    await tester.pump();

    expect(find.byType(ToolCard), findsNWidgets(4));
    expect(find.text('shell'), findsOneWidget);
    expect(find.text('read'), findsOneWidget);
    expect(find.text('edit'), findsOneWidget);
    expect(find.text('subagent'), findsOneWidget);
    // El subtitulo sale del `input` de cada tool, no del input crudo en JSON.
    expect(find.text('Get-ChildItem lib/ui/features/chat'), findsOneWidget);
    expect(find.text('docs/plan-matriz-v2.md'), findsOneWidget);
  });

  testWidgets('una tool completed muestra su salida al tocarla', (
    tester,
  ) async {
    final vm = await loadedVm([userJson('msg_u1', 'hola'), richTurn()]);
    addTearDown(vm.dispose);
    await pumpChat(tester, vm);
    await tester.tap(find.byKey(TurnActivityBox.headKey));
    await tester.pump();

    // Plegada: no se ve la salida.
    expect(find.textContaining('linea 2'), findsNothing);

    // El `edit` es el que tiene diff.
    await tester.tap(find.widgetWithText(ToolCard, 'edit'));
    await tester.pump();

    expect(find.textContaining('-   return ListView();'), findsOneWidget);
    expect(find.text('Copiar'), findsOneWidget);
    expect(find.text('Abrir diff'), findsOneWidget);

    // El `shell` no tiene diff: su pie solo ofrece Copiar.
    await tester.tap(find.widgetWithText(ToolCard, 'shell'));
    await tester.pump();
    expect(find.text('chat_view.dart\ncomposer.dart'), findsOneWidget);
  });

  testWidgets('una tool error se marca y muestra su errorMessage', (
    tester,
  ) async {
    final vm = await loadedVm([userJson('msg_u1', 'hola'), richTurn()]);
    addTearDown(vm.dispose);
    await pumpChat(tester, vm);
    await tester.tap(find.byKey(TurnActivityBox.headKey));
    await tester.pump();

    // El rotulo de error, sin tocar nada mas.
    expect(find.text('Error'), findsOneWidget);

    await tester.tap(find.widgetWithText(ToolCard, 'subagent'));
    await tester.pump();

    expect(
      find.text('Explore agent aborted: Tool execution was interrupted'),
      findsOneWidget,
    );
  });

  testWidgets('el mensaje del usuario sale como burbuja a la derecha', (
    tester,
  ) async {
    final vm = await loadedVm([
      userJson('msg_u1', 'Usa el server local.'),
      assistantJson(id: 'msg_a1'),
    ]);
    addTearDown(vm.dispose);
    await pumpChat(tester, vm);

    expect(find.text('Usa el server local.'), findsOneWidget);
    final bubble = tester.widget<Align>(
      find
          .ancestor(
            of: find.text('Usa el server local.'),
            matching: find.byType(Align),
          )
          .first,
    );
    expect(bubble.alignment, Alignment.centerRight);
  });

  testWidgets('el boton de enviar es Detener cuando working', (tester) async {
    // Sin `time.completed` el viewmodel queda trabajando (API_CONTRACT 7.4).
    final vm = await loadedVm([
      userJson('msg_u1', 'hola'),
      assistantJson(
        id: 'msg_a1',
        complete: false,
        content: [
          toolJson(
            id: 'call_1',
            name: 'shell',
            output: 'ok',
            input: {'command': 'ls'},
          ),
        ],
      ),
    ]);
    addTearDown(vm.dispose);
    expect(vm.working, isTrue);

    await pumpChat(tester, vm);

    expect(find.byKey(ChatComposer.sendKey), findsOneWidget);
    expect(find.byTooltip('Detener'), findsOneWidget);
    expect(find.byTooltip('Enviar'), findsNothing);
    // Y la caja de actividad working muestra el spinner, no el resumen.
    expect(find.textContaining('herramientas'), findsNothing);
  });

  testWidgets('terminado el turno el boton vuelve a ser Enviar', (
    tester,
  ) async {
    final vm = await loadedVm([userJson('msg_u1', 'hola'), richTurn()]);
    addTearDown(vm.dispose);
    expect(vm.working, isFalse);

    await pumpChat(tester, vm);

    expect(find.byTooltip('Enviar'), findsOneWidget);
    expect(find.byTooltip('Detener'), findsNothing);
  });

  testWidgets('las 3 capas apagadas de la spec no se pintan', (tester) async {
    // El viewmodel TIENE modelo, agente y contexto: si las capas estuvieran
    // prendidas, el subtitulo, el contador y el chip TSL saldrian.
    final vm = await loadedVm([userJson('msg_u1', 'hola'), richTurn()]);
    addTearDown(vm.dispose);
    expect(kSession.model, isNotNull);
    expect(kSession.agent, isNotNull);
    await pumpChat(tester, vm);

    // chat.appbar.subtitle
    expect(find.text('deepseek-v4.1-flash · build'), findsNothing);
    // chat.composer.counter
    expect(find.textContaining('/20000'), findsNothing);
    // chat.composer.tsl
    expect(find.text('TSL'), findsNothing);

    // Y lo que si esta prendido se ve: titulo, pills y contexto.
    expect(find.text('Disena las vistas mobile'), findsOneWidget);
    expect(find.text('deepseek-v4.1-flash'), findsOneWidget);
    expect(find.text('build'), findsOneWidget);
    expect(find.text(r'14.2k contexto · $0.38'), findsOneWidget);
  });

  testWidgets('un assistant con error del proveedor pinta la caja de error', (
    tester,
  ) async {
    final vm = await loadedVm([
      userJson('msg_u1', 'hola'),
      {
        ...assistantJson(
          id: 'msg_a_err',
          content: [
            {
              'type': 'text',
              'text': 'Me corto el rate limit a mitad del parrafo.',
            },
          ],
        ),
        'error': {
          'type': 'provider.auth',
          'message': 'Upstream request failed (status 429)',
        },
      },
    ]);
    addTearDown(vm.dispose);
    await pumpChat(tester, vm);

    expect(find.text('Error del proveedor'), findsOneWidget);
    expect(
      find.text('provider.auth: Upstream request failed (status 429)'),
      findsOneWidget,
    );
    // El texto parcial que quedo se sigue viendo debajo.
    expect(
      find.text('Me corto el rate limit a mitad del parrafo.'),
      findsOneWidget,
    );
  });

  testWidgets('una tool question pendiente pinta la card de pregunta', (
    tester,
  ) async {
    final vm = await loadedVm([
      userJson('msg_u1', 'hola'),
      assistantJson(
        id: 'msg_a_q',
        complete: false,
        content: [
          toolJson(
            id: 'call_q',
            name: 'question',
            status: 'pending',
            input: {
              'questions': [
                {
                  'header': 'Arquitectura',
                  'question': 'Donde vive la lista de sesiones?',
                  'options': [
                    {
                      'label': 'App Flutter mobile nueva',
                      'description': 'Android/iOS',
                    },
                    {'label': 'Modulo dentro de OpenHer'},
                  ],
                },
              ],
            },
          ),
        ],
      ),
    ]);
    addTearDown(vm.dispose);
    await pumpChat(tester, vm);

    expect(find.byType(QuestionCard), findsOneWidget);
    expect(find.text('Donde vive la lista de sesiones?'), findsOneWidget);
    expect(find.text('App Flutter mobile nueva'), findsOneWidget);
    expect(find.text('Modulo dentro de OpenHer'), findsOneWidget);
  });

  testWidgets('los puntos de escritura aparecen mientras no llega texto', (
    tester,
  ) async {
    final vm = await loadedVm([
      userJson('msg_u1', 'hola'),
      assistantJson(id: 'msg_a1', complete: false),
    ]);
    addTearDown(vm.dispose);
    await pumpChat(tester, vm);

    expect(find.byType(TypingDots), findsOneWidget);
  });

  testWidgets('el aviso de compactacion es una pila centrada', (tester) async {
    final vm = await loadedVm([
      userJson('msg_u1', 'hola'),
      {
        'id': 'msg_c1',
        'type': 'compaction',
        'time': {'created': 2000},
        'reason': 'auto',
        'summary': 'resumen',
        'recent': '',
      },
      richTurn(),
    ]);
    addTearDown(vm.dispose);
    await pumpChat(tester, vm);

    expect(
      find.text('Contexto compactado · se conservaron los últimos 12 mensajes'),
      findsOneWidget,
    );
  });

  testWidgets(
    'un abierto manual sobrevive los rebuilds y solo se cierra al terminar '
    'el turno',
    (tester) async {
      // Es la regla que mas fácil se rompe: si `_open` se recalculara en cada
      // build, un delta de texto se comería el toggle del usuario.
      final source = ControllableSource();
      final vm = await liveVm([
        userJson('msg_u1', 'hola'),
        assistantJson(
          id: 'msg_a_live',
          complete: false,
          content: [
            toolJson(
              id: 'call_1',
              name: 'shell',
              output: 'ok',
              input: {'command': 'ls'},
            ),
          ],
        ),
      ], source);
      addTearDown(vm.dispose);
      await pumpChat(tester, vm);

      // Turno trabajando + thinkingDefault: la caja arranca abierta.
      expect(vm.working, isTrue);
      expect(find.byType(ToolCard), findsOneWidget);

      await tester.tap(find.byKey(TurnActivityBox.headKey));
      await tester.pump();
      expect(find.byType(ToolCard), findsNothing, reason: 'cerrada a mano');

      // Un delta llega: el VM notifica, el chat se rebuilda, la caja NO se
      // toca.
      source.emit('session.text.delta', {
        'messageID': 'msg_a_live',
        'text': 'sigo',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        find.byType(ToolCard),
        findsNothing,
        reason: 'un rebuild no puede pisar el toggle manual',
      );

      // Tampoco la abre un status busy (working sigue true, no hay transicion).
      source.emit('session.status', {'type': 'busy'});
      await tester.pump();
      expect(find.byType(ToolCard), findsNothing);

      // Ahora si: el turno termina (working true -> false) y ahi se cierra.
      source.emit('session.status', {'type': 'idle'});
      await tester.pump();
      expect(vm.working, isFalse);
      expect(find.byType(ToolCard), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  testWidgets('la hoja de acciones tiene las 12 filas, en orden', (
    tester,
  ) async {
    final vm = await loadedVm([userJson('msg_u1', 'hola'), richTurn()]);
    addTearDown(vm.dispose);
    await pumpChat(tester, vm);

    await tester.tap(find.byKey(ChatView.overflowKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    for (final action in ChatSessionAction.values) {
      expect(
        find.text(action.label),
        findsOneWidget,
        reason: 'falta la fila ${action.name}',
      );
    }
    expect(ChatSessionAction.values, hasLength(12));
    // El orden es el del prototipo, no el del enum alfabético.
    expect(ChatSessionAction.values.map((a) => a.label).toList(), [
      'Renombrar',
      'OpenCode Hub',
      'Deshacer',
      'Rehacer',
      'Compactar',
      'Exportar markdown',
      'Prompts',
      'Fork de la sesión',
      'Modo lectura',
      'Historial de prompts',
      'Ajustes del chat',
      'Estadísticas de la sesión',
    ]);
  });

  testWidgets('una accion de la hoja se la pasa al shell', (tester) async {
    final picked = <ChatSessionAction>[];
    final vm = await loadedVm([userJson('msg_u1', 'hola'), richTurn()]);
    addTearDown(vm.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: ChatView(viewModel: vm, onAction: picked.add),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(ChatView.overflowKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Compactar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(picked, [ChatSessionAction.compact]);
  });
}
