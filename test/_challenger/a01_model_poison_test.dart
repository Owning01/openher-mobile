/// A01 — Payloads malformados/hostiles contra las fábricas del dominio.
///
/// Regla que se ataca: los `fromJson` son **totales** (nunca tiran) y todo
/// campo ausente vale su default. Cada caso de acá es un payload que un build
/// distinto (o un proxy hostil) podría mandar. Un `throw` acá es BLOCKER: la
/// lista de mensajes se cae y el chat queda en negro.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/domain/models/errors.dart';
import 'package:openher_mobile/domain/models/message.dart';
import 'package:openher_mobile/domain/models/session.dart';
import 'package:openher_mobile/domain/models/tool.dart';

/// Nombres de `type` que el server puede agregar después (API_CONTRACT §4.1).
const List<String> kFutureTypes = [
  'user',
  'assistant',
  'system',
  'synthetic',
  'compaction',
  'agent-switched',
  'model-switched',
  'shell',
];

void main() {
  group('A01.1 SessionMessage.fromJson: type ausente o desconocido', () {
    test('{} no tira y produce un mensaje vacío', () {
      final m = SessionMessage.fromJson(const <String, Object?>{});
      expect(m.id, '');
      expect(m.createdAtMs, 0);
      expect(m, isA<SystemMessage>());
      expect((m as SystemMessage).text, '');
    });

    test('cada type del dialecto v2 se reconoce', () {
      for (final type in kFutureTypes) {
        final m = SessionMessage.fromJson(<String, Object?>{'type': type});
        expect(m, isNotNull, reason: 'type=$type');
      }
    });

    test('un type inventado (futuro) cae en SystemMessage, no revienta', () {
      final m = SessionMessage.fromJson(const <String, Object?>{
        'type': 'session-compacted-v9',
        'id': 'msg_x',
        'text': 'hola',
      });
      expect(m, isA<SystemMessage>());
      expect(m.id, 'msg_x');
    });

    test('type como número / lista / mapa no revienta', () {
      for (final type in <Object?>[
        42,
        null,
        ['user'],
        {'a': 1},
        true,
      ]) {
        final m = SessionMessage.fromJson(<String, Object?>{'type': type});
        expect(m, isA<SystemMessage>(), reason: 'type=$type');
      }
    });
  });

  group('A01.2 AssistantMessage: content nulo / con basura', () {
    test('content ausente ⇒ vacío (no null)', () {
      final a = AssistantMessage.fromJson(const <String, Object?>{});
      expect(a.content, isEmpty);
      expect(a.textContent, '');
    });

    test('content: null ⇒ vacío', () {
      final a = AssistantMessage.fromJson(const <String, Object?>{
        'content': null,
      });
      expect(a.content, isEmpty);
    });

    test('content: [null, {}, "x", 7] no tira y no pierde el texto bueno', () {
      final a = AssistantMessage.fromJson(<String, Object?>{
        'content': <Object?>[
          null,
          <String, Object?>{},
          'x',
          7,
          <String, Object?>{'type': 'text', 'text': 'saludable'},
        ],
      });
      expect(a.content, hasLength(5));
      expect(a.textContent, contains('saludable'));
      // Los basura se vuelven AssistantText vacío: no se cuelgan en el render.
      expect(
        a.content.whereType<AssistantText>().every((t) => t.text.isNotEmpty),
        isFalse,
        reason: 'los items basura se tratan como texto vacío',
      );
    });

    test('content como string/map (no lista) ⇒ vacío, sin throw', () {
      for (final content in <Object?>['texto', 5, <String, Object?>{}]) {
        final a = AssistantMessage.fromJson(<String, Object?>{
          'content': content,
        });
        expect(a.content, isEmpty, reason: 'content=$content');
      }
    });

    test('cost como string ⇒ 0 (no NaN, no throw)', () {
      final a = AssistantMessage.fromJson(const <String, Object?>{
        'cost': '0.011',
      });
      expect(a.cost, 0);
    });

    test('cost como double negativo / NaN-no-JSON no rompe toString', () {
      final a = AssistantMessage.fromJson(const <String, Object?>{
        'cost': -5.5,
      });
      expect(a.cost, -5.5);
      expect(a.serverCostIsFinite, isTrue);
    });
  });

  group('A01.3 TokenUsage: tipos寄托iles', () {
    test('tokens como string / lista ⇒ todo en 0', () {
      for (final raw in <Object?>['123', <Object?>[], 7, null]) {
        final t = TokenUsage.fromJson(raw);
        expect(t.total, 0, reason: 'tokens=$raw');
      }
    });

    // ADJUDICADO 2026-09-28: este probe asumia que un numero|string' no se
    // castea. Se cambio a la inversa a proposito: asInt tolera strings
    // numericos porque un time.completed en string hacia que el turno
    // pareciera eterno y el boton Detener quedara pegado. Mostrar 999 es
    // mejor que mostrar 0: el 0 es un dato falso, el 999 es el dato real.
    test('tokens.input como string numerico se tolera (no se pierde)', () {
      final t = TokenUsage.fromJson(const <String, Object?>{'input': '999'});
      expect(t.input, 999);
      // Un string no numerico sigue cayendo al default, no inventa nada.
      final bad = TokenUsage.fromJson(const <String, Object?>{'input': 'n/d'});
      expect(bad.input, 0);
    });

    test('tokens.input como double ⇒ trunca a int', () {
      final t = TokenUsage.fromJson(const <String, Object?>{'input': 12.9});
      expect(t.input, 12);
    });

    // ADJUDICADO 2026-09-28: misma decision que para input. Un string
    // numerico se tolera; uno no numerico cae al default. Mostrar el
    // numero real es mejor que mostrar un 0 inventado.
    test('cache.read como string numerico se tolera', () {
      final t = TokenUsage.fromJson(<String, Object?>{
        'cache': <String, Object?>{'read': '9000'},
      });
      expect(t.cacheRead, 9000);
      final bad = TokenUsage.fromJson(<String, Object?>{
        'cache': <String, Object?>{'read': 'n/d'},
      });
      expect(bad.cacheRead, 0);
    });
  });

  group('A01.4 MessageTime: completed como string', () {
    test('completed ausente ⇒ isComplete false', () {
      final t = MessageTime.fromJson(const <String, Object?>{'created': 1000});
      expect(t.isComplete, isFalse);
    });

    test('completed como STRING ⇒ ¿el turno se da por terminado?', () {
      // Trampa: si el server (o un proxy) manda `"completed": "2600"` en vez de
      // `2600`, `asInt` devuelve null y `isComplete` queda false ⇒ el botón
      // Detener queda pegado para siempre. El default "no terminado" es el
      // default que MIENTE.
      final t = MessageTime.fromJson(const <String, Object?>{
        'created': 1000,
        'completed': '2600',
      });
      expect(
        t.isComplete,
        isTrue,
        reason:
            'un completed numérico serializado como string no debe dejar el '
            'turno sin terminar (ver API_CONTRACT §7.4)',
      );
    });

    test('completed como double ⇒ trunca a int y termina', () {
      final t = MessageTime.fromJson(const <String, Object?>{
        'created': 1000,
        'completed': 2600.7,
      });
      expect(t.completedMs, 2600);
      expect(t.isComplete, isTrue);
    });

    test('created ausente ⇒ 0, no throw', () {
      final t = MessageTime.fromJson(null);
      expect(t.createdMs, 0);
    });
  });

  group('A01.5 ToolState: state ausente / status raros / error raro', () {
    test('state ausente ⇒ ToolPending, no throw', () {
      final item = AssistantContent.fromJson(<String, Object?>{
        'type': 'tool',
        'id': 'call_1',
        'name': 'shell',
        'executed': false,
      });
      expect(item, isA<AssistantTool>());
      expect((item as AssistantTool).state, isA<ToolPending>());
    });

    test('state: null / string / lista ⇒ ToolPending', () {
      for (final state in <Object?>[null, 'pending', <Object?>[], 7]) {
        final s = ToolState.fromJson(state);
        expect(s, isA<ToolPending>(), reason: 'state=$state');
      }
    });

    test('status: "weird" ⇒ estado que no afirma nada, sin throw', () {
      final s = ToolState.fromJson(const <String, Object?>{
        'status': 'weird',
        'title': 'leyendo',
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': 'salida'},
        ],
      });
      expect(s.statusName, 'pending');
      expect(s.inputText, '');
    });

    test('error como LISTA ⇒ OcErrorInfo vacío, sin throw', () {
      final s = ToolState.fromJson(const <String, Object?>{
        'status': 'error',
        'error': <Object?>['boom', 1, null],
      });
      expect(s, isA<ToolError>());
      expect((s as ToolError).errorMessage, '');
    });

    test('error como STRING ⇒ el texto crudo (canal B medido)', () {
      final s = ToolState.fromJson(const <String, Object?>{
        'status': 'error',
        'error': 'se cayó la tool',
      });
      expect((s as ToolError).errorMessage, 'se cayó la tool');
    });

    test('error como objeto v2 {type,message} ⇒ name + message', () {
      final s = ToolState.fromJson(const <String, Object?>{
        'status': 'error',
        'error': <String, Object?>{'type': 'unknown', 'message': 'boom'},
      });
      expect((s as ToolError).errorMessage, 'boom');
      expect(s.error.name, 'unknown');
    });

    test('completed usa content[] (NO output:String) — Trampa §4.2', () {
      final s = ToolState.fromJson(const <String, Object?>{
        'status': 'completed',
        'output': 'esto NO debe ser la salida',
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': 'la salida real'},
        ],
      });
      expect(s, isA<ToolCompleted>());
      expect(s.textContent, 'la salida real');
    });

    test('HELD/DISEÑO: completed con output:String v1 NO se lee a propósito', () {
      // `tool.dart` declara explícitamente que NO copia el shim de v1
      // (`output: String`) y que la app habla **sólo v2** (decisión D1, que
      // además rechaza un server v1 en el probe con `UnsupportedServerError`).
      // Este test documenta la decisión: si algún día se acepta v1, este assert
      // es el que hay que cambiar.
      final s = ToolState.fromJson(const <String, Object?>{
        'status': 'completed',
        'output': 'la salida vieja',
      });
      expect(s, isA<ToolCompleted>());
      expect(s.textContent, '', reason: 'shim v1 rechazado a propósito');
    });

    test(
      'content con items basura ⇒ TextToolContent vacío, sin perder el bueno',
      () {
        final s = ToolState.fromJson(<String, Object?>{
          'status': 'completed',
          'content': <Object?>[
            null,
            7,
            'texto plano',
            <String, Object?>{'type': 'text', 'text': 'bueno'},
          ],
        });
        expect(s.content, hasLength(4));
        expect(s.textContent, contains('bueno'));
      },
    );

    test('content con uri de 5MB (data: URL) no cuelga', () {
      final s = ToolState.fromJson(<String, Object?>{
        'status': 'completed',
        'content': <Object?>[
          <String, Object?>{
            'type': 'file',
            'uri': 'data:image/png;base64,${'A' * 2000000}',
          },
        ],
      });
      expect(s.content.single, isA<FileToolContent>());
    });
  });

  group('A01.6 AssistantContent: tool sin name/id', () {
    test('tool sin name ni id ⇒ AssistantTool con defaults, sin throw', () {
      final item = AssistantContent.fromJson(const <String, Object?>{
        'type': 'tool',
      });
      expect(item, isA<AssistantTool>());
      final tool = item as AssistantTool;
      expect(tool.name, '');
      expect(tool.id, '');
      expect(tool.executed, isFalse);
      expect(tool.subagentDescription, isNull);
      expect(tool.questionsRaw, isEmpty);
    });

    test('executed como string ⇒ false, no cast', () {
      final tool =
          AssistantContent.fromJson(const <String, Object?>{
                'type': 'tool',
                'name': 'x',
                'state': <String, Object?>{'status': 'pending'},
                'executed': 'true',
              })
              as AssistantTool;
      expect(tool.executed, isFalse);
    });

    test('tool input con questions basura ⇒ lista vacía', () {
      final tool =
          AssistantContent.fromJson(<String, Object?>{
                'type': 'tool',
                'name': 'question',
                'state': <String, Object?>{
                  'status': 'pending',
                  'input': 'pregunta cruda (String, medida)',
                },
              })
              as AssistantTool;
      expect(tool.questionsRaw, isEmpty);
      expect(tool.state.inputText, 'pregunta cruda (String, medida)');
    });

    test('inputText con un Map que no es JSON-encodable no tira', () {
      final s = ToolState.fromJson(<String, Object?>{
        'status': 'running',
        'input': <String, Object?>{'fn': Object()},
      });
      expect(() => s.inputText, returnsNormally);
      expect(s.inputText, isNotEmpty);
    });
  });

  group('A01.7 SessionInfo: campos寄托iles', () {
    test('{} ⇒ sesión vacía sin throw', () {
      final s = SessionInfo.fromJson(const <String, Object?>{});
      expect(s.id, '');
      expect(s.title, '');
      expect(s.directory, '');
      expect(s.cost, 0);
      expect(s.tokens.total, 0);
      expect(s.isArchived, isFalse);
      expect(s.isSubagent, isFalse);
    });

    test('tokens como string ⇒ 0; cost como lista ⇒ 0', () {
      final s = SessionInfo.fromJson(const <String, Object?>{
        'tokens': 'muchos',
        'cost': <Object?>[1],
      });
      expect(s.tokens.total, 0);
      expect(s.cost, 0);
    });

    test('location como string ⇒ directory vacío (no throw)', () {
      final s = SessionInfo.fromJson(const <String, Object?>{
        'location': 'C:/x',
      });
      expect(s.directory, '');
    });

    test('model como string ⇒ null', () {
      final s = SessionInfo.fromJson(const <String, Object?>{'model': 'gpt'});
      expect(s.model, isNull);
    });

    test('model-switched con previous como STRING (no objeto)', () {
      final m = ModelSwitchedMessage.fromJson(const <String, Object?>{
        'type': 'model-switched',
        'model': <String, Object?>{'id': 'a', 'providerID': 'p'},
        'previous': 'el-modelo-anterior',
      });
      expect(m.model.id, 'a');
      // El `previous` crudo se pierde: el modelo anterior queda desconocido.
      expect(
        m.previous?.id,
        'el-modelo-anterior',
        reason: 'previous como string no debería perderse (v1 medido)',
      );
    });
  });

  group('A01.8 OcErrorInfo', () {
    test('null / lista / número ⇒ mensaje vacío, sin throw', () {
      for (final raw in <Object?>[null, <Object?>[], 42, true]) {
        final e = OcErrorInfo.fromJson(raw);
        expect(e.message, '', reason: 'raw=$raw');
        expect(e.toString(), '');
      }
    });

    test('string ⇒ mensaje crudo', () {
      expect(OcErrorInfo.fromJson('boom').message, 'boom');
    });

    test('envoltura v1 {name, data:{message}} ⇒ nombre + mensaje', () {
      final e = OcErrorInfo.fromJson(const <String, Object?>{
        'name': 'APIError',
        'data': <String, Object?>{'message': 'rate limit', 'isRetryable': true},
      });
      expect(e.name, 'APIError');
      expect(e.message, 'rate limit');
    });

    test('v2 assistant.error {type,message,status} ⇒ name=type', () {
      final e = OcErrorInfo.fromJson(const <String, Object?>{
        'type': 'provider.auth',
        'message': 'token vencido',
        'status': 401,
      });
      expect(e.name, 'provider.auth');
      expect(e.message, 'token vencido');
    });

    test('message como lista ⇒ cae al campo `text` o vacío, sin throw', () {
      final e = OcErrorInfo.fromJson(const <String, Object?>{
        'message': <Object?>['a', 'b'],
        'text': 'texto de respaldo',
      });
      expect(e.message, 'texto de respaldo');
    });
  });
}

/// Extensión auxiliar sólo para este archivo: finitud del costo.
extension on AssistantMessage {
  bool get serverCostIsFinite => cost.isFinite;
}
