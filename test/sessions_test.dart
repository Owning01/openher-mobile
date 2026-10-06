import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/core/storage/prefs_store.dart';
import 'package:openher_mobile/data/repositories/session_repository.dart';
import 'package:openher_mobile/domain/models/errors.dart';
import 'package:openher_mobile/domain/models/message.dart';
import 'package:openher_mobile/domain/models/session.dart';
import 'package:openher_mobile/ui/core/layer_gate.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/features/sessions/session_favorites.dart';
import 'package:openher_mobile/ui/features/sessions/sessions_view.dart';
import 'package:openher_mobile/ui/features/sessions/sessions_viewmodel.dart';

/// Config de la máquina de desarrollo. La contraseña no se usa: el test no
/// habla con nadie, `MockClient` responde todo.
const ServerConfig kConfig = ServerConfig(
  host: '127.0.0.1',
  port: 4098,
  password: 's3cr3t',
);

/// Instante fijo: los grupos dependen del día local y un `DateTime.now()` en el
/// test lo haría fallar una vez por día (a las 00:01).
final DateTime kNow = DateTime(2026, 9, 28, 15, 30);

/// El catch-all del SPA: todo path desconocido devuelve HTML 200.
const String kSpaHtml =
    '<!doctype html><html><head><title>opencode</title></head><body></body>'
    '</html>';

SessionRepository repoWith(MockClient mock, {Duration? timeout}) =>
    SessionRepository(
      ApiClient(
        config: kConfig,
        client: mock,
        timeout: timeout,
        // Sin espera real entre reintentos.
        backoff: (_) => Duration.zero,
      ),
    );

http.Response json(String body, {int status = 200}) =>
    http.Response(body, status, headers: {'content-type': 'application/json'});

/// Un `SessionV2Info` medido, con la forma exacta del dialecto v2.
String sessionJson({
  required String id,
  required String title,
  required int updatedMs,
  String directory = 'G:/code/openher-mobile',
  String agent = 'build',
  String? parent,
  double cost = 0.42,
}) => jsonEncode({
  'id': id,
  'projectID': 'G:/code/openher-mobile',
  'title': title,
  'directory': directory,
  'location': {'directory': directory},
  'version': '0.15.3',
  'parentID': ?parent,
  'agent': agent,
  'model': {'id': 'claude-sonnet-4-5', 'providerID': 'anthropic'},
  'cost': cost,
  'tokens': {
    'input': 1200,
    'output': 800,
    'reasoning': 300,
    'cache': {'read': 900},
  },
  'time': {'created': updatedMs - 60000, 'updated': updatedMs},
});

String listJson(List<String> sessions) => jsonEncode({
  'data': [for (final s in sessions) jsonDecode(s)],
  'cursor': {
    'previous': 'eyJpZCI6InNlcy1jIn0=',
    'next': 'eyJpZCI6InNlcy0xIn0=',
  },
});

/// Reparte los tres endpoints que usa la pantalla.
MockClient server({
  required String list,
  String active = '{"data":{}}',
  String? created,
  List<String>? posted,
}) => MockClient((request) async {
  final path = request.url.path;
  if (path == '/api/session' && request.method == 'GET') return json(list);
  if (path == '/api/session' && request.method == 'POST') {
    posted?.add(request.body);
    return json(
      created ??
          sessionJson(
            id: 'ses_new',
            title: 'Nueva',
            updatedMs: kNow.millisecondsSinceEpoch,
          ),
    );
  }
  if (path == '/api/session/active') return json(active);
  return http.Response(kSpaHtml, 200, headers: {'content-type': 'text/html'});
});

/// Pumpa [child] con el tema del repo y el catálogo de capas de la spec.
Future<void> pumpView(WidgetTester tester, Widget child) async {
  LayerCatalog.debugSetInstance(LayerCatalog.forTest(_sessionsLayers));
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: child));
}

