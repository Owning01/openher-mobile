import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/domain/models/message.dart';
import 'package:openher_mobile/domain/models/session.dart';
import 'package:openher_mobile/ui/features/chat/chat_view.dart';
import 'package:openher_mobile/ui/features/chat/chat_viewmodel.dart';

/// El contexto que muestra la app es el contexto de verdad.
///
/// El bug reportado era "el contexto mostrado es incorrecto". La causa no era un
/// redondeo: `serverTokens` devolvía **`session.tokens`**, que es un **contador
/// acumulado** de toda la vida de la sesión, y la etiqueta decía "contexto".
///
/// Medido contra el server real sobre una sesión larga: la app pintaba
/// **15.538.680** donde el contexto real era **102.924** — **151×** inflado.
/// Los números de abajo son los reales de esa sesión, para que el test no mida
/// una invención.
const kRealSession = <String, Object?>{
  // Lo que traía `GET /api/session/{id}`.
  'sessionTokens': <String, Object?>{
    'input': 14527502,
    'output': 802019,
    'reasoning': 0,
    'cache': <String, Object?>{'read': 620738966, 'write': 0},
  },
  // El último assistant, con lo que el modelo tenía cargado.
  'lastAssistantTokens': <String, Object?>{
    'input': 1450,
    'output': 60,
    'reasoning': 98,
    'cache': <String, Object?>{'read': 101376, 'write': 0},
  },
};

