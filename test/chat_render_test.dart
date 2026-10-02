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
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
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
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

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
  // 7.4: el turno termino si hay `time.completed` **o** `finish`. Un turno
  // `complete: false` tiene que omitir las dos, si no el fixture dice
  // "terminado" y los tests que esperan un turno vivo mienten.
  if (complete) 'finish': 'stop',
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
  int _seq = 0;

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
      // Un id por frame, como el server: el viewmodel dedupea por `id`
      // (§7.1) y dos frames del mismo tipo con el mismo id se comen el
      // segundo.
      id: 'evt_${++_seq}_$type',
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

/// Plataforma de `image_picker` **fchea**, para probar el Clip sin telefono.
///
/// No es un mock generico. `getImage` —el camino de una sola foto— **lanza a
/// proposito**: volver de `pickMultiImage` a `pickImage` es exactamente el bug
/// que abrio este archivo (el selector de Android no dejaba marcar mas de una
/// imagen), asi que el camino de uno solo tiene que romper el test con un
/// mensaje que lo diga, no devolver en silencio una foto y dejar pasar el
/// defecto.
///
/// `extends` + `MockPlatformInterfaceMixin`, y no `implements`: el paquete
/// verifica la plataforma al asignarla y un `implements` puro hace fallar un
/// assert. Con `extends` los metodos que no se toquen heredan el
/// `UnimplementedError` de la base, asi que no hay que escribir los 20.
class _FakePicker extends ImagePickerPlatform with MockPlatformInterfaceMixin {
  _FakePicker(this.files);

  /// Lo que "devuelve la galeria": rutas falsas, el Clip no las abre.
  final List<XFile> files;

  /// Cuantas veces se pidio la seleccion multiple.
  int multiCalls = 0;

