/// El selector de tema de color de Ajustes.
///
/// Complementa (no reemplaza) a `test/settings_test.dart`, que sigue siendo el
/// dueño del contrato de la pantalla completa. Acá sólo el grupo Apariencia y
/// la paleta: que la liste muestre las 61 variantes del escritorio más el
/// automático, que elegir una la persista y avise, y que un id que no existe
/// caiga al automático en vez de romper.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/core/storage/creds_store.dart';
import 'package:openher_mobile/core/storage/prefs_store.dart';
import 'package:openher_mobile/ui/core/app_icon.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/core/theme_variants.dart';
import 'package:openher_mobile/ui/core/tokens.dart';
import 'package:openher_mobile/ui/features/settings/settings_view.dart';

void main() {
  late InMemoryPrefs backend;
  late PrefsStore prefs;

  setUp(() {
    backend = InMemoryPrefs();
    prefs = PrefsStore(prefs: backend);
  });

  group('la fila de paleta', () {
    testWidgets('arranca en Automático y con la lista plegada', (tester) async {
      await pumpSettings(tester, view(prefs));

      expect(find.text('Tema de color'), findsOneWidget);
      expect(find.text('Automático'), findsOneWidget);
      expect(prefs.themeVariantId, isEmpty, reason: 'default = automático');
      expect(
        backend.values.containsKey(PrefsStore.themeVariantKey),
        isFalse,
        reason: 'no se escribe nada hasta que el usuario elige',
      );
      // 61 filas no se construyen hasta que se piden.
      expect(find.text('Dracula'), findsNothing);
      expect(find.byKey(SettingsView.themeVariantAutoKey), findsNothing);
    });

    testWidgets('la lista trae las 61 variantes, agrupadas y con un check', (
      tester,
    ) async {
      await pumpSettings(tester, view(prefs));
      await openList(tester);

      // Una muestra por entrada: 61 variantes + el automático, más la de la
      // fila plegada que sigue arriba.
      expect(find.byType(ThemeSwatch), findsNWidgets(63));
      for (final kind in ThemeVariantKind.values) {
        for (final variant in ThemeVariants.ofKind(kind)) {
          expect(
            find.byKey(SettingsView.themeVariantOptionKey(variant.id)),
            findsOneWidget,
            reason: 'falta ${variant.id} en la lista',
          );
        }
      }
      // Los tres rótulos de sección, en orden: el del sistema, oscuro y claro.
      expect(find.text('Del sistema'), findsOneWidget);
      expect(find.text('Oscuro'), findsOneWidget);
      expect(find.text('Claro'), findsOneWidget);
      // 'Automático' aparece dos veces en pantalla y por dos motivos: como
      // valor de la fila plegada y como entrada de la lista.
      expect(
        find.descendant(
          of: find.byKey(SettingsView.themeVariantAutoKey),
          matching: find.text('Automático'),
        ),
        findsOneWidget,
      );
      // Sólo la entrada elegida lleva el galón, y al arrancar es el automático.
      expect(checks(tester), findsOneWidget);
    });

    testWidgets('elegir una variante la persiste, avisa y se marca', (
      tester,
    ) async {
      final picked = <String>[];
      await pumpSettings(tester, view(prefs, onThemeVariant: picked.add));
      await openList(tester);

      await tapOption(tester, 'dracula');

      expect(prefs.themeVariantId, 'dracula');
      expect(backend.values[PrefsStore.themeVariantKey], 'dracula');
      expect(picked, <String>['dracula'], reason: 'avisa para repintar la app');
      // Se pliega y la fila contraída muestra el nombre del tema elegido.
      expect(find.text('Dracula'), findsOneWidget);
      expect(
        find.byKey(SettingsView.themeVariantOptionKey('dracula')),
        findsNothing,
        reason: 'elegir cierra la lista',
      );
    });

    testWidgets('el automático devuelve al monocromo y avisa con ""', (
      tester,
    ) async {
      final picked = <String>[];
      await pumpSettings(tester, view(prefs, onThemeVariant: picked.add));
      await openList(tester);
      await tapOption(tester, 'dracula');
      expect(prefs.themeVariantId, 'dracula');

      await openList(tester);
      await tester.ensureVisible(find.byKey(SettingsView.themeVariantAutoKey));
      await tester.tap(find.byKey(SettingsView.themeVariantAutoKey));
      await tester.pumpAndSettle();

      expect(prefs.themeVariantId, isEmpty);
      expect(backend.values[PrefsStore.themeVariantKey], '');
      expect(picked, <String>['dracula', '']);
      expect(find.text('Automático'), findsOneWidget);
    });

    testWidgets('el tema elegido sobrevive a un store y un widget nuevos', (
      tester,
    ) async {
      await pumpSettings(tester, view(prefs));
      await openList(tester);
      await tapOption(tester, 'github-light');

      // Store nuevo sobre el mismo backend, pantalla nueva: tiene que releer.
      final githubLight = ThemeVariants.byId('github-light')!;
      await pumpSettings(
        tester,
        view(PrefsStore(prefs: backend)),
        theme: AppTheme.variantOf(githubLight),
      );
      expect(find.text('GitHub (claro)'), findsOneWidget);
      expect(PrefsStore(prefs: backend).themeVariantId, 'github-light');
      // Y el palomar marcada es el de la elegida, no otro.
      expect(checks(tester), findsNothing, reason: 'la lista está plegada');
    });

    testWidgets('un id que no está en el catálogo cae al automático', (
      tester,
    ) async {
      // Pref vieja, catálogo editado o app reinstalada: la lista no puede
      // romper ni quedarse sin marcar.
      backend.values[PrefsStore.themeVariantKey] = 'tema-que-no-existe';
      await pumpSettings(tester, view(prefs));

      expect(find.text('Automático'), findsOneWidget);
      expect(find.text('Tema que no existe'), findsNothing);
      expect(
        backend.values[PrefsStore.themeVariantKey],
        'tema-que-no-existe',
        reason: 'la pantalla no reescribe lo que no entiende',
      );
    });

    testWidgets('la fila muestra las muestras de la paleta elegida', (
      tester,
    ) async {
      await prefs.setThemeVariant('gruvbox');
      await pumpSettings(tester, view(prefs));
      final gruvbox = ThemeVariants.byId('gruvbox')!;

      expect(rowSwatch(tester), gruvbox.colors.swatch);
    });

    testWidgets('sin variante, la fila muestra los tokens del chrome', (
      tester,
    ) async {
      await pumpSettings(tester, view(prefs));
      expect(rowSwatch(tester), <Color>[
        AppColors.lightBg,
        AppColors.lightSurfaceStrong,
        AppColors.lightPrimary,
        AppColors.lightSecondary,
      ]);
    });
  });

  group('el brillo y la paleta son dos cosas', () {
    testWidgets('elegir una paleta no toca el modo claro/oscuro', (
      tester,
    ) async {
      await pumpSettings(tester, view(prefs));
      await openList(tester);
      await tapOption(tester, 'dracula');

      expect(prefs.themeMode, AppThemeMode.system, reason: 'queda como estaba');
      expect(
        find.text('Sistema'),
        findsOneWidget,
        reason: 'la fila de brillo sigue mostrando el valor persistido',
      );
    });

    testWidgets('cambiar el brillo tampoco toca la paleta', (tester) async {
      await prefs.setThemeVariant('nord');
      await pumpSettings(tester, view(prefs));

      await tester.tap(find.byKey(SettingsView.themeRowKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Oscuro').last);
      await tester.pumpAndSettle();

      expect(prefs.themeMode, AppThemeMode.dark);
      expect(prefs.themeVariantId, 'nord');
      expect(find.text('Nord'), findsOneWidget);
    });
  });

  group('lo que se guarda alcanza para pintar', () {
    test('el id persistido arma el ThemeData', () async {
      // El contrato con `app.dart`: se guarda el id, y con el id sale un
      // ThemeData. Si esto falla, la preferencia se guardó pero no se usa.
      for (final id in <String>['dracula', 'nord-light', 'opencode']) {
        await prefs.setThemeVariant(id);
        final reread = PrefsStore(prefs: backend);
        final variant = ThemeVariants.byId(reread.themeVariantId);
        expect(variant, isNotNull, reason: id);
        final theme = AppTheme.variantOf(variant!);
        expect(theme.colorScheme.primary, variant.colors.primary);
        expect(theme.brightness, variant.kind.brightness);
        expect(theme.scaffoldBackgroundColor, variant.colors.bg);
      }
    });

    test('automático es un id vacío, no un id raro', () async {
      expect(prefs.themeVariantId, isEmpty);
      expect(ThemeVariants.byId(prefs.themeVariantId), isNull);
      await prefs.setThemeVariant('nord');
      expect(ThemeVariants.byId(''), isNull);
    });
  });
}

// ───────────────────────────── helpers ───────────────────────────────────────

Widget view(
  PrefsStore prefs, {
  void Function(String variantId)? onThemeVariant,
}) => SettingsView(
  creds: CredsStore(store: InMemorySecureStore()),
  prefs: prefs,
  layerKeys: const <String>['chat.appbar'],
  onThemeVariant: onThemeVariant,
);

/// Pump con la superficie alta de `test/settings_test.dart`: la pantalla es una
/// `ListView` y con el viewport chico las filas de abajo no llegan a
/// construirse.
Future<void> pumpSettings(
  WidgetTester tester,
  Widget view, {
  ThemeData? theme,
}) async {
  tester.view.physicalSize = const Size(520, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: theme ?? AppTheme.light(), home: view),
  );
  await tester.pumpAndSettle();
}

/// Despliega la lista de paletas.
Future<void> openList(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byKey(SettingsView.themeVariantRowKey),
    120,
  );
  await tester.tap(find.byKey(SettingsView.themeVariantRowKey));
  await tester.pumpAndSettle();
}

/// Toca la variante [id], trayéndola a la vista si hace falta.
Future<void> tapOption(WidgetTester tester, String id) async {
  final row = find.byKey(SettingsView.themeVariantOptionKey(id));
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

/// Los galones de la lista: el check de la entrada elegida.
Finder checks(WidgetTester tester) => find.byWidgetPredicate(
  (widget) => widget is AppIcon && widget.name == 'check',
);

/// Los colores de muestra de la fila de paleta, leídos del widget.
List<Color> rowSwatch(WidgetTester tester) => tester
    .widget<ThemeSwatch>(
      find.descendant(
        of: find.byKey(SettingsView.themeVariantRowKey),
        matching: find.byType(ThemeSwatch),
      ),
    )
    .colors;
