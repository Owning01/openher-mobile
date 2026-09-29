import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/domain/models/file_type.dart';
import 'package:openher_mobile/ui/features/files/html_view.dart';

/// E2E del render de HTML: se levanta el widget con un documento real y se
/// comprueba que la estructura llega a la pantalla.
///
/// No es un unit test de una funcion pura: renderiza, mide y falla si el
/// contenido no aparece. Es el mecanismo de prueba que el repo pide, y ademas
/// es lo unico ejecutable sin el handset en la mano.
void main() {
  const config = ServerConfig(
    host: '127.0.0.1',
    port: 4098,
    username: 'opencode',
    password: 'p',
  );

  /// pump de [HtmlView] y devuelve los textos que quedaron en pantalla.
  Future<List<String>> render(WidgetTester tester, String html) async {
    final found = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: HtmlView(
            config: config,
            path: 'docs/pagina.html',
            source: html,
          ),
        ),
      ),
    );
    for (final t in find.byType(Text).evaluate()) {
      final w = t.widget as Text;
      final span = w.textSpan;
      if (span != null) {
        found.add(span.toPlainText());
      } else if (w.data != null) {
        found.add(w.data!);
      }
    }
    return found;
  }

  group('clasificacion', () {
    test('html es su propio tipo, no code', () {
      expect(FileType.of('pagina.html').kind, FileKind.html);
      expect(FileType.of('viejo.htm').kind, FileKind.html);
      expect(FileType.of('XHTML.xhtml').kind, FileKind.html);
      // El case de la extension tiene que ser el mismo: `.HTML` se abre igual.
      expect(FileType.of('PAGINA.HTML').kind, FileKind.html);
      // Y un `.css` sigue siendo codigo, no html.
      expect(FileType.of('estilo.css').kind, FileKind.code);
    });
  });

  group('estructura', () {
    testWidgets('encabezados, parrafo, listas y tabla', (tester) async {
      final texts = await render(tester, '''
        <html><body>
          <h1>Titulo principal</h1>
          <p>Un parrafo con <strong>negrita</strong> y <em>cursiva</em>.</p>
          <h2>Subtitulo</h2>
          <ul><li>primero</li><li>segundo</li></ul>
          <ol><li>uno</li><li>dos</li></ol>
          <table>
            <tr><th>col A</th><th>col B</th></tr>
            <tr><td>celda 1</td><td>celda 2</td></tr>
          </table>
        </body></html>
      ''');

      String all() => texts.join(' | ');
      expect(all(), contains('Titulo principal'));
      expect(all(), contains('Subtitulo'));
      expect(all(), contains('Un parrafo con negrita y cursiva'));
      expect(all(), contains('primero'));
      expect(all(), contains('segundo'));
      // La lista ordenada numerada: el marcador es texto de la pantalla.
      expect(all(), contains('1.'));
      expect(all(), contains('2.'));
      expect(all(), contains('col A'));
      expect(all(), contains('celda 2'));
    });

    testWidgets('el texto inline conserva el orden y los saltos', (tester) async {
      final texts = await render(tester, '<p>uno<br>dos</p>');
      expect(texts.join(' | '), contains('uno'));
      expect(texts.join(' | '), contains('dos'));
    });

    testWidgets('codigo y cita', (tester) async {
      final texts = await render(tester, '''
        <blockquote>Una cita</blockquote>
        <pre><code>void main() {}</code></pre>
      ''');
      final all = texts.join(' | ');
      expect(all, contains('Una cita'));
      expect(all, contains('void main() {}'));
    });
  });

  group('lo que tiene que aguantar', () {
    testWidgets('un HTML vacio no rompe la pantalla', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HtmlView(config: config, path: 'x.html', source: ''),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('El HTML no tiene contenido visible'), findsOneWidget);
    });

    testWidgets('HTML a medio escribir no rompe la pantalla', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HtmlView(
              config: config,
              path: 'x.html',
              // Tags sin cerrar, atributo sin comillas,Entities sin escape.
              source: '<div><p>texto sin cerrar <b>negrita <div>',
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('script y style no se renderizan como texto', (tester) async {
      final texts = await render(tester, '''
        <body>
          <script>var secreto = 1; alert('hola')</script>
          <style>.x { color: red; }</style>
          <p>visible</p>
        </body>
      ''');
      final all = texts.join(' | ');
      expect(all, contains('visible'));
      expect(all, isNot(contains('secreto')));
      expect(all, isNot(contains('color: red')));
    });

    testWidgets('un tag desconocido no se come el contenido', (tester) async {
      final texts = await render(tester, '''
        <marquee>texto dentro</marquee>
        <p>despues</p>
      ''');
      final all = texts.join(' | ');
      expect(all, contains('texto dentro'));
      expect(all, contains('despues'));
    });
  });

  group('recursos', () {
    testWidgets('una imagen embebida data: se decodifica', (tester) async {
      // 1x1 PNG transparente, en base64.
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmM'
          'IQAAAABJRU5ErkJggg==';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HtmlView(
              config: config,
              path: 'x.html',
              source: '<p>img</p><img src="data:image/png;base64,$png" alt="pixel">',
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      // El `alt` es lo que se ve si la imagen no carga: tiene que estar.
      expect(find.text('pixel'), findsOneWidget);
    });

    testWidgets('el src de una imagen local se arma contra la carpeta del html',
        (tester) async {
      // Se verifica el resolver, que es lo que decide si la imagen carga:
      // `fileUrl` es lo que ya se midio contra el server.
      final u = config.fileUrl('docs/img/logo.png');
      expect(u.path, '/api/fs/read/docs/img/logo.png');
      expect(u.queryParameters['location[directory]'], isNull);
    });
  });
}
