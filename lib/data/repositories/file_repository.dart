/// Repositorio del sistema de archivos remoto (`/api/fs/*`, dialecto v2).
///
/// ## Lo que el server manda de verdad
///
/// Medido contra el build de esta máquina (`packages/sdk/openapi.json` →
/// `FileSystemEntry`, `additionalProperties: false`), una entrada es
/// exactamente esto:
///
/// ```json
/// {"path": "lib",          "type": "directory"}
/// {"path": "pubspec.yaml", "type": "file"}
/// ```
///
/// De ahí salen todas las rarezas de acá, y este es el **único** archivo que las
/// conoce:
///
/// - **No hay `name`.** Sale del último segmento de `path` ([FileNode.name]).
/// - **No hay `size`.** [FileNode.size] queda `null` salvo que un build futuro
///   lo mande.
/// - **No hay nada de git.** `/api/fs/list` no informa del estado del repo, así
///   que [FileNode.isDirty], [FileNode.additions] y [FileNode.deletions] quedan
///   en su default y los marcadores de `files.row.git` / `files.row.diff` no
///   tienen nada que dibujar. Igual se leen si vinieran, para que el día que el
///   server los mande no haya que tocar la UI.
/// - **Las carpetas llegan con separador al final**: `FileSystem.list` arma el
///   path como `path.relative(location.directory, …) + path.sep`
///   (`packages/core/src/filesystem.ts:101`), o sea que en un server Windows
///   terminan en `\` y en uno Linux en `/`. Por eso [FileNode.path] sale
///   normalizado (sin separador final) y `isDirectory` se deduce **antes** de
///   normalizar.
/// - **El path es relativo al `location`**, no al directorio pedido, y viene
///   ordenado: carpetas primero, después por path (`filesystem.ts:106`). Acá no
///   se reordena nada: el server es la única fuente del orden.
///
/// ## Rutas
///
/// [FileNode.path] es relativo a la raíz del `location` del server (lo que
/// `/api/location` llama `directory`), nunca absoluto. Todas las operaciones de
/// ruta de la app viven en los estáticos de [FileNode] —[FileNode.join],
/// [FileNode.parentOf], [FileNode.segmentsOf]— para que la vista y el
/// viewmodel compartan exactamente la misma aritmética.
library;

import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/network/api_client.dart';
import '../../core/network/server_config.dart';
import '../../domain/models/errors.dart';
import '../../ui/features/files/fs_path.dart';

/// Una entrada del árbol de archivos: una carpeta o un archivo.
///
/// Inmutable. [path] es relativo a la raíz del `location` y **sin** separador
/// final; [name] es el último segmento de ese path.
class FileNode {
  const FileNode({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.extension = '',
    this.size,
    this.isDirty = false,
    this.additions = 0,
    this.deletions = 0,
  });

  /// Mapea una entrada cruda de `/api/fs/list` o `/api/fs/find`.
  ///
  /// Tolera las tres formas en que puede venir la "es una carpeta": el
  /// discriminador `type` del dialecto v2, un `isDirectory`/`is_dir` booleano
  /// (builds viejos) y el separador final que agrega el server. Con `name`
  /// explícito gana el `name`; si no, sale del path.
  factory FileNode.fromJson(Map<String, Object?> json) {
    final raw = asStr(json['path']) ?? '';
    final name = asStr(json['name']) ?? basename(raw);
    final isDirectory =
        asStr(json['type']) == 'directory' ||
        (asBool(json['isDirectory']) ?? asBool(json['is_dir']) ?? false) ||
        _endsWithSeparator(raw);
    return FileNode(
      name: name,
      path: normalize(raw),
      isDirectory: isDirectory,
      // Una carpeta no tiene extensión: `openher-flutter-desktop` no es `desktop`.
      extension: isDirectory ? '' : extensionOf(name),
      size: asInt(json['size']),
      isDirty: asBool(json['isDirty']) ?? false,
      additions: asInt(json['additions']) ?? 0,
      deletions: asInt(json['deletions']) ?? 0,
    );
  }

  /// Último segmento de [path] (`.gitignore` a secas, sin separador encima).
  final String name;

  /// Ruta relativa a la raíz del `location`, normalizada, sin separador final.
  final String path;

