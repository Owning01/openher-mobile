/// Estado de la pantalla de Archivos.
///
/// Un [ChangeNotifier] y nada más: el árbol de archivos es del **server**, así
/// que no hay caché local que pueda quedar vieja (tirar el pull-to-refresh y
/// volver a pedir es más barato que mantener una copia que miente).
library;

import 'package:flutter/foundation.dart' show ChangeNotifier;

import '../../../data/repositories/file_repository.dart';
import '../../../domain/models/errors.dart';
import 'fs_path.dart';

/// Una parte de la ruta actual, para la fila de breadcrumbs.
///
/// El primero es siempre la raíz del `location` (`/`), así que desde cualquier
/// profundidad un toque devuelve a la raíz sin necesitar el overflow.
class FileCrumb {
  const FileCrumb({
    required this.label,
    required this.path,
    required this.isTail,
  });

  /// Lo que se ve: `/` para la raíz, el nombre del segmento para el resto.
  final String label;

  /// A dónde navega un toque: la ruta relativa completa hasta acá.
  final String path;

  /// `true` en el último (el directorio donde se está).
  final bool isTail;

  @override
  String toString() => 'FileCrumb($label -> $path)';
}

/// Texto listo para pintar en la UI. Mismo criterio que `ConnectView`: la
/// jerarquía sellada se desenvuelve (su `toString` es `'$runtimeType: $message'`)
/// y lo que no es del dominio se muestra con su `toString`, que en Dart ya
/// incluye el tipo.
String describeFilesError(Object error) =>
    error is OchError ? error.message : error.toString();

class FilesViewModel extends ChangeNotifier {
  /// El directorio de arranque es la raíz; para estar en otro lado se llama
  /// [load] (o [navigateTo]), que es el mismo camino que usa el usuario.
  FilesViewModel({required this.repository});

  final FileRepository repository;

  List<FileNode> _nodes = const <FileNode>[];

  /// Lo que hay en [path] (o los resultados de la búsqueda actual).
  List<FileNode> get nodes => _nodes;

  String _path = FileRepository.rootPath;

  /// Directorio actual, relativo a la raíz del `location`. `''` es la raíz.
  String get path => _path;

  /// Los discos de la PC, o `null` si todavía no se preguntaron.
  ///
  /// `null` y no `[]` porque son cosas distintas: `[]` es "pregunté y no hay
  /// discos", y `null` es "todavía no pregunté". Confundirlas hacía que la
  /// pantalla mostrara "no hay discos" antes de tiempo.
  List<String>? _roots;

  List<String>? get roots => _roots;

  /// ¿Se está en la raíz de un **disco**? Ahí el padre no es una carpeta: es la
  /// lista de discos.
  bool get isDriveRoot => _path.isNotEmpty && esRaiz(_path);

  bool _loading = false;

  /// ¿Hay una request en vuelo? Se puede refrescar con la lista vieja en pantalla.
  bool get loading => _loading;

  String? _error;

  /// Mensaje del último fallo, o `null`. Cuando hay error la lista se vacía:
  /// mezclar resultados viejos con un error dice cosas falsas.
  String? get error => _error;

  String _query = '';

  /// Búsqueda activa. Vacía = se está listando [path].
  String get query => _query;

  /// ¿Se está en la raíz del `location`? (no hay padre al que subir)
  bool get isRoot => _path.isEmpty;


  /// Directorio vacío: se puede pintar "Esta carpeta está vacía".
  bool get isEmpty => !_loading && _error == null && _nodes.isEmpty;

  /// La fila de breadcrumbs del [path] actual.
  ///
  /// El **primer trozo es el disco**, no `/`: la app navega el disco de la PC, y
  /// el nivel de arriba de `G:/Proyectos/web` es `G:`, no la raíz del `location`
  /// del server. Antes el primer trozo era `/` y por eso no había forma de
  /// volver a la lista de discos.
  List<FileCrumb> get crumbs => buildCrumbs(_path);

  /// El `location` del server es una ruta absoluta en la máquina de aquél: la
  /// app no la conoce y no hay dónde preguntarla sin abrir otro endpoint. Por
  /// eso la raíz se muestra como `/` y los segmentos con su nombre.
  static List<FileCrumb> buildCrumbs(String path) {
    final segments = FileNode.segmentsOf(path);
    final crumbs = <FileCrumb>[];

    // ¿Hay disco? `G:/Proyectos/web` -> `G:`. Sin disco (ruta relativa vieja) se
    // conserva el `/` de antes, para no romper lo que ya funciona.
    final drive = _driveOf(path);
    if (drive != null) {
      crumbs.add(
        // Con la barra: `_crumbsText` **concatena** las etiquetas, así que
        // `C:` + `lib` daba `C:lib`. Con `C:/` da `C:/lib`, que es la
        // ruta de verdad y lo que el breadcrumb tiene que mostrar.
        FileCrumb(label: normalizarRuta(drive), path: normalizarRuta(drive), isTail: segments.length <= 1),
      );
    } else {
      crumbs.add(
        FileCrumb(
          label: '/',
          path: FileRepository.rootPath,
          isTail: segments.isEmpty,
        ),
      );
    }

    var accumulated = drive == null ? '' : normalizarRuta(drive);
    for (var i = 0; i < segments.length; i++) {
      // El primer segmento de una ruta absoluta es el nombre del disco, que ya
      // va en el trozo de arriba.
      if (drive != null && i == 0) continue;
      accumulated = accumulated.isEmpty
          ? segments[i]
          : FileNode.join(accumulated, segments[i]);
      crumbs.add(
        FileCrumb(
          label: segments[i],
          path: accumulated,
          isTail: i == segments.length - 1,
        ),
      );
    }
    return crumbs;
  }

