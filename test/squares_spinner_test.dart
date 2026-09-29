import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/ui/features/chat/squares_spinner.dart';

/// El spinner de 8 cuadrados: que sean 8, que sea rectangular, y que se mueva.
///
/// Y además deja las **imágenes** en `test/goldens/`, que son el artefacto
/// verificable de cómo se ve: la grilla no se décriten en un comentario, se
/// mira. Se regeneran con `flutter test test/squares_spinner_test.dart
/// --update-goldens`.
///
/// Las capturas son sólo de la grilla, sin texto a propósito: en `flutter test`
/// la fuente por defecto es Ahem (cada glifo es un rectángulo negro), así que
/// un golden con rótulo saldría como un bloque y no serviría para ver nada.
void main() {
  Future<void> pumpSpinner(
    WidgetTester tester, {
    required Duration phase,
    Brightness brightness = Brightness.light,
  }) async {
    // DPR 1 y una pantalla chica: el golden tiene que ser la grilla y nada
    // más. Con el DPR por defecto (3) los 8px de cada cuadrado se rasterizan a
    // 24 y el PNG pesa por nada.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(240, 120);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: Center(
            // `RepaintBoundary` ceñido a la grilla: sin él el capturador de
            // goldens sube hasta el borde de la pantalla y los 800x600 del
            // test default entran en el archivo (medido: 800x600 con una
            // grilla de 41x19).
            child: RepaintBoundary(child: SquaresSpinner()),
          ),
        ),
      ),
    );
    await tester.pump(phase);
  }

  testWidgets('son 8 cuadrados en una grilla de 4x2', (tester) async {
    await pumpSpinner(tester, phase: Duration.zero);

    final squares = find.descendant(
      of: find.byType(SquaresSpinner),
      matching: find.byType(DecoratedBox),
    );
    expect(squares, findsNWidgets(8), reason: 'la grilla tiene que ser de 8');

    // Geometría exacta, no "más ancho que alto": con un `Row` de `Row`s las
    // dos filas salían una al lado de la otra y el conjunto daba 8 en línea,
    // que también es más ancho que alto. Se mide contra `size` y `gap`.
    final lado = SquaresSpinner().size;
    final gap = SquaresSpinner().gap;
    final size = tester.getSize(find.byType(SquaresSpinner));
    expect(
      size.width,
      closeTo(4 * lado + 3 * gap, 0.01),
      reason: 'cuatro cuadrados por fila, con tres huecos',
    );
    expect(
      size.height,
      closeTo(2 * lado + gap, 0.01),
      reason: 'dos filas, con un hueco: 4x2 y no 8 en línea',
    );
  });

  /// Luminancia perceptual de cada cuadrado de la grilla, en 0..255.
  ///
  /// Se mide **luminancia y no alfa**: el widget mezcla dos colores sólidos
  /// (`Color.lerp` entre el tinte de reposo y el acento), así que los ocho
  /// alfa dan 1.0 siempre. Un guard que mirara el alfa era vacuo.
  List<double> luminancias(WidgetTester tester) => [
    for (final e in tester.widgetList<DecoratedBox>(
      find.descendant(
        of: find.byType(SquaresSpinner),
        matching: find.byType(DecoratedBox),
      ),
    ))
      () {
            final c = (e.decoration as BoxDecoration).color!;
            return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
          }() *
          255,
  ];

  /// Cuánto se distingue la cabeza del resto de la grilla. Medido: 92 en tema
  /// claro y 121 en oscuro. La versión rota, con la onda al revés, daba 25.
  const contrasteMinimo = 60.0;

  testWidgets('la luz se mueve: los cuadrados no están todos iguales', (
    tester,
  ) async {
    await pumpSpinner(tester, phase: const Duration(milliseconds: 100));
    final primera = luminancias(tester);
    expect(primera, hasLength(8));

    for (final l in primera) {
      expect(l, inInclusiveRange(0.0, 255.0));
    }
    expect(
      (primera.reduce((a, b) => a > b ? a : b) -
              (primera.reduce((a, b) => a < b ? a : b)))
          .abs(),
      greaterThanOrEqualTo(contrasteMinimo),
      reason:
          'con la grilla entera encendida o apagada no hay spinner: '
          'las luminancias $primera',
    );

    await tester.pump(const Duration(milliseconds: 400));
    final segunda = luminancias(tester);

    int cabeza(List<double> v) => v.indexOf(v.reduce((a, b) => a > b ? a : b));
    expect(
      cabeza(segunda),
      isNot(cabeza(primera)),
      reason:
          'la cabeza tiene que cambiar de cuadrado entre cuadros, '
          'sino es un color fijo y no una animación',
    );
  });

  testWidgets('siempre hay un cuadrado al frente, en cualquier fase', (
    tester,
  ) async {
    // El defecto medido: con la onda anterior había cuadros donde los ocho
    // cuadrados quedaban apagados, y en tema oscuro el spinner se
    // desaparecía. Se recorre el ciclo entero mirando que nunca haya un
    // momento sin nada encendido.
    for (final t in <double>[
      0,
      0.13,
      0.26,
      0.39,
      0.5,
      0.63,
      0.76,
      0.89,
      0.99,
    ]) {
      await pumpSpinner(
        tester,
        phase: Duration(milliseconds: (1400 * t).round()),
      );
      final v = luminancias(tester);
      final rango =
          v.reduce((a, b) => a > b ? a : b) - v.reduce((a, b) => a < b ? a : b);
      expect(
        rango,
        greaterThanOrEqualTo(contrasteMinimo),
        reason:
            'en t=$t la grilla no tiene nada al frente y el spinner se '
            'apaga entero; luminancias $v',
      );
    }
  });

  testWidgets('el final del ciclo y el principio son la misma imagen', (
    tester,
  ) async {
    // El salto del último cuadrado al primero no se tiene que ver. Con la
    // distancia módulo `squares` el frame final y el inicial coinciden.
    List<Color> colores() => tester
        .widgetList<DecoratedBox>(
          find.descendant(
            of: find.byType(SquaresSpinner),
            matching: find.byType(DecoratedBox),
          ),
        )
        .map((e) => (e.decoration as BoxDecoration).color!)
        .toList();

    await pumpSpinner(tester, phase: Duration.zero);
    final inicio = colores();
    await tester.pump(const Duration(milliseconds: 1400));
    final fin = colores();

    expect(
      fin.map((c) => c.toARGB32()).toList(),
      inicio.map((c) => c.toARGB32()).toList(),
      reason: 'el reinicio del ciclo tiene que ser invisible',
    );
  });

  testWidgets('semántica: se anuncia como "Pensando"', (tester) async {
    await pumpSpinner(tester, phase: Duration.zero);
    expect(find.bySemanticsLabel('Pensando'), findsOneWidget);
  });

  // ───────────────────── los PNG del spinner ─────────────────────
  //
  // Un golden por cada uno de los **8 pasos** del ciclo, más dos del tema
  // oscuro. Ocho cuadros del mismo ciclo valen más que tres fotos sueltas: se
  // ve el recorrido entero de la cabeza de una sentada. Se regeneran con
  // `flutter test test/squares_spinner_test.dart --update-goldens`; sin ese flag
  // solo comparan contra lo que está en el repo.
  //
  // La fase de cada paso va por `i/8 + 0.02` del ciclo: la cabeza redondea al
  // entero más cercano, así que en ese punto cae exacta sobre el cuadrado `i`.

  for (var i = 0; i < 8; i++) {
    testWidgets('captura paso $i', (tester) async {
      await pumpSpinner(
        tester,
        phase: Duration(milliseconds: (1400 * (i / 8 + 0.02)).round()),
      );
      await expectLater(
        find.byType(SquaresSpinner),
        matchesGoldenFile('goldens/spinner_paso_$i.png'),
      );
    });
  }

  for (final i in <int>[0, 4]) {
    testWidgets('captura paso $i en oscuro', (tester) async {
      await pumpSpinner(
        tester,
        phase: Duration(milliseconds: (1400 * (i / 8 + 0.02)).round()),
        brightness: Brightness.dark,
      );
      await expectLater(
        find.byType(SquaresSpinner),
        matchesGoldenFile('goldens/spinner_oscuro_$i.png'),
      );
    });
  }
}
