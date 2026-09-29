import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/domain/models/message.dart';
import 'package:openher_mobile/ui/features/chat/chat_viewmodel.dart';

/// Un solo juego de puntos de escritura, y sólo en el assistant que se está
/// escribiendo.
///
/// El síntoma reportado era "a veces me aparecen muchos spinner en el chat y
/// luego desaparecen". La causa: la condición era `working && texto vacío`, y
/// `working` es del **turno entero**. Un mensaje de assistant que sólo trae
/// tool calls tiene `textContent` vacío **por diseño**, así que cada uno pintaba
/// sus puntos durante todo el turno, y al terminar el turno desaparecían todos
/// juntos. Con dos o tres mensajes así, tres juegos de puntos a la vez.
void main() {
  const kConfig =
      ServerConfig(host: '127.0.0.1', port: 4098, password: 's3cr3t');

  /// Un mensaje de assistant.
  ///
  /// Ojo con el orden: el server manda la página **de más nuevo a más viejo**
  /// (`order=desc`) y el viewmodel la invierte antes de ingerir, así que la
  /// lista interna queda de más viejo a más nuevo. Dar la página al revés hace
  /// que el test mida lo contrario de lo que cree.
  Map<String, Object?> assistant({
    required String id,
    String text = '',
    bool completed = false,
  }) =>
      {
        'id': id,
        'type': 'assistant',
        'time': {
          'created': 1759000000000 +
              (id.codeUnitAt(id.length - 1) - 'a'.codeUnitAt(0)) * 1000,
          if (completed) 'completed': 1759000009000,
        },
        if (text.isNotEmpty) 'content': [{'type': 'text', 'text': text}],
      };

  /// La página como la manda el server: del más nuevo al más viejo.
  String page(List<Map<String, Object?>> data) => jsonEncode({
        'data': data.reversed.toList(),
        'cursor': {'previous': null, 'next': null},
      });

  Future<ChatViewModel> vm(List<Map<String, Object?>> data) async {
    final vm = ChatViewModel(
      ApiClient(
        config: kConfig,
        client: MockClient(
          (_) async => http.Response(
            page(data),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
        timeout: const Duration(seconds: 1),
      ),
      sessionId: 'ses_1',
    );
    addTearDown(vm.dispose);
    return vm;
  }

  group('un solo assistant abierto', () {
    test('es el ultimo de la lista', () async {
      final v = await vm([
        assistant(id: 'msg_a', text: 'primero', completed: true),
        assistant(id: 'msg_b', text: 'segundo'),
      ]);
      await v.load();

      expect(v.openAssistantId, 'msg_b');
    });

    test('ignora los mensajes que no son assistant', () async {
      final v = await vm([
        assistant(id: 'msg_a', text: 'respondio', completed: true),
        {
          'id': 'msg_u',
          'type': 'user',
          'time': {'created': 1759000005000, 'completed': 1759000005000},
          'text': 'pregunta',
        },
      ]);
      await v.load();

      expect(
        v.openAssistantId,
        'msg_a',
        reason: 'el prompt del usuario no es un assistant abierto',
      );
    });

    test('con tres assistant, SOLO el ultimo puede pintar puntos', () async {
      // Los tres sin texto: dos porque todavia no llego delta y uno porque
      // s\u00f3lo trae tool calls. Antes los tres pintaban puntos.
      final v = await vm([
        assistant(id: 'msg_a'),
        assistant(id: 'msg_b'),
        assistant(id: 'msg_c'),
      ]);
      await v.load();

      final abiertos =
          v.messages.where((m) => m.id == v.openAssistantId).length;
      expect(abiertos, 1, reason: 'tiene que haber exactamente uno');

      final sinTexto = v.messages
          .where((m) => m is AssistantMessage)
          .where((m) => (m as AssistantMessage).textContent.trim().isEmpty)
          .length;
      expect(
        sinTexto,
        3,
        reason: 'los tres estan vacios, que es justamente el caso del bug',
      );
    });

    test('sin ningun assistant, no hay abierto', () async {
      final v = await vm([]);
      await v.load();
      expect(v.openAssistantId, isNull);
    });
  });
}
