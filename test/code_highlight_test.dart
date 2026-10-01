import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/ui/core/tokens.dart';
import 'package:openher_mobile/ui/features/chat/code_highlight.dart';

/// El bloque de codigo del chat tiene que salir **coloreado**.
///
/// El sintoma era "no me esta dibujando con colores en el chat". La causa: los
/// tokens `--code-*` de `tokens.dart` estaban portados desde `tokens.css` desde
/// el primer dia y **nada los leia**. El bloque se pintaba entero del color del
/// texto, y los tokens seguian ahi, sin usarse.
///
/// Por eso el test no verifica que la funcion exista: verifica que el span que
/// devuelve **realmente lleve varios colores distintos**, que es lo que se ve en
/// la pantalla. Un test que solo comprobara `colorFor('keyword') != null`
/// pasaria con un resaltador que no pinta nada.
void main() {
  const base = TextStyle(
    fontFamily: 'monospace',
    fontSize: 11.5,
    color: Color(0xFF18181B),
  );

  group('la paleta de tokens', () {
    test('cada clase de token tiene color, en los dos brillos', () {
      const clases = [
        'keyword',
        'string',
        'comment',
        'number',
        'function',
        'built_in',
        'attr',
      ];
      for (final c in clases) {
        expect(
          CodeHighlighter.colorFor(c, false),
          isNotNull,
          reason: '$c sin color en claro',
        );
        expect(
          CodeHighlighter.colorFor(c, true),
          isNotNull,
          reason: '$c sin color en oscuro',
        );
      }
    });

    test('el oscuro y el claro son colores DISTINTOS', () {
      // Si fueran el mismo, el tema no estaria haciendo nada y el resaltado se
      // veria igual de noche que de dia.
      for (final c in ['keyword', 'string', 'number', 'built_in', 'attr']) {
        expect(
          CodeHighlighter.colorFor(c, false),
          isNot(CodeHighlighter.colorFor(c, true)),
          reason: '$c es igual en claro y oscuro',
        );
      }
    });

    test('los colores vienen de los tokens, no de hex sueltos', () {
      // La portabilidad es el punto: si manana cambia `--code-keyword`, el
      // resaltado lo sigue. Este test ata la tabla a los tokens a proposito.
      expect(
        CodeHighlighter.colorFor('keyword', false),
        AppColors.lightCodeKeyword,
      );
      expect(
        CodeHighlighter.colorFor('keyword', true),
        AppColors.darkCodeKeyword,
      );
      expect(
        CodeHighlighter.colorFor('string', false),
        AppColors.lightCodeString,
      );
      expect(CodeHighlighter.colorFor('number', true), AppColors.darkCodeNumber);
      expect(CodeHighlighter.colorFor('attr', false), AppColors.lightCodeAttr);
    });

    test('el comentario es el mismo gris en los dos brillos', () {
      // A proposito en el diseno: el gris del comentario funciona en los dos y
      // lo distingue de un token de color, que es lo que se busca.
      expect(
        CodeHighlighter.colorFor('comment', false),
        AppColors.darkCodeComment,
      );
      expect(
        CodeHighlighter.colorFor('comment', true),
        AppColors.darkCodeComment,
      );
    });

    test('una clase desconocida no inventa un color', () {
      // `null` significa "dejalo como el texto base". Poner cualquier color
      // seria mentir sobre lo que el resaltador reconoce.
      expect(CodeHighlighter.colorFor('no-existe', false), isNull);
      expect(CodeHighlighter.colorFor(null, false), isNull);
    });
  });

  group('el span que se pinta', () {
    setUp(CodeHighlighter.clearCache);

    test('un bloque de Dart sale con MAS DE UN color', () {
      final span = CodeHighlighter.spanFor(
        'void main() {\n  final x = "hola";\n}\n',
        'dart',
        base,
      );
      final colores = _colores(span).toSet();
      expect(
        colores.length,
        greaterThan(1),
        reason: 'un solo color = el bloque se ve plano, que es el bug',
      );
    });

    test('el texto del bloque no se pierde', () {
      const codigo = 'void main() {\n  final x = 1;\n}\n';
      final span = CodeHighlighter.spanFor(codigo, 'dart', base);
      expect(_texto(span), codigo);
    });

    test('con el lenguaje del fence el resaltado es correcto', () {
      // La palabra clave `void` y el numero `1` tienen que quedar con colores
      // distintos, y ambos distintos del texto base.
      final span = CodeHighlighter.spanFor(
        'void f() { return 42; }',
        'dart',
        base,
      );
      final colores = _colores(span).toSet();
      expect(colores, contains(AppColors.lightCodeKeyword));
      expect(colores, contains(AppColors.lightCodeNumber));
    });

    test('en oscuro usa la paleta oscura', () {
      final claro = CodeHighlighter.colorFor('keyword', false);
      final oscuro = CodeHighlighter.colorFor('keyword', true);
      expect(claro, isNot(oscuro));
      final span = CodeHighlighter.spanFor(
        'void f() {}',
        'dart',
        base,
        dark: true,
      );
      expect(_colores(span), contains(oscuro));
    });

    test('un lenguaje desconocido no rompe: sale el texto', () {
      // Autodetectar un idioma inventado es una loteria; lo que NO puede pasar
      // es que la burbuja deje de pintarse.
      final span = CodeHighlighter.spanFor('esto no es codigo', 'no-existe', base);
      expect(_texto(span), 'esto no es codigo');
    });

    test('sin lenguaje autodetecta y no rompe', () {
      final span = CodeHighlighter.spanFor('print(1)', null, base);
      expect(_texto(span), 'print(1)');
    });

    test('un bloque enorme no se intenta parsear', () {
      // Un `highlight.parse` de 60 KB es medio segundo de jank en un telefono.
      // El texto tiene que salir igual, plano.
      final enorme = 'const a = 1;\n' * 5000;
      final span = CodeHighlighter.spanFor(enorme, 'dart', base);
      expect(_texto(span), enorme);
    });
  });

  group('el cache', () {
    setUp(CodeHighlighter.clearCache);

    test('el mismo bloque se cachea', () {
      CodeHighlighter.spanFor('void a() {}', 'dart', base);
      expect(CodeHighlighter.cacheSize, 1);
      CodeHighlighter.spanFor('void a() {}', 'dart', base);
      expect(CodeHighlighter.cacheSize, 1, reason: 'no debe crecer');
    });

    test('otro brillo es otra entrada', () {
      // El `TextSpan` lleva el color embebido: servir el de claro en oscuro
      // dejaria el codigo con los colores del tema anterior.
      CodeHighlighter.spanFor('void a() {}', 'dart', base, dark: false);
      CodeHighlighter.spanFor('void a() {}', 'dart', base, dark: true);
      expect(CodeHighlighter.cacheSize, 2);
    });

    test('otro estilo base es otra entrada', () {
      CodeHighlighter.spanFor('void a() {}', 'dart', base);
      CodeHighlighter.spanFor(
        'void a() {}',
        'dart',
        const TextStyle(fontSize: 14),
      );
      expect(CodeHighlighter.cacheSize, 2);
    });

    test('el mismo span se devuelve (es inmutable, se puede compartir)', () {
      final a = CodeHighlighter.spanFor('void a() {}', 'dart', base);
      final b = CodeHighlighter.spanFor('void a() {}', 'dart', base);
      expect(identical(a, b), isTrue);
    });
  });
}

/// Todos los colores que aparecen en el arbol de spans.
Iterable<Color?> _colores(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span.style?.color;
    for (final child in span.children ?? const <InlineSpan>[]) {
      yield* _colores(child);
    }
  }
}

/// El texto del arbol de spans, para verificar que no se perdio nada.
String _texto(InlineSpan span) {
  if (span is! TextSpan) return '';
  final sb = StringBuffer(span.text ?? '');
  for (final child in span.children ?? const <InlineSpan>[]) {
    sb.write(_texto(child));
  }
  return sb.toString();
}
