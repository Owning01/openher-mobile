/// Split desktop: arrastre, colapso y reapertura.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/features/navigation/desktop_split.dart';

void main() {
  group('clampMasterWidth', () {
    test('acota al rango 240-600', () {
      expect(clampMasterWidth(380), 380.0);
      expect(clampMasterWidth(10), 240.0);
      expect(clampMasterWidth(2000), 600.0);
    });
  });

  group('DesktopSplit', () {
    Future<void> pumpSplit(
      WidgetTester tester, {
      double width = 380.0,
      bool visible = true,
      void Function(double dx)? onResize,
      void Function()? onResizeEnd,
      void Function()? onToggle,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: DesktopSplit(
              sessions: const Text('master'),
              chat: const Text('chat'),
              masterWidth: width,
              sidebarVisible: visible,
              onResize: onResize ?? (_) {},
              onResizeEnd: onResizeEnd ?? () {},
              onToggle: onToggle ?? () {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('visible: master + divisor + chat', (tester) async {
      await pumpSplit(tester);

      expect(find.text('master'), findsOneWidget);
      expect(find.text('chat'), findsOneWidget);
      expect(find.byKey(DesktopSplit.resizeHandleKey), findsOneWidget);
      expect(find.byKey(DesktopSplit.expandStripKey), findsNothing);
    });

    testWidgets('oculto: tira de reapertura en vez de master', (
      tester,
    ) async {
      await pumpSplit(tester, visible: false);

      expect(find.text('master'), findsNothing);
      expect(find.text('chat'), findsOneWidget);
      expect(find.byKey(DesktopSplit.resizeHandleKey), findsNothing);
      expect(find.byKey(DesktopSplit.expandStripKey), findsOneWidget);
    });

    testWidgets('arrastrar avisa el delta y al soltar persiste', (
      tester,
    ) async {
      final deltas = <double>[];
      var ends = 0;
      await pumpSplit(
        tester,
        onResize: deltas.add,
        onResizeEnd: () => ends++,
      );

      // `timedDrag` y no `drag`: el `Tooltip` del divisor deja un timer
      // pendiente y `drag` lo denuncia como error (`warnIfMissed: false` lo
      // salta, y el `pump` largo liquida el timer del tooltip).
      await tester.timedDrag(
        find.byKey(DesktopSplit.resizeHandleKey),
        const Offset(50, 0),
        const Duration(milliseconds: 100),
        warnIfMissed: false,
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));

      expect(deltas, isNotEmpty);
      expect(deltas.reduce((a, b) => a + b), greaterThan(0));
      expect(ends, 1);
    });

    testWidgets('la tira reabre con un toque', (tester) async {
      var toggles = 0;
      await pumpSplit(tester, visible: false, onToggle: () => toggles++);

      await tester.tap(find.byKey(DesktopSplit.expandStripKey));
      await tester.pump();

      expect(toggles, 1);
    });

    testWidgets('el divisor es ajustable por lector de pantalla', (
      tester,
    ) async {
      await pumpSplit(tester, width: 380.0);

      // Sin `increasedValue`/`decreasedValue` el framework revienta el árbol
      // de semántica: este test lo fija como contrato.
      final data = tester
          .getSemantics(find.byKey(DesktopSplit.resizeHandleKey))
          .getSemanticsData();
      expect(data.hasAction(SemanticsAction.increase), isTrue);
      expect(data.hasAction(SemanticsAction.decrease), isTrue);
      expect(data.label, 'Ancho de la lista de sesiones');
      expect(data.value, '380 píxeles');
    });
  });
}