  final bool isDirectory;

  /// Extensión sin el punto y en minúsculas (`yaml`, `dart`). Vacía si el
  /// nombre no tiene punto, si el punto es el primer carácter (`.gitignore`) o
  /// si termina en punto. Las carpetas siempre la tienen vacía.
  final String extension;

  /// Tamaño en bytes. Hoy siempre `null`: `FileSystemEntry` no lo trae
  /// (`additionalProperties: false`).
  final int? size;

  /// Marcador de git sucio. Ver la nota de git en el header de este archivo.
  final bool isDirty;

  /// Líneas agregadas / borradas para el chip de diff. Ver la nota de git.
  final int additions;
  final int deletions;

  /// ¿Lleva el chip `+N -N`? (sólo archivos: una carpeta no tiene diff).
  bool get hasDiffCount => !isDirectory && (additions > 0 || deletions > 0);

  /// ¿Lleva el punto de 6 px de `files.row.git`?
  bool get gitMarked => isDirty || hasDiffCount;

  @override
  String toString() =>
      'FileNode($path, ${isDirectory ? 'dir' : 'file'})'
      '${hasDiffCount ? ' +$additions -$deletions' : ''}';

  // ───────────────────────────── aritmética de rutas ─────────────────────────

  /// Separadores que puede traer un path del server: `\` en un server Windows y
  /// `/` en uno Linux (ver el header). Se partido por los dos, siempre.
  static final RegExp separator = RegExp(r'[\\/]+');

  static final RegExp trailingSeparators = RegExp(r'[\\/]+$');

  static bool _endsWithSeparator(String path) =>
      path.isNotEmpty && trailingSeparators.hasMatch(path);

  /// Quita el separador final que el server pone en las carpetas.
  static String normalize(String path) =>
      path.replaceFirst(trailingSeparators, '');

  /// Último segmento de [path]. `lib/` → `lib`; `''` → `''`.
  static String basename(String path) {
    final segments = segmentsOf(path);
    return segments.isEmpty ? '' : segments.last;
  }

  /// [path] partido en segmentos, sin los vacíos de los separadores.
  static List<String> segmentsOf(String path) => normalize(path)
      .split(separator)
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);

  /// Ruta padre. `lib/ui/core` → `lib/ui`; `lib` → `''` (la raíz).
  static String parentOf(String path) {
    final clean = normalize(path);
    if (clean.isEmpty) return '';
    final cut = clean.lastIndexOf(separator);
    return cut <= 0 ? '' : clean.substring(0, cut);
  }

  /// `[directory, name]`. El separador de salida es `/` a propósito: es el que
  /// acepta `path.resolve` en los dos sistemas (`filesystem.ts:67`), mientras
  /// que un `\` sería un carácter de nombre de archivo en Linux.
  static String join(String directory, String name) {
    final base = normalize(directory);
    return base.isEmpty ? name : '$base/$name';
  }

  /// Extensión de [name] en minúsculas, o `''` si no tiene.
  static String extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }
}

/// Envoltura de los endpoints de filesystem.
///
/// No guarda estado ni cachea: la pantalla de Archivos es una vista del árbol
/// del servidor, y un `RefreshIndicator` que devuelve lo de hace un minuto es
/// peor que no tener pull-to-refresh.
class FileRepository {
  FileRepository({required this.config, http.Client? client})
    : _api = ApiClient(config: config, client: client);

  /// La raíz del `location` del server es [rootPath]: un path relativo vacío.
  /// Se manda como `null` al server, no como `path=`, porque `ListInput.path` es
  /// opcional y un string vacío no es un `RelativePath` válido.
  static const String rootPath = '';

  final ServerConfig config;

  final ApiClient _api;

  /// `GET /api/fs/list` — una carpeta, en el orden que devuelve el server
  /// (carpetas primero, después archivos, por path).
  ///
  /// El `location[directory]` **no** se manda: cada server habla del `location`
  /// que el usuario abrió al conectar, y mandarle otro sería pedirle un
  /// directorio que la app ni conoce.
  ///
  /// **Acepta rutas absolutas**, y eso es lo que habilita cambiar de disco.
  /// Medido 2026-10-6: `path=G:/` lista el disco `G:` aunque el `location` del
  /// server sea `C:\Users\perca`. El doc viejo decía que el path era "nunca
  /// absoluto"; era falso y era lo que bloqueaba salir de la carpeta base.
  Future<List<FileNode>> listDirectory({String path = rootPath}) async {
    final page = await _api.listDirectory(path: path.isEmpty ? null : path);
    return _map(page.data);
  }

