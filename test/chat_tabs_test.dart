/// Tira de pestañas: render, selección y cierre.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/domain/models/message.dart';
import 'package:openher_mobile/domain/models/session.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/features/chat/chat_tabs.dart';

SessionInfo _ses(String id, [String title = '']) => SessionInfo(
  id: id,
  projectID: 'prj_1',
  title: title,
  cost: 0,
  tokens: const TokenUsage(),
  time: const SessionTime(createdMs: 0, updatedMs: 0),
);

void main() {
  group('ChatTabStrip.titleOf', () {
    test('título del server, o prefijo del id', () {
      expect(ChatTabStrip.titleOf(_ses('a', 'Diseño')), 'Diseño');
      expect(
        ChatTabStrip.titleOf(_ses('ses_0acd172ac001')),
        'ses_0acd172a…',
      );
      expect(ChatTabStrip.titleOf(_ses('corto')), 'corto');
    });
  });

  group('ChatTabStrip', () {
    Future<void> pumpStrip(
      WidgetTester tester, {
      required List<SessionInfo> tabs,
      String? activeId,
      void Function(String id)? onSelect,
      void Function(String id)? onClose,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: ChatTabStrip(
              tabs: tabs,
              activeId: activeId,
              onSelect: onSelect ?? (_) {},
              onClose: onClose ?? (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('una pestaña por sesión, con su título', (tester) async {
      await pumpStrip(
        tester,
        tabs: [_ses('a', 'Uno'), _ses('b', 'Dos')],
        activeId: 'a',
      );

      expect(find.text('Uno'), findsOneWidget);
      expect(find.text('Dos'), findsOneWidget);
    });

    testWidgets('tocar una pestaña la selecciona (y la × no selecciona)', (
      tester,
    ) async {
      final picked = <String>[];
      final closed = <String>[];
      await pumpStrip(
        tester,
        tabs: [_ses('a', 'Uno'), _ses('b', 'Dos')],
        activeId: 'a',
        onSelect: picked.add,
        onClose: closed.add,
      );

      await tester.tap(find.text('Dos'));
      await tester.pump();
      expect(picked, ['b']);
      expect(closed, isEmpty);

      await tester.tap(find.byKey(ChatTabStrip.closeKey('b')));
      await tester.pump();
      expect(closed, ['b']);
      // La × cierra sin cambiar de pestaña.
      expect(picked, ['b']);
    });

    testWidgets('la activa lleva el borde primary', (tester) async {
      await pumpStrip(
        tester,
        tabs: [_ses('a', 'Uno'), _ses('b', 'Dos')],
        activeId: 'b',
      );

      Container boxOf(String text) => tester.widget<Container>(
        find.ancestor(of: find.text(text), matching: find.byType(Container)).first,
      );
      final active = boxOf('Dos').decoration! as BoxDecoration;
      final idle = boxOf('Uno').decoration! as BoxDecoration;
      expect(active.border?.bottom.width, 2);
      expect(idle.border, isNull);
    });
  });
}
