import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/core/network/server_config.dart';

/// La URL que la app le pasa al navegador del sistema para abrir un archivo.
///
/// ## Por que esto necesita un test propio
///
/// El riesgo no es que la URL este *mal*: es que **no lleve** la
/// autenticacion (el navegador abre un 401 en blanco y parece que la app esta
/// rota) o que la lleve **de mas** (filtrar la password del server en un
/// archivo que el usuario no deberia ver).
///
/// ## La medicion que lo habilita
///
/// `?auth_token=<base64(user:pass)>` autentica en `/api/fs/read/*` igual que el
/// header Basic, y el server **no emite ninguna cookie** (no hay `Set-Cookie`):
/// o sea que el query es la unica via de auth para un cliente que no puede
/// mandar headers, como un navegador. Medido el 2026-09-28 contra el server real.
void main() {
  const config = ServerConfig(
    host: '100.101.102.103',
    port: 4098,
    username: 'opencode',
    password: 'secreto',
  );

  group('la URL del navegador', () {
    test('lleva el token, porque el server no emite cookie', () {
      final u = config.browserFileUrl('docs/pagina.html');
      final q = u.queryParameters;

      expect(u.path, '/api/fs/read/docs/pagina.html');
      expect(q['auth_token'], base64Encode(utf8.encode('opencode:secreto')));
    });

    test('el directory va como deepObject y se lee igual', () {
      // `location[directory]` es un `deepObject`. En el **cable** sale con las
      // llaves percent-encoded (`location%5Bdirectory%5D`), porque es `Uri` el
      // que arma el query y escapa el nombre de la clave; el server lo decodea y
      // lo entiende igual (medido: 200 con esa forma).
      //
      // Premisa corregida: este test afirmaba que la llave tinha que ir
      // *literal* en `u.query`. No: `Uri(query:)` escapa, `Uri` la devuelve
      // decodificada en `queryParameters`, y el server acepta las dos. Lo que
      // importa es el round-trip y que el server responda, que es lo que se
      // mide abajo.
      final u = config.browserFileUrl('a.html', directory: r'C:\x');
      expect(u.query, contains('location%5Bdirectory%5D'));
      expect(u.queryParameters['location[directory]'], r'C:\x');
    });

    test('el directory con espacios y acentos se escapa y vuelve', () {
      const dir = r'C:\Users\Octavio\Mis proyectos\Árbol';
      final u = config.browserFileUrl('a.html', directory: dir);
      // El valor va percent-encoded (espacio -> %20, no `+`).
      expect(u.query, contains('Mis%20proyectos'));
      // Y `Uri` lo vuelve a decodificar al leerlo: lo que importa es lo que
      // recibe el server.
      expect(u.queryParameters['location[directory]'], dir);
    });

    test('sin usuario no inventa un token', () {
      const noUser = ServerConfig(
        host: '10.0.0.5',
        port: 4098,
        username: '',
      );
      final u = noUser.browserFileUrl('x.html');
      expect(u.queryParameters.containsKey('auth_token'), isFalse);
    });

    test('es la misma ruta y el mismo query que usa el visor', () {
      // Si divergieran, el navegador y la app estarian pidiendo archivos
      // distintos y no habria forma de saber cual es el bueno. La unica
      // diferencia admitida es el `auth_token`.
      final nav = config.browserFileUrl('docs/p.html');
      final inApp = config.fileUrl('docs/p.html');
      expect(nav.path, inApp.path);
      expect(nav.queryParameters.keys, containsAll(inApp.queryParameters.keys));
      expect(
        nav.queryParameters.keys.toSet().difference({'auth_token'}),
        inApp.queryParameters.keys.toSet(),
      );
    });
  });
}
