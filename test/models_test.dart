// Tests de `lib/domain/models/` contra el JSON REAL del server (dialecto v2).
//
// Todos los fixtures de acá salen de respuestas medidas contra
// `127.0.0.1:4098` (`GET /api/session/{id}/message` y `GET /api/session`) o
// del esquema `packages/sdk/openapi.json`. No hay shapes inventados: si algo no
// está en el server, no está en este archivo.
//
// Se parsea con `jsonDecode` a propósito, que es lo mismo que va a hacer la
// capa de red: el modelo recibe `Map<String, Object?>` y nunca debe tirar.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/domain/models/errors.dart';
import 'package:openher_mobile/domain/models/event.dart';
import 'package:openher_mobile/domain/models/message.dart';
import 'package:openher_mobile/domain/models/session.dart';
import 'package:openher_mobile/domain/models/tool.dart';

Map<String, Object?> decode(String json) =>
    jsonDecode(json) as Map<String, Object?>;

// --- Fixtures medidos -------------------------------------------------------

/// Assistant real de `ses_f19b83c02ffeTyvqP4q0tmFU8a` con un tool `shell`
/// `completed`. Salida del shell recortada; el resto es literal.
const String _assistantWithTool = r'''
{"id":"msg_0e647c46b001bM6b7GYe4kEYfB","time":{"created":1790569858926,
 "streamed":1790569862197,"completed":1790569862612},"type":"assistant",
 "agent":"worker","model":{"id":"space-bunny-free","providerID":"opencode-go",
 "variant":"max"},"content":[
 {"type":"text","text":"I'll start by exploring the project structure."},
 {"type":"tool","id":"call_function_kd6c2dxt4g29_1","name":"shell","executed":false,
  "state":{"status":"completed",
   "input":{"command":"Set-Location 'G:\\Proyectos\\openher-mobile'"},
   "content":[{"type":"text","text":"Mode   Name\n----   ----\n-a    pubspec.yaml"}],
   "metadata":{"status":"completed","truncated":false,"exit":0},
   "time":{"created":1790569861755,"ran":1790569862185,
           "completed":1790569862433}}}],
 "finish":"tool-calls","rawFinish":"tool_calls","cost":0.011,
 "tokens":{"input":1,"output":2,"reasoning":3,"cache":{"read":4,"write":5}},
 "error":null,"snapshot":{"start":"94e4cee4","end":"94e4cee4","files":[]}}
''';

/// Tool `question` real: el `input` es un mapa con `questions[]` de
/// `{question, header, options:[{label, description}]}`.
const String _questionTool = r'''
{"id":"msg_q001","time":{"created":1790568356955},"type":"assistant",
 "agent":"build","model":{"id":"muse-spark-1.3-contributor",
 "providerID":"opencode-go","variant":"xhigh"},
 "content":[{"type":"tool","id":"call_function_jyq9irxzb4an_1","name":"question",
   "executed":false,
   "state":{"status":"completed",
    "input":{"questions":[
      {"question":"¿Qué es exactamente la vista mobile?",
       "header":"Alcance mobile",
       "options":[{"label":"App Flutter mobile nueva",
                   "description":"Un cliente delgado del mismo backend."}]}],
      "multiple":false,"custom":true},
    "content":[{"type":"text","text":"User has answered."}]}}],
 "finish":"tool-calls"}
''';

/// Assistant con el error de mensaje (canal A). `name` + `message` en el
/// sobre, como manda el SDK.
const String _assistantApiError = r'''
{"id":"msg_err1","time":{"created":1789605806638,"completed":1789605807246},
 "type":"assistant","agent":"build",
 "model":{"id":"deepseek-v4.1-flash","providerID":"opencode-go","variant":"max"},
 "content":[],"finish":"error",
 "error":{"name":"APIError","message":"Upstream request failed (status 429)",
          "data":{"statusCode":429,"isRetryable":true}}}
''';