  /// Los discos de la PC, **descubiertos probando** cada letra.
  ///
  /// El server **no tiene** un endpoint que los enumere: medido 2026-10-6,
  /// `/api/fs/roots`, `/api/fs/drives` y `/api/drives` dan **404**. La única
  /// forma de saber qué discos hay es pedir la lista de cada raíz y ver cuál
  /// contesta.
  ///
  /// **En paralelo y con timeout corto**, y no por gusto: en serie, 26 requests
  /// a un server que puede tardar 10 s por una unidad de red muerta son cuatro
  /// minutos de pantalla congelada. En paralelo, el peor caso es un timeout.
  ///
  /// Devuelve las raíces que contestaron, en orden de letra. Una letra que no
  /// existe simplemente no aparece: no hay forma de distinguir "no existe" de
  /// "está caída", y decirlo en pantalla es trabajo de la UI.
  Future<List<String>> roots() async {
    final resultados = await Future.wait(
      kLetrasDeDisco.map((letra) async {
        final raiz = discoDe(letra);
        try {
          await _api
              .listDirectory(path: raiz)
              .timeout(kRootProbeTimeout);
          return raiz;
        } catch (_) {
          return null;
        }
      }),
    );
    return resultados.whereType<String>().toList(growable: false);
  }

  /// Cuánto se espera a una letra antes de darla por muerta.
  ///
  /// 3 s: el server es local o va por Tailscale, así que una respuesta sana
  /// llega en milisegundos. Lo que tarda más es una unidad de red que no
  /// contesta, y esa hay que descartarla rápido.
  static const Duration kRootProbeTimeout = Duration(seconds: 3);

  /// `GET /api/fs/read/<path>` — los bytes crudos del archivo.
  ///
  /// Es lo que alimenta "Descargar": el server no tiene endpoint de descarga
  /// con otro formato, el binario **es** la descarga.
  Future<Uint8List> downloadBytes({
    required String path,
    String? directory,
  }) => _api.readFileBytes(directory: directory, path: path);

  /// El `directory` del `location` del server (`GET /api/location`).
  ///
  /// Se cachea: no cambia mientras el server corre, y la pantalla de Archivos
  /// lo pregunta en cada descarga para decidir si el archivo está al alcance
  /// de `GET /api/fs/read` (solo sirve dentro del `location`; fuera devuelve
  /// el HTML del SPA con 200, medido 2026-10-08). Un fallo se propaga: sin
  /// saber la base no hay veredicto y se intenta igual.
  String? _locationDirectory;
  Future<String?> locationDirectory() async {
    final cached = _locationDirectory;
    if (cached != null) return cached;
    final map = await _api.location();
    final directory = map['directory'];
    if (directory is! String || directory.isEmpty) return null;
    _locationDirectory = directory;
    return directory;
  }

  /// `GET /api/fs/find` — búsqueda por nombre, en todo el `location`.
  ///
  /// A diferencia de [listDirectory], acá los paths vienen de la raíz: son
  /// rutas completas dentro del proyecto, no nombres sueltos.
  Future<List<FileNode>> findFiles(
    String query, {
    String? type,
    int? limit,
  }) async {
    final page = await _api.findFiles(query: query, type: type, limit: limit);
    return _map(page.data);
  }

  /// Cierra el cliente HTTP propio. Un `http.Client` inyectado es del caller y
  /// no se toca (mismo contrato que [ApiClient.close]).
  void close() => _api.close();

  /// Descarta lo que no es un mapa en vez de tirarle un cast al cliente: una
  /// entrada rara no puede voltear la pantalla entera.
  static List<FileNode> _map(List<dynamic> data) => <FileNode>[
    for (final item in data)
      if (asMap(item) case final Map<String, Object?> json)
        FileNode.fromJson(json),
  ];
}
