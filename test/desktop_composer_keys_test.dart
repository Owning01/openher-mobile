/// Teclado físico del composer (desktop): Enter manda, Ctrl+V pega.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/core/storage/prefs_store.dart';
import 'package:openher_mobile/ui/features/chat/chat_view.dart';
import 'package:openher_mobile/ui/features/chat/composer.dart';
import 'package:openher_mobile/ui/features/chat/composer_suggestions.dart';

void main() {
  group('ChatView.isWide', () {
    test('900 acota a 1000, 899 va a sangre', () {
      expect(ChatView.isWide(900), isTrue);
      expect(ChatView.isWide(1920), isTrue);
      expect(ChatView.isWide(899), isFalse);
      expect(ChatView.isWide(390), isFalse);
      expect(ChatView.kWideMaxWidth, 1000.0);
    });
  });

  group('sidebar en prefs', () {
    test('defaults: 380 visible', () {
      final prefs = PrefsStore(prefs: InMemoryPrefs());
      expect(prefs.sidebarWidth, 380.0);
      expect(prefs.sidebarVisible, isTrue);
    });

    test('persiste y acota', () async {
      final prefs = PrefsStore(prefs: InMemoryPrefs());
      await prefs.setSidebarWidth(500);
      expect(prefs.sidebarWidth, 500.0);
      await prefs.setSidebarWidth(2000);
      expect(prefs.sidebarWidth, 600.0);
      await prefs.setSidebarWidth(10);
      expect(prefs.sidebarWidth, 240.0);
      await prefs.setSidebarVisible(false);
      expect(prefs.sidebarVisible, isFalse);
    });
  });

  group('teclas del composer', () {
    Future<void> pumpComposer(
      WidgetTester tester, {
      Future<bool> Function()? onPasteRequest,
      required void Function(String text, List<ComposerAttachment> files)
      onSend,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatComposer(
              working: false,
              canSend: true,
              onSend: (text, files) => onSend(text, files),
              onPasteRequest: onPasteRequest,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(ChatComposer.inputKey));
      await tester.pump();
    }

    testWidgets('Enter manda el texto', (tester) async {
      final sent = <String>[];
      await pumpComposer(
        tester,
        onSend: (text, _) => sent.add(text),
      );
      await tester.enterText(find.byKey(ChatComposer.inputKey), 'hola');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(sent, ['hola']);
    });

    testWidgets('Ctrl+V con imagen llama al callback y no revienta', (
      tester,
    ) async {
      var pasted = false;
      final sent = <String>[];
      await pumpComposer(
        tester,
        onPasteRequest: () async {
          pasted = true;
          return true;
        },
        onSend: (text, _) => sent.add(text),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pump();

      expect(pasted, isTrue);
      // La imagen la adjunta el shell: el composer no manda texto por ella.
      expect(sent, isEmpty);
    });

    testWidgets('Ctrl+V sin imagen no revienta ni manda', (tester) async {
      // Sin plugin de portapapeles en tests, `Clipboard.getData` tira: el
      // composer lo absorbe y no manda nada.
      final sent = <String>[];
      await pumpComposer(
        tester,
        onPasteRequest: () async => false,
        onSend: (text, _) => sent.add(text),
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pump();

      expect(sent, isEmpty);
    });

    testWidgets('Esc cierra el menú de sugerencias', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatComposer(
              working: false,
              canSend: true,
              onSend: (_, _) {},
              suggestions: const [
                ComposerSuggestion(
                  label: 'review',
                  kind: ComposerSuggestionKind.command,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(ChatComposer.inputKey));
      await tester.pump();
      await tester.enterText(find.byKey(ChatComposer.inputKey), '/rev');
      await tester.pump();

      expect(find.byKey(ChatComposer.suggestionsKey), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(find.byKey(ChatComposer.suggestionsKey), findsNothing);
    });
  });
}
