/// Archivos: repositorio, viewmodel y pantalla.
///
/// No hay server: todo el HTTP va por `MockClient`, con la forma medida de
/// `/api/fs/list` (`FileSystemEntry` de `packages/sdk/openapi.json`: `path` +
/// `type`, y las carpetas con el separador al final).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/data/repositories/file_repository.dart';
import 'package:openher_mobile/domain/models/errors.dart';
import 'package:openher_mobile/ui/core/layer_gate.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/features/files/files_view.dart';
import 'package:openher_mobile/ui/features/files/files_viewmodel.dart';

const ServerConfig kConfig = ServerConfig(
  host: '127.0.0.1',
  port: 4098,
  username: 'opencode',
  password: 'hunter2',
);

/// Un directorio con una carpeta y un archivo, como lo manda el server.
const String kListDir = '''
{"data":[{"path":"lib","type":"directory"},
         {"path":"pubspec.yaml","type":"file"}],
 "cursor":{"previous":"eyJpZCI6Imx5XzAifQ=="}}
''';

/// El fallback del catch-all del SPA: 200 con `text/html` (`API_CONTRACT` §1.6).
const String kSpaHtml =
    '<!doctype html><html><head><title>opencode</title></head><body></body>'
    '</html>';

/// Captura las requests y responde siempre lo mismo.
class _FakeFs {
  _FakeFs(this.body, {this.type = 'application/json'});

  String body;
  final String type;
  final List<Uri> requests = <Uri>[];

  MockClient get client => MockClient((request) async {
    requests.add(request.url);
    return http.Response(
      body,
      200,
      headers: <String, String>{'content-type': type},
    );
  });
}

FileRepository _repo(_FakeFs fake) =>
    FileRepository(config: kConfig, client: fake.client);

