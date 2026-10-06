/// El detector de rutas de imagen y la tira de miniaturas.
///
/// El agente **no manda markdown**: medido 2026-10-06 contra el server real (60
/// sesiones), 0 imágenes `![]()` y 6 rutas **desnudas** en el texto. Por eso el
/// detector trabaja sobre el texto pelado y no con un builder de `img` de
/// markdown, que no vería ninguna.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/features/chat/message_bubble.dart';

void main() {
  group('imagePathsIn', () {
    test('encuentra una ruta desnuda, que es lo que manda el agente', () {
      // Estos nombres salieron de la sesión `ses_f68b1dbeeffeYe`, medidos.
      expect(imagePathsIn('Mira: bautismoOlivia2021.jpeg'), [
        'bautismoOlivia2021.jpeg',
      ]);
      expect(imagePathsIn('rociiorz-20220305-0001.webp'), [
        'rociiorz-20220305-0001.webp',
      ]);
    });

    test('una ruta absoluta de Windows entera', () {
      expect(imagePathsIn(r'Listo: G:\Proyectos\fotos\shot.png'), [
        r'G:\Proyectos\fotos\shot.png',
      ]);
    });

    test('varias rutas, en orden y sin repetir', () {
      expect(imagePathsIn('a.png y b.jpg y otra vez a.png'), [
        'a.png',
        'b.jpg',
      ]);
    });

    test('una extension suelta NO es una imagen', () {
      // Medido: en una lista apareció un `.webp` pelado. Sin esta guarda se
      // inventaba una miniatura de un archivo que no está en el texto.
      expect(imagePathsIn('los formatos: .webp, .jpg'), isEmpty);
      expect(imagePathsIn('extension .png'), isEmpty);
    });

    test('un separador pegado a la extension tampoco', () {
      // **Este es el caso que la guarda del nombre protege de verdad.** Con
      // espacio adelante, la propia regex ya no matchea (necesita un carácter
      // antes del punto); con una barra, sí matchea y el nombre queda vacío.
      expect(imagePathsIn(r'G:\fotos\.png'), isEmpty);
      expect(imagePathsIn('carpeta/.jpg'), isEmpty);
    });

    test('una URI con esquema no cuenta', () {
      // No la sirve el server de la sesión: una miniatura rota es peor que
      // ninguna.
      expect(imagePathsIn('https://ejemplo.test/foto.png'), isEmpty);
    });

    test('se corta en los delimitadores de la prosa', () {
      expect(imagePathsIn('`foto.png`'), ['foto.png']);
      expect(imagePathsIn('(foto.png)'), ['foto.png']);
      expect(imagePathsIn('![alt](foto.png)'), ['foto.png']);
      expect(imagePathsIn('- foto.png'), ['foto.png']);
    });

    test('una extension que no es imagen no cuenta', () {
      expect(imagePathsIn('main.dart y notas.md'), isEmpty);
      expect(imagePathsIn('informe.pdf'), isEmpty);
    });

    test('texto sin rutas', () {
      expect(imagePathsIn(''), isEmpty);
      expect(imagePathsIn('no hay nada aca'), isEmpty);
    });
  });

  group('la tira de miniaturas', () {
    /// Un `Uri` falso: los tests no salen a la red.
    Uri urlDe(String path) =>
        Uri.parse('http://127.0.0.1:4098/api/fs/read/$path');

    Future<void> pumpTira(WidgetTester tester, List<String> paths) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: MessageImages(paths: paths, urlOf: urlDe),
          ),
        ),
      );
    }

    testWidgets('sin rutas no ocupa ni un pixel', (tester) async {
      await pumpTira(tester, const []);
      expect(find.byKey(MessageImages.thumbKey(0)), findsNothing);
    });

    testWidgets('una miniatura por ruta, siempre minimizada', (tester) async {
      await pumpTira(tester, const ['a.png', 'b.jpg']);

      expect(find.byKey(MessageImages.thumbKey(0)), findsOneWidget);
      expect(find.byKey(MessageImages.thumbKey(1)), findsOneWidget);
      expect(find.byKey(MessageImages.thumbKey(2)), findsNothing);

      // **Siempre minimizada**: 72 px de alto, no la altura de la pantalla.
      // Es lo que hace que la tira no ocupe el chat.
      for (final i in [0, 1]) {
        expect(
          tester.getSize(find.byKey(MessageImages.thumbKey(i))).height,
          MessageImages.thumbHeight,
        );
      }
    });

    testWidgets(
      'tocar una miniatura la expande, con la altura de la pantalla',
      (tester) async {
        await pumpTira(tester, const ['a.png']);

        expect(find.byKey(MessageImages.expandedKey), findsNothing);
        await tester.tap(find.byKey(MessageImages.thumbKey(0)));
        await tester.pumpAndSettle();

        expect(find.byKey(MessageImages.expandedKey), findsOneWidget);
        // El nombre se ve en la expansión: es lo único que dice **qué** archivo
        // se está mirando cuando la tira tiene cuatro. `findsWidgets` y no uno:
        // sin red, el `errorBuilder` de la miniatura también escribe el nombre.
        expect(find.text('a.png'), findsWidgets);
      },
    );

    testWidgets('la expansion usa un porcentaje del alto, no un fijo', (
      tester,
    ) async {
      // Alto de pantalla chico.
      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpTira(tester, const ['a.png']);
      await tester.tap(find.byKey(MessageImages.thumbKey(0)));
      await tester.pumpAndSettle();

      final chico = tester
          .widgetList<Image>(find.byType(Image))
          .map((i) => i.height)
          .whereType<double>()
          .last;

      // La misma imagen en una pantalla mas alta tiene que pedir mas alto: un
      // valor fijo en pixeles se veria gigante en un telefono y diminuto en una
      // tablet.
      tester.view.physicalSize = const Size(400, 1200);
      await tester.pumpAndSettle();
      final grande = tester
          .widgetList<Image>(find.byType(Image))
          .map((i) => i.height)
          .whereType<double>()
          .last;

      expect(chico, isNotNull);
      expect(
        grande,
        greaterThan(chico),
        reason: 'la altura tiene que seguir a la pantalla',
      );
    });
  });
}
