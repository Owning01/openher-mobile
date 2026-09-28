/// Ajustes + [PrefsStore].
///
/// El probe es un fake (no hay server) y las preferencias viven en un
/// [InMemoryPrefs]. Lo que se verifica es el contrato de la pantalla: los rótulos
/// exactos de la maqueta, que los interruptores persistan de verdad, que
/// `Cerrar sesión` pida confirmación y que el confirm sea el único camino al
/// borrado, y que las capas se apaguen por clave.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/core/storage/creds_store.dart';
import 'package:openher_mobile/core/storage/prefs_store.dart';
import 'package:openher_mobile/domain/models/errors.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/core/tokens.dart';
import 'package:openher_mobile/ui/features/settings/settings_view.dart';

void main() {
  late InMemorySecureStore secure;
  late CredsStore creds;
  late InMemoryPrefs backend;
  late PrefsStore prefs;

  const config = ServerConfig(
    host: '10.0.2.2',
    port: 4098,
    username: 'opencode',
    password: 'hunter2',
  );

  setUp(() {
    secure = InMemorySecureStore();
    creds = CredsStore(store: secure);
    backend = InMemoryPrefs();
    prefs = PrefsStore(prefs: backend);
  });

  group('SettingsView: grupos y rótulos', () {
    testWidgets('los cuatro grupos están, con sus títulos exactos', (
      tester,
    ) async {
      await pumpSettings(tester, build(creds, prefs));

      for (final title in <String>[
        'Servidor',
        'Apariencia',
        'Modelo',
        'Datos',
      ]) {
        expect(find.text(title), findsOneWidget, reason: 'grupo $title');
      }
      expect(find.text('Ajustes'), findsOneWidget);
    });

    testWidgets('las filas son las de la maqueta', (tester) async {
      await pumpSettings(tester, build(creds, prefs));

      const labels = <String>[
        'Host',
        'Puerto',
        'Usuario',
        'Contraseña',
        'Estado',
        'Probar conexión',
        'Tema',
        'Tamaño de texto',
        'Animaciones',
        'Modelo por defecto',
        'Agente por defecto',
        'Traducir ES→EN',
        'Modo de datos',
        'Espacio usado',
        'Cerrar sesión',
        'Capas de la UI',
      ];
      for (final label in labels) {
        expect(find.text(label), findsOneWidget, reason: 'fila $label');
      }
    });

    testWidgets('los valores por defecto son los del diseño', (tester) async {
      await pumpSettings(tester, build(creds, prefs));

      expect(find.text('10.0.2.2'), findsOneWidget); // host del server
      expect(find.text('4098'), findsOneWidget); // puerto
      expect(find.text('opencode'), findsOneWidget); // usuario
      expect(find.text('Conectado'), findsOneWidget); // estado
      expect(find.text('Sistema'), findsOneWidget); // tema
      expect(find.text('Medio'), findsOneWidget); // tamaño de texto
      expect(find.text('space-bunny-free'), findsOneWidget); // modelo
      expect(find.text('build'), findsOneWidget); // agente
      expect(find.text('Completo'), findsOneWidget); // modo de datos
      expect(find.text('18.4 MB'), findsOneWidget); // espacio usado
    });

    testWidgets('la contraseña se muestra tapada, nunca en claro', (
      tester,
    ) async {
      await pumpSettings(tester, build(creds, prefs));

      expect(find.text('•••••••'), findsOneWidget);
      expect(find.text('hunter2'), findsNothing);
    });

    testWidgets('sin server, el estado dice "Sin conectar" y no hay probe', (
      tester,
    ) async {
      var probes = 0;
      await pumpSettings(
        tester,
        build(creds, prefs, config: null, onProbe: (_) async => probes++),
      );

      expect(find.text('Sin conectar'), findsOneWidget);
      expect(find.text('Conectado'), findsNothing);
      expect(find.text('—'), findsWidgets);

      // La fila sin probe no es un botón: no se puede tocar.
      await tester.tap(find.byKey(SettingsView.probeRowKey));
      await tester.pumpAndSettle();
      expect(probes, 0);
    });

    testWidgets('las filas miden 44 px de alto mínimo', (tester) async {
      await pumpSettings(tester, build(creds, prefs));

      for (final key in <Key>[
        const Key('settings-row-host'),
        SettingsView.animationsSwitchKey,
        SettingsView.logoutRowKey,
        SettingsView.probeRowKey,
      ]) {
        expect(
          tester.getSize(find.byKey(key)).height,
          greaterThanOrEqualTo(44),
          reason: '$key es un objetivo táctil',
        );
      }
    });

    testWidgets('los grupos están separados por AppSpacing.lg', (tester) async {
      await pumpSettings(tester, build(creds, prefs));

      final server = tester.getTopLeft(find.text('Servidor'));
      final appearance = tester.getTopLeft(find.text('Apariencia'));
      // Título (labelSmall 11px/1.3 ≈ 14px) + AppSpacing.sm (8) + filas + lg (16).
      expect(appearance.dy - server.dy, greaterThan(16));
    });

    testWidgets('los mismos rótulos existen en oscuro', (tester) async {
      await pumpSettings(tester, build(creds, prefs), theme: AppTheme.dark());
      for (final label in <String>['Servidor', 'Datos', 'Cerrar sesión']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });
  });

  group('SettingsView: interruptores', () {
    testWidgets('Animaciones arranca ON y al togglear se persiste', (
      tester,
    ) async {
      await pumpSettings(tester, build(creds, prefs));
      expect(switchValue(tester, SettingsView.animationsSwitchKey), isTrue);
      expect(prefs.animations, isTrue);

      await tester.tap(find.byKey(SettingsView.animationsSwitchKey));
      await tester.pumpAndSettle();

      expect(prefs.animations, isFalse);
      expect(backend.values[PrefsStore.animationsKey], isFalse);
      expect(
        switchValue(tester, SettingsView.animationsSwitchKey),
        isFalse,
        reason: 'el switch se repinta con lo persistido',
      );

      // Prueba de persistencia de verdad: un store nuevo sobre el mismo backend
      // y un widget nuevo tienen que mostrar OFF.
      await pumpSettings(
        tester,
        build(
          CredsStore(store: InMemorySecureStore()),
          PrefsStore(prefs: backend),
        ),
      );
      expect(switchValue(tester, SettingsView.animationsSwitchKey), isFalse);
    });

    testWidgets('Traducir ES→EN arranca OFF y persiste al ON', (tester) async {
      await pumpSettings(tester, build(creds, prefs));
      expect(switchValue(tester, SettingsView.translateSwitchKey), isFalse);
      expect(prefs.translateEsEn, isFalse);

      await tester.tap(find.byKey(SettingsView.translateSwitchKey));
      await tester.pumpAndSettle();

      expect(prefs.translateEsEn, isTrue);
      expect(backend.values[PrefsStore.translateKey], isTrue);
      expect(switchValue(tester, SettingsView.translateSwitchKey), isTrue);
    });
  });

  group('SettingsView: capas de la UI', () {
    const keys = <String>['chat.appbar', 'chat.appbar.subtitle'];

    testWidgets('arranca plegado y se despliega con la cabecera', (
      tester,
    ) async {
      await pumpSettings(
        tester,
        build(
          creds,
          prefs,
          layerKeys: keys,
          layerDefaults: const {
            'chat.appbar': true,
            // Apagada en la spec aprobada: el switch arranca en OFF.
            'chat.appbar.subtitle': false,
          },
        ),
      );

      expect(find.text('Capas de la UI'), findsOneWidget);
      expect(find.text('1 de 2'), findsOneWidget);
      expect(find.text('chat.appbar'), findsNothing);

      await tester.tap(find.byKey(SettingsView.layersHeaderKey));
      await tester.pumpAndSettle();

      expect(find.text('chat.appbar'), findsOneWidget);
      expect(find.text('chat.appbar.subtitle'), findsOneWidget);
      expect(
        switchValue(tester, SettingsView.layerSwitchKey('chat.appbar')),
        isTrue,
      );
      expect(
        switchValue(
          tester,
          SettingsView.layerSwitchKey('chat.appbar.subtitle'),
        ),
        isFalse,
        reason: 'la spec la apagó',
      );
    });

    testWidgets('toggling una capa la persiste y avisa', (tester) async {
      final toggled = <String, bool>{};
      await pumpSettings(
        tester,
        build(
          creds,
          prefs,
          layerKeys: keys,
          onLayerToggle: (key, value) => toggled[key] = value,
        ),
      );
      await tester.tap(find.byKey(SettingsView.layersHeaderKey));
      await tester.pumpAndSettle();
      // Sin `layerDefaults` inyectados, las dos arrancan encendidas.
      expect(find.text('2 de 2'), findsOneWidget);

      await tester.tap(
        find.byKey(SettingsView.layerSwitchKey('chat.appbar.subtitle')),
      );
      await tester.pumpAndSettle();

      expect(toggled, <String, bool>{'chat.appbar.subtitle': false});
      expect(prefs.layerSwitches, <String, bool>{
        'chat.appbar.subtitle': false,
      });
      expect(
        switchValue(
          tester,
          SettingsView.layerSwitchKey('chat.appbar.subtitle'),
        ),
        isFalse,
      );
      expect(find.text('1 de 2'), findsOneWidget);

      // Y de vuelta: el override pisa el default de la spec otra vez.
      await tester.tap(
        find.byKey(SettingsView.layerSwitchKey('chat.appbar.subtitle')),
      );
      await tester.pumpAndSettle();
      expect(toggled['chat.appbar.subtitle'], isTrue);
      expect(
        prefs.layerEnabled('chat.appbar.subtitle', fallback: true),
        isTrue,
      );

      await tester.tap(find.byKey(SettingsView.layerSwitchKey('chat.appbar')));
      await tester.pumpAndSettle();
      expect(prefs.layerEnabled('chat.appbar', fallback: true), isFalse);
      expect(find.text('1 de 2'), findsOneWidget);
    });

    testWidgets('sin inyección lista el subconjunto de respaldo', (
      tester,
    ) async {
      await pumpSettings(tester, build(creds, prefs));
      expect(find.text('Capas de la UI'), findsOneWidget);
      expect(
        find.text(
          '${SettingsView.defaultLayerKeys.length} de '
          '${SettingsView.defaultLayerKeys.length}',
        ),
        findsOneWidget,
      );
      expect(
        SettingsView.defaultLayerKeys.length,
        lessThan(94),
        reason: 'la spec completa se carga, no se copia en Dart',
      );
    });
  });

  group('SettingsView: probar conexión', () {
    testWidgets('el resultado OK va en un snackbar', (tester) async {
      var probes = 0;
      await pumpSettings(
        tester,
        build(creds, prefs, onProbe: (_) async => probes++),
      );

      await tester.tap(find.byKey(SettingsView.probeRowKey));
      await tester.pumpAndSettle();

      expect(probes, 1);
      expect(find.text('Conexión OK con http://10.0.2.2:4098'), findsOneWidget);
    });

    testWidgets('el fallo va en un snackbar y no filtra la contraseña', (
      tester,
    ) async {
      await pumpSettings(
        tester,
        build(
          creds,
          prefs,
          onProbe: (_) async =>
              throw const HtmlFallbackError(path: '/api/location'),
        ),
      );

      await tester.tap(find.byKey(SettingsView.probeRowKey));
      await tester.pumpAndSettle();

      final snack = find.byType(SnackBar);
      expect(snack, findsOneWidget);
      final text = tester
          .widgetList<Text>(
            find.descendant(of: snack, matching: find.byType(Text)),
          )
          .map((t) => t.data ?? '')
          .join(' ');
      expect(text, contains('No se pudo conectar'));
      expect(text, contains('HTML'));
      expect(text, isNot(contains('hunter2')));
    });

    testWidgets('probar no cambia lo guardado', (tester) async {
      await creds.write(config);
      final writes = secure.writes;
      await pumpSettings(
        tester,
        build(creds, prefs, onProbe: (_) async => throw const NetworkError()),
      );

      await tester.tap(find.byKey(SettingsView.probeRowKey));
      await tester.pumpAndSettle();

      expect(secure.writes, writes, reason: 'probar no escribe');
      expect(secure.deletes, 0);
      expect((await creds.read())!.password, 'hunter2');
    });
  });

  group('SettingsView: cerrar sesión', () {
    testWidgets('pide confirmación con el texto exacto del diseño', (
      tester,
    ) async {
      await creds.write(config);
      await pumpSettings(tester, build(creds, prefs));

      await tester.tap(find.byKey(SettingsView.logoutRowKey));
      await tester.pumpAndSettle();

      expect(find.text('Cancelar'), findsOneWidget);
      expect(find.byKey(SettingsView.logoutConfirmKey), findsOneWidget);
      // `Cerrar sesión` aparece tres veces: la fila, el título del diálogo y el
      // botón de peligro. El que borra se apunta por clave, no por texto.
      expect(
        find.text('Cerrar sesión'),
        findsNWidgets(3),
        reason: 'fila + título del diálogo + botón de peligro',
      );
      expect(
        find.text(
          'Esta acción no se puede deshacer. Elimina las credenciales '
          'guardadas en este dispositivo.',
        ),
        findsOneWidget,
      );
      // Nada se borró con abrir el diálogo.
      expect(secure.deletes, 0);
    });

    testWidgets('Cancelar no borra nada y no avisa', (tester) async {
      await creds.write(config);
      var loggedOut = 0;
      await pumpSettings(
        tester,
        build(creds, prefs, onLoggedOut: () => loggedOut++),
      );

      await tester.tap(find.byKey(SettingsView.logoutRowKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SettingsView.logoutCancelKey));
      await tester.pumpAndSettle();

      expect(find.text('Cancelar'), findsNothing);
      expect(loggedOut, 0);
      expect(secure.deletes, 0);
      expect((await creds.read())!.password, 'hunter2');
    });

    testWidgets('el botón de peligro borra y avisa', (tester) async {
      await creds.write(config);
      var loggedOut = 0;
      await pumpSettings(
        tester,
        build(creds, prefs, onLoggedOut: () => loggedOut++),
      );

      await tester.tap(find.byKey(SettingsView.logoutRowKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SettingsView.logoutConfirmKey));
      await tester.pumpAndSettle();

      expect(loggedOut, 1);
      expect(secure.deletes, 1);
      expect(await creds.read(), isNull);
      expect(find.text('Cancelar'), findsNothing);
    });

    testWidgets('el botón de peligro usa el token danger del tema', (
      tester,
    ) async {
      await pumpSettings(tester, build(creds, prefs));
      await tester.tap(find.byKey(SettingsView.logoutRowKey));
      await tester.pumpAndSettle();

      final button = find.byKey(SettingsView.logoutConfirmKey);
      expect(
        tester
            .widget<Text>(
              find.descendant(of: button, matching: find.byType(Text)),
            )
            .style
            ?.color,
        AppTheme.light().colorScheme.error,
      );
      expect(AppTheme.light().colorScheme.error, AppColors.lightDanger);
    });
  });

  group('PrefsStore', () {
    test('los defaults son los del diseño', () {
      expect(prefs.themeMode, AppThemeMode.system);
      expect(prefs.textScale, AppTextScale.medium);
      expect(prefs.textScaleValue, 1.0);
      expect(prefs.animations, isTrue, reason: 'default ON');
      expect(prefs.translateEsEn, isFalse, reason: 'default OFF');
      expect(prefs.defaultModel, 'space-bunny-free');
      expect(prefs.defaultAgent, 'build');
      expect(prefs.lastDirectory, '');
      expect(prefs.layerSwitches, isEmpty);
    });

    test('un valor escrito se relee con un store nuevo', () async {
      await prefs.setThemeMode(AppThemeMode.dark);
      await prefs.setTextScale(AppTextScale.small);
      await prefs.setLastDirectory('C:/dev/openher');

      final again = PrefsStore(prefs: backend);
      expect(again.themeMode, AppThemeMode.dark);
      expect(again.themeMode.label, 'Oscuro');
      expect(again.textScale, AppTextScale.small);
      expect(again.textScale.value, 0.85);
      expect(again.lastDirectory, 'C:/dev/openher');
    });

    test('el tamaño de texto tiene los tres valores rotulados', () {
      expect(AppTextScale.values.map((s) => s.value), <double>[
        0.85,
        1.0,
        1.15,
      ]);
      expect(AppTextScale.values.map((s) => s.label), <String>[
        'Chico',
        'Medio',
        'Grande',
      ]);
    });

    test('una pref corrupta no rompe la lectura', () {
      backend.values[PrefsStore.layersKey] = 'no soy json';
      expect(prefs.layerSwitches, isEmpty);

      backend.values[PrefsStore.layersKey] = '{"a":"no soy bool"}';
      expect(prefs.layerSwitches, isEmpty);

      backend.values[PrefsStore.themeKey] = 'inventado';
      expect(prefs.themeMode, AppThemeMode.system);
    });

    test('los overrides de capas respetan el default de la spec', () async {
      const spec = <String, bool>{
        'chat.appbar': true,
        'chat.appbar.subtitle': false,
      };
      expect(prefs.resolveLayers(spec), spec);

      await prefs.setLayer('chat.appbar.subtitle', true);
      expect(
        prefs.layerEnabled('chat.appbar.subtitle', fallback: false),
        isTrue,
      );
      expect(prefs.resolveLayers(spec), <String, bool>{
        'chat.appbar': true,
        'chat.appbar.subtitle': true,
      });

      await prefs.resetLayers();
      expect(prefs.layerSwitches, isEmpty);
      expect(prefs.resolveLayers(spec), spec);
    });

    test('setLayer es idempotente y no duplica trabajo', () async {
      await prefs.setLayer('chat.appbar', false);
      final raw = backend.values[PrefsStore.layersKey] as String;
      await prefs.setLayer('chat.appbar', false);
      expect(backend.values[PrefsStore.layersKey], raw);
    });

    test('exige un backend: sin prefs ni shared no hay store', () {
      expect(() => PrefsStore(), throwsArgumentError);
    });

    test('snapshot trae todo de una vez', () async {
      await prefs.setAnimations(false);
      await prefs.setTranslateEsEn(true);
      await prefs.setDefaultModel('otro-modelo');
      await prefs.setDefaultAgent('plan');
      await prefs.setLastDirectory('/tmp');
      await prefs.setLayer('chat.appbar', false);

      final snap = prefs.snapshot();
      expect(snap.animations, isFalse);
      expect(snap.translateEsEn, isTrue);
      expect(snap.defaultModel, 'otro-modelo');
      expect(snap.defaultAgent, 'plan');
      expect(snap.lastDirectory, '/tmp');
      expect(snap.layerSwitches, <String, bool>{'chat.appbar': false});
      expect(snap.themeMode, AppThemeMode.system);
    });
  });
}

// ───────────────────────────── helpers ───────────────────────────────────────

Widget build(
  CredsStore creds,
  PrefsStore prefs, {
  ServerConfig? config = const ServerConfig(
    host: '10.0.2.2',
    port: 4098,
    username: 'opencode',
    password: 'hunter2',
  ),
  Future<void> Function(ServerConfig)? onProbe,
  void Function()? onLoggedOut,
  void Function(String key, bool value)? onLayerToggle,
  List<String>? layerKeys,
  Map<String, bool>? layerDefaults,
}) => SettingsView(
  creds: creds,
  prefs: prefs,
  config: config,
  onProbe: onProbe,
  onLoggedOut: onLoggedOut,
  onLayerToggle: onLayerToggle,
  layerKeys: layerKeys,
  layerDefaults: layerDefaults,
);

/// Pump con un `MaterialApp` temado. La superficie es alta a propósito: la
/// pantalla es una `ListView` y con el viewport chico las filas de abajo no
/// llegan a construirse.
Future<void> pumpSettings(
  WidgetTester tester,
  Widget view, {
  ThemeData? theme,
}) async {
  tester.view.physicalSize = const Size(520, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: theme ?? AppTheme.light(), home: view),
  );
  await tester.pumpAndSettle();
}

/// Estado del `Switch` de la clave [key].
bool switchValue(WidgetTester tester, Key key) =>
    tester.widget<Switch>(find.byKey(key)).value;
