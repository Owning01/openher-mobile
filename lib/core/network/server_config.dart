import 'dart:convert';

/// Configuración del server opencode al que se conecta la app.
///
/// Inmutable. El dialecto está **fijado a v2**: el prefijo de path es [apiPrefix]
/// (`/api`) y no hay negociación de versión ni header que la anuncie
/// (`docs/API_CONTRACT.md` §1.5). El probe de versión lo hace [ApiClient] contra
/// `/api/location`, no contra `/api/health` (que da 404 en el build medido).
///
/// ## Secretos
/// [password] **sí** se persiste: [toJson] es el payload que va cifrado a
/// `flutter_secure_storage` (decisión D2: en Android no hay disco del PC, las
/// credenciales las da el usuario). Ese JSON NUNCA se loguea ni se muestra.
/// Por eso [toString] redacta, y [redactAuthToken] limpia el `?auth_token=` de
/// una URL antes de poder imprimirla.
class ServerConfig {
  const ServerConfig({
    this.host = defaultHost,
    this.port = defaultPort,
    this.username = defaultUsername,
    this.password = '',
    this.apiPrefix = defaultApiPrefix,
  });

  static const String defaultHost = '127.0.0.1';
  static const int defaultPort = 4098;

  /// El server compara el usuario **siempre**; su default es `opencode`
  /// (`OPENCODE_SERVER_USERNAME`, `packages/server/src/auth.ts`).
  static const String defaultUsername = 'opencode';

  /// Prefijo del dialecto v2.
  static const String defaultApiPrefix = '/api';

  /// Query param con el que se autentica el stream SSE (no se puede setear
  /// header en un `EventSource`; el server lo chequea **antes** que el header).
  static const String authTokenParam = 'auth_token';

  /// Clave del `deepObject` de location del SDK v2. Se emite **literal** en la
  /// query (ver [api]).
  static const String locationParam = 'location[directory]';

  final String host;
  final int port;
  final String username;
  final String password;
  final String apiPrefix;

  /// El server sin `OPENCODE_SERVER_PASSWORD` no exige auth ⇒ con usuario vacío
  /// no se manda ninguna credencial.
  bool get hasAuth => username.isNotEmpty;

  /// `http://host:port`, sin prefijo de API.
  String get baseUrl => 'http://$host:$port';

  /// `http://host:port/api`.
  String get apiBaseUrl => '$baseUrl$apiPrefix';

  /// `base64(user:pass)`. Vacío ⇒ no mandar auth.
  String get _credentials => base64Encode(utf8.encode('$username:$password'));

  /// `Authorization: Basic base64(user:pass)`, o `null` si no hay usuario.
  String? get basicAuthHeader => hasAuth ? 'Basic $_credentials' : null;

  /// Valor para `?auth_token=` — el carrier que usa el stream SSE.
  String? get authTokenQuery => hasAuth ? _credentials : null;

  /// URI de un endpoint v2.
  ///
  /// - El **path** lo percent-encode `Uri` solo: no pre-codificar los ids.
  /// - Las **claves** de [query] se emiten literales a propósito: `location[directory]`
  ///   es un `deepObject` y el parser de query del server lo reconoce por el nombre
  ///   exacto. `Uri` los re-codifica a `%5B…%5D`, que cualquier parser conforme
  ///   vuelve a decodificar (medido: `Uri.parse(...).queryParameters` devuelve
  ///   `location[directory]`).
  /// - Los **valores** van con [Uri.encodeComponent]: espacio → `%20` (no `+`, que
  ///   `decodeURIComponent` NO vuelve a espacio) y `&`/`=`/`+` escapados.
  /// - Un valor `null` **se omite** del query: se pueden pasar parámetros
  ///   opcionales directo, sin `if`.
  Uri api(String path, {Map<String, String?> query = const {}}) => Uri(
    scheme: 'http',
    host: host,
    port: port,
    path: '$apiPrefix${path.startsWith('/') ? path : '/$path'}',
    query: buildQuery(query),
  );

