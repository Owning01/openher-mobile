import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/data/repositories/session_repository.dart';
import 'package:openher_mobile/domain/models/session.dart';
import 'package:openher_mobile/ui/features/sessions/sessions_viewmodel.dart';

/// La pantalla de sesiones tiene que traer **todas** las sesiones.
///
/// El síntoma reportado era "no me está trayendo todas las sesiones". La causa no
/// era el filtro de la pantalla (que es correcto y está medido: `parentID` presente
/// ⇒ subagente), sino que el repo pedía **una** página de 100 y nunca使用的是
/// cursor.
///
/// Medido contra el server real 2026-09-30: hay 2.000 sesiones (654 principales,
/// 1.346 subagentes). `limit=100` devuelve 100 sesiones de las cuales sólo 59 son
/// principales — y con el interruptor de subagentes apagado, que es el default,
/// **595 sesiones que el usuario tiene quedan invisibles sin ningún aviso**.
void main() {
  const kConfig = ServerConfig(
    host: '127.0.0.1',
    port: 4098,
    password: 's3cr3t',
  );

  /// Un item de sesión con la forma real que devuelve el server.
  Map<String, Object?> item(int i, {String? parent}) => {
    'id': 'ses_${i.toString().padLeft(4, '0')}',
    'projectID': 'prj_1',
    'title': 'sesión $i',
    if (parent != null) 'parentID': parent,
    'cost': 0,
    'tokens': <String, Object?>{
      'input': 0,
      'output': 0,
      'reasoning': 0,
      'cache': <String, Object?>{'read': 0, 'write': 0},
    },
    'time': {
      'created': 1759000000000 + i * 1000,
      'updated': 1759000000000 + i * 1000,
    },
  };

  /// Cursor base64 como el que devuelve el server.
  ///
  /// El **server** (el fake) es quien lo decodifica, porque es quien lo emitió:
  /// la app lo pasa opaco de vuelta. Si la app lo interpretara, el fake la
  /// delataría, y ese es el punto: el cursor es del server, no nuestro.
  String cursor(int indice) =>
      base64Encode(utf8.encode('{"order":"desc","anchor":$indice}'));

  int indiceDelCursor(String? cur) {
    if (cur == null) return 0;
    final mapa =
        jsonDecode(utf8.decode(base64Decode(cur))) as Map<String, Object?>;
    return mapa['anchor']! as int;
  }

  /// Un server con [total] sesiones, paginadas de a [limit].
  ApiClient fakeServer({
    required int total,
    int limit = 100,
    int? subagentsEvery,
  }) {
    return ApiClient(
      config: kConfig,
      client: MockClient((req) async {
        final q = req.url.queryParameters;
        final lim = int.tryParse(q['limit'] ?? '') ?? limit;
        final desde = indiceDelCursor(q['cursor']);
        final items = <Map<String, Object?>>[];
        for (var i = desde; i < total && items.length < lim; i++) {
          final parent = (subagentsEvery != null && i % subagentsEvery == 0)
              ? 'ses_padre'
              : null;
          items.add(item(i, parent: parent));
        }
        final hayMas = desde + items.length < total;
        return http.Response(
          jsonEncode({
            'data': items,
            'cursor': {
              if (items.isNotEmpty)
                'next': hayMas ? cursor(desde + items.length) : null,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
      timeout: const Duration(seconds: 1),
    );
  }

  group('listAll', () {
    test('trae las 2.000, no las 100 de la primera página', () async {
      final repo = SessionRepository(fakeServer(total: 2000));
      final sessions = await repo.listAll();
      expect(sessions, hasLength(2000));
    });

    test('pide una página por cada 100, encadenando el cursor', () async {
      // El server fake **decodifica** el cursor que emitió, que es lo que hace
      // el real: si no, el fake aceptaría cualquier página y la prueba no
      // probaría que el cursor de verdad se encadena.
      var peticiones = 0;
      final api = ApiClient(
        config: kConfig,
        client: MockClient((req) async {
          peticiones++;
          final desde = indiceDelCursor(req.url.queryParameters['cursor']);
          final items = [for (var i = desde; i < desde + 100; i++) item(i)];
          return http.Response(
            jsonEncode({
              'data': items,
              'cursor': {if (desde + 100 < 2000) 'next': cursor(desde + 100)},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        timeout: const Duration(seconds: 1),
      );

      final sessions = await SessionRepository(api).listAll();
      expect(sessions, hasLength(2000));
      expect(peticiones, 20, reason: '2000 / 100 = 20 páginas');
    });

    test('el cursor viaja opaco: la app no lo interpreta', () async {
      // Si la app decodificara el cursor para "entenderlo", un cambio en el
      // formato del server la rompería. El server manda `{"previous": null, ...}`
      // con un `next` que es base64 de un JSON que **no** tiene que ser válido.
      String? visto;
      final api = ApiClient(
        config: kConfig,
        client: MockClient((req) async {
          final q = req.url.queryParameters;
          if (q['cursor'] != null) visto = q['cursor'];
          final esPrimera = q['cursor'] == null;
          return http.Response(
            jsonEncode({
              'data': esPrimera ? [item(0)] : [item(1)],
              'cursor': esPrimera ? {'next': 'no-es-json-valido'} : null,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        timeout: const Duration(seconds: 1),
      );

      final sessions = await SessionRepository(api).listAll();
      expect(sessions, hasLength(2));
      expect(visto, 'no-es-json-valido');
    });

    test('con next null corta: no pide una página de más', () async {
      var peticiones = 0;
      final api = ApiClient(
        config: kConfig,
        client: MockClient((req) async {
          peticiones++;
          return http.Response(
            jsonEncode({
              'data': [item(0)],
              'cursor': {},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        timeout: const Duration(seconds: 1),
      );

      await SessionRepository(api).listAll();
      expect(peticiones, 1);
    });

    test('con un cursor repetido corta: no se cicla', () async {
      // El server no avanzó (mismo cursor devuelto). Pedir otra vez daría la
      // misma respuesta, para siempre. Cortar es lo único que evita el bucle.
      var peticiones = 0;
      final api = ApiClient(
        config: kConfig,
        client: MockClient((req) async {
          peticiones++;
          return http.Response(
            jsonEncode({
              'data': [item(peticiones)],
              'cursor': {'next': 'el-mismo-cursor'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        timeout: const Duration(seconds: 1),
      );

      final sessions = await SessionRepository(api).listAll();
      expect(sessions, isNotEmpty);
      expect(peticiones, 2, reason: 'pide, ve el mismo cursor y para');
    });

    test('respeta el tope de páginas aunque el server no agote', () async {
      // Un build futuro que devuelva `next` siempre: sin tope, 2.000 páginas.
      var peticiones = 0;
      final api = ApiClient(
        config: kConfig,
        client: MockClient((req) async {
          peticiones++;
          return http.Response(
            jsonEncode({
              'data': [item(peticiones)],
              'cursor': {'next': 'sigue-$peticiones'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        timeout: const Duration(seconds: 1),
      );

      await SessionRepository(api).listAll();
      expect(peticiones, kSessionAllPages);
    });

    test('el orden es del más reciente al más viejo', () async {
      final repo = SessionRepository(fakeServer(total: 300));
      final sessions = await repo.listAll();
      for (var i = 1; i < sessions.length; i++) {
        expect(
          sessions[i - 1].updatedAtMs,
          greaterThanOrEqualTo(sessions[i].updatedAtMs),
          reason: 'en el índice $i el orden se rompió',
        );
      }
    });

    test('deduplica por id entre páginas', () async {
      // El cursor a veces solapa un item entre páginas (el server lo ancla por
      // `time` + `id`, no por posición). Un `ses_` repetido en la lista rompe el
      // mapa por id de la pantalla de favoritas.
      final api = ApiClient(
        config: kConfig,
        client: MockClient((req) async {
          final esPrimera = req.url.queryParameters['cursor'] == null;
          return http.Response(
            jsonEncode({
              'data': esPrimera ? [item(0), item(1)] : [item(1), item(2)],
              'cursor': esPrimera ? {'next': 'c'} : null,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        timeout: const Duration(seconds: 1),
      );

      final sessions = await SessionRepository(api).listAll();
      expect(sessions, hasLength(3));
      expect(sessions.map((s) => s.id).toSet(), hasLength(3));
    });
  });

  group('la lista sigue viniendo con parentID', () {
    test('los subagentes se distinguen de las principales', () async {
      // El filtro de la pantalla depende de esto: `parentID` presente ⇒
      // subagente. Si `listAll` perdiera el campo, el interruptor no filtraría
      // nada y el síntoma sería "aparecen subagentes que pedí ocultar".
      final repo = SessionRepository(fakeServer(total: 200, subagentsEvery: 2));
      final sessions = await repo.listAll();
      final sub = sessions.where((s) => s.isSubagent).length;
      final main = sessions.length - sub;
      expect(main, greaterThan(0));
      expect(sub, greaterThan(0));
      expect(main + sub, 200);
    });
  });

  group('list (la de una página) sigue existiendo', () {
    test('pide una sola página', () async {
      var peticiones = 0;
      final api = ApiClient(
        config: kConfig,
        client: MockClient((req) async {
          peticiones++;
          return http.Response(
            jsonEncode({
              'data': [for (var i = 0; i < 100; i++) item(i)],
              'cursor': {'next': 'mas'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        timeout: const Duration(seconds: 1),
      );

      final sessions = await SessionRepository(api).list();
      expect(sessions, hasLength(100));
      expect(peticiones, 1);
    });
  });

  group('la pantalla usa listAll, no list', () {
    test('el viewmodel trae las 2.000, no las 100 de una pagina', () async {
      // Este es el guard que importa. `listAll` puede estar bien y el bug
      // seguir vivo si la pantalla vuelve a llamar a `list`: el sintoma seria
      // exactamente el reportado ("no me trae todas las sesiones") y ningun
      // test del repositorio lo veria, porque el repositorio funciona bien.
      final vm = SessionsViewModel(
        repository: SessionRepository(fakeServer(total: 2000)),
        clock: () => DateTime(2026, 9, 30, 12),
      );
      addTearDown(vm.dispose);
      await vm.load();

      expect(
        vm.mainSessions,
        hasLength(2000),
        reason: 'si esto dice 59, la pantalla volvio a pedir una sola pagina',
      );
    });

    test('el interruptor de subagentes tambien los muestra todos', () async {
      final vm = SessionsViewModel(
        repository: SessionRepository(
          fakeServer(total: 2000, subagentsEvery: 2),
        ),
        clock: () => DateTime(2026, 9, 30, 12),
      );
      addTearDown(vm.dispose);
      await vm.load();

      expect(vm.visible, hasLength(1000), reason: 'principales con el filtro');
      vm.showSubagents = true;
      expect(
        vm.visible,
        hasLength(2000),
        reason: 'con el interruptor prendido, todas',
      );
    });
  });
}
