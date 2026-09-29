import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/core/storage/prefs_store.dart';
import 'package:openher_mobile/ui/features/sessions/session_favorites.dart';

/// Las favoritas: un `string[]` ordenado de ids, igual que el escritorio.
///
/// Es el port de `web/src/hooks/useSessions.ts`:
/// `useLocalStorage<string[]>(FAVORITES_KEY, [])` + un `Set` derivado.
void main() {
  group('persistencia', () {
    test('arranca vacía si no hay nada guardado', () {
      final fav = SessionFavorites(InMemoryPrefs());
      addTearDown(fav.dispose);
      expect(fav.order, isEmpty);
      expect(fav.contains('ses_1'), isFalse);
    });

    test('guarda y relee el orden exacto', () {
      final prefs = InMemoryPrefs();
      final fav = SessionFavorites(prefs);
      addTearDown(fav.dispose);

      fav
        ..toggle('ses_c')
        ..toggle('ses_a')
        ..toggle('ses_b');

      expect(fav.order, <String>['ses_c', 'ses_a', 'ses_b']);

      // Una instancia nueva lee lo mismo, en el mismo orden: el orden es parte
      // del dato, no un efecto del orden de llegada de la lista.
      final otra = SessionFavorites(prefs);
      addTearDown(otra.dispose);
      expect(otra.order, <String>['ses_c', 'ses_a', 'ses_b']);
      expect(otra.contains('ses_a'), isTrue);
    });

    test('escribió un JSON, no texto armado a mano', () {
      final prefs = InMemoryPrefs();
      final fav = SessionFavorites(prefs);
      addTearDown(fav.dispose);
      fav.toggle('ses_x');

      // La clave es la misma que usa el escritorio, para que el archivo sea
      // legible desde el otro lado si algún día se sincroniza.
      expect(prefs.getString(SessionFavorites.key), '["ses_x"]');
    });
  });

  group('toggle', () {
    test('desmarcar saca el id y deja el resto en su orden', () {
      final fav = SessionFavorites(InMemoryPrefs());
      addTearDown(fav.dispose);
      fav
        ..toggle('ses_a')
        ..toggle('ses_b')
        ..toggle('ses_c')
        ..toggle('ses_b');

      expect(fav.order, <String>['ses_a', 'ses_c']);
    });

    test('volver a marcar después de desmarcar lo pone al final', () {
      final fav = SessionFavorites(InMemoryPrefs());
      addTearDown(fav.dispose);
      // a, b → desmarcar a → marcar a de nuevo. Recién ahí va al final.
      // (El nombre dice "volver a marcar": marcar dos veces seguidas la
      // desmarcaría, que es lo que prueba el test de arriba.)
      fav
        ..toggle('ses_a')
        ..toggle('ses_b')
        ..toggle('ses_a')
        ..toggle('ses_a');
      expect(fav.order, <String>['ses_b', 'ses_a']);
    });
  });

  group('reordenar', () {
    test('sube y baja una favorita sin perder ninguna', () {
      final fav = SessionFavorites(InMemoryPrefs());
      addTearDown(fav.dispose);
      fav
        ..toggle('ses_a')
        ..toggle('ses_b')
        ..toggle('ses_c');

      expect(fav.move(0, 2), isTrue);
      expect(fav.order, <String>['ses_b', 'ses_c', 'ses_a']);
      expect(fav.move(2, 0), isTrue);
      expect(fav.order, <String>['ses_a', 'ses_b', 'ses_c']);
    });

    test('un índice inválido devuelve false en vez de romper', () {
      final fav = SessionFavorites(InMemoryPrefs());
      addTearDown(fav.dispose);
      fav.toggle('ses_a');

      expect(fav.move(0, 5), isFalse);
      expect(fav.move(-1, 0), isFalse);
      expect(fav.move(0, 0), isTrue);
      expect(fav.order, <String>['ses_a']);
    });
  });

  group('una lista corrupta no rompe la app', () {
    test('un JSON basura se pierde sola y se sigue marcando', () {
      final prefs = InMemoryPrefs();
      prefs.setString(SessionFavorites.key, '{no soy un array');
      final fav = SessionFavorites(prefs);
      addTearDown(fav.dispose);

      // Perder preferencias es mejor que no abrir la app: la lista arranca
      // vacía y el usuario vuelve a marcar.
      expect(fav.order, isEmpty);
      expect(() => fav.toggle('ses_nueva'), returnsNormally);
      expect(fav.order, <String>['ses_nueva']);
    });

    test('un JSON que no es una lista de strings se ignora', () {
      final prefs = InMemoryPrefs();
      prefs.setString(SessionFavorites.key, '[1, 2, {"a": 1}]');
      final fav = SessionFavorites(prefs);
      addTearDown(fav.dispose);
      expect(fav.order, isEmpty);
    });
  });
}
