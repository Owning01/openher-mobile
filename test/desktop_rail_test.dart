/// Vista desktop: breakpoint y rail sin tocar la rama móvil.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/features/navigation/desktop_rail.dart';
import 'package:openher_mobile/ui/features/navigation/mobile_nav.dart';

void main() {
  group('isDesktopWidth', () {
    test('900 entra, 844 (teléfono acostado) no', () {
      expect(isDesktopWidth(900), isTrue);
      expect(isDesktopWidth(1280), isTrue);
      expect(isDesktopWidth(899), isFalse);
      expect(isDesktopWidth(844), isFalse);
      expect(isDesktopWidth(390), isFalse);
    });
  });

  group('DesktopRail', () {
    Future<void> pumpRail(
      WidgetTester tester, {
      MobileTab current = MobileTab.sessions,
      bool chatEnabled = true,
      void Function(MobileTab tab)? onSelect,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: DesktopRail(
              current: current,
              chatEnabled: chatEnabled,
              onSelect: onSelect ?? (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('muestra los 4 destinos con sus etiquetas', (tester) async {
      await pumpRail(tester);

      for (final tab in MobileTab.values) {
        expect(find.text(tab.label), findsOneWidget);
      }
    });

    testWidgets('tocar un destino avisa cuál', (tester) async {
      final picked = <MobileTab>[];
      await pumpRail(tester, onSelect: picked.add);

      await tester.tap(find.text('Archivos'));
      await tester.pump();

      expect(picked, [MobileTab.files]);
    });

    testWidgets('sin onToggleSidebar no hay botón de colapso', (tester) async {
      await pumpRail(tester);

      expect(find.byTooltip('Ocultar lista (Ctrl+B)'), findsNothing);
      expect(find.byTooltip('Mostrar lista (Ctrl+B)'), findsNothing);
    });

    testWidgets('el botón del rail colapsa y expande', (tester) async {
      var toggles = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: DesktopRail(
              current: MobileTab.sessions,
              onSelect: (_) {},
              sidebarVisible: true,
              onToggleSidebar: () => toggles++,
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Ocultar lista (Ctrl+B)'));
      await tester.pump();

      expect(toggles, 1);
    });

    testWidgets('colapsado el tooltip invita a mostrar', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: DesktopRail(
              current: MobileTab.sessions,
              onSelect: (_) {},
              sidebarVisible: false,
              onToggleSidebar: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byTooltip('Mostrar lista (Ctrl+B)'), findsOneWidget);
    });
  });
}