  /// El ultimo metodo que se llamo, para el mensaje de error del assert.
  String lastCall = '(ninguno)';

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    multiCalls++;
    lastCall = 'getMultiImageWithOptions';
    return files;
  }

  @override
  Future<List<XFile>?> getMultiImage({
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
  }) async {
    multiCalls++;
    lastCall = 'getMultiImage';
    return files;
  }

  @override
  Future<XFile?> getImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
  }) async {
    lastCall = 'getImage';
    throw StateError(
      'getImage(): se abrio el selector de UNA sola foto. Con esa llamada el '
      'usuario no puede marcar mas de una imagen.',
    );
  }
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
    // Sin `onOpenDiff` el chip no se pinta: antes aparecia siempre y
    // contestaba con un Snackbar que promete "lo abre la vista de archivos"
    // sin que hubiera nada conectado detras. Sin handler, no hay accion.
    expect(
      find.text('Abrir diff'),
      findsNothing,
      reason: 'una accion sin handler no se ofrece',
    );

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

    // La caja tiene altura FIJA y scroll interno (lo que pidió el usuario:
    // kToolListMaxHeight), así que con 4 tools la cuarta queda fuera del
    // viewport hasta que se scrollea. Este ensureVisible es lo que
    // prueba que el scroll interno funciona, no un rodeo.
    await tester.ensureVisible(find.widgetWithText(ToolCard, 'subagent'));
    await tester.pumpAndSettle();
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
      //
      // El server de este test cierra el assistant en el re-fetch que dispara
      // el `step.ended`: por §7.4 el turno termina con `idle` **y** el último
      // assistant cerrado, y los dos llegan juntos.
      final source = ControllableSource();
      var turnClosed = false;
      final vm = ChatViewModel(
        ApiClient(
          config: kConfig,
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'data': [
                  userJson('msg_u1', 'hola'),
                  assistantJson(
                    id: 'msg_a_live',
                    complete: turnClosed,
                    content: [
                      toolJson(
                        id: 'call_1',
                        name: 'shell',
                        output: 'ok',
                        input: {'command': 'ls'},
                      ),
                    ],
                  ),
                ],
              }),
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
      addTearDown(vm.dispose);
      await pumpChat(tester, vm);

      // Adjudicado 2026-09-28. Antes la caja "arrancaba abierta" mientras el
      // turno trabajaba, y el test fijaba eso. El usuario reportó que las
      // herramientas le llenaban el chat de más altura, y la causa era esa:
      // hay **una caja por mensaje de assistant**, así que un chat de 30 turnos
      // acababa con 30 cajas abiertas de 180 px cada una.
      //
      // La regla nueva es una sola y no admite excepciones: la caja es un
      // resumen de una línea y sólo se abre si el usuario la abre. Un rebuild
      // —un delta, un poll— no la abre ni la cierra.
      expect(vm.working, isTrue);
      expect(find.byType(ToolCard), findsNothing, reason: 'arranca comprimida');

      await tester.tap(find.byKey(TurnActivityBox.headKey));
      await tester.pump();
      expect(find.byType(ToolCard), findsOneWidget, reason: 'abierta a mano');

      // Un delta llega: el VM notifica, el chat se rebuilda, la caja NO se
      // toca. Esta parte del contrato no cambió y es la que más fácil se rompe.
      source.emit('session.text.delta', {
        'messageID': 'msg_a_live',
        'text': 'sigo',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        find.byType(ToolCard),
        findsOneWidget,
        reason: 'un rebuild no puede pisar el toggle manual',
      );

      // Tampoco la abre un status busy (working sigue true, no hay transición).
      source.emit('session.execution.started', {'sessionID': kSessionId});
      await tester.pump();
      expect(find.byType(ToolCard), findsOneWidget);

      // El turno termina: `succeeded` + el `step.ended` que hace que el
      // re-fetch traiga el assistant ya cerrado.
      turnClosed = true;
      source.emit('session.execution.succeeded', {'sessionID': kSessionId});
      source.emit('session.step.ended', {'assistantMessageID': 'msg_a_live'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(vm.working, isFalse);
      // Y sigue abierta, porque la decisión es del usuario y no del estado del
      // turno: si se auto-cerrara, el usuario que la abrió para leer una tool
      // la perdería justo cuando el texto de arriba se está acomodando.
      expect(
        find.byType(ToolCard),
        findsOneWidget,
        reason: 'terminar el turno no le roba la caja al usuario',
      );
    },
  );

  testWidgets('la hoja de acciones lista sólo lo que tiene algo detrás', (
    tester,
  ) async {
    // Adjudicado 2026-09-28. Este test pedía 12 filas exactas y el orden del
    // prototipo. ElEnum tenía 12 y **ninguna hacía nada**: `onAction` no lo
    // pasaba nadie, así que la hoja cerraba y no pasaba nada. Eso es lo que
    // reportó el usuario ("ninguna de las configuraciones funciona").
    //
    // Se.cross-checkearon contra el spec del dialecto v2
    // (`openapi.json`, sección `/api/session/{sessionID}`) y contra el server
    // real. De las 12, sólo 5 tienen respaldo:
    //
    //   Compactar           -> POST /api/session/{id}/compact        (medido)
    //   Deshacer            -> POST /api/session/{id}/revert/stage
    //                          + /revert/commit                     (medido)
    //   Exportar markdown   -> local
    //   Modo lectura        -> local
    //   Estadísticas        -> local
    //
    // Las 7 sacadas -- Renombrar, OpenCode Hub, Rehacer, Prompts, Fork de la
    // sesión, Historial de prompts y Ajustes del chat -- existen en el cliente
    // de escritorio o en la maqueta, pero el dialecto v2 **no expone endpoint
    // para ninguna**. Un botón inerte promete una función que no se puede
    // cumplir, y por eso se fueron en vez de quedar ahí mintiendo.
    //
    // El orden que queda es el del prototipo, no el alfabético del enum.
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
    expect(ChatSessionAction.values, hasLength(5));
    expect(ChatSessionAction.values.map((a) => a.label).toList(), [
      'Compactar',
      'Deshacer',
      'Exportar markdown',
      'Modo lectura',
      'Estadísticas',
    ]);

    // Y lo que no se fue: que ninguna acción sea un adorno. Cada una ejecuta
    // algo o el enum se vació de nuevo.
    for (final action in ChatSessionAction.values) {
      expect(action.icon, isNotEmpty, reason: '${action.name} necesita glifo');
    }
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

  // ───────────────────────── helpers de la card de pregunta ────────────────

  /// Un tool `question` con el `input` como **string crudo**, que es la forma
  /// real de v2 (`tool.dart`: en `pending` el `input` es un `String`, no un
  /// mapa). Antes la card leía sólo el mapa y quedaba siempre vacía.
  Map<String, Object?> questionStringInput() => toolJson(
    id: 'call_q',
    name: 'question',
    status: 'pending',
    input: jsonEncode({
      'questions': [
        {
          'header': 'Arquitectura',
          'question': 'Donde vive la lista de sesiones?',
          'options': [
            {'label': 'App Flutter mobile nueva', 'description': 'Android/iOS'},
            {'label': 'Modulo dentro de OpenHer'},
          ],
        },
      ],
    }),
  );

  Map<String, Object?> questionTurn() => assistantJson(
    id: 'msg_a_q',
    complete: false,
    content: [questionStringInput()],
  );

  /// ViewModel con un server de laboratorio: contesta la lista, el
  /// `POST /prompt` y el `POST …/question/{id}/reply` con el status que se le
  /// pida (404 = el build medido en `:4098`, donde ese path no existe).
  Future<ChatViewModel> questionVm({
    required List<Map<String, Object?>> messages,
    required int replyStatus,
    required void Function(String method, String path, String body) onCall,
    ChatEventSource? source,
  }) async {
    final vm = ChatViewModel(
      ApiClient(
        config: kConfig,
        client: MockClient((request) async {
          final path = request.url.path;
          onCall(request.method, path, request.body);
          if (path.endsWith('/reply')) {
            if (replyStatus != 204) {
              return http.Response(
                jsonEncode({'message': 'not found'}),
                replyStatus,
                headers: const {'content-type': 'application/json'},
              );
            }
            return http.Response('', 204);
          }
          if (path.endsWith('/prompt')) {
            return http.Response(
              jsonEncode({
                'data': {'id': 'msg_1'},
              }),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({'data': messages}),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      ),
      sessionId: kSessionId,
      sessionInfo: kSession,
      streamFactory: (config, directory) => source ?? SilentSource(),
    );
    await vm.load();
    if (source != null) vm.connectStream();
    return vm;
  }

  testWidgets('una question con input en STRING pinta la card y sus opciones', (
    tester,
  ) async {
    final vm = await loadedVm([userJson('msg_u1', 'hola'), questionTurn()]);
    addTearDown(vm.dispose);
    await pumpChat(tester, vm);

    // El `input` crudo es un JSON en string: si sólo se leyera el mapa, la
    // card saldría vacía y el turno quedaría trabado detrás del botón Detener.
    expect(find.byType(QuestionCard), findsOneWidget);
    expect(find.text('Arquitectura'), findsOneWidget);
    expect(find.text('Donde vive la lista de sesiones?'), findsOneWidget);
    expect(find.text('App Flutter mobile nueva'), findsOneWidget);
    expect(find.text('Android/iOS'), findsOneWidget);
    expect(find.text('Modulo dentro de OpenHer'), findsOneWidget);
    // Y no miente "pensando": con una pregunta esperando no hay puntos.
    expect(
      find.byType(TypingDots),
      findsNothing,
      reason: 'el modelo esta esperando al usuario, no escribiendo',
    );
  });

  testWidgets('un input de question que no es JSON no rompe la card', (
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
            input: 'a medio escribir',
          ),
        ],
      ),
    ]);
    addTearDown(vm.dispose);
    await pumpChat(tester, vm);

    // Sin preguntas que pintar: el header genérico y el "Ahora no" (que siempre
    // funciona) siguen ahí. La lista de mensajes no se rompe.
    expect(find.byType(QuestionCard), findsOneWidget);
    expect(find.text('Pregunta del agente'), findsOneWidget);
    expect(find.byKey(QuestionCard.skipKey), findsOneWidget);
  });

  testWidgets('la card contesta por el endpoint de reply cuando existe', (
    tester,
  ) async {
    final calls = <String>[];
    final source = ControllableSource();
    final vm = await questionVm(
      messages: [userJson('msg_u1', 'hola'), questionTurn()],
      replyStatus: 204,
      onCall: (method, path, body) => calls.add('$method $path $body'),
      source: source,
    );
    addTearDown(vm.dispose);
    await pumpChat(tester, vm);

    // El `requestID` vive en el evento, no en el mensaje.
    source.emit('question.asked', {
      'id': 'que_42',
      'questions': <Object?>[],
      'tool': {'messageID': 'msg_a_q', 'callID': 'call_q'},
    });
    await tester.pump();
    // El re-fetch del `question.asked` (250 ms) es lo que hace que la card
    // vuelva a construirse con el `requestID` pegado.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(vm.requestIdFor('call_q'), 'que_42');

    await tester.tap(find.text('App Flutter mobile nueva'));
    await tester.pump();
    await tester.tap(find.byKey(QuestionCard.submitKey));
    await tester.pump();
    await tester.pump();

    expect(
      calls.any(
        (c) =>
            c.startsWith('POST /api/session/$kSessionId/question/que_42/reply'),
      ),
      isTrue,
      reason: 'la card tiene que pegarle al endpoint del protocolo',
    );
    expect(
      calls.where(
        (c) => c.contains('"answers":[["App Flutter mobile nueva"]]'),
      ),
      isNotEmpty,
      reason: 'el body es {answers:[[…]]}: un array por pregunta',
    );
    expect(
      calls.where((c) => c.contains('/prompt')),
      isEmpty,
      reason: 'si el endpoint existe no se manda un prompt de más',
    );
    expect(vm.questionReplyViaApi, isTrue);
  });

  testWidgets('si el endpoint da 404 la respuesta va como prompt y se avisa', (
    tester,
  ) async {
    final calls = <String>[];
    final vm = await questionVm(
      messages: [userJson('msg_u1', 'hola'), questionTurn()],
      replyStatus: 404,
      onCall: (method, path, body) => calls.add('$method $path $body'),
    );
    addTearDown(vm.dispose);
    await pumpChat(tester, vm);

    await tester.tap(find.text('Modulo dentro de OpenHer'));
    await tester.pump();
    await tester.tap(find.byKey(QuestionCard.submitKey));
    await tester.pump();
    await tester.pump();

    expect(
      calls.any((c) => c.contains('POST /api/session/$kSessionId/prompt')),
      isTrue,
      reason: 'el fallback es un prompt normal: siempre funciona',
    );
    expect(
      calls.any((c) => c.contains('"text":"Modulo dentro de OpenHer"')),
      isTrue,
    );
    // Y no se oculta: el usuario tiene que saber por dónde se contestó.
    expect(
      find.textContaining('no expone el endpoint de preguntas'),
      findsOneWidget,
    );
  });

  testWidgets('un status retry se muestra como "Reintentando en Ns"', (
    tester,
  ) async {
    final source = ControllableSource();
    final vm = await liveVm([userJson('msg_u1', 'hola'), richTurn()], source);
    addTearDown(vm.dispose);
    await pumpChat(tester, vm);

    expect(find.textContaining('Reintentando'), findsNothing);

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
          'message': 'Se reintenta solo.',
          'label': 'Ver limites',
        },
      },
    });
    await tester.pump();
    await tester.pump();

    expect(
      find.text('Reintentando en 8s — Cuota del provider agotada'),
      findsOneWidget,
      reason: 'un retry dice el motivo y la cuenta, no sólo "ocupado"',
    );

    source.emit('session.status', {
      'status': {'type': 'idle'},
    });
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Reintentando'), findsNothing);
  });

  testWidgets('con onOpenDiff el chip existe y le pasa el tool al shell', (
    tester,
  ) async {
    final opened = <AssistantTool>[];
    final vm = await loadedVm([userJson('msg_u1', 'hola'), richTurn()]);
    addTearDown(vm.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: ChatView(viewModel: vm, onOpenDiff: opened.add),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(TurnActivityBox.headKey));
    await tester.pump();
    await tester.tap(find.widgetWithText(ToolCard, 'edit'));
    await tester.pump();

    expect(find.text('Abrir diff'), findsOneWidget);
    // El chip queda debajo del pliegue de la lista: hay que traerlo a la
    // pantalla antes de tocarlo.
    await tester.ensureVisible(find.text('Abrir diff'));
    await tester.pump();
    await tester.tap(find.text('Abrir diff'));
    await tester.pump();

    expect(opened, hasLength(1));
    expect(opened.single.name, 'edit');
  });

  group('adjuntar varias fotos de una', () {
    late _FakePicker picker;
    late ImagePickerPlatform original;

    setUp(() {
      original = ImagePickerPlatform.instance;
      picker = _FakePicker(<XFile>[
        XFile('/falso/a.jpg', name: 'a.jpg'),
        XFile('/falso/b.png', name: 'b.png'),
        XFile('/falso/c.webp', name: 'c.webp'),
      ]);
      ImagePickerPlatform.instance = picker;
    });

    tearDown(() => ImagePickerPlatform.instance = original);

    testWidgets('el Clip abre el selector multiple y deja las 3 adjuntas', (
      tester,
    ) async {
      final vm = await loadedVm([userJson('msg_u1', 'hola'), richTurn()]);
      addTearDown(vm.dispose);
      await pumpChat(tester, vm);

      // Antes de tocar el Clip no hay tira de adjuntos.
      expect(
        find.byKey(ChatComposer.attachmentsKey),
        findsNothing,
        reason: 'la tira de adjuntos no deberia existir todavia',
      );

      await tester.tap(find.byKey(ChatComposer.attachKey));
      await tester.pumpAndSettle();

      // **La** asercion que muerde: si vuelve `pickImage`, `getImage` lanza y
      // `lastCall` dice cual de los dos caminos se tomo.
      expect(
        picker.lastCall,
        anyOf('getMultiImageWithOptions', 'getMultiImage'),
        reason:
            'el Clip tiene que pedir la seleccion MULTIPLE. Termino en '
            '${picker.lastCall}, que es el camino de una sola foto.',
      );
      expect(picker.multiCalls, 1);
      // 3 fotos elegidas -> 3 adjuntos: ni 1 ni 0.
      expect(find.byKey(ChatComposer.attachmentsKey), findsOneWidget);
      expect(find.byKey(ChatComposer.attachmentThumbKey(0)), findsOneWidget);
      expect(find.byKey(ChatComposer.attachmentThumbKey(2)), findsOneWidget);
      expect(find.byKey(ChatComposer.attachmentThumbKey(3)), findsNothing);
    });

    testWidgets('elegir fotos dos veces ACUMULA y no reemplaza', (
      tester,
    ) async {
      final vm = await loadedVm([userJson('msg_u1', 'hola'), richTurn()]);
      addTearDown(vm.dispose);
      await pumpChat(tester, vm);

      await tester.tap(find.byKey(ChatComposer.attachKey));
      await tester.pumpAndSettle();
      expect(find.byKey(ChatComposer.attachmentThumbKey(2)), findsOneWidget);

      // La segunda tanda son las mismas 3. Si `_pending` se reemplazara en vez
      // de acumular, el indice 2 seguiria existiendo y el 5 no.
      await tester.tap(find.byKey(ChatComposer.attachKey));
      await tester.pumpAndSettle();

      expect(picker.multiCalls, 2);
      expect(find.byKey(ChatComposer.attachmentThumbKey(5)), findsOneWidget);
      expect(find.byKey(ChatComposer.attachmentThumbKey(6)), findsNothing);
    });

    testWidgets('un archivo que no es imagen se rechaza y lo demas pasa', (
      tester,
    ) async {
      picker = _FakePicker(<XFile>[
        XFile('/falso/a.jpg', name: 'a.jpg'),
        XFile('/falso/notas.txt', name: 'notas.txt'),
      ]);
      ImagePickerPlatform.instance = picker;

      final vm = await loadedVm([userJson('msg_u1', 'hola'), richTurn()]);
      addTearDown(vm.dispose);
      await pumpChat(tester, vm);

      await tester.tap(find.byKey(ChatComposer.attachKey));
      await tester.pumpAndSettle();

      // La buena se admite y la mala no: el filtro es por extension.
      expect(find.byKey(ChatComposer.attachmentThumbKey(0)), findsOneWidget);
      expect(find.byKey(ChatComposer.attachmentThumbKey(1)), findsNothing);
      // Y el rechazo se avisa **una** vez, no uno por archivo.
      expect(
        find.text('1 de 2 no se adjuntaron: no son imágenes.'),
        findsOneWidget,
      );
    });

    testWidgets('la x de un thumb borra solo ese y no los otros', (
      tester,
    ) async {
      final vm = await loadedVm([userJson('msg_u1', 'hola'), richTurn()]);
      addTearDown(vm.dispose);
      await pumpChat(tester, vm);

      await tester.tap(find.byKey(ChatComposer.attachKey));
      await tester.pumpAndSettle();
      expect(find.byKey(ChatComposer.attachmentThumbKey(2)), findsOneWidget);

      // La `x` es un `InkWell` de 16 px sobre el thumb: se toca por coordenada
      // relativa al thumb, no por key, porque no tiene key propia.
      final x = tester.getTopLeft(
        find.byKey(ChatComposer.attachmentThumbKey(1)),
      );
      await tester.tapAt(x + const Offset(40, 0));
      await tester.pumpAndSettle();

      // El de en medio se fue; el de abajo **sube** de lugar, no se corre a la
      // izquierda: son dos elementos, no tres con un hueco.
      expect(find.byKey(ChatComposer.attachmentThumbKey(0)), findsOneWidget);
      expect(find.byKey(ChatComposer.attachmentThumbKey(1)), findsOneWidget);
      expect(find.byKey(ChatComposer.attachmentThumbKey(2)), findsNothing);
    });

    testWidgets('mandar 3 fotos NO las manda dos veces', (tester) async {
      // **El doble envio que se escondia.** Mientras el composer no recibia
      // `attachments`, `onSend` mergeaba `_pending` con lo que el composer le
      // devolvia (que era `[]`), asi que nunca se noto. Al conectar
      // `attachments`, cada foto fue **dos** veces al server: mismo uri, mismo
      // nombre, doble payload, y el modelo recibia cada foto repetida.
      final bodies = <Map<String, Object?>>[];
      final vm = ChatViewModel(
        ApiClient(
          config: kConfig,
          client: MockClient((req) async {
            if (req.method == 'POST' && req.url.path.endsWith('/prompt')) {
              bodies.add(jsonDecode(req.body) as Map<String, Object?>);
            }
            return http.Response(
              jsonEncode({'data': <Object?>[]}),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }),
        ),
        sessionId: kSessionId,
        sessionInfo: kSession,
        streamFactory: (config, directory) => SilentSource(),
      );
      await vm.load();
      addTearDown(vm.dispose);
      await pumpChat(tester, vm);

      await tester.tap(find.byKey(ChatComposer.attachKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(ChatComposer.inputKey), 'mira esto');
      await tester.pump();
      await tester.tap(find.byKey(ChatComposer.sendKey));
      await tester.pumpAndSettle();

      expect(bodies, hasLength(1), reason: 'un solo POST a /prompt');
      final files = (bodies.single['files']! as List)
          .cast<Map<String, Object?>>();
      expect(files, hasLength(3), reason: '3 fotos, no 6');
      // El `name` que se manda es `XFile.name`, que en `cross_file` se deriva
      // del path (`path.split(pathSeparator).last`, el `name:` del constructor
      // esta **ignorado**). En el host de test el separador es `\`, asi que la
      // ruta falsa queda entera; en Android sale `a.jpg`. Lo que importa aqui
      // es el orden y que ninguna se repita.
      expect(
        files.map((f) => f['name']),
        <String>['/falso/a.jpg', '/falso/b.png', '/falso/c.webp'],
        reason: 'el orden es el del picker, sin repetir',
      );
    });
  });
}
