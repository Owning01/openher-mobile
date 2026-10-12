/// Pestañas de chats en el nav: sin duplicados, con activación y cierre.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/domain/models/message.dart';
import 'package:openher_mobile/domain/models/session.dart';
import 'package:openher_mobile/ui/features/navigation/mobile_nav.dart';

SessionInfo _ses(String id, [String title = 'test']) => SessionInfo(
  id: id,
  projectID: 'prj_1',
  title: title,
  cost: 0,
  tokens: const TokenUsage(),
  time: const SessionTime(createdMs: 0, updatedMs: 0),
);

void main() {
  group('pestañas de chats', () {
    test('abrir dos veces la misma no duplica: la activa', () {
      final nav = MobileNav();
      nav.openSession(_ses('a'));
      nav.openSession(_ses('b'));
      nav.openSession(_ses('a'));

      expect(nav.openChats.map((s) => s.id), ['b', 'a']);
      expect(nav.chatSessionId, 'a');
      expect(nav.tab, MobileTab.chat);
    });

    test('activateSession cambia la activa y la mueve al frente', () {
      final nav = MobileNav();
      nav.openSession(_ses('a'));
      nav.openSession(_ses('b'));
      nav.activateSession('a');

      expect(nav.chatSessionId, 'a');
      expect(nav.openChats.map((s) => s.id), ['b', 'a']);
    });

    test('activateSession con id desconocido no hace nada', () {
      final nav = MobileNav();
      nav.openSession(_ses('a'));
      nav.activateSession('zzz');

      expect(nav.chatSessionId, 'a');
      expect(nav.openChats, hasLength(1));
    });

    test('cerrar la activa pasa a la más reciente', () {
      final nav = MobileNav();
      nav.openSession(_ses('a'));
      nav.openSession(_ses('b'));
      nav.openSession(_ses('c'));
      nav.closeSession('c');

      expect(nav.chatSessionId, 'b');
      expect(nav.openChats.map((s) => s.id), ['a', 'b']);
    });

    test('cerrar una que no es la activa no cambia la activa', () {
      final nav = MobileNav();
      nav.openSession(_ses('a'));
      nav.openSession(_ses('b'));
      nav.closeSession('a');

      expect(nav.chatSessionId, 'b');
      expect(nav.openChats.map((s) => s.id), ['b']);
    });

    test('cerrar la última deja sin activa', () {
      final nav = MobileNav();
      nav.openSession(_ses('a'));
      nav.closeSession('a');

      expect(nav.chatSessionId, isNull);
      expect(nav.chatSession, isNull);
      expect(nav.openChats, isEmpty);
    });

    test('single:true reemplaza en vez de acumular (móvil)', () {
      final nav = MobileNav();
      nav.openSession(_ses('a'));
      nav.openSession(_ses('b'), single: true);

      expect(nav.openChats.map((s) => s.id), ['b']);
      expect(nav.chatSessionId, 'b');
    });

    test('tope de 12 pestañas: la más vieja sale', () {
      final nav = MobileNav();
      for (var i = 0; i < 14; i++) {
        nav.openSession(_ses('ses_$i'));
      }

      expect(nav.openChats, hasLength(MobileNav.maxOpenChats));
      expect(nav.openChats.map((s) => s.id), isNot(contains('ses_0')));
      expect(nav.chatSessionId, 'ses_13');
    });

    test('entrar al Chat con pestañas pero sin activa vuelve a la última', () {
      final nav = MobileNav();
      nav.openSession(_ses('a'));
      nav.openSession(_ses('b'));
      nav.leaveChat();
      expect(nav.chatSessionId, isNull);

      nav.select(MobileTab.chat);

      expect(nav.tab, MobileTab.chat);
      expect(nav.chatSessionId, 'b');
    });

    test('sin pestañas entrar al Chat sigue bloqueado', () {
      final nav = MobileNav();
      nav.select(MobileTab.chat);

      expect(nav.tab, MobileTab.sessions);
    });
  });
}
