/// Rutas de archivo del navegador, como funciones puras.
///
/// ## Por qué existe este archivo
///
/// El navegador trabajaba con rutas **relativas a la raíz del `location` del
/// server** (`''` = raíz), y por eso no se podía salir de esa carpeta: no había
/// forma de nombrar un disco. Medido 2026-10-06 contra el server real:
///
/// - `GET /api/fs/list?path=C:/` -> **200**, lista el disco `C:`
/// - `GET /api/fs/list?path=G:/` -> **200**, lista el disco `G:`
/// - `GET /api/fs/list?path=G:` (sin la barra) -> **500**
/// - `GET /api/fs/roots`, `/fs/drives`, `/api/drives` -> **404**: el server
///   **no tiene** un endpoint que enumere discos.
///
/// De ahí las dos reglas que este archivo hace cumplir y que, si se escriben a
/// mano en cada lugar, se olvidan en uno: **una ruta absoluta siempre lleva la
/// barra final en el disco** (`G:/`, nunca `G:`) y **el separador es `/`**,
/// aunque el server conteste con `\`.
library;

/// Normaliza una ruta para hablar con el server.
///
/// Cambia `\` por `/`, colapsa las barras repetidas y garantiza la barra final
/// cuando la ruta es la **raíz de un disco** (`G:` -> `G:/`).
///
/// Lo último no es cosmético: `path=G:` devuelve **500** y `path=G:/` devuelve
/// **200** (medido). Es el error más fácil de cometer y el más difícil de
/// entender cuando aparece como un 500 pelado.
String normalizarRuta(String ruta) {
  var r = ruta.replaceAll('\\', '/');
  // Colapsa `//` sin tocar el `//` inicial de una UNC (`//server/share`).
  final unc = r.startsWith('//');
  final cuerpo = unc ? r.substring(2) : r;
  r = (unc ? '//' : '') + cuerpo.replaceAll(RegExp('/+'), '/');
  if (r.isEmpty) return r;
  // Una letra suelta (`C`) o `C:` son la raíz de un disco. El dos puntos
  // es obligatorio y se lo agregamos nosotros: medir esto como "path de
  // largo 1" y devolver 'C/' (lo que hacía antes) rompía todo lo de arriba:
  // `discoDe('C')` daba 'C/' y el probe pedía `?path=C%2F`, que el server
  // no reconoce como disco.
  if (RegExp(r'^[A-Za-z](:)?$').hasMatch(r)) {
    return '${r[0].toUpperCase()}:/';
  }
  return r;
}

/// El nombre del último segmento: `G:/a/b/` -> `b`.
///
/// La raíz de un disco devuelve `G:` (sin la barra), que es lo que se muestra
/// en el breadcrumb y en el selector de discos.
String nombreDeRuta(String ruta) {
  final r = normalizarRuta(ruta);
  final sinBarra = r.endsWith('/') && r.length > 1
      ? r.substring(0, r.length - 1)
      : r;
  if (sinBarra.isEmpty) return '/';
  final corte = sinBarra.lastIndexOf('/');
  return corte < 0 ? sinBarra : sinBarra.substring(corte + 1);
}

/// La carpeta que contiene a [ruta], o `null` si ya es una raíz.
///
/// `null` y no `''` porque son cosas distintas: `''` es "no sé a dónde ir" y
/// `null` es "no hay a dónde subir". Confundirlas hacía que el botón de subir
/// navegara a la raíz del `location` en vez de deshabilitarse.
String? carpetaPadre(String ruta) {
  final r = normalizarRuta(ruta);
  if (esRaiz(r)) return null;
  final sinBarra = r.endsWith('/') ? r.substring(0, r.length - 1) : r;
  final corte = sinBarra.lastIndexOf('/');
  if (corte <= 0) return null;
  final padre = sinBarra.substring(0, corte);
  // Un padre de una letra (`G`) es la raíz del disco: con barra.
  return normalizarRuta(padre);
}

/// ¿Es una raíz? Un disco (`G:/`), una UNC (`//server/share/`) o `/`.
bool esRaiz(String ruta) {
  final r = normalizarRuta(ruta);
  if (r == '/' || r.isEmpty) return true;
  if (RegExp(r'^[A-Za-z]:/$').hasMatch(r)) return true;
  // UNC: `//server/share/` es raíz, `//server/share/sub/` no.
  if (r.startsWith('//')) {
    final partes = r.substring(2).split('/').where((p) => p.isNotEmpty);
    return partes.length <= 2;
  }
  return false;
}

/// Une [carpeta] con un nombre que devolvió el server.
///
/// Las entradas de `GET /api/fs/list` vienen **relativas** y con `\` al final
/// (`{"path": ".agents\\"}`), así que el cliente compone la ruta absoluta.
///
/// `..` se resuelve de verdad en vez de concatenarse: `G:/a/` + `..` tiene que
/// dar `G:/`, y concatenar daría `G:/a/..` — que el server resuelve, pero que
/// deja la ruta ilegible en el breadcrumb y rompe la comparación con la raíz.
String unirRuta(String carpeta, String nombre) {
  final n = nombre.replaceAll('\\', '/');
  if (n == '..') return carpetaPadre(carpeta) ?? normalizarRuta(carpeta);
  if (n == '.' || n.isEmpty) return normalizarRuta(carpeta);
  final base = normalizarRuta(carpeta);
  final limpio = n.replaceAll(RegExp(r'^/+|/+$'), '');
  if (limpio.isEmpty) return base;
  return normalizarRuta(base.endsWith('/') ? '$base$limpio' : '$base/$limpio');
}

/// Las letras de disco que se prueban al buscar discos.
///
/// `A:` y `B:` se incluyen a propósito: son los disquetes históricos y en
/// Windows moderno casi nunca existen, pero una máquina con una unidad mapeada
/// ahí es justo la que se quejaría de que no aparece.
const List<String> kLetrasDeDisco = [
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
  'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
];

/// La raíz de disco para una letra: `G` -> `G:/`.
String discoDe(String letra) => normalizarRuta(letra.toUpperCase());

/// ¿`ruta` está dentro de `base` (o es `base`)?
///
/// Comparación por segmento, no por prefijo de string: `C:/fotos2` no está
/// dentro de `C:/fotos`. Insensible a mayúsculas (Windows) y a `\` vs `/`.
/// Es lo que decide si `GET /api/fs/read` puede servir un archivo: el server
/// solo resuelve dentro de su `location` (medido 2026-10-08: fuera devuelve
/// el HTML del SPA con 200).
bool dentroDe(String base, String ruta) {
  final b = normalizarRuta(base).toLowerCase();
  final r = normalizarRuta(ruta).toLowerCase();
  if (b.isEmpty || r.isEmpty) return false;
  if (r == b) return true;
  final prefijo = b.endsWith('/') ? b : '$b/';
  return r.startsWith(prefijo);
}