void main() {
  const kConfig = ServerConfig(
    host: '127.0.0.1',
    port: 4098,
    password: 's3cr3t',
  );

  Map<String, Object?> assistantWith(
    Map<String, Object?> tokens, {
    String id = 'msg_a',
    int created = 1759000000000,
  }) => {
    'id': id,
    'type': 'assistant',
    'time': {'created': created, 'completed': created + 1000},
    'tokens': tokens,
    'cost': 0.01,
  };

  Future<ChatViewModel> vm(
    List<Map<String, Object?>> data, {
    SessionInfo? info,
  }) async {
    final v = ChatViewModel(
      ApiClient(
        config: kConfig,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': data.reversed.toList(),
              'cursor': {'previous': null, 'next': null},
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
        timeout: const Duration(seconds: 1),
      ),
      sessionId: 'ses_1',
      sessionInfo: info,
    );
    addTearDown(v.dispose);
    await v.load();
    return v;
  }

  /// La `SessionInfo` de la sesión larga medida, con su acumulado gigante.
  ///
  /// Hace falta para que el test no sea **vacuo**: sin `sessionInfo` poblado, el
  /// fallback viejo (`sessionInfo?.tokens.total`) daba `null` y devolvía lo
  /// mismo que el código bueno. Con ella, el test de abajo **falla** si alguien
  /// vuelve al acumulado. Se comprobó rompiéndolo.
  SessionInfo bigSession() => SessionInfo(
    id: 'ses_1',
    projectID: 'prj_1',
    title: 'sesion larga',
    cost: 3.0,
    tokens: const TokenUsage(
      input: 14527502,
      output: 802019,
      cacheRead: 620738966,
    ),
    time: const SessionTime(createdMs: 0, updatedMs: 0),
  );

  group('TokenUsage.context', () {
    test('es input + cacheRead + reasoning', () {
      const t = TokenUsage(
        input: 1450,
        output: 60,
        reasoning: 98,
        cacheRead: 101376,
        cacheWrite: 500,
      );
      expect(t.context, 1450 + 101376 + 98);
    });

    test('cacheWrite NO cuenta: lo relee el proximo turno', () {
      // Lo que este turno escribe en el cache es lo que el siguiente lee como
      // `cache.read`. Contarlo ahora cuenta el mismo prefijo dos veces.
      const a = TokenUsage(input: 100, cacheRead: 5000, cacheWrite: 2000);
      const b = TokenUsage(input: 100, cacheRead: 5000, cacheWrite: 0);
      expect(a.context, b.context);
    });

    test('output NO cuenta: es lo generado, no lo cargado', () {
      const corto = TokenUsage(input: 100, cacheRead: 5000, output: 10);
      const largo = TokenUsage(input: 100, cacheRead: 5000, output: 9999);
      expect(corto.context, largo.context);
    });

    test('sin cache es solo input + reasoning', () {
      const t = TokenUsage(input: 800, reasoning: 200);
      expect(t.context, 1000);
    });

    test('los tres en cero dan cero, no null', () {
      expect(const TokenUsage().context, 0);
    });
  });

  group('ChatViewModel.contextTokens', () {
    test('el real, no el acumulado de la sesion', () async {
      final v = await vm([
        assistantWith(
          kRealSession['lastAssistantTokens']! as Map<String, Object?>,
        ),
      ]);

      final real = 1450 + 101376 + 98;
      expect(v.contextTokens, real);
      expect(
        v.contextTokens,
        isNot(14527502 + 802019),
        reason: 'el acumulado de la sesión NO es el contexto',
      );
    });

    test('con varios assistants gana el ULTIMO, no la suma', () async {
      // El error clásico: sumar todos los `tokens` de la lista. El contexto es
      // una foto de la ventana ahora, y la ventana la define el último turno.
      final v = await vm([
        assistantWith(
          const {'input': 10, 'output': 5},
          id: 'msg_1',
          created: 1759000000000,
        ),
        assistantWith(
          const {
            'input': 1450,
            'reasoning': 98,
            'cache': {'read': 101376},
          },
          id: 'msg_2',
          created: 1759000005000,
        ),
      ]);

      expect(v.contextTokens, 1450 + 101376 + 98);
      expect(v.contextTokens, isNot(10 + 1450 + 98 + 101376));
    });

    test('sin assistant da 0, NO el acumulado de la sesion', () async {
      // El fallback viejo leía `sessionInfo.tokens.total`. Con la sesión larga
      // de verdad eso da 15.538.680 con cero mensajes en la página: el número
      // más grande justamente cuando la app no sabe nada.
      final v = await vm([], info: bigSession());
      expect(
        v.contextTokens,
        0,
        reason: 'sin assistant no hay contexto que informar; el acumulado no '
            'es un sustituto',
      );
    });

    test('con la sesion larga el mensaje gana al acumulado', () async {
      // El caso del bug reportado, con las dos fuentes disponibles y en
      // conflicto. `sessionInfo` dice 15.538.680; el último assistant dice
      // 102.924. Gana el assistant.
      final v = await vm(
        [
          assistantWith(
            kRealSession['lastAssistantTokens']! as Map<String, Object?>,
          ),
        ],
        info: bigSession(),
      );
      expect(v.sessionInfo!.tokens.total, greaterThan(15000000));
      expect(v.contextTokens, 102924);
    });
  });

  group('contextLabel', () {
    test('el porcentaje aparece cuando se conoce la ventana', () {
      // 102.9k de 200k es 51%. Sin el porcentaje, el número solo no dice si
      // 103k es mucho o poco.
      final s = contextLabel(102924, 0.38, window: 200000);
      expect(s, contains('51%'));
      // A 100k el decimal se saca a propósito (`k >= 100 ? 0 : 1`): "103k"
      // informa igual que "102.9k" y ocupa menos.
      expect(s, contains('103k'));
    });

    test('sin ventana no inventa porcentaje', () {
      final s = contextLabel(102924, 0.38);
      expect(s, isNot(contains('%')));
      expect(s, contains('103k'));
    });

    test('con una ventana chica el porcentaje se nota', () {
      // 40k de 128k: acá el decimal sí ayuda, y el porcentaje es lo que dice
      // "estás por la mitad".
      final s = contextLabel(65536, 0.1, window: 131072);
      expect(s, contains('50%'));
      expect(s, contains('65.5k'));
    });

    test('una ventana de 0 no divide por cero', () {
      expect(contextLabel(102924, 0.38, window: 0), isNot(contains('%')));
    });

    test('de 100k en adelante el decimal es ruido', () {
      expect(contextLabel(151000, 1.0), contains('151k'));
      expect(contextLabel(151000, 1.0), isNot(contains('151.0k')));
    });

    test('el costo se mantiene con dos decimales', () {
      expect(contextLabel(1000, 0.5), contains(r'$0.50'));
    });
  });

  group('lo que la app mostraba antes', () {
    test('el acumulado de la sesion es 151x el contexto real', () {
      // El número exacto del bug, medido. Si algún día los dos se parecen, este
      // test avisa de que el server cambió la semántica de `session.tokens` y
      // hay que volver a mirarlo.
      final acumulado =
          (kRealSession['sessionTokens']! as Map<String, Object?>)['input']!
              as int;
      final contexto = 102924;
      expect(acumulado / contexto, greaterThan(100));
    });
  });
}
