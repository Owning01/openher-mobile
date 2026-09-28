import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/domain/models/agent_catalog.dart';
import 'package:openher_mobile/domain/models/message.dart';
import 'package:openher_mobile/domain/models/session.dart';
import 'package:openher_mobile/ui/features/chat/chat_viewmodel.dart';

const ServerConfig kConfig = ServerConfig(
  host: '127.0.0.1',
  port: 4098,
  password: 's3cr3t',
);

ApiClient clientWith(MockClient mock) =>
    ApiClient(config: kConfig, client: mock, backoff: (_) => Duration.zero);

/// El server responde **204 sin cuerpo** a los dos endpoints de cambio
/// (medido 2026-09-28). Si el cliente tratara eso como un error, o intentara
/// deserializar un JSON vacío, elegir modelo o agente reventaría.
http.Response noContent() => http.Response('', 204);

/// `GET /api/agent` medido: 26, con `compaction`/`title`/`summary` ocultos.
const String kAgentList = '''
{"data":[
 {"id":"build","name":"Build","mode":"primary","hidden":false,
  "description":"The default agent.","request":{}},
 {"id":"plan","name":"Plan","mode":"primary","hidden":false,
  "description":"Read-only agent.","request":{}},
 {"id":"general","name":"General","mode":"subagent","hidden":false,
  "description":"General-purpose agent.","request":{}},
 {"id":"compaction","name":"Compaction","mode":"primary","hidden":true,
  "description":"","request":{}}
]}
''';

