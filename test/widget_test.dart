import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/app.dart';
import 'package:openher_mobile/core/storage/creds_store.dart';
import 'package:openher_mobile/core/storage/prefs_store.dart';

/// Smoke del arranque de la app.
///
/// No toca la red: credenciales vacías ⇒ debe caer en la pantalla **Conectar**,
/// y ése es el primer estado real que ve el usuario.
void main() {
  testWidgets('sin credenciales arranca en Conectar', (tester) async {
    final creds = CredsStore(store: InMemorySecureStore());
    final prefs = PrefsStore(prefs: InMemoryPrefs());

    await tester.pumpWidget(OpenHerMobileApp(prefs: prefs, creds: creds));
    // El arranque carga el catálogo de capas: un pump alcanza.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Conectar'), findsWidgets);
    expect(find.text('Host'), findsOneWidget);
    expect(find.text('Puerto'), findsOneWidget);
    expect(find.text('Usuario'), findsOneWidget);
    expect(find.text('Contraseña'), findsOneWidget);
  });
}
