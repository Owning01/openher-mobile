import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/app.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/domain/models/message.dart';
import 'package:openher_mobile/domain/models/session.dart';
import 'package:openher_mobile/core/network/sse_client.dart';
import 'package:openher_mobile/core/storage/creds_store.dart';
import 'package:openher_mobile/core/storage/prefs_store.dart';
import 'package:openher_mobile/domain/models/event.dart';
import 'package:openher_mobile/ui/core/layer_gate.dart';
import 'package:openher_mobile/ui/features/chat/chat_view.dart';
import 'package:openher_mobile/ui/features/chat/chat_viewmodel.dart';
import 'package:openher_mobile/ui/features/navigation/mobile_bottom_nav.dart';
import 'package:openher_mobile/ui/features/navigation/mobile_nav.dart';

/// El shell: arranque y la pestaña Chat.
///
/// El destino Chat se construye siempre (es un `IndexedStack`), y con un id de
/// sesión vacío el `load()` del viewmodel sacaba un
/// `GET /api/session//message?limit=30&order=desc`: una ruta que no existe en
/// el server, en cada arranque y en cada `leaveChat()`. Acá se verifica que sin
/// sesión **no existe viewmodel**: sin `ChatView` en el árbol no hay `load()`,
/// así que no hay request que no pueda satisfacerse, y el estado que se muestra
/// es honesto en vez de un banner de error.
void main() {
  final prefs = PrefsStore(prefs: InMemoryPrefs());
  final creds = CredsStore(store: InMemorySecureStore());

  const config = ServerConfig(
    host: '127.0.0.1',
    port: 4848,
    username: 'u',
    password: 'p',
  );

  setUp(() => LayerCatalog.debugSetInstance(null));
  tearDown(() => LayerCatalog.debugSetInstance(null));

  /// El shell montado, con el catálogo de capas ya en memoria.
  ///
  /// Se pumpa [AppShell] y no [OpenHerMobileApp] a propósito: la app raíz carga
  /// el catálogo del bundle y despacha al shell según las credenciales, y lo que
  /// se verifica acá es el comportamiento del shell.
  ///
  /// Devuelve la [MobileNav] inyectada: es la única forma de abrir una sesión
  /// sin un server detrás (el camino normal es tocar una fila de la lista).
  Future<MobileNav> pumpShell(WidgetTester tester) async {
    final nav = MobileNav();
    LayerCatalog.debugSetInstance(
      LayerCatalog.forTest(const {
        'app.bottomnav': true,
        'sessions.appbar': true,
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          config: config,
          prefs: prefs,
          creds: creds,
          nav: nav,
          // Sin stream real: un socket de verdad deja timers vivos y el test
          // falla con "A Timer is still pending".
          chatStreamFactory: (_, _) => _FakeEventSource(),
          onProbe: (_) async {},
          onLoggedOut: () {},
        ),
      ),
    );
    await tester.pump();
    return nav;
  }

  testWidgets('sin credenciales arranca en Conectar', (tester) async {
    await tester.pumpWidget(OpenHerMobileApp(prefs: prefs, creds: creds));
    // El arranque carga el catálogo de capas: un pump alcanza.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Conectar'), findsWidgets);
    expect(find.text('Host'), findsOneWidget);
    expect(find.text('Puerto'), findsOneWidget);
    expect(find.text('Usuario'), findsOneWidget);
    expect(find.text('Contraseña'), findsOneWidget);
  });

  testWidgets('sin sesión abierta el chat NO construye viewmodel', (
    tester,
  ) async {
    await pumpShell(tester);

    // Estamos en el shell, no en Conectar.
    expect(find.byType(MobileBottomNav), findsOneWidget);
    // `ChatView` es lo único que muestra el resultado de `load()`. Si no está,
    // no se creó `ChatViewModel`, y por lo tanto no salió
    // `/api/session//message` (una ruta que no puede existir).
    //
    // `skipOffstage: false` porque el `IndexedStack` marca como offstage al
    // destino que no está al frente: sin esto el finder ni lo miraría, y el
    // test pasaría por la razón equivocada.
    expect(find.byType(ChatView, skipOffstage: false), findsNothing);
  });

  testWidgets('sin sesión abierta el chat dice qué hacer, no muestra error', (
    tester,
  ) async {
    await pumpShell(tester);

    expect(
      find.byKey(AppShell.noChatSessionKey, skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.text('Sin sesión abierta', skipOffstage: false),
      findsOneWidget,
    );
    // Un spinner eterno tampoco: no hay nada que esperar.
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  /// El viewmodel del chat: se llega por el `ChatView` que lo muestra.
  ChatViewModel vmOf(WidgetTester tester) => tester
      .widget<ChatView>(find.byType(ChatView, skipOffstage: false))
      .viewModel;

  testWidgets('cambiar de pestaña pausa el stream del chat', (tester) async {
    final nav = await pumpShell(tester);

    // Abrir una sesión: sin esto el destino Chat ni se puede seleccionar (el
    // bottom-nav lo deshabilita) y nunca hay viewmodel que pausar.
    nav.openSession(kTestSession('ses_abc'));
    await tester.pump();
    expect(vmOf(tester).visible, isTrue, reason: 'el chat está al frente');

    // Ir a Ajustes tocando la barra: el chat queda montado (IndexedStack) pero
    // fuera de pantalla, que es justo cuando tiene que pausar el stream.
    await tester.tap(find.text('Ajustes'));
    await tester.pump();
    expect(
      vmOf(tester).visible,
      isFalse,
      reason: 'con el chat fuera de pantalla no hay socket ni poll de 2 s',
    );

    // Y volver al chat lo reanuda.
    await tester.tap(find.text('Chat'));
    await tester.pump();
    expect(vmOf(tester).visible, isTrue);
  });

  test('leaveChat vacía la sesión y devuelve al primer destino', () {
    final nav = MobileNav();
    // El destino Chat sin sesión no se puede seleccionar: la lista lo cubre.
    nav.select(MobileTab.chat);
    expect(nav.tab, MobileTab.sessions);

    nav.openSession(kTestSession('ses_abc'));
    expect(nav.tab, MobileTab.chat);
    expect(nav.chatSessionId, 'ses_abc');

    // El `+` de la lista y el tap de una fila usan el mismo camino.
    nav.leaveChat();
    expect(nav.chatSessionId, isNull);
    expect(nav.tab, MobileTab.sessions);
  });

  test('MobileTab.chat tiene glifo propio (no repite el de sesiones)', () {
    final icons = MobileTab.values.map((t) => t.icon).toList();
    expect(
      icons.toSet().length,
      icons.length,
      reason: 'los destinos del pulgar tienen que ser distinguibles',
    );
  });
}

/// Stream del chat que no abre nada: el test del shell verifica la propagación
/// de visibilidad, no la red. Con un SSE real el test cierra con "A Timer is
/// still pending".
class _FakeEventSource implements ChatEventSource {
  final StreamController<OcEvent> _events = StreamController.broadcast();
  final StreamController<StreamState> _states = StreamController.broadcast();

  @override
  Stream<OcEvent> get events => _events.stream;

  @override
  Stream<StreamState> get stateChanges => _states.stream;

  @override
  StreamState get state => StreamState.streaming;

  @override
  Uri streamUri({int? after}) => Uri.parse('http://127.0.0.1/api/event');

  @override
  void connect() {}

  @override
  Future<void> dispose() async {
    await _events.close();
    await _states.close();
  }
}

/// Una sesiÃ³n mÃ­nima para los tests que abren el chat.
///
/// `onOpen` pasÃ³ a llevar la sesiÃ³n **entera** (no sÃ³lo el id) para que el chat
/// reciba su `agent` y su `model`: sin ellos, al reentrar los pills del
/// composer volvÃ­an a decir "Elegir". Es un cambio de firma, no de
/// comportamiento: lo que los tests afirman sigue siendo lo mismo.
SessionInfo kTestSession(String id) => SessionInfo(
  id: id,
  projectID: 'prj_1',
  title: 'test',
  cost: 0,
  tokens: const TokenUsage(),
  time: const SessionTime(createdMs: 0, updatedMs: 0),
);