void main() {
  setUp(() {
    // Todas las capas de Archivos encendidas: es el default de la spec.
    LayerCatalog.debugSetInstance(
      LayerCatalog.forTest(<String, bool>{
        for (final key in <String>[
          FilesView.layerAppBar,
          FilesView.layerTitle,
          FilesView.layerSearch,
          FilesView.layerOverflow,
          FilesView.layerBreadcrumb,
          FilesView.layerRowEntry,
          FilesView.layerRowName,
          FilesView.layerRowExt,
          FilesView.layerRowGit,
          FilesView.layerRowDiff,
          FilesView.layerSheet,
        ])
          key: true,
      }),
    );
  });
  tearDown(() => LayerCatalog.debugSetInstance(null));

  group('FileRepository: mapeo de /api/fs/list', () {
    test('dos entradas: la carpeta y el yaml', () async {
      final repository = _repo(_FakeFs(kListDir));
      addTearDown(repository.close);

      final nodes = await repository.listDirectory();

      expect(nodes, hasLength(2));
      expect(nodes[0].name, 'lib');
      expect(nodes[0].isDirectory, isTrue);
      expect(nodes[0].extension, isEmpty, reason: 'una carpeta no tiene ext');
      expect(nodes[1].name, 'pubspec.yaml');
      expect(nodes[1].isDirectory, isFalse);
      expect(nodes[1].extension, 'yaml');
    });

    test('el separador final del server marca la carpeta', () async {
      // Forma real de un server Windows: `path.relative(...) + path.sep`.
      final repository = _repo(
        _FakeFs('{"data":[{"path":"lib\\\\","type":"directory"}]}'),
      );
      addTearDown(repository.close);

      final node = (await repository.listDirectory(path: 'lib')).single;

      expect(node.isDirectory, isTrue);
      expect(node.name, 'lib');
      expect(node.path, 'lib', reason: 'el path sale normalizado');
    });

    test('el `name` explícito gana sobre el path', () async {
      // El build viejo mandaba `name`; si viene, es la fuente de verdad.
      final repository = _repo(
        _FakeFs('{"data":[{"name":"lib","path":"lib"}]}'),
      );
      addTearDown(repository.close);

      final node = (await repository.listDirectory()).single;

      expect(node.name, 'lib');
      expect(node.isDirectory, isFalse, reason: 'sin `type` no inventa nada');
    });

    test('lo que no es un mapa se descarta sin romper la lista', () async {
      final repository = _repo(
        _FakeFs(
          '{"data":["basura", 3, null, {"path":"a.dart","type":"file"}]}',
        ),
      );
      addTearDown(repository.close);

      final nodes = await repository.listDirectory();

      expect(nodes, hasLength(1));
      expect(nodes.single.extension, 'dart');
    });

    test(
      'la raíz se pide sin `path=` (el server no quiere un vacío)',
      () async {
        final fake = _FakeFs(kListDir);
        final repository = _repo(fake);
        addTearDown(repository.close);

        await repository.listDirectory();

        expect(fake.requests.single.queryParameters, isEmpty);
      },
    );

    test('findFiles manda la query y devuelve paths completos', () async {
      final fake = _FakeFs(
        '{"data":[{"path":"lib/core/x.dart","type":"file"}]}',
      );
      final repository = _repo(fake);
      addTearDown(repository.close);

      final nodes = await repository.findFiles('x.dart');

      expect(fake.requests.single.query, contains('query=x.dart'));
      expect(nodes.single.path, 'lib/core/x.dart');
    });

    test('el HTML del catch-all sale como HtmlFallbackError', () async {
      final repository = _repo(_FakeFs(kSpaHtml, type: 'text/html'));
      addTearDown(repository.close);

      await expectLater(
        repository.listDirectory(),
        throwsA(isA<HtmlFallbackError>()),
      );
    });
  });

  group('FileNode: path y extensión', () {
    test('la extensión es la del último punto, en minúsculas', () {
      expect(FileNode.extensionOf('main.dart'), 'dart');
      expect(FileNode.extensionOf('README.MD'), 'md');
      expect(FileNode.extensionOf('.gitignore'), isEmpty);
      expect(FileNode.extensionOf('Makefile'), isEmpty);
      expect(FileNode.extensionOf('build.'), isEmpty);
    });

    test('la aritmética de rutas es la del server', () {
      expect(FileNode.basename('lib/ui/'), 'ui');
      expect(FileNode.basename(''), isEmpty);
      expect(FileNode.parentOf('lib/ui/core'), 'lib/ui');
      expect(FileNode.parentOf('lib'), isEmpty);
      expect(FileNode.parentOf(''), isEmpty);
      expect(FileNode.join('lib', 'ui'), 'lib/ui');
      expect(FileNode.join('', 'lib'), 'lib');
      expect(FileNode.join('lib\\', 'ui'), 'lib/ui');
      expect(FileNode.segmentsOf('lib\\ui/core'), <String>[
        'lib',
        'ui',
        'core',
      ]);
    });

    test('lee el estado de git si un build futuro lo manda', () {
      final node = FileNode.fromJson(<String, Object?>{
        'path': 'pubspec.yaml',
        'type': 'file',
        'isDirty': true,
        'additions': 12,
        'deletions': 4,
      });

      expect(node.gitMarked, isTrue);
      expect(node.hasDiffCount, isTrue);
      expect(node.toString(), contains('+12 -4'));
    });

    test('sin git, el nodo no inventa marcadores', () {
      final node = FileNode.fromJson(<String, Object?>{
        'path': 'pubspec.yaml',
        'type': 'file',
      });

      expect(node.gitMarked, isFalse);
      expect(node.hasDiffCount, isFalse);
      expect(node.size, isNull);
    });
  });

  group('FilesViewModel', () {
    test('carga la raíz y deja los nodos', () async {
      final repository = _repo(_FakeFs(kListDir));
      final model = FilesViewModel(repository: repository);
      addTearDown(model.dispose);

      await model.load(FileRepository.rootPath);

      expect(model.nodes, hasLength(2));
      expect(model.path, isEmpty);
      expect(model.error, isNull);
      expect(model.loading, isFalse);
    });

    test('un HTML deja error, lista vacía y ningún crash', () async {
      final repository = _repo(_FakeFs(kSpaHtml, type: 'text/html'));
      final model = FilesViewModel(repository: repository);
      addTearDown(model.dispose);

      await model.load(FileRepository.rootPath);

      expect(model.error, contains('HTML'));
      expect(model.nodes, isEmpty);
      expect(model.isEmpty, isFalse, reason: 'con error no se dice "vacía"');
    });

    test('navegar, subir y volver a la raíz arman bien el path', () async {
      final fake = _FakeFs(kListDir);
      final repository = _repo(fake);
      final model = FilesViewModel(repository: repository);
      addTearDown(model.dispose);

      await model.navigateTo('lib');
      expect(model.path, 'lib');
      await model.navigateTo('core');
      expect(model.path, 'lib/core');
      await model.up();
      expect(model.path, 'lib');
      await model.up();
      expect(model.path, isEmpty);

      final before = fake.requests.length;
      await model.up(); // en la raíz no hay padre: no se pide nada
      expect(model.path, isEmpty);
      expect(
        fake.requests,
        hasLength(before),
        reason: 'subir en la raíz no I/O',
      );

      // Cada request lleva el path pedido; la raíz no lleva ninguno.
      expect(
        fake.requests.map((uri) => uri.queryParameters['path']).toList(),
        <String?>['lib', 'lib/core', 'lib', null],
      );
    });

    test(
      'la búsqueda deja el path donde estaba y se va con una vacía',
      () async {
        // Un solo cliente que responde distinto según venga `query`: el mismo
        // server, el mismo directorio.
        final model = FilesViewModel(
          repository: FileRepository(
            config: kConfig,
            client: MockClient((request) async {
              final isSearch = request.url.queryParameters.containsKey('query');
              return http.Response(
                isSearch
                    ? '{"data":[{"path":"lib/main.dart","type":"file"}]}'
                    : kListDir,
                200,
                headers: <String, String>{'content-type': 'application/json'},
              );
            }),
          ),
        );
        addTearDown(model.dispose);

        await model.load('lib');
        expect(model.nodes, hasLength(2));

        await model.search('main');
        expect(model.query, 'main');
        expect(model.path, 'lib', reason: 'buscar no navega');
        expect(model.nodes.single.name, 'main.dart');

        await model.search('  ');
        expect(model.query, isEmpty);
        expect(model.path, 'lib');
        // Volvió al listado, no a la raíz.
        expect(model.nodes, hasLength(2));
      },
    );

    test('los crumbs son la raíz más cada segmento', () {
      final crumbs = FilesViewModel.buildCrumbs('lib/ui/core');
      expect(crumbs.map((c) => c.label).toList(), <String>[
        '/',
        'lib',
        'ui',
        'core',
      ]);
      expect(crumbs.map((c) => c.path).toList(), <String>[
        '',
        'lib',
        'lib/ui',
        'lib/ui/core',
      ]);
      expect(crumbs.last.isTail, isTrue);
      expect(crumbs.first.isTail, isFalse);
    });

    test('en la raíz el único crumb es la raíz', () {
      final crumbs = FilesViewModel.buildCrumbs('');
      expect(crumbs, hasLength(1));
      expect(crumbs.single.label, '/');
      expect(crumbs.single.isTail, isTrue);
    });

    test('la respuesta lenta de una carpeta no pisa la nueva', () async {
      final gate = Completer<void>();
      var call = 0;
      final model = FilesViewModel(
        repository: FileRepository(
          config: kConfig,
          client: MockClient((request) async {
            call++;
            if (call == 1) {
              await gate.future;
              return http.Response(
                '{"data":[{"path":"lento.dart","type":"file"}]}',
                200,
                headers: <String, String>{'content-type': 'application/json'},
              );
            }
            return http.Response(
              '{"data":[{"path":"rapido.dart","type":"file"}]}',
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }),
        ),
      );
      addTearDown(model.dispose);

      final slow = model.load('lento');
      final fast = model.load('rapido');
      await fast;
      gate.complete();
      await slow;

      expect(model.path, 'rapido');
      expect(model.nodes.single.name, 'rapido.dart');
    });

    test('dispose con una request en vuelo no tira', () async {
      final gate = Completer<void>();
      final model = FilesViewModel(
        repository: FileRepository(
          config: kConfig,
          client: MockClient((_) async {
            await gate.future;
            return http.Response('{"data":[]}', 200);
          }),
        ),
      );

      final pending = model.load('lib');
      model.dispose();
      gate.complete();

      await expectLater(pending, completes);
    });
  });

  group('FilesView', () {
    /// Pump de la pantalla con un viewmodel dado. Superficie alta: la lista y
    /// la hoja entran en un solo viewport.
    Future<void> pumpView(
      WidgetTester tester,
      FilesViewModel model, {
      void Function(String path)? onAddToChat,
    }) async {
      tester.view.physicalSize = const Size(500, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: FilesView(
            config: kConfig,
            onAddToChat: onAddToChat ?? (_) {},
            viewModel: model,
          ),
        ),
      );
      await tester.pump();
    }

    /// Pump de la pantalla con un viewmodel ya cargado (sin red en el test).
    Future<FilesViewModel> pumpFiles(
      WidgetTester tester, {
      String body = kListDir,
      String contentType = 'application/json',
      void Function(String path)? onAddToChat,
    }) async {
      final model = FilesViewModel(
        repository: _repo(_FakeFs(body, type: contentType)),
      );
      addTearDown(model.dispose);
      await model.load(FileRepository.rootPath);
      // La raiz ya no es una carpeta: es "Este equipo". Los tests que
      // quieren ver archivos entran a un disco, que es el modelo nuevo.
      await model.openDrive('C:/');
      await pumpView(tester, model, onAddToChat: onAddToChat);
      return model;
    }

    testWidgets('el app bar, el breadcrumb y la extensión del archivo', (
      tester,
    ) async {
      await pumpFiles(
        tester,
        body:
            '{"data":[{"path":"lib","type":"directory"},'
            '{"path":"lib/main.dart","type":"file"}]}',
      );

      expect(find.text('Archivos'), findsOneWidget);
      // **Adjudicado 2026-10-06.** La raíz ya no es `/`: es "Este equipo"
      // y el primer trozo del breadcrumb es el **disco**, no la raíz del
      // `location` del server. La etiqueta lleva la barra (`C:/`) porque
      // `_crumbsText` concatena las etiquetas y tiene que dar la ruta.
      expect(_crumbsText(tester), 'C:/');
      expect(find.text('main.dart'), findsOneWidget);
      expect(find.text('dart'), findsOneWidget, reason: 'files.row.ext');
      // La carpeta se muestra con la barra del prototipo.
      expect(find.text('lib/'), findsOneWidget);
    });

    testWidgets('el breadcrumb muestra el directorio con sus segmentos', (
      tester,
    ) async {
      final model = FilesViewModel(
        repository: _repo(
          _FakeFs('{"data":[{"path":"a.dart","type":"file"}]}'),
        ),
      );
      addTearDown(model.dispose);
      await model.load('lib/ui/core');
      await pumpView(tester, model);

      expect(_crumbsText(tester), '/lib/ui/core');
    });

    testWidgets('una carpeta vacía lo dice', (tester) async {
      await pumpFiles(tester, body: '{"data":[]}');

      expect(find.byKey(FilesView.emptyKey), findsOneWidget);
      expect(find.text('Esta carpeta está vacía.'), findsOneWidget);
    });

    testWidgets('tocar una carpeta entra a ella', (tester) async {
      final model = await pumpFiles(tester);

      await tester.tap(find.byKey(FilesView.rowKey('lib')));
      await tester.pumpAndSettle();

      // **Adjudicado 2026-10-06.** `pumpFiles` entra al disco `C:/` (la raíz ya
      // no es una carpeta), así que la ruta es **absoluta**: `C:/lib`, no `lib`.
      // El criterio no cambia: tocar la carpeta entra a ella y el breadcrumb
      // refleja dónde quedó.
      expect(model.path, 'C:/lib');
      expect(_crumbsText(tester), 'C:/lib');
    });

    testWidgets('tocar largo abre la hoja y "Añadir al chat" avisa', (
      tester,
    ) async {
      final added = <String>[];
      await pumpFiles(
        tester,
        body: '{"data":[{"path":"lib/main.dart","type":"file"}]}',
        onAddToChat: added.add,
      );

      await tester.longPress(find.byKey(FilesView.rowKey('lib/main.dart')));
      await tester.pumpAndSettle();

      expect(find.text('Añadir al chat'), findsOneWidget);
      expect(find.text('Copiar ruta'), findsOneWidget);
      expect(find.text('Abrir'), findsOneWidget);

      await tester.tap(
        find.byKey(FilesView.sheetActionKey(FileAction.addToChat.name)),
      );
      await tester.pumpAndSettle();

      expect(added, <String>['lib/main.dart']);
      expect(
        find.text('Añadir al chat'),
        findsNothing,
        reason: 'la hoja cerró',
      );
    });

    testWidgets('un .html de otro disco se descarga igual', (tester) async {
      // **Adjudicado 2026-10-08.** Este test afirmaba el freno fuera del
      // location, que nació de una medición errónea: lo que fallaba era el
      // sniff (`text/html` ⇒ fallback), no el server — `C:/Windows` y `G:`
      // devuelven bytes reales. Con el veredicto por cuerpo, la descarga
      // procede: en el test los bytes llegan hasta compartir (que sin
      // plataforma tira, y ese es el aviso que se ve).
      final reads = <Uri>[];
      final client = MockClient((request) async {
        const jsonType = <String, String>{'content-type': 'application/json'};
        if (request.url.path.contains('fs/read')) {
          reads.add(request.url);
          return http.Response(
            '<!DOCTYPE html><html lang="es"><head><title>seek</title></head>'
            '<body>maqueta</body></html>',
            200,
            headers: <String, String>{'content-type': 'text/html'},
          );
        }
        return http.Response(
          '{"data":[{"path":"G:\\\\Proyectos\\\\seek-asm\\\\mockup-bar.html",'
          '"type":"file"}]}',
          200,
          headers: jsonType,
        );
      });
      final model = FilesViewModel(
        repository: FileRepository(config: kConfig, client: client),
      );
      addTearDown(model.dispose);
      await model.load('G:/Proyectos/seek-asm');
      await pumpView(tester, model);

      await tester.longPress(
        find.byKey(
          FilesView.rowKey(r'G:\Proyectos\seek-asm\mockup-bar.html'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(FilesView.sheetActionKey(FileAction.download.name)),
      );
      await tester.pumpAndSettle();

      // En widget no se puede afirmar el compartir: `writeAsBytes` es I/O
      // real y bajo `flutter_test` no completa (fake async). Lo que prueba el
      // fix es que la request sale y los bytes se aceptan (el repo-test de
      // arriba afirma los bytes); acá se afirma que no hay freno ni error.
      expect(reads, hasLength(1), reason: 'la descarga sale a la red');
      expect(
        find.textContaining('No se pudo descargar'),
        findsNothing,
        reason: 'el .html genuino ya no se confunde con el SPA',
      );
    });

    /// Cada accion de la hoja tiene que ser apretable.
    ///
    /// Salio de un bug real: "Abrir" y "Ver diff" estaban con `onPressed: null`
    /// (el `switch` de arriba ya hacia su parte), asi que en el handset la fila
    /// salia `clickable="false"` y apretarla no hacia nada. `flutter analyze` y
    /// los tests de contenido no lo detectan porque el texto "Abrir" seguia
    /// estando igual; lo detecta el arbol de accesibilidad. Este test lo cierra.
    testWidgets('ninguna accion de la hoja queda sin destino', (tester) async {
      await pumpFiles(
        tester,
        body: '{"data":[{"path":"docs/pagina.html","type":"file"}]}',
      );

      await tester.longPress(find.byKey(FilesView.rowKey('docs/pagina.html')));
      await tester.pumpAndSettle();

      for (final action in FileAction.values) {
        final finder = find.byKey(FilesView.sheetActionKey(action.name));
        expect(finder, findsOneWidget, reason: 'la hoja no muestra ${action.name}');
        // El `InkWell` **es** el widget con la key (no un descendiente), y un
        // item deshabilitado tiene `onTap: null`: no recibe toques. Ese es
        // exactamente el sintoma del bug.
        expect(
          tester.widget<InkWell>(finder).onTap,
          isNotNull,
          reason: '${action.name} esta en la hoja pero no tiene destino',
        );
      }
    });

    /// Pump de UN archivo y la hoja de acciones ya abierta. Es el atajo que
    /// necesitan los tests de la accion de navegador.
    Future<void> pumpSheet(WidgetTester tester, String name) async {
      await pumpFiles(
        tester,
        body: '{"data":[{"path":"$name","type":"file"}]}',
      );
      await tester.tap(find.byKey(FilesView.rowKey(name)));
      await tester.pumpAndSettle();
    }

    /// "Abrir en el navegador": cuando la fila aparece.
    ///
    /// El riesgo no es que la URL este mal (eso lo cubre
    /// `browser_open_test.dart`), es que la fila aparezca donde el navegador
    /// no va a poder mostrar nada, o que falte donde si va a poder.
    group('abrir en el navegador', () {
      testWidgets('aparece para un .html, que es lo que la pide', (
        tester,
      ) async {
        await pumpSheet(tester, 'pagina.html');
        expect(find.text('Abrir en el navegador'), findsOneWidget);
      });

      testWidgets('aparece para imagen, PDF, markdown y codigo', (
        tester,
      ) async {
        for (final name in <String>['a.png', 'b.pdf', 'c.md', 'd.dart']) {
          await pumpSheet(tester, name);
          expect(
            find.text('Abrir en el navegador'),
            findsOneWidget,
            reason: '\$name se abre bien en el navegador',
          );
          await tester.tapAt(const Offset(10, 10));
          await tester.pumpAndSettle();
        }
      });

      testWidgets('no aparece para un binario', (tester) async {
        await pumpSheet(tester, 'app.apk');
        expect(find.text('Abrir en el navegador'), findsNothing);
        expect(find.text('Abrir'), findsOneWidget);
      });

      testWidgets('no aparece para video ni audio: el reproductor propio es mejor',
          (tester) async {
        for (final name in <String>['c.mp4', 'd.mp3']) {
          await pumpSheet(tester, name);
          expect(
            find.text('Abrir en el navegador'),
            findsNothing,
            reason: name,
          );
          await tester.tapAt(const Offset(10, 10));
          await tester.pumpAndSettle();
        }
      });
    });


    testWidgets('el error del server se muestra y reintenta', (tester) async {
      await pumpFiles(tester, body: kSpaHtml, contentType: 'text/html');

      expect(find.byKey(FilesView.errorKey), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
      expect(find.text('Esta carpeta está vacía.'), findsNothing);
    });

    testWidgets('el buscador pide una vez por búsqueda, no una por tecla', (
      tester,
    ) async {
      final fake = _FakeFs(
        '{"data":[{"path":"lib","type":"directory"},'
        '{"path":"lib/main.dart","type":"file"}]}',
      );
      final model = FilesViewModel(repository: _repo(fake));
      addTearDown(model.dispose);
      await pumpView(tester, model);
      // La raiz es "Este equipo": sin entrar a un disco, la sonda de
      // discos llena `requests` y el test mide otra cosa.
      await model.openDrive('C:/');
      await tester.pumpAndSettle();
      // Entrar al disco ya hizo su request: sin limpiar, el test mide el
      // arranque y no la búsqueda, que es lo que importa acá.
      fake.requests.clear();

      await _tapIcon(tester, 'Buscar archivos');
      expect(find.byKey(FilesView.searchFieldKey), findsOneWidget);

      await tester.enterText(find.byKey(FilesView.searchFieldKey), 'main');
      // El debounce todavía no venció: no se buscó nada.
      expect(fake.requests, isEmpty);
      await tester.pump(FilesView.searchDebounce);
      await tester.pumpAndSettle();

      expect(fake.requests, hasLength(1));
      expect(fake.requests.single.query, contains('query=main'));
      expect(model.query, 'main');
      // En una búsqueda se ve el path completo, no el nombre suelto.
      expect(find.text('lib/main.dart'), findsOneWidget);

      // Tocar una carpeta del resultado abre ésa, no una con el path pegado al
      // directorio de arriba.
      await tester.tap(find.byKey(FilesView.rowKey('lib')));
      await tester.pumpAndSettle();

      expect(model.path, 'lib');
      expect(model.query, isEmpty, reason: 'navegar sale de la búsqueda');
      expect(_crumbsText(tester), '/lib');
    });

    testWidgets('el overflow ofrece Actualizar e Ir a la raíz', (tester) async {
      await pumpFiles(tester);

      await _tapIcon(tester, 'Más acciones');

      expect(find.text('Actualizar'), findsOneWidget);
      expect(find.text('Ir a la raíz'), findsOneWidget);
    });
  });

  group('FileRepository.downloadBytes: /api/fs/read en crudo', () {
    FileRepository repoCon(
      Future<http.Response> Function(http.BaseRequest) handler,
    ) => FileRepository(config: kConfig, client: MockClient(handler));

    test('devuelve los bytes exactos y pide la ruta con location', () async {
      http.BaseRequest? vista;
      final repository = repoCon((request) async {
        vista = request;
        return http.Response.bytes(
          <int>[1, 2, 3],
          200,
          headers: <String, String>{'content-type': 'image/png'},
        );
      });
      addTearDown(repository.close);

      final bytes = await repository.downloadBytes(
        path: 'foto.png',
        directory: 'G:/fotos',
      );

      expect(bytes, <int>[1, 2, 3]);
      expect(vista!.url.path, '/api/fs/read/foto.png');
      expect(
        vista!.url.queryParameters['location[directory]'],
        'G:/fotos',
      );
    });

    test('un 404 tira ApiError, no devuelve basura', () async {
      final repository = repoCon(
        (_) async => http.Response('{"_tag":"FileNotFoundError"}', 404),
      );
      addTearDown(repository.close);

      expect(
        repository.downloadBytes(path: 'noexiste.txt'),
        throwsA(isA<ApiError>()),
      );
    });

    test('un .html genuino se descarga: el header no decide', () async {
      // **Adjudicado 2026-10-08.** El sniff viejo (`text/html` ⇒ fallback)
      // rompía descargas reales: `mockup-bar.html` en G: volvía 200 con sus
      // bytes y la app lo tiraba. El veredicto es el cuerpo (marca del SPA).
      const body =
          '<!DOCTYPE html><html lang="es"><head><title>seek</title></head>'
          '<body>maqueta</body></html>';
      final repository = repoCon(
        (_) async => http.Response(
          body,
          200,
          headers: <String, String>{'content-type': 'text/html'},
        ),
      );
      addTearDown(repository.close);

      expect(
        await repository.downloadBytes(path: 'mockup-bar.html'),
        isNotEmpty,
      );
    });

    test('el shell del SPA no se comparte como archivo', () async {
      // **Adjudicado 2026-10-08.** El fixture anterior era inventado
      // (`<title>opencode</title>`) y la premisa también: ningún `.html`
      // genuino es fallback. El shell real trae su marca
      // (`v2-background-bg-deep`, medida en `/` y `/algo`); solo ese cuerpo
      // se rechaza.
      final repository = repoCon(
        (_) async => http.Response(
          '<!doctype html><html lang="en" style="background-color: '
          'var(--v2-background-bg-deep, #fafafa)"><head></head>'
          '<body></body></html>',
          200,
          headers: <String, String>{'content-type': 'text/html'},
        ),
      );
      addTearDown(repository.close);

      expect(
        repository.downloadBytes(path: 'raro'),
        throwsA(isA<HtmlFallbackError>()),
      );
    });

    test('un 401 tira AuthError', () async {
      final repository = repoCon((_) async => http.Response('x', 401));
      addTearDown(repository.close);

      expect(
        repository.downloadBytes(path: 'a.txt'),
        throwsA(isA<AuthError>()),
      );
    });
  });
}

/// Apretar el `AppIconButton` del app bar por su etiqueta de accesibilidad: los
/// iconos son SVG y no tienen texto.
Future<void> _tapIcon(WidgetTester tester, String label) async {
  await tester.tap(
    find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.label == label,
    ),
  );
  await tester.pumpAndSettle();
}

/// El breadcrumb tal como se lee en pantalla: todos los textos de la fila, en
/// orden (las migas y los `/` que las separan).
String _crumbsText(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(FilesView.breadcrumbKey),
        matching: find.byType(Text),
      ),
    )
    .map((text) => text.data ?? '')
    .join();