  /// La misma URL de [fileUrl] pero con el token en el query, para que la
  /// pueda abrir **otro proceso** (el navegador del sistema) sin poder mandarle
  /// un header Basic.
  ///
  /// **Medido 2026-09-28**: `?auth_token=<base64(user:pass)>` autentica en
  /// `/api/fs/read/*` igual que el header (200 con y sin; 401 sin ninguno), y
  /// tambien en `/api/location`, `/api/model`, `/api/agent` y `/api/session`.
  /// El server no emite ninguna cookie (no hay `Set-Cookie`), asi que el query
  /// es la unica via de auth para un cliente que no puede mandar headers.
  ///
  /// ## Por que esto **no** alcanza para un WebView embebido y si para el
  /// navegador del sistema
  ///
  /// Un WebView dentro de la app podria cargar esta URL y tendria CSS y JS de
  /// verdad. No se hace, y el motivo es el subrecurso: una pagina con
  /// `<link rel=stylesheet href="estilo.css">` pide `/api/fs/read/estilo.css`,
  /// que resuelve a la raiz del location y no a la carpeta del archivo (404), y
  /// una hoja de estilo con `@import` o `url()` choca con lo mismo. El navegador
  /// del sistema se abre **con su barra de direcciones y su contexto**, es una
  /// pestana real: el usuario ve de que URL viene y puede cerrarla. Por eso el
  /// HTML se abre ahi y no adentro.
  ///
  /// ## El costo: la password viaja en la URL
  ///
  /// Es el precio de no tener cookies, y es real: la URL puede quedar en el
  /// historial del navegador, y si el usuario la copia y la manda, manda la
  /// password del server. Por eso la app **no** la copia al portapapeles (la
  /// accion "Copiar ruta" copia el path pelado) y por eso el aviso va escrito.
  Uri browserFileUrl(String path, {String? directory}) => api(
    '/fs/read/${path.startsWith('/') ? path.substring(1) : path}',
    query: <String, String?>{
      'location[directory]': directory,
      'auth_token': authTokenQuery,
    },
  );

  /// La URL directa de un archivo del workspace: `GET /api/fs/read/<path>`.
  ///
  /// **Medido 2026-09-28**: este endpoint no devuelve texto, devuelve los
  /// **bytes crudos** con el `Content-Type` correcto. Verificado con un APK de
  /// 56 MB (`application/vnd.android.package-archive`, 56.318.889 bytes) y con
  /// un SVG (`image/svg+xml`, 284 bytes). Esa medicion es la que habilita el
  /// visor de imagenes, video, audio y PDF: sin ella no hay de donde sacar los
  /// bytes de un binario.
  ///
  /// No existe otra via: `/api/fs/raw/*`, `/api/fs/download/*` y `/api/file/*`
  /// dan **404**, y cualquier ruta sin prefijo cae en el catch-all del SPA que
  /// devuelve HTML 200.
  ///
  /// [directory] `null` = la raiz del `location` del server, que es lo mismo
  /// que hace `GET /api/fs/list` cuando no se le pasa.
  Uri fileUrl(String path, {String? directory}) => api(
    '/fs/read/${path.startsWith('/') ? path.substring(1) : path}',
    query: <String, String?>{'location[directory]': directory},
  );

  /// Los headers que necesitan los cargadores de red del visor de archivos
  /// (`Image.network`, `SvgPicture.network`, `video_player`, `PdfViewer.uri`).
  ///
  /// Sin esto el server responde 401: la imagen aparece con un error de
  /// autenticacion en vez del archivo.
  Map<String, String> get binaryHeaders =>
      hasAuth ? <String, String>{'authorization': basicAuthHeader!} : const {};

  /// Serializa [query] a `k=v&k2=v2`, omitiendo los `null` y escapando valores.
  static String buildQuery(Map<String, String?> query) {
    final parts = <String>[];
    query.forEach((key, value) {
      if (value == null) return;
      parts.add('$key=${Uri.encodeComponent(value)}');
    });
    return parts.join('&');
  }