void main() {
  /// Un VM mínimo, con la sesión que devuelve el server al crearla: **sin**
  /// model ni gent, que es la forma real y la que dispara el bug.
  ///
  /// No se conecta el stream: la factoría lanza si alguien lo pide, así el
  /// test no puede colgarse en un socket.
  ChatViewModel buildVm({String? agent}) => ChatViewModel(
    ApiClient(
      config: kConfig,
      client: MockClient((_) async => http.Response('{"data":[]}', 200)),
      backoff: (_) => Duration.zero,
    ),
    sessionId: 'ses_1',
    sessionInfo: SessionInfo(
      id: 'ses_1',
      projectID: 'prj_1',
      title: 'sin titulo',
      cost: 0,
      tokens: const TokenUsage(),
      time: const SessionTime(createdMs: 0, updatedMs: 0),
      agent: agent,
    ),
    streamFactory: (_, _) => throw StateError('este test no abre stream'),
  );

  group('listAgents', () {
    test('pega a /api/agent y devuelve los crudos', () async {
      final seen = <String>[];
      final api = clientWith(
        MockClient((req) async {
          seen.add('${req.method} ${req.url.path}');
          return http.Response(kAgentList, 200);
        }),
      );
      final raw = await api.listAgents(directory: r'C:\p');
      expect(seen, ['GET /api/agent']);
      expect(raw.length, 4, reason: 'los ocultos llegan y se filtran aparte');
      expect(raw.first['id'], 'build');
    });

    test('el catálogo filtra los ocultos y separa por modo', () async {
      final api = clientWith(
        MockClient((_) async => http.Response(kAgentList, 200)),
      );
      final c = AgentCatalog.fromList(await api.listAgents());
      expect(c.selectable.map((a) => a.id), ['build', 'plan', 'general']);
      expect(c.primaries.map((a) => a.id), ['build', 'plan']);
      expect(c.subagents.map((a) => a.id), ['general']);
    });
  });

  group('setSessionAgent', () {
    test(
      'manda {"agent": id} a /api/session/{id}/agent y acepta el 204',
      () async {
        http.Request? seen;
        final api = clientWith(
          MockClient((req) async {
            seen = req;
            return noContent();
          }),
        );
        await api.setSessionAgent('ses_1', agent: 'plan', directory: null);

        expect(seen, isNotNull);
        expect(seen!.method, 'POST');
        expect(seen!.url.path, '/api/session/ses_1/agent');
        expect(jsonDecode(seen!.body), {'agent': 'plan'});
      },
    );

    // El caso que rompía todo: un 204 no es un error, y tampoco se puede
    // pasar por `_object`, queDevelopería un JSON de un cuerpo vacío.
    test('el 204 no se trata como error', () async {
      final api = clientWith(MockClient((_) async => noContent()));
      await expectLater(
        api.setSessionAgent('ses_1', agent: 'build'),
        completes,
      );
    });
  });

  group('setSessionModel', () {
    test('manda {model:{id, providerID, variant}} al path correcto', () async {
      http.Request? seen;
      final api = clientWith(
        MockClient((req) async {
          seen = req;
          return noContent();
        }),
      );
      await api.setSessionModel(
        'ses_1',
        providerId: 'opencode-go',
        modelId: 'space-bunny-free',
        variantId: 'high',
      );

      expect(seen, isNotNull);
      expect(seen!.method, 'POST');
      expect(seen!.url.path, '/api/session/ses_1/model');
      final body = jsonDecode(seen!.body) as Map<String, dynamic>;
      expect(body['model'], {
        'id': 'space-bunny-free',
        'providerID': 'opencode-go',
        'variant': 'high',
      });
    });

    // Sin nivel elegido se manda la clave SIN valor: el server lo interpreta
    // como "el nivel por defecto del modelo". Mandar `variant: null` sería
    // mandarle un null explícito, que no es lo mismo.
    test('sin nivel, la clave variant no se manda', () async {
      http.Request? seen;
      final api = clientWith(
        MockClient((req) async {
          seen = req;
          return noContent();
        }),
      );
      await api.setSessionModel(
        'ses_1',
        providerId: 'opencode-go',
        modelId: 'space-bunny-free',
      );
      final model =
          (jsonDecode(seen!.body) as Map<String, dynamic>)['model']
              as Map<String, dynamic>;
      expect(model.containsKey('variant'), isFalse);
      expect(model['id'], 'space-bunny-free');
    });

    test('el 204 no se trata como error', () async {
      final api = clientWith(MockClient((_) async => noContent()));
      await expectLater(
        api.setSessionModel('ses_1', providerId: 'p', modelId: 'm'),
        completes,
      );
    });
  });

  group('applySelection: el pill tiene que mostrar lo elegido', () {
    // Este es el bug reportado tal cual: `modelLabel: info?.model?.id` daba
    // siempre null porque una sesión nueva del server v2 **no** trae campo
    // `model` (medido: id, projectID, cost, tokens, time, location), así que
    // el pill decía "Elegir modelo" para siempre, incluso después de elegir.
    test('tras elegir, el modelo en uso es el elegido', () {
      final vm = buildVm();
      expect(
        vm.currentModel,
        isNull,
        reason: 'la sesión nueva no trae modelo: ese es el motivo del bug',
      );
      vm.applySelection(
        model: const ModelRef(
          id: 'space-bunny-free',
          providerID: 'opencode-go',
        ),
      );
      expect(vm.currentModel?.id, 'space-bunny-free');
      expect(vm.currentModel?.providerID, 'opencode-go');
    });

    test('con variante, el pill la conserva (es el nivel de pensamiento)', () {
      final vm = buildVm();
      vm.applySelection(
        model: const ModelRef(
          id: 'space-bunny-free',
          providerID: 'opencode-go',
          variant: 'high',
        ),
      );
      expect(vm.currentModel?.variant, 'high');
    });

    // Un `null` significa "no lo toco", nunca "borralo": elegir modelo no
    // puede dejar la sesión sin agente.
    test('cambiar el modelo no borra el agente, y al revés', () {
      final vm = buildVm();
      vm.applySelection(
        model: const ModelRef(id: 'm1', providerID: 'p'),
        agent: 'plan',
      );
      vm.applySelection(
        model: const ModelRef(id: 'm2', providerID: 'p'),
      );
      expect(vm.currentModel?.id, 'm2');
      expect(
        vm.currentAgent,
        'plan',
        reason: 'elegir modelo no toca el agente',
      );

      vm.applySelection(agent: 'build');
      expect(
        vm.currentModel?.id,
        'm2',
        reason: 'elegir agente no toca el modelo',
      );
      expect(vm.currentAgent, 'build');
    });

    // Si el server ya trae agente (una sesión vieja o una creada desde el
    // escritorio), manda lo suyo mientras no se elija otro.
    test('lo que dice el server manda si no se eligió nada', () {
      final vm = buildVm(agent: 'general');
      expect(vm.currentAgent, 'general');
      vm.applySelection(agent: 'plan');
      expect(vm.currentAgent, 'plan');
    });

    test('un apply vacío no notifica', () {
      final vm = buildVm();
      var notified = 0;
      vm.addListener(() => notified++);
      vm.applySelection();
      expect(notified, 0);
      vm.applySelection(agent: 'plan');
      expect(notified, 1);
    });
  });
}
