import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/domain/models/errors.dart';

/// El contrato de `/command`, `/skill`, `/mcp/resource` y `fs/find`, medido.
///
/// Estos cuatro endpoints no existían en la app: no había menú de `/` ni de `@`.
/// El riesgo acá no es la aritmética sino **inventar el contrato**, y la forma de
/// no inventarlo es dejar por escrito lo que el server realmente devolvió.
///
/// Los cuerpos de abajo son **literales de las respuestas reales** del
/// 2026-09-29, con la envoltura v2 `{location, data}` y recortados a lo que la
/// app lee. Si el server cambia la forma, estos tests fallan y avisan, en vez de
/// que la app muestre un menú vacío sin decir nada.
void main() {
  const kConfig = ServerConfig(
    host: '127.0.0.1',
    port: 4098,
    password: 's3cr3t',
  );

  /// Lo que respondió el server, literal.
  const kCommandResponse = '{"location":{"directory":"C:\\\\Users\\\\perca"},'
      '"data":[{"name":"init","description":"guided AGENTS.md setup"},'
      '{"name":"review",'
      '"description":"review changes [commit|branch|pr], defaults to uncommitted"},'
      '{"name":"debate","description":"Mesa de trabajo colaborativa (default isolated)."}]}';

  const kSkillResponse = '{"location":{"directory":"C:\\\\Users\\\\perca"},'
      '"data":[{"id":"opencode","name":"OpenCode",'
      '"description":"Use this skill for any question about OpenCode itself"},'
      '{"id":"report","name":"Report",'
      '"description":"Use when the user wants to report an opencode issue"}]}';

  const kMcpResponse = '{"location":{"directory":"C:\\\\Users\\\\perca"},'
      '"data":{"resources":[],"templates":[]}}';

  const kAgentResponse = '{"location":{"directory":"C:\\\\Users\\\\perca"},'
      '"data":[{"id":"build","name":"builder","mode":"primary",'
      '"description":"Code Builder","hidden":false},'
      '{"id":"compaction","name":"compaction","mode":"primary",'
      '"description":"internal","hidden":true}]}';

  const kFindResponse = '{"location":{"directory":"C:\\\\Users\\\\perca"},'
      '"data":[{"path":".config/opencode/service.json","type":"file"}]}';

  ApiClient clientReturning(String body, List<String> log) => ApiClient(
    config: kConfig,
    client: MockClient((req) async {
      log.add('${req.method} ${req.url.path}');
      return http.Response(body, 200, headers: {
        'content-type': 'application/json',
      });
    }),
    timeout: const Duration(seconds: 1),
  );

  group('GET /api/command', () {
    test('devuelve la lista del server, no una inventada', () async {
      final log = <String>[];
      final api = clientReturning(kCommandResponse, log);
      final commands = await api.listCommands(directory: r'C:\Users\perca');

      expect(log, ['GET /api/command']);
      expect(commands, hasLength(3));
      expect(commands.map((c) => c['name']), ['init', 'review', 'debate']);
      expect(commands.first['description'], 'guided AGENTS.md setup');
    });

    test('son 3, no los 16 que anuncia el cliente web', () async {
      // El cliente web de OpenHer mezcla esta lista con 13 hardcodeados
      // (`compact`, `undo`, `redo`, `themes`, `history`, …) que este server no
      // tiene: medido, dan 404 en `POST /api/session/{id}/command`.
      //
      // Si algún día el server trae más, este test falla y avisa de que hay que
      // releer la lista, no de que se agreguen a mano.
      final log = <String>[];
      final api = clientReturning(kCommandResponse, log);
      expect(await api.listCommands(), hasLength(3));
    });
  });

  group('POST /api/session/{id}/command', () {
    test('manda {name, text} y el name SIN barra', () async {
      Map<String, Object?>? body;
      final api = ApiClient(
        config: kConfig,
        client: MockClient((req) async {
          body = jsonDecode(req.body) as Map<String, Object?>;
          return http.Response('', 204);
        }),
        timeout: const Duration(seconds: 1),
      );

      await api.runCommand(
        'ses_1',
        name: '/review',
        text: 'el diff de la api',
        directory: r'C:\Users\perca',
      );

      expect(body, isNotNull);
      // `name` y `text` son los dos campos requeridos por el schema, y
      // `additionalProperties: false`: mandar `command` en vez de `name` da un
      // 400 Missing key ["name"] (medido en el cliente web).
      expect(body!.keys.toSet(), {'name', 'text'});
      // El lookup del server es exacto: `/review` no empareja con `review`.
      expect(body!['name'], 'review');
      expect(body!['text'], 'el diff de la api');
    });

    test('sin argumentos manda text vacío, no lo omite', () async {
      // `text` es requerido: mandarlo ausente es un 400 igual que con `name`.
      Map<String, Object?>? body;
      final api = ApiClient(
        config: kConfig,
        client: MockClient((req) async {
          body = jsonDecode(req.body) as Map<String, Object?>;
          return http.Response('', 204);
        }),
        timeout: const Duration(seconds: 1),
      );

      await api.runCommand('ses_1', name: 'init');

      expect(body!.containsKey('text'), isTrue);
      expect(body!['text'], '');
    });

    test('un 404 se propaga, no se traga', () async {
      // Es el caso de un comando que el server no tiene: tiene que verse, no
      // fingir que se corrió.
      final api = ApiClient(
        config: kConfig,
        client: MockClient(
          (_) async => http.Response('no such command', 404),
        ),
        timeout: const Duration(seconds: 1),
      );

      await expectLater(
        api.runCommand('ses_1', name: 'compact'),
        throwsA(isA<ApiError>()),
      );
    });
  });

  group('GET /api/mcp/resource', () {
    test('la respuesta es un objeto, no una lista', () async {
      // `data` es `{resources: [...], templates: [...]}`. Una comprensión de
      // lista sobre eso daría un menú vacío **en silencio**, que es el peor modo
      // de falla: parecería que no hay recursos MCP.
      final log = <String>[];
      final api = clientReturning(kMcpResponse, log);
      final resources = await api.listMcpResources(directory: r'C:\Users\perca');

      expect(log, ['GET /api/mcp/resource']);
      expect(resources, isEmpty);
    });

    test('con recursos los lee de la clave correcta', () async {
      const conRecursos = '{"data":{"resources":[{"uri":"docs://guia",'
          '"name":"Guia","server":"docs","description":"la guia",'
          '"mimeType":"text/markdown"}],"templates":[]}}';
      final log = <String>[];
      final api = clientReturning(conRecursos, log);
      final resources = await api.listMcpResources();

      expect(resources, hasLength(1));
      // El McpResource real no trae `id`: trae `uri`, y el `id` es el `uri`.
      expect(resources.first['name'], 'Guia');
      expect(resources.first['uri'], 'docs://guia');
    });

    test('`templates` no se cuela como recurso', () async {
      const conTemplate =
          '{"data":{"resources":[],"templates":[{"name":"plantilla",'
          '"uri":"t://1"}]}}';
      final log = <String>[];
      final api = clientReturning(conTemplate, log);
      expect(await api.listMcpResources(), isEmpty);
    });
  });

  group('las fuentes del @', () {
    test('las skills traen id, name y description', () async {
      final log = <String>[];
      final api = clientReturning(kSkillResponse, log);
      final skills = await api.listSkills(directory: r'C:\Users\perca');

      expect(log, ['GET /api/skill']);
      expect(skills, hasLength(2));
      expect(skills.first['id'], 'opencode');
      expect(skills.first['name'], 'OpenCode');
    });

    test('los agentes llegan crudos; el filtro de hidden es de la vista', () async {
      // El repo devuelve los crudos, como todos los endpoints. Ocultar los
      // `hidden` es decisión de la vista (un agente interno no va en el `@`), no
      // del transporte.
      final log = <String>[];
      final api = clientReturning(kAgentResponse, log);
      final agents = await api.listAgents(directory: r'C:\Users\perca');

      expect(log, ['GET /api/agent']);
      expect(agents, hasLength(2));
      expect(
        agents.firstWhere((a) => a['id'] == 'compaction')['hidden'],
        isTrue,
      );
    });

    test('la búsqueda de archivos usa /fs/find, no /find/file', () async {
      // Medido: `/api/find/file` da **404** y `/api/fs/find` da 200. El cliente
      // web tiene las dos rutas con un `pickV2` en medio; acá va la que existe.
      final log = <String>[];
      final api = clientReturning(kFindResponse, log);
      final page = await api.findFiles(
        query: 'service',
        directory: r'C:\Users\perca',
        limit: 12,
      );

      expect(log, ['GET /api/fs/find']);
      expect(page.data, hasLength(1));
      expect(
        (page.data.first as Map)['path'],
        '.config/opencode/service.json',
      );
    });
  });

  group('el sobre v2', () {
    test('un data vacío no es lo mismo que un sobre roto', () async {
      // Una lista vacía es una respuesta válida y pinta "sin coincidencias"; un
      // sobre sin `data` es un cambio de contrato y debería decir algo. Los dos
      // tienen que ser distinguibles, y con la lista vacía la app no puede
      // inventarse la diferencia.
      final log = <String>[];
      final vacio = clientReturning(
        '{"location":{"directory":"C:\\\\x"},"data":[]}',
        log,
      );
      expect(await vacio.listCommands(), isEmpty);

      final sinData = clientReturning('{"location":{"directory":"C:\\\\x"}}', log);
      expect(await sinData.listCommands(), isEmpty);
    });
  });
}