  /// El disco de una ruta absoluta, o `null` si no lo tiene.
  ///
  /// `G:/a` -> `G:`; `G:` -> `G:`; `lib/ui` -> `null`.
  static String? _driveOf(String path) {
    final normal = normalizarRuta(path);
    final match = RegExp(r'^([A-Za-z]:)').firstMatch(normal);
    return match?.group(1);
  }

  // ───────────────────────────── movimientos ──────────────────────────────────

  /// Lista [path]. Navegar **sale** de la búsqueda: si estás viendo un
  /// directorio, no estás buscando.
  Future<void> load(String path) {
    // La misma ruta normalizada va **al server** y al estado. Antes el estado
    // quedaba normalizado y el pedido no: `parentOf(C:/fotos')` da `C:` y el
    // server manda `?path=C%3A`, que contesta 500 (medido).
    final limpio = normalizarRuta(path);
    return _fetch(
      path: limpio,
      query: '',
      request: () => repository.listDirectory(path: limpio),
    );
  }

  /// Entra a la carpeta [name] dentro de [path].
  Future<void> navigateTo(String name) => load(FileNode.join(_path, name));

  /// Sube al padre. En la raíz no hace nada (y no pide nada).
  ///
  /// Desde la raíz de un **disco** el padre no es una carpeta: es la lista de
  /// discos. Ahí "subir" significa volver a "Este equipo", que es lo que hace
  /// Explorer con el botón de arriba.
  Future<void> up() async {
    if (isRoot) return;
    if (isDriveRoot) {
      await loadRoots();
      return;
    }
    await load(FileNode.parentOf(_path));
  }

  /// Pide los discos de la PC y los deja en [roots].
  ///
  /// No lista nada: la pantalla muestra "Este equipo" con los discos, y recién
  /// cuando el usuario toca uno se lista. Pedir los discos y listar el primero a
  /// la vez era lo que hacía que abrir Archivos tardara un timeout entero.
  Future<void> loadRoots() async {
    _loading = true;
    _error = null;
    _notify();
    // La vista de "Este equipo" solo se muestra con la raiz vacia: sin esto,
    // `up()` desde un disco llamaba a loadRoots y el path seguia siendo `C:/`,
    // asi que la lista de discos nunca aparecia.
    _path = FileRepository.rootPath;
    _query = '';
    _nodes = const <FileNode>[];
    try {
      _roots = await repository.roots();
    } catch (e) {
      _error = describeFilesError(e);
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// Entra a un disco: `G:/`.
  ///
  /// Es el mismo camino que [load], pero con la ruta absoluta del disco. El
  /// server la resuelve aunque el `location` sea otro (medido).
  Future<void> openDrive(String drive) => load(normalizarRuta(drive));

  /// Busca por nombre en todo el `location` (`/api/fs/find`).
  ///
  /// Una búsqueda vacía no es un filtro de cero resultados: es "volvé a
  /// listar", así que se vuelve a pedir el directorio actual y el [path] no se
  /// mueve en ningún caso.
  Future<void> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return load(_path);
    await _fetch(
      path: _path,
      query: trimmed,
      request: () => repository.findFiles(trimmed),
    );
  }

  /// Vuelve a pedir lo que se está mostrando, sin perder el modo actual
  /// (listado o búsqueda). Es lo que dispara el pull-to-refresh.
  Future<void> refresh() => _fetch(
    path: _path,
    query: _query,
    request: () => _query.isEmpty
        ? repository.listDirectory(path: _path)
        : repository.findFiles(_query),
  );

  /// El cuerpo de toda request. [_generation] es la que evita la carrera de
  /// esta pantalla: el usuario entra a `lib` y aprieta atrás antes de que
  /// vuelva la primera respuesta, y sin esto la lista lenta pisaba a la nueva y
  /// dejaba el breadcrumb apuntando al directorio equivocado.
  ///
  /// Después del `await` no se escribe nada si la request ya no es la vigente:
  /// una respuesta tardía se descarta entera.
  Future<void> _fetch({
    required String path,
    required String query,
    required Future<List<FileNode>> Function() request,
  }) async {
    final generation = ++_generation;
    // La ruta se **normaliza** al guardarla: `FileNode.parentOf(C:/fotos)`
    // devuelve `C:` (sin barra), y el resto del modelo —`esRaiz`, `buildCrumbs`,
    // la comparación con `rootPath`— trabaja con `C:/`. Sin normalizar acá, el
    // path guardado y el de la vista se desalineaban por una barra.
    _path = normalizarRuta(path);
    _query = query;
    _loading = true;
    _error = null;
    _notify();
    List<FileNode>? nodes;
    String? failure;
    try {
      nodes = await request();
    } on Object catch (error) {
      failure = describeFilesError(error);
    }
    if (!_isCurrent(generation)) return;

    if (failure == null) {
      _nodes = List<FileNode>.unmodifiable(nodes ?? const <FileNode>[]);
    } else {
      // Con error la lista se vacía: resultados viejos al lado de un error de
      // red dicen cosas que no son verdad.
      _nodes = const <FileNode>[];
    }
    _error = failure;
    _loading = false;
    _notify();
  }

  int _generation = 0;
  bool _disposed = false;

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // El repositorio es del viewmodel, así que se cierra con él. Un
    // `http.Client` inyectado no se toca: lo decide `ApiClient.close`.
    repository.close();
    super.dispose();
  }
}