/// Assistant con `content: []` y `error` como objeto v2 medido.
const String _assistantEmptyError = r'''
{"id":"msg_0989d8532001hpOrgBlTQppUl5",
 "time":{"created":1789266858023,"completed":1789266858216},
 "type":"assistant","agent":"build",
 "model":{"id":"deepseek-flash","providerID":"deepseek","variant":"max"},
 "content":[],
 "snapshot":{"start":"94e4cee4","end":"94e4cee4","files":[]},
 "finish":"error",
 "error":{"type":"provider.auth","message":"Provider request failed with HTTP 401",
          "status":401}}
''';

/// Un tool que falló (canal B). `error` es objeto, no string.
const String _assistantToolError = r'''
{"id":"msg_terr1","time":{"created":1790570454319,"completed":1790570455537},
 "type":"assistant","agent":"worker",
 "model":{"id":"space-bunny-free","providerID":"opencode-go","variant":"max"},
 "content":[{"type":"tool","id":"call_function_4fhbyz9hzfex_1","name":"edit",
   "executed":false,
   "state":{"status":"error",
    "input":{"path":"G:\\Proyectos\\openher-mobile\\lib\\layer_gate.dart"},
    "error":{"type":"unknown",
             "message":"Explore agent aborted: Tool execution was interrupted"}}}],
 "finish":"stop"}
''';

/// Un item por cada tipo de mensaje que no sea user/assistant, más el
/// `agent-switched`/`model-switched` con su `previous` (medido en v2).
const String _otherMessageTypes = r'''
[
 {"id":"msg_sys1","time":{"created":1789258797871},"type":"system",
  "text":"The Code Mode tool catalog has changed.",
  "description":"Instructions updated: core/codemode"},
 {"id":"msg_syn1","time":{"created":1789258785408},"type":"synthetic",
  "sessionID":"ses_f685c4cfdffe7Bp2ILFUkX1fTF",
  "text":"The server restarted while you were working.",
  "description":"Continuing after restart"},
 {"id":"msg_cmp1","time":{"created":1789258000000},"type":"compaction",
  "reason":"auto","summary":"Resumen del contexto anterior",
  "recent":"los últimos mensajes"},
 {"id":"msg_agt1","time":{"created":1789250842886},"type":"agent-switched",
  "agent":"build","previous":"plan"},
 {"id":"msg_mdl1","time":{"created":1789252799475},"type":"model-switched",
  "model":{"id":"deepseek-v4.1-flash","providerID":"opencode-go","variant":"max"},
  "previous":{"id":"muse-spark-1.3-contributor","providerID":"opencode-go",
              "variant":"xhigh"}},
 {"id":"msg_shl1","time":{"created":1789257000000},"type":"shell",
  "callID":"sh_0e64bc484001OqT4sKExx32BVP",
  "command":"flutter test","output":"All tests passed!"},
 {"id":"msg_usr1","time":{"created":1789257000001},"type":"user",
  "text":"corré los tests","files":[{"uri":"file:///a.png","mime":"image/png",
  "name":"captura.png"}],"agents":["build"]}
]
''';

/// `SessionV2Info` medido. Trae `location.directory` (spec v2) y `parentID`
/// de subagente.
const String _sessionInfo = r'''
{"id":"ses_f19b83c02ffeTyvqP4q0tmFU8a",
 "parentID":"ses_f685c4cfdffe7Bp2ILFUkX1fTF",
 "projectID":"3535484ff1bbc536c3c6c1e239b27cc59b604c3d","agent":"worker",
 "model":{"id":"space-bunny-free","providerID":"opencode-go","variant":"max"},
 "cost":0.42,
 "tokens":{"input":16549,"output":384,"reasoning":120,
           "cache":{"read":32997,"write":0}},
 "time":{"created":1790569858127,"updated":1790569858132},
 "title":"M2 domain models",
 "location":{"directory":"G:\\Proyectos\\opencode-remote-android"}}
''';

// --- Tests ------------------------------------------------------------------

