/// Los discos de la PC: descubrirlos, entrar a uno, y que "subir" vuelva a
/// "Este equipo" sin que la UI pierda el rumbo.
///
/// La raíz del navegador **no es una carpeta**: es la lista de discos. Por eso
/// el camino de `up()` desde la raíz de un disco tiene que volver a la lista,
/// no a una carpeta padre que no existe.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/data/repositories/file_repository.dart';
import 'package:openher_mobile/ui/features/files/files_viewmodel.dart';
import 'package:openher_mobile/ui/features/files/fs_path.dart';

const ServerConfig _kConfig = ServerConfig(host: '127.0.0.1', port: 4098);

/// Un server falso que sabe listar **solo** las raíces `C:/` y `G:/`.
///
/// El resto de letras devuelve un error: eso es lo que valida la detección, si
/// no parece que cualquier letra sirve.
MockClient _serverDeDiscos() => MockClient((req) async {
  final path = req.url.queryParameters['path'];
  // ignore: avoid_print
  if (path == 'C:/' || path == 'G:/') {
    return http.Response(
      '{"data":[{"path":"fotos","type":"directory"}]}',
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
  return http.Response(
    '{"_tag":"FileNotFoundError"}',
    404,
    headers: const {'content-type': 'application/json'},
  );
});

FilesViewModel _vm() => FilesViewModel(
  repository: FileRepository(
    config: _kConfig,
    client: _serverDeDiscos(),
  ),
);

void main() {
  group('fs_path: las funciones puras', () {
    test('normalizarRuta pone la barra en la raíz de un disco', () {
      // Medido: `path=G:` devuelve 500 y `path=G:/` devuelve 200.
      expect(normalizarRuta('G:'), 'G:/');
      expect(normalizarRuta('G'), 'G:/');
      expect(normalizarRuta(r'G:\Proyectos'), 'G:/Proyectos');
      expect(normalizarRuta('G:/Proyectos/'), 'G:/Proyectos/');
    });

    test('nombreDeRuta saca el último segmento', () {
      expect(nombreDeRuta('G:/a/b/'), 'b');
      expect(nombreDeRuta('C:/'), 'C:');
      expect(nombreDeRuta('fa.png'), 'fa.png');
    });

    test('carpetaPadre sube un nivel, y null en la raíz', () {
      expect(carpetaPadre('G:/a/b'), 'G:/a');
      expect(carpetaPadre('G:/a'), 'G:/');
      expect(carpetaPadre('G:/'), isNull);
    });

    test('esRaiz distingue disco de subcarpeta', () {
      expect(esRaiz('G:/'), isTrue);
      expect(esRaiz('C:/'), isTrue);
      expect(esRaiz('G:/Proyectos'), isFalse);
      expect(esRaiz('/'), isTrue);
    });

    test('unirRuta resuelve .. en vez de concatenarlo', () {
      expect(unirRuta('G:/a/', '..'), 'G:/');
      expect(unirRuta('G:/', 'fotos'), 'G:/fotos');
      expect(unirRuta('G:/a', 'b'), 'G:/a/b');
    });
  });

  group('la detección de discos', () {
    test('roots() devuelve solo las que contestan', () async {
      final vm = _vm();
      addTearDown(vm.dispose);

      await vm.loadRoots();

      expect(vm.roots, isNotNull);
      expect(vm.roots, containsAll(<String>['C:/', 'G:/']));
      expect(vm.roots, isNot(contains('D:/')), reason: 'D:/ no contesta');
    });
  });

  group('subir desde un disco', () {
    test('up() desde la raíz de un disco vuelve a "Este equipo"', () async {
      // **Este es el hueco que no estaba cubierto**: `isDriveRoot` devolvía
      // false siempre, y el break no hacía caer ningún test.
      final vm = _vm();
      addTearDown(vm.dispose);

      await vm.loadRoots();
      await vm.openDrive('C:/');
      expect(vm.path, 'C:/');
      expect(vm.isDriveRoot, isTrue);
      expect(vm.isRoot, isFalse);

      await vm.up();

      // El path vuelve a la raíz y los discos se cargan: eso es "Este equipo".
      expect(vm.path, '');
      expect(vm.isRoot, isTrue);
      expect(vm.roots, isNotNull);
      expect(vm.roots, isNotEmpty);
    });

    test('up() desde una subcarpeta sube un nivel, no a Este equipo', () async {
      final vm = _vm();
      addTearDown(vm.dispose);

      await vm.loadRoots();
      await vm.openDrive('C:/');
      await vm.navigateTo('fotos');
      expect(vm.path, 'C:/fotos');

      await vm.up();

      expect(vm.path, 'C:/');
      expect(vm.isRoot, isFalse, reason: 'no debe volver a Este equipo');
    });
  });
}