/// Las capas que implementa esta pantalla, todas activas (spec aprobada).
const Map<String, bool> _sessionsLayers = {
  'sessions.appbar': true,
  'sessions.appbar.add': true,
  'sessions.appbar.search': true,
  'sessions.appbar.title': true,
  'sessions.empty': true,
  'sessions.group.headers': true,
  'sessions.row.attention': true,
  'sessions.row.cost': true,
  'sessions.row.meta': true,
  'sessions.row.status': true,
  'sessions.row.time': true,
  'sessions.row.title': true,
  'sessions.search': true,
  'sessions.swipe.action': true,
};

void main() {
  setUp(() => LayerCatalog.debugSetInstance(null));
  tearDown(() => LayerCatalog.debugSetInstance(null));

  group('SessionRepository', () {
    test('mapea la página a SessionInfo y ordena por actualización', () async {
      final repo = repoWith(
        server(
          list: listJson([
            sessionJson(
              id: 'ses_old',
              title: 'vieja',
              updatedMs: kNow
                  .subtract(const Duration(days: 3))
                  .millisecondsSinceEpoch,
            ),
            sessionJson(
              id: 'ses_new',
              title: 'nueva',
              updatedMs: kNow.millisecondsSinceEpoch,
            ),
          ]),
        ),
      );

      final sessions = await repo.list();

      expect(sessions.map((s) => s.id), ['ses_new', 'ses_old']);
      expect(sessions.first.title, 'nueva');
      // `location.directory` es el campo del spec v2.
      expect(sessions.first.directory, 'G:/code/openher-mobile');
      expect(sessions.first.agent, 'build');
      expect(sessions.first.cost, closeTo(0.42, 1e-9));
      expect(sessions.first.tokens.total, 2300);
      expect(sessions.first.model?.providerID, 'anthropic');
    });

    test('descarta items que no son mapas sin romper la lista', () async {
      final repo = repoWith(
        server(
          list: jsonEncode({
            'data': [
              'no soy un mapa',
              42,
              jsonDecode(sessionJson(id: 'ses_ok', title: 'ok', updatedMs: 0)),
            ],
            'cursor': {'next': 'x'},
          }),
        ),
      );

      final sessions = await repo.list();

      expect(sessions.map((s) => s.id), ['ses_ok']);
    });

    test('fetchActive devuelve sólo las que están running', () async {
      final repo = repoWith(
        server(
          list: '{"data":[]}',
          active: jsonEncode({
            'data': {
              'ses_x': {'type': 'running'},
              'ses_y': {'type': 'idle'},
              // Un build viejo manda el tipo como string plano.
              'ses_z': 'running',
            },
          }),
        ),
      );

      final running = await repo.fetchActive();

      expect(running, {'ses_x', 'ses_z'});
    });

    test('create devuelve la sesión creada', () async {
      final posted = <String>[];
      final repo = repoWith(
        server(
          list: '{"data":[]}',
          created: sessionJson(
            id: 'ses_9',
            title: 'creada',
            updatedMs: kNow.millisecondsSinceEpoch,
          ),
          posted: posted,
        ),
      );

      final created = await repo.create();

      expect(created.id, 'ses_9');
      expect(posted, hasLength(1));
      // Sin `location` el server usa su directorio actual.
      expect(posted.single, '{}');
    });

    test('un HTML del catch-all lanza HtmlFallbackError', () async {
      final repo = repoWith(MockClient((_) async => html(kSpaHtml)));

      expect(repo.list(), throwsA(isA<HtmlFallbackError>()));
    });
  });

  group('agrupado por fecha', () {
    test('HOY / AYER / ESTA SEMANA / ANTERIORES en orden', () {
      final sessions = [
        sessionAt(kNow),
        sessionAt(kNow.subtract(const Duration(days: 1))),
        sessionAt(kNow.subtract(const Duration(days: 3))),
        sessionAt(kNow.subtract(const Duration(days: 20))),
      ];

      final groups = groupSessions(sessions, kNow);

      expect(groups.map((g) => g.bucket.label), [
        'HOY',
        'AYER',
        'ESTA SEMANA',
        'ANTERIORES',
      ]);
      expect(groups.first.sessions, hasLength(1));
      // Un grupo vacío no ocupa encabezado.
      expect(groupSessions([sessionAt(kNow)], kNow), hasLength(1));
    });

    // Ordenado de más a menos reciente. El server devuelve las sesiones en el
    // orden de los cursores, así que sin este sort la sesión que acabás de usar
    // podía quedar debajo de otras del mismo día.
    test('dentro de un grupo van de más reciente a menos reciente', () {
      final hoy = kNow;
      final sessions = [
        sessionAt(hoy.subtract(const Duration(minutes: 30))),
        sessionAt(hoy.subtract(const Duration(hours: 5))),
        sessionAt(hoy.subtract(const Duration(minutes: 2))),
      ];

      final grupo = groupSessions(sessions, kNow).single;

      expect(grupo.sessions.map((s) => s.updatedAtMs).toList(), [
        hoy.subtract(const Duration(minutes: 2)).millisecondsSinceEpoch,
        hoy.subtract(const Duration(minutes: 30)).millisecondsSinceEpoch,
        hoy.subtract(const Duration(hours: 5)).millisecondsSinceEpoch,
      ]);
    });

    // El sort no puede mezclar los grupos: el de HOY sigue arriba del de AYER.
    test('el sort por fecha no reordena los grupos entre sí', () {
      final sessions = [
        sessionAt(kNow.subtract(const Duration(days: 2))),
        sessionAt(kNow.subtract(const Duration(minutes: 1))),
        sessionAt(kNow.subtract(const Duration(days: 1))),
      ];

      expect(groupSessions(sessions, kNow).map((g) => g.bucket.label), [
        'HOY',
        'AYER',
        'ESTA SEMANA',
      ]);
    });

    test('día calendario, no 24 horas: 23:40 de ayer es AYER', () {
      final late = DateTime(2026, 9, 28, 0, 5);
      final yesterdayLate = DateTime(2026, 9, 27, 23, 40);

      expect(bucketOfDays(0), SessionBucket.today);
      expect(
        groupSessions([sessionAt(yesterdayLate)], late).single.bucket,
        SessionBucket.yesterday,
      );
    });

    test('un updated en el futuro no inventa un grupo "MAÑANA"', () {
      expect(bucketOfDays(-3), SessionBucket.today);
    });

    test('formatRelative y formatCost', () {
      int ago(Duration d) => kNow.subtract(d).millisecondsSinceEpoch;

      expect(formatRelative(ago(const Duration(seconds: 20)), kNow), 'ahora');
      expect(formatRelative(ago(const Duration(minutes: 2)), kNow), '2 min');
      expect(formatRelative(ago(const Duration(minutes: 14)), kNow), '14 min');
      expect(formatRelative(ago(const Duration(hours: 1)), kNow), '1 h');
      expect(formatRelative(ago(const Duration(days: 1)), kNow), 'ayer');
      expect(formatRelative(ago(const Duration(days: 3)), kNow), '3 d');
      // 2026-09-28 menos 30 días = 2026-08-29.
      expect(formatRelative(ago(const Duration(days: 30)), kNow), '29/8');
      expect(formatCost(0.42), r'$0.42');
      expect(formatCost(2.07), r'$2.07');
    });
  });

  group('SessionsViewModel', () {
    test('carga la lista y la agrupa: hoy ⇒ HOY', () async {
      final vm = SessionsViewModel(
        repository: repoWith(
          server(
            list: listJson([
              sessionJson(
                id: 'ses_today',
                title: 'Diseña las vistas mobile',
                updatedMs: kNow.millisecondsSinceEpoch,
              ),
              sessionJson(
                id: 'ses_old',
                title: 'vieja',
                updatedMs: kNow
                    .subtract(const Duration(days: 30))
                    .millisecondsSinceEpoch,
              ),
            ]),
          ),
        ),
        clock: () => kNow,
      );

      await vm.load();

      expect(vm.sessions, hasLength(2));
      expect(vm.error, isNull);
      expect(vm.loading, isFalse);
      expect(vm.groups.map((g) => g.bucket.label), ['HOY', 'ANTERIORES']);
      expect(vm.groups.first.sessions.single.id, 'ses_today');
      expect(vm.relativeTime(vm.sessions.first), 'ahora');
      expect(vm.costOf(vm.sessions.first), r'$0.42');
      vm.dispose();
    });

    test('activeSessions marca running', () async {
      final vm = SessionsViewModel(
        repository: repoWith(
          server(
            list: listJson([
              sessionJson(id: 'ses_x', title: 'corriendo', updatedMs: 0),
            ]),
            active: '{"data":{"ses_x":{"type":"running"}}}',
          ),
        ),
        clock: () => kNow,
      );

      await vm.load();

      expect(vm.running, contains('ses_x'));
      expect(vm.isRunning(vm.sessions.single), isTrue);
      vm.dispose();
    });

    test('un HTML del catch-all deja error seteado y no revienta', () async {
      final vm = SessionsViewModel(
        repository: repoWith(MockClient((_) async => html(kSpaHtml))),
        clock: () => kNow,
      );

      await vm.load();

      expect(vm.error, isNotNull);
      expect(vm.error, contains('HTML'));
      expect(vm.sessions, isEmpty);
      expect(vm.loading, isFalse);
      // El primer group header es HOY aunque la lista esté vacía: `groups`
      // no inventa grupos vacíos.
      expect(vm.groups, isEmpty);
      vm.dispose();
    });

    test('search filtra por título sin volver al server', () async {
      // Sólo se cuenta `GET /api/session`: `load` también pega a `/active`.
      var lists = 0;
      final vm = SessionsViewModel(
        repository: repoWith(
          MockClient((request) async {
            if (request.url.path == '/api/session') lists++;
            return json(
              listJson([
                sessionJson(id: 'a', title: 'Diseña las vistas', updatedMs: 0),
                sessionJson(id: 'b', title: 'Arregla el box', updatedMs: 0),
              ]),
            );
          }),
        ),
        clock: () => kNow,
      );
      await vm.load();

      vm.search('dise');
      expect(vm.visible.map((s) => s.id), ['a']);
      expect(vm.query, 'dise');

      // **Adjudicado 2026-09-30, no editado para que pase.** El
      // `expect(lists, 1)` de abajo ya no es 1 desde que la pantalla pagina
      // con el cursor: son 2. La causa es el **fixture**, no la app:
      // `listJson` mete siempre un `cursor.next`, o sea que jura que hay otra
      // página aunque la respuesta traiga los mismos dos ítems. `listAll`
      // pide esa segunda, ve el mismo cursor y para (guard en
      // `session_paging_test.dart`).
      //
      // Lo que este test quiere afirmar es que **filtrar es local**, y eso se
      // mide como delta: importa que buscar no gaste un request, no cuántas
      // páginas llevó la carga. La garantía original queda intacta y más
      // precisa.
      final trasCargar = lists;

      vm.search('');
      expect(vm.visible, hasLength(2));
      // Filtrar es local: no se gastó un request.
      expect(lists, trasCargar, reason: 'buscar no toca el server');
      expect(trasCargar, greaterThan(0), reason: 'load sí pegó al server');
      vm.dispose();
    });

    test('attention marca los subagentes (parentID presente)', () async {
      final vm = SessionsViewModel(
        repository: repoWith(
          server(
            list: listJson([
              sessionJson(id: 'padre', title: 'padre', updatedMs: 0),
              sessionJson(
                id: 'hijo',
                title: 'subagente',
                updatedMs: 0,
                parent: 'padre',
              ),
            ]),
          ),
        ),
        clock: () => kNow,
      );

      await vm.load();

      expect(vm.attention, {'hijo'});
      expect(vm.needsAttention(vm.sessions.first), isFalse);
      vm.dispose();
    });

    test(
      'la lista muestra sólo las principales: los subagentes se ocultan',
      () async {
        // La regla del escritorio, textual: "Recientes lista SOLO sesiones
        // principales (sin parentID), ni hijas con padre vivo ni huérfanas"
        // (`web/src/components/SessionList.tsx`).
        final vm = SessionsViewModel(
          repository: repoWith(
            server(
              list: listJson([
                sessionJson(id: 'p1', title: 'principal uno', updatedMs: 0),
                sessionJson(
                  id: 's1',
                  title: 'subagente',
                  updatedMs: 0,
                  parent: 'p1',
                ),
                // Huérfana: el padre se borró del server pero el `parentID` sigue
                // apuntando a él. La regla del escritorio también la oculta.
                sessionJson(
                  id: 's2',
                  title: 'huerfana',
                  updatedMs: 0,
                  parent: 'p9',
                ),
                sessionJson(id: 'p2', title: 'principal dos', updatedMs: 0),
              ]),
            ),
          ),
          clock: () => kNow,
        );
        addTearDown(vm.dispose);

        await vm.load();

        expect(vm.visible.map((s) => s.id), <String>[
          'p1',
          'p2',
        ], reason: 'por defecto sólo las principales');
        expect(vm.mainSessions, hasLength(2));
        expect(vm.subagentSessions.map((s) => s.id), <String>['s1', 's2']);
      },
    );

    test('el interruptor deja ver los subagentes', () async {
      final vm = SessionsViewModel(
        repository: repoWith(
          server(
            list: listJson([
              sessionJson(id: 'p1', title: 'principal', updatedMs: 0),
              sessionJson(
                id: 's1',
                title: 'subagente',
                updatedMs: 0,
                parent: 'p1',
              ),
            ]),
          ),
        ),
        clock: () => kNow,
      );
      addTearDown(vm.dispose);

      await vm.load();
      expect(vm.showSubagents, isFalse);

      vm.showSubagents = true;
      expect(
        vm.visible,
        hasLength(2),
        reason: 'con el interruptón prendido, todas',
      );

      vm.showSubagents = false;
      expect(vm.visible, hasLength(1));
    });

    test('el filtro por título también mira las principales', () async {
      final vm = SessionsViewModel(
        repository: repoWith(
          server(
            list: listJson([
              sessionJson(id: 'p1', title: 'Zip del proyecto', updatedMs: 0),
              sessionJson(
                id: 's1',
                title: 'Zip del subagente',
                updatedMs: 0,
                parent: 'p1',
              ),
            ]),
          ),
        ),
        clock: () => kNow,
      );
      addTearDown(vm.dispose);

      await vm.load();
      vm.search('zip');

      // El subagente sigue oculto con el interruptor apagado: si no, buscar
      // "zip" devolvería resultados que después no aparecen en la lista.
      expect(vm.visible.map((s) => s.id), <String>['p1']);
    });

    test('favoritas: van en el orden del usuario y fuera de su día', () async {
      final prefs = InMemoryPrefs();
      final favorites = SessionFavorites(prefs)
        ..toggle('p2')
        ..toggle('p1');
      addTearDown(favorites.dispose);

      final vm = SessionsViewModel(
        repository: repoWith(
          server(
            list: listJson([
              sessionJson(
                id: 'p1',
                title: 'primero en el server',
                updatedMs: 0,
              ),
              sessionJson(
                id: 'p2',
                title: 'segundo en el server',
                updatedMs: 0,
              ),
              sessionJson(id: 'p3', title: 'sin marcar', updatedMs: 0),
            ]),
          ),
        ),
        favorites: favorites,
        clock: () => kNow,
      );
      addTearDown(vm.dispose);

      await vm.load();

      expect(
        vm.favoriteSessions.map((s) => s.id),
        <String>['p2', 'p1'],
        reason: 'el orden es el del usuario, no el del server',
      );
      expect(vm.isFavorite('p1'), isTrue);
      expect(vm.isFavorite('p3'), isFalse);

      // La sesión no marcada sigue en la lista de siempre.
      expect(vm.visible.map((s) => s.id), contains('p3'));
    });

    test('una favorita que ya no existe no aparece', () async {
      final favorites = SessionFavorites(InMemoryPrefs())
        ..toggle('borrada')
        ..toggle('viva');
      addTearDown(favorites.dispose);

      final vm = SessionsViewModel(
        repository: repoWith(
          server(
            list: listJson([
              sessionJson(id: 'viva', title: 'viva', updatedMs: 0),
            ]),
          ),
        ),
        favorites: favorites,
        clock: () => kNow,
      );
      addTearDown(vm.dispose);

      await vm.load();

      // Un id guardado de una sesión que el server ya no devuelve tiene que
      // filtrarse: si no, la lista de favoritas miente sobre lo que hay.
      expect(vm.favoriteSessions.map((s) => s.id), <String>['viva']);
    });

    test('create() llama al server y devuelve el id nuevo', () async {
      final posted = <String>[];
      final vm = SessionsViewModel(
        repository: repoWith(
          server(
            list: listJson([
              sessionJson(id: 'ses_1', title: 'vieja', updatedMs: 0),
            ]),
            created: sessionJson(
              id: 'ses_new',
              title: 'Nueva sesión',
              updatedMs: kNow.millisecondsSinceEpoch,
            ),
            posted: posted,
          ),
        ),
        clock: () => kNow,
      );
      await vm.load();

      final id = await vm.create();

      expect(id, 'ses_new');
      expect(posted, hasLength(1));
      // La nueva entra arriba: es lo más reciente.
      expect(vm.sessions.first.id, 'ses_new');
      expect(vm.sessions, hasLength(2));
      expect(vm.error, isNull);
      vm.dispose();
    });

    test('create() que falla devuelve null y deja el error', () async {
      final vm = SessionsViewModel(
        repository: repoWith(
          MockClient(
            (request) async => request.method == 'POST'
                ? http.Response('{"message":"boom"}', 500)
                : json('{"data":[]}'),
          ),
        ),
        clock: () => kNow,
      );

      expect(await vm.create(), isNull);
      expect(vm.error, 'El servidor falló (500).');
      vm.dispose();
    });

    test(
      'el polling no repinta si active no cambió y para en dispose',
      () async {
        var activeCalls = 0;
        var notifies = 0;
        final vm = SessionsViewModel(
          repository: SessionRepository(
            ApiClient(
              config: kConfig,
              client: MockClient((request) async {
                if (request.url.path == '/api/session/active') {
                  activeCalls++;
                  return json('{"data":{"ses_x":{"type":"running"}}}');
                }
                return json('{"data":[]}');
              }),
              backoff: (_) => Duration.zero,
            ),
          ),
          pollInterval: const Duration(milliseconds: 20),
          clock: () => kNow,
        );
        vm.addListener(() => notifies++);

        await vm.load();
        expect(activeCalls, 1);
        final afterLoad = notifies;
        expect(vm.running, {'ses_x'});

        // Segundo poll con el mismo resultado: cero repintados.
        await vm.pollActive();
        expect(activeCalls, 2);
        expect(notifies, afterLoad);

        vm.startPolling();
        await Future<void>.delayed(const Duration(milliseconds: 70));
        expect(activeCalls, greaterThan(2));

        vm.dispose();
        final atDispose = activeCalls;
        await Future<void>.delayed(const Duration(milliseconds: 70));
        expect(activeCalls, atDispose, reason: 'el timer no puede sobrevivir');
      },
    );
  });

  group('SessionsView', () {
    testWidgets('pinta título, encabezado HOY y "En ejecución"', (
      tester,
    ) async {
      final vm = SessionsViewModel(
        repository: repoWith(
          server(
            list: listJson([
              sessionJson(
                id: 'ses_today',
                title: 'Diseña las vistas mobile',
                updatedMs: kNow.millisecondsSinceEpoch,
                cost: 0.42,
              ),
              sessionJson(
                id: 'ses_old',
                title: 'vieja',
                directory: 'G:/code/openher-flutter-desktop',
                agent: 'plan',
                updatedMs: kNow
                    .subtract(const Duration(days: 30))
                    .millisecondsSinceEpoch,
                cost: 2.07,
              ),
            ]),
            active: '{"data":{"ses_today":{"type":"running"}}}',
          ),
        ),
        clock: () => kNow,
      );
      await pumpView(tester, SessionsView(viewmodel: vm, onOpen: (_) {}));

      expect(find.text('Sesiones'), findsOneWidget);
      await settle(tester);

      expect(find.byKey(SessionsView.listKey), findsOneWidget);
      expect(find.text('HOY'), findsOneWidget);
      expect(find.text('ANTERIORES'), findsOneWidget);
      expect(find.text('Diseña las vistas mobile'), findsOneWidget);
      // `.smeta` del prototipo: basename del directorio + agente.
      expect(find.text('openher-mobile · build'), findsOneWidget);
      expect(find.text('openher-flutter-desktop · plan'), findsOneWidget);
      expect(find.text('En ejecución'), findsOneWidget);
      // La sesión que corre lleva la **luz en el título**, no solo el punto: el
      // título es lo que el usuario mira al volver de otra pantalla, y con
      // títulos largos el punto se pierde. Una sola luz en toda la lista,
      // porque es un solo reloj compartido.
      expect(find.byKey(SessionsView.titleSweepKey), findsOneWidget);
      expect(find.text(r'$0.42'), findsOneWidget);
      expect(find.text(r'$2.07'), findsOneWidget);
      expect(find.text('Sin sesiones'), findsNothing);

      await unmount(tester, vm);
    });

    testWidgets('estado vacío cuando no hay sesiones', (tester) async {
      final vm = SessionsViewModel(
        repository: repoWith(server(list: '{"data":[]}')),
        clock: () => kNow,
      );
      await pumpView(tester, SessionsView(viewmodel: vm, onOpen: (_) {}));
      // El primer frame sale con el spinner: `load()` ya viene en curso.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await settle(tester);

      expect(find.byKey(SessionsView.emptyKey), findsOneWidget);
      expect(find.text('Sin sesiones'), findsOneWidget);
      expect(
        find.text('Toca + para crear una sesión en el directorio actual.'),
        findsOneWidget,
      );
      expect(find.byKey(SessionsView.listKey), findsNothing);

      await unmount(tester, vm);
    });

    testWidgets('un error del server se muestra sin romper la pantalla', (
      tester,
    ) async {
      final vm = SessionsViewModel(
        repository: repoWith(MockClient((_) async => html(kSpaHtml))),
        clock: () => kNow,
      );
      await pumpView(tester, SessionsView(viewmodel: vm, onOpen: (_) {}));
      await settle(tester);

      expect(find.byKey(SessionsView.errorKey), findsOneWidget);
      expect(find.textContaining('HTML'), findsOneWidget);
      expect(find.text('Sesiones'), findsOneWidget);

      await unmount(tester, vm);
    });

    testWidgets('el buscador filtra la lista en pantalla', (tester) async {
      final vm = SessionsViewModel(
        repository: repoWith(
          server(
            list: listJson([
              sessionJson(id: 'a', title: 'Diseña las vistas', updatedMs: 0),
              sessionJson(id: 'b', title: 'Arregla el box', updatedMs: 0),
            ]),
          ),
        ),
        clock: () => kNow,
      );
      await pumpView(tester, SessionsView(viewmodel: vm, onOpen: (_) {}));
      await settle(tester);

      // Oculto por default.
      expect(find.byKey(SessionsView.searchFieldKey), findsNothing);
      await tester.tap(find.byKey(SessionsView.searchButtonKey));
      await tester.pump();
      expect(find.byKey(SessionsView.searchFieldKey), findsOneWidget);

      await tester.enterText(find.byKey(SessionsView.searchFieldKey), 'Diseña');
      await tester.pump();

      expect(find.text('Diseña las vistas'), findsOneWidget);
      expect(find.text('Arregla el box'), findsNothing);

      await unmount(tester, vm);
    });

    testWidgets('el `+` crea la sesión y abre el chat con el id nuevo', (
      tester,
    ) async {
      final posted = <String>[];
      final opened = <String>[];
      final vm = SessionsViewModel(
        repository: repoWith(
          server(
            list: '{"data":[]}',
            created: sessionJson(
              id: 'ses_new',
              title: 'Nueva sesión',
              updatedMs: kNow.millisecondsSinceEpoch,
            ),
            posted: posted,
          ),
        ),
        clock: () => kNow,
      );
      await pumpView(
        tester,
        SessionsView(viewmodel: vm, onOpen: (s) => opened.add(s.id)),
      );
      await settle(tester);

      await tester.tap(find.byKey(SessionsView.addButtonKey));
      await settle(tester);

      expect(posted, hasLength(1));
      expect(opened, ['ses_new']);
      expect(find.text('Nueva sesión'), findsOneWidget);

      await unmount(tester, vm);
    });

    testWidgets('tocar una fila abre esa sesión', (tester) async {
      final opened = <String>[];
      final vm = SessionsViewModel(
        repository: repoWith(
          server(
            list: listJson([
              sessionJson(id: 'ses_t', title: 'Diseña', updatedMs: 0),
            ]),
          ),
        ),
        clock: () => kNow,
      );
      await pumpView(
        tester,
        SessionsView(viewmodel: vm, onOpen: (s) => opened.add(s.id)),
      );
      await settle(tester);

      await tester.tap(find.text('Diseña'));
      await tester.pump();

      expect(opened, ['ses_t']);
      await unmount(tester, vm);
    });

    testWidgets('long-press abre el menú de las 5 acciones', (tester) async {
      final actions = <SessionAction>[];
      final vm = SessionsViewModel(
        repository: repoWith(
          server(
            list: listJson([
              sessionJson(id: 'ses_t', title: 'Diseña', updatedMs: 0),
            ]),
          ),
        ),
        clock: () => kNow,
      );
      await pumpView(
        tester,
        SessionsView(
          viewmodel: vm,
          onOpen: (_) {},
          onAction: (action, _) => actions.add(action),
        ),
      );
      await settle(tester);

      await tester.longPress(find.text('Diseña'));
      await tester.pumpAndSettle();

      for (final label in [
        'Renombrar',
        'Fork',
        'Exportar markdown',
        'Archivar',
        'Cerrar',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }

      await tester.tap(find.text('Renombrar'));
      await tester.pumpAndSettle();

      expect(actions, [SessionAction.rename]);
      expect(find.text('Renombrar'), findsNothing, reason: 'el sheet cerró');

      await unmount(tester, vm);
    });

    testWidgets('el swipe reporta Archivar y la fila vuelve (snap-back)', (
      tester,
    ) async {
      final actions = <SessionAction>[];
      final vm = SessionsViewModel(
        repository: repoWith(
          server(
            list: listJson([
              sessionJson(id: 'ses_t', title: 'Diseña', updatedMs: 0),
            ]),
          ),
        ),
        clock: () => kNow,
      );
      await pumpView(
        tester,
        SessionsView(
          viewmodel: vm,
          onOpen: (_) {},
          onAction: (action, _) => actions.add(action),
        ),
      );
      await settle(tester);

      await tester.drag(find.text('Diseña'), const Offset(-400, 0));
      await tester.pumpAndSettle();

      expect(actions, [SessionAction.archive]);
      // Archivar no existe en el server: la fila no puede desaparecer.
      expect(find.text('Diseña'), findsOneWidget);

      await unmount(tester, vm);
    });
  });
}

http.Response html(String body) =>
    http.Response(body, 200, headers: {'content-type': 'text/html'});

SessionInfo sessionAt(DateTime when) => SessionInfo.fromJson(
  jsonDecode(
        sessionJson(
          id: 'ses_${when.millisecondsSinceEpoch}',
          title: 'x',
          updatedMs: when.millisecondsSinceEpoch,
        ),
      )
      as Map<String, Object?>,
);

/// Deja terminar los futures de la pantalla sin `pumpAndSettle`: el punto que
/// late es una animación infinita y `pumpAndSettle` nunca converge con ella.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

/// Baja la pantalla: sin esto el `AnimationController` del punto que late
/// quedaría vivo y el test falla por un ticker sin parar.
Future<void> unmount(WidgetTester tester, SessionsViewModel vm) async {
  await tester.pumpWidget(const SizedBox.shrink());
  vm.dispose();
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