void main() {
  group('AssistantMessage', () {
    test('parsea el assistant medido con un tool completed', () {
      final msg = SessionMessage.fromJson(decode(_assistantWithTool));

      expect(msg, isA<AssistantMessage>());
      final a = msg as AssistantMessage;

      expect(a.id, 'msg_0e647c46b001bM6b7GYe4kEYfB');
      expect(a.agent, 'worker');
      expect(a.model.id, 'space-bunny-free');
      expect(a.model.providerID, 'opencode-go');
      expect(a.model.variant, 'max');
      expect(a.finish, 'tool-calls');
      expect(a.rawFinish, 'tool_calls');
      expect(a.cost, 0.011);
      expect(a.tokens.input, 1);
      expect(a.tokens.output, 2);
      expect(a.tokens.reasoning, 3);
      expect(a.tokens.cacheRead, 4);
      expect(a.tokens.cacheWrite, 5);
      expect(a.totalTokens, 6); // 1+2+3; el cache no cuenta
      expect(a.isComplete, isTrue);
      expect(a.hasError, isFalse);
      expect(a.createdAtMs, 1790569858926);
      expect(a.textContent, "I'll start by exploring the project structure.");

      // Un tool, y su estado es ToolCompleted con 1 TextToolContent.
      expect(a.toolItems, hasLength(1));
      final tool = a.toolItems.single;
      expect(tool.name, 'shell');
      expect(tool.executed, isFalse);
      expect(tool.state, isA<ToolCompleted>());

      final done = tool.state as ToolCompleted;
      expect(done.statusName, 'completed');
      expect(done.content, hasLength(1));
      expect(done.content.single, isA<TextToolContent>());
      expect(
        (done.content.single as TextToolContent).text,
        'Mode   Name\n----   ----\n-a    pubspec.yaml',
      );
      expect(done.textContent, 'Mode   Name\n----   ----\n-a    pubspec.yaml');

      // input es un Map en completed y se pretty-prints para la card.
      expect(done.input, isA<Map<String, Object?>>());
      expect(done.inputText, contains("openher-mobile"));
      expect(done.metadata['exit'], 0);
      expect(done.outputPaths, isEmpty);
    });

    test('parsea el tool question y conserva questionsRaw', () {
      final a =
          SessionMessage.fromJson(decode(_questionTool)) as AssistantMessage;
      final tool = a.toolItems.single;

      expect(tool.name, 'question');
      expect(tool.questionsRaw, hasLength(1));

      final q = tool.questionsRaw.single;
      expect(q['question'], '¿Qué es exactamente la vista mobile?');
      expect(q['header'], 'Alcance mobile');

      final options = q['options']! as List<Object?>;
      expect(options, hasLength(1));
      final opt = options.single! as Map<String, Object?>;
      expect(opt['label'], 'App Flutter mobile nueva');
      expect(opt['description'], 'Un cliente delgado del mismo backend.');
    });

    test('tool con status error: errorMessage trae el texto humano', () {
      final a =
          SessionMessage.fromJson(decode(_assistantToolError))
              as AssistantMessage;
      final err = a.toolItems.single.state;

      expect(err, isA<ToolError>());
      final toolErr = err as ToolError;
      expect(toolErr.statusName, 'error');
      expect(
        toolErr.errorMessage,
        'Explore agent aborted: Tool execution was interrupted',
      );
      expect(toolErr.error.name, 'unknown');
    });

    test('error de mensaje (canal A): hasError y name', () {
      final a =
          SessionMessage.fromJson(decode(_assistantApiError))
              as AssistantMessage;

      expect(a.hasError, isTrue);
      expect(a.error, isNotNull);
      expect(a.error!.name, 'APIError');
      expect(a.error!.message, 'Upstream request failed (status 429)');
      // El sobre `data` se conserva para debug.
      expect(a.error!.data['statusCode'], 429);
      // Un error de mensaje no ensucia `textContent` (no hay texto).
      expect(a.textContent, isEmpty);
    });

    test('error v2 con type (no name) también resuelve', () {
      final a =
          SessionMessage.fromJson(decode(_assistantEmptyError))
              as AssistantMessage;

      expect(a.hasError, isTrue);
      expect(a.error!.name, 'provider.auth');
      expect(a.error!.message, 'Provider request failed with HTTP 401');
      expect(a.content, isEmpty);
      expect(a.isComplete, isTrue);
    });
  });

  group('tipos de mensaje', () {
    test('cada type cae en su clase concreta, sin tirar', () {
      final list = jsonDecode(_otherMessageTypes) as List<Object?>;
      final byType = <String, SessionMessage>{
        for (final raw in list)
          (raw! as Map<String, Object?>)['type']! as String:
              SessionMessage.fromJson(raw as Map<String, Object?>),
      };

      final system = byType['system']! as SystemMessage;
      expect(system.text, contains('Code Mode'));
      expect(system.description, 'Instructions updated: core/codemode');

      final synthetic = byType['synthetic']! as SyntheticMessage;
      expect(synthetic.text, contains('server restarted'));
      expect(synthetic.sessionID, 'ses_f685c4cfdffe7Bp2ILFUkX1fTF');

      final compaction = byType['compaction']! as CompactionMessage;
      expect(compaction.reason, 'auto');
      expect(compaction.summary, 'Resumen del contexto anterior');
      expect(compaction.recent, 'los últimos mensajes');

      final agent = byType['agent-switched']! as AgentSwitchedMessage;
      expect(agent.agent, 'build');
      expect(agent.previous, 'plan');

      final model = byType['model-switched']! as ModelSwitchedMessage;
      expect(model.model.id, 'deepseek-v4.1-flash');
      expect(model.previous!.id, 'muse-spark-1.3-contributor');

      final shell = byType['shell']! as ShellMessage;
      expect(shell.callID, 'sh_0e64bc484001OqT4sKExx32BVP');
      expect(shell.command, 'flutter test');
      expect(shell.output, 'All tests passed!');

      final user = byType['user']! as UserMessage;
      expect(user.text, 'corré los tests');
      expect(user.files.single.name, 'captura.png');
      expect(user.files.single.uri, 'file:///a.png');
      expect(user.agents, ['build']);
    });
  });

  group('entrada malformada', () {
    test('SessionMessage.fromJson({}) no tira: default seguro', () {
      final msg = SessionMessage.fromJson(const <String, Object?>{});

      expect(msg, isA<SystemMessage>());
      expect((msg as SystemMessage).text, isEmpty);
      expect(msg.id, isEmpty);
      expect(msg.createdAtMs, 0);
    });

    test('assistant sin content: lista vacía, sin tirar', () {
      final a =
          SessionMessage.fromJson(const {
                'id': 'msg_x',
                'type': 'assistant',
                'time': {'created': 1},
              })
              as AssistantMessage;

      expect(a.content, isEmpty);
      expect(a.textContent, isEmpty);
      expect(a.toolItems, isEmpty);
      expect(a.isComplete, isFalse);
      expect(a.model.id, isEmpty);
      expect(a.cost, 0);
    });

    test('tipos raros en los valores no rompen el parseo', () {
      final msg =
          SessionMessage.fromJson(const {
                'id': 42,
                'type': 'assistant',
                'time': 'no es un mapa',
                'cost': 'no es un numero',
                'model': <String, Object?>{'id': 7},
                'content': 'no es una lista',
              })
              as AssistantMessage;

      expect(msg.id, isEmpty); // no era string
      expect(msg.createdAtMs, 0); // time no era mapa
      expect(msg.cost, 0); // no era numero
      expect(msg.model.id, isEmpty);
      expect(msg.content, isEmpty);
    });

    test('tool state sin status cae a pending sin tirar', () {
      final state = ToolState.fromJson(const {'input': 'crudo'});
      expect(state, isA<ToolPending>());
      expect((state as ToolPending).inputText, 'crudo');
    });
  });

  group('helpers de estado y evento', () {
    test('isBusyStatus / isSettledStatus', () {
      expect(isBusyStatus('busy'), isTrue);
      expect(isBusyStatus('retry'), isTrue);
      expect(isBusyStatus('running'), isTrue);
      expect(isBusyStatus('idle'), isFalse);

      expect(isSettledStatus('idle'), isTrue);
      expect(isSettledStatus('completed'), isTrue);
      expect(isSettledStatus('busy'), isFalse);
    });

    test('isBusyStatus acepta el objeto v2 {type}', () {
      expect(isBusyStatus(const {'type': 'busy'}), isTrue);
      expect(isSettledStatus(const {'type': 'idle'}), isTrue);
    });

    test('isDeltaEvent / isSettledEvent sobre los type medidos', () {
      expect(isDeltaEvent('session.text.delta'), isTrue);
      expect(isDeltaEvent('session.reasoning.delta'), isTrue);
      expect(isDeltaEvent('session.tool.input.delta'), isTrue);
      expect(isDeltaEvent('session.text.ended'), isFalse);

      expect(isSettledEvent('session.text.ended'), isTrue);
      expect(isSettledEvent('session.tool.success'), isTrue);
      expect(isSettledEvent('session.text.delta'), isFalse);
    });
  });

  group('OcEvent', () {
    test('parsea el frame medido de /api/event', () {
      final ev = OcEvent.fromJson(
        decode(r'''
{"id":"evt_0e64bb95b0011cqouuAK7f6P2Y","type":"session.step.ended",
 "location":{"directory":"G:\\Proyectos\\opencode-remote-android"},
 "data":{"sessionID":"ses_abc","finish":"tool-calls"},
 "durable":{"aggregateID":"ses_abc","seq":431,"version":1}}
'''),
      );

      expect(ev.id, 'evt_0e64bb95b0011cqouuAK7f6P2Y');
      expect(ev.type, 'session.step.ended');
      expect(ev.sessionID, 'ses_abc');
      expect(ev.seq, 431);
      expect(isSettledEvent(ev.type), isTrue);
    });

    test('acepta la clave "event" del stream por sesión', () {
      final ev = OcEvent.fromJson(const {
        'id': 'evt_1',
        'event': 'session.text.delta',
      });
      expect(ev.type, 'session.text.delta');
      expect(isDeltaEvent(ev.type), isTrue);
    });
  });

  group('OchError', () {
    test('cada error tiene mensaje y decide si es reintentable', () {
      expect(const ApiError(statusCode: 500).retriable, isTrue);
      expect(const ApiError(statusCode: 429).retriable, isTrue);
      expect(const ApiError(statusCode: 404).retriable, isFalse);
      expect(const AuthError().retriable, isFalse);
      expect(const NetworkError().retriable, isTrue);
      expect(const HtmlFallbackError(path: '/api/health').retriable, isFalse);
      // El mensaje es siempre en español y no vacío.
      for (final e in <OchError>[
        const ApiError(statusCode: 401),
        const AuthError(),
        const NetworkError(),
        const HtmlFallbackError(path: '/api/health'),
      ]) {
        expect(e.message, isNotEmpty);
        expect(e.toString(), contains(e.message));
      }
    });

    test('OcErrorInfo es liberal: message, error o text', () {
      // v1 SDK: {name, data:{message}}
      final v1 = OcErrorInfo.fromJson(const {
        'name': 'ProviderAuthError',
        'data': {'message': 'falta la API key'},
      });
      expect(v1.name, 'ProviderAuthError');
      expect(v1.message, 'falta la API key');

      // Un string suelto.
      expect(OcErrorInfo.fromJson('se rompio').message, 'se rompio');
      // Sin nada reconocible: vacío, nunca tira.
      expect(OcErrorInfo.fromJson(null).message, isEmpty);
    });
  });

  group('SessionInfo', () {
    test('parsea el SessionV2Info medido', () {
      final s = SessionInfo.fromJson(decode(_sessionInfo));

      expect(s.id, 'ses_f19b83c02ffeTyvqP4q0tmFU8a');
      expect(s.title, 'M2 domain models');
      expect(s.agent, 'worker');
      expect(s.model!.id, 'space-bunny-free');
      expect(s.model!.variant, 'max');
      expect(s.location.directory, r'G:\Proyectos\opencode-remote-android');
      expect(s.directory, s.location.directory);
      expect(s.cost, 0.42);
      expect(s.tokens.total, 16549 + 384 + 120);
      expect(s.isSubagent, isTrue);
      expect(s.parentID, 'ses_f685c4cfdffe7Bp2ILFUkX1fTF');
    });

    test('cae al directory de nivel raíz si no hay location', () {
      final s = SessionInfo.fromJson(const {
        'id': 'ses_x',
        'directory': r'C:\repo',
        'title': 't',
      });
      expect(s.directory, r'C:\repo');
    });
  });
}