  /// Devuelve una copia de [url] con `?auth_token=` reemplazado por `REDACTED`.
  ///
  /// **Obligatorio antes de loguear una URL de stream**: el token es la
  /// contraseña en base64 y los logs de Android son legibles por cualquiera con
  /// `adb logcat` (`API_CONTRACT.md` §1.2).
  static Uri redactAuthToken(Uri url) {
    if (!url.queryParameters.containsKey(authTokenParam)) return url;
    return url.replace(
      queryParameters: <String, String>{
        ...url.queryParameters,
        authTokenParam: 'REDACTED',
      },
    );
  }

  /// Lee un servidor guardado. Tolera `port` como `num` o `String`.
  factory ServerConfig.fromJson(Map<String, dynamic> json) => ServerConfig(
    host: _asString(json['host']) ?? defaultHost,
    port: _asInt(json['port']) ?? defaultPort,
    username: _asString(json['username']) ?? defaultUsername,
    password: _asString(json['password']) ?? '',
    apiPrefix: _asString(json['apiPrefix']) ?? defaultApiPrefix,
  );

  /// ⚠️ Incluye [password]: es el payload cifrado de `flutter_secure_storage`.
  /// No loguear ni mostrar el resultado.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'host': host,
    'port': port,
    'username': username,
    'password': password,
    'apiPrefix': apiPrefix,
  };

  ServerConfig copyWith({
    String? host,
    int? port,
    String? username,
    String? password,
    String? apiPrefix,
  }) => ServerConfig(
    host: host ?? this.host,
    port: port ?? this.port,
    username: username ?? this.username,
    password: password ?? this.password,
    apiPrefix: apiPrefix ?? this.apiPrefix,
  );

  static String? _asString(Object? value) => value is String ? value : null;

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// Redactado: **nunca** incluye la password.
  @override
  String toString() =>
      'ServerConfig($apiBaseUrl, user: '
      '${hasAuth ? username : '(none)'}, password: ${password.isEmpty ? '(none)' : '***'})';
}

/// ¿Esta respuesta es el fallback HTML del SPA?
///
/// **La trampa #1 del server**: todo path desconocido cae al catch-all y
/// devuelve el index del SPA con `content-type: text/html` y status **200**
/// (`httpapi/server.ts:194-203`). Un path inventado NO da 404: da HTML 200. Un
/// parser ingenuo revienta con `FormatException` en vez de decir "esto no es la
/// API".
///
/// Se mira el `content-type` y, por si el server lo manda mal, los primeros
/// caracteres del cuerpo.
bool looksLikeHtml(String? contentType, String body) {
  final type = contentType?.toLowerCase() ?? '';
  if (type.contains('text/html') || type.contains('application/xhtml')) {
    return true;
  }
  final head = body.trimLeft().toLowerCase();
  return head.startsWith('<!doctype html') || head.startsWith('<html');
}

/// ¿Este cuerpo es el shell del SPA de opencode, no un archivo genuino?
///
/// Se usa donde el `content-type` no decide: un `.html` genuino viene como
/// `text/html` igual que el catch-all. La marca es el CSS del shell
/// (`v2-background-bg-deep`, medido 2026-10-08 en `/` y en `/algo` del server
/// real); un archivo de usuario con ese string exacto es indistinguible, y se
/// acepta el riesgo porque la alternativa (rechazar todo HTML) rompía
/// descargas reales. Solo se miran los primeros 2 KB: la marca vive en el
/// `<head>`.
bool esShellDelSpa(List<int> bytes) {
  final head = utf8.decode(
    bytes.length > 2048 ? bytes.sublist(0, 2048) : bytes,
    allowMalformed: true,
  );
  return head.contains('v2-background-bg-deep');
}

/// Mensaje canónico del fallback HTML, con la hint de qué hacer.
const String htmlFallbackMessage =
    'el server respondió HTML: esa ruta no existe en opencode v2 (o no estás '
    'hablando con un server opencode)';
