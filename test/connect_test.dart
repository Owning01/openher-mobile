/// Conectar + [CredsStore].
///
/// El probe es un fake: **no hay server** en los tests. Lo que se verifica es la
/// parte que sí es de esta app —el formulario, el orden validar→probar→guardar,
/// el error en pantalla y la promesa de no filtrar la contraseña— y el contrato
/// de [CredsStore] con un backend en memoria.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/core/storage/creds_store.dart';
import 'package:openher_mobile/domain/models/errors.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/features/connect/connect_view.dart';

void main() {
  late InMemorySecureStore secure;
  late CredsStore creds;

  setUp(() {
    secure = InMemorySecureStore();
    creds = CredsStore(store: secure);
  });

  group('ConnectView: el formulario', () {
    testWidgets('arranca con los defaults medidos del server', (tester) async {
      await pumpConnect(tester, ConnectView(onProbe: _neverProbe));

      expect(
        textOf(tester, ConnectView.hostFieldKey),
        ServerConfig.defaultHost,
      );
      expect(textOf(tester, ConnectView.portFieldKey), '4098');
      expect(textOf(tester, ConnectView.userFieldKey), 'opencode');
      // El password nunca se prellena: no se vuelve a pintar un secreto.
      expect(textOf(tester, ConnectView.passwordFieldKey), '');
    });

    testWidgets('la contraseña arranca tapada y el toggle la muestra', (
      tester,
    ) async {
      await pumpConnect(tester, ConnectView(onProbe: _neverProbe));
      await tester.enterText(
        find.byKey(ConnectView.passwordFieldKey),
        'hunter2',
      );

      expect(passwordIsObscured(tester), isTrue);
      await tester.tap(find.byKey(ConnectView.togglePasswordKey));
      await tester.pumpAndSettle();
      expect(passwordIsObscured(tester), isFalse);
    });

    testWidgets('Puerto rechaza 0 y 70000 sin llegar al probe', (tester) async {
      var probes = 0;
      var connected = false;
      await pumpConnect(
        tester,
        ConnectView(
          onProbe: (_) async => probes++,
          onConnected: (_) => connected = true,
        ),
      );

      for (final invalid in <String>['0', '70000']) {
        await tester.enterText(find.byKey(ConnectView.portFieldKey), invalid);
        await tester.tap(find.byKey(ConnectView.connectButtonKey));
        await tester.pumpAndSettle();

        expect(
          find.text('El puerto va de 1 a 65535.'),
          findsOneWidget,
          reason: 'puerto $invalid',
        );
        expect(probes, 0, reason: 'puerto $invalid no debe tocar la red');
        expect(connected, isFalse);
        expect(find.byKey(ConnectView.errorKey), findsNothing);
      }
    });

    testWidgets('un puerto no numérico también se rechaza', (tester) async {
      await pumpConnect(tester, ConnectView(onProbe: _neverProbe));
      await tester.enterText(find.byKey(ConnectView.portFieldKey), 'abc');
      await tester.tap(find.byKey(ConnectView.connectButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('El puerto tiene que ser un número.'), findsOneWidget);
    });

    testWidgets('un host con http:// se rechaza en el campo', (tester) async {
      await pumpConnect(tester, ConnectView(onProbe: _neverProbe));
      await tester.enterText(
        find.byKey(ConnectView.hostFieldKey),
        'http://192.168.1.5:4098',
      );
      await tester.tap(find.byKey(ConnectView.connectButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Sólo el host, sin http:// ni ruta.'), findsOneWidget);
    });
  });

  group('ConnectView: conectar', () {
    testWidgets('el botón queda deshabilitado mientras se prueba', (
      tester,
    ) async {
      final gate = Completer<void>();
      var probes = 0;
      await pumpConnect(
        tester,
        ConnectView(
          onProbe: (_) {
            probes++;
            return gate.future;
          },
        ),
      );

      await tester.tap(find.byKey(ConnectView.connectButtonKey));
      await tester.pump();
      expect(probes, 1);
      expect(
        tester
            .widget<FilledButton>(find.byKey(ConnectView.connectButtonKey))
            .onPressed,
        isNull,
        reason: 'con un probe en vuelo no se puede volver a tocar',
      );
      // El rótulo no cambia: el botón sigue siendo encontrable y legible.
      expect(find.text('Conectar'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('con un probe OK avisa con el host y el puerto escritos', (
      tester,
    ) async {
      ServerConfig? received;
      await pumpConnect(
        tester,
        ConnectView(
          onProbe: _neverProbe,
          onConnected: (config) => received = config,
        ),
      );

      await tester.enterText(find.byKey(ConnectView.hostFieldKey), '10.0.2.2');
      await tester.enterText(find.byKey(ConnectView.portFieldKey), '5555');
      await tester.enterText(find.byKey(ConnectView.userFieldKey), 'octa');
      await tester.enterText(
        find.byKey(ConnectView.passwordFieldKey),
        'hunter2',
      );
      await tester.tap(find.byKey(ConnectView.connectButtonKey));
      await tester.pumpAndSettle();

      expect(received, isNotNull);
      final got = received!;
      expect(got.host, '10.0.2.2');
      expect(got.port, 5555);
      expect(got.username, 'octa');
      expect(got.password, 'hunter2');
      expect(find.byKey(ConnectView.errorKey), findsNothing);
    });

    testWidgets('sólo guarda si el probe pasó', (tester) async {
      await pumpConnect(
        tester,
        ConnectView(
          onProbe: (config) async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            if (config.port == 1) throw const NetworkError('sin red');
          },
          creds: creds,
        ),
      );

      await tester.tap(find.byKey(ConnectView.connectButtonKey));
      await tester.pumpAndSettle();
      expect(secure.writes, 1);
      expect(await creds.read(), isNotNull);

      // Un probe que falla no deja una contraseña inválida en la Keystore.
      await tester.enterText(find.byKey(ConnectView.portFieldKey), '1');
      await tester.tap(find.byKey(ConnectView.connectButtonKey));
      await tester.pumpAndSettle();
      expect(secure.writes, 1, reason: 'no se guarda lo que el server rechazó');
      expect(find.byKey(ConnectView.errorKey), findsOneWidget);
    });

    testWidgets('el fallback HTML del catch-all se muestra y no conecta', (
      tester,
    ) async {
      ServerConfig? received;
      await pumpConnect(
        tester,
        ConnectView(
          onProbe: (_) async =>
              throw const HtmlFallbackError(path: '/api/location'),
          onConnected: (config) => received = config,
          creds: creds,
        ),
      );
      await tester.enterText(
        find.byKey(ConnectView.passwordFieldKey),
        'hunter2',
      );

      await tester.tap(find.byKey(ConnectView.connectButtonKey));
      await tester.pumpAndSettle();

      expect(received, isNull, reason: 'no navega si el probe falla');
      final message = errorMessage(tester);
      expect(message, contains('HTML'));
      // El texto de UI no repite el nombre del tipo: la convención
      // `'$runtimeType: $message'` se desenvuelve.
      expect(message, isNot(contains('HtmlFallbackError')));
      expect(message, isNot(contains('hunter2')));
      expect(secure.writes, 0);
    });

    testWidgets('un error genérico también se muestra en pantalla', (
      tester,
    ) async {
      await pumpConnect(
        tester,
        ConnectView(onProbe: (_) async => throw Exception('se rompió')),
      );
      await tester.tap(find.byKey(ConnectView.connectButtonKey));
      await tester.pumpAndSettle();

      // Fuera de la jerarquía sellada no hay convención que desenvolver: se
      // muestra el `toString` tal cual, que en Dart ya dice el tipo.
      expect(errorMessage(tester), 'Exception: se rompió');
    });

    testWidgets('un 401 se muestra con el mensaje del dominio', (tester) async {
      await pumpConnect(
        tester,
        ConnectView(onProbe: (_) async => throw const AuthError()),
      );
      await tester.tap(find.byKey(ConnectView.connectButtonKey));
      await tester.pumpAndSettle();

      expect(errorMessage(tester), contains('Credenciales inválidas'));
    });
  });

  group('ConnectView: probar sin guardar', () {
    testWidgets('proba, no guarda y no navega', (tester) async {
      // Con algo ya en la Keystore: "Probar conexión" no lo pisa.
      await creds.write(const ServerConfig(password: 'hunter2'));
      final before = secure.writes;

      ServerConfig? received;
      var probes = 0;
      await pumpConnect(
        tester,
        ConnectView(
          onProbe: (_) async => probes++,
          onConnected: (config) => received = config,
          creds: creds,
        ),
      );

      await tester.tap(find.byKey(ConnectView.probeButtonKey));
      await tester.pumpAndSettle();

      expect(probes, 1);
      expect(received, isNull);
      expect(secure.writes, before, reason: 'probar no escribe');
      expect(secure.deletes, 0);
      expect((await creds.read())!.password, 'hunter2');
      expect(find.byKey(ConnectView.errorKey), findsNothing);
    });

    testWidgets('el fallo de "Probar conexión" se muestra inline', (
      tester,
    ) async {
      await pumpConnect(
        tester,
        ConnectView(
          onProbe: (_) async => throw const NetworkError('sin red'),
          creds: creds,
        ),
      );
      await tester.tap(find.byKey(ConnectView.probeButtonKey));
      await tester.pumpAndSettle();

      expect(errorMessage(tester), 'No se pudo conectar con el servidor.');
      expect(secure.writes, 0);
    });
  });

  group('ConnectView: tema', () {
    testWidgets('los rótulos son los mismos en oscuro', (tester) async {
      await pumpConnect(
        tester,
        ConnectView(onProbe: _neverProbe),
        theme: AppTheme.dark(),
      );
      expect(find.text('Conectar'), findsOneWidget);
      expect(find.text('Probar conexión'), findsOneWidget);
      expect(find.text('Host'), findsOneWidget);
    });
  });

  group('CredsStore', () {
    test('guarda y relee la config completa, con la contraseña', () async {
      const config = ServerConfig(
        host: '10.0.2.2',
        port: 4098,
        username: 'opencode',
        password: 'hunter2',
      );
      await creds.write(config);

      final back = await creds.read();
      expect(back, isNotNull);
      expect(back!.host, '10.0.2.2');
      expect(back.port, 4098);
      expect(back.username, 'opencode');
      expect(back.password, 'hunter2');
      expect(back.apiPrefix, ServerConfig.defaultApiPrefix);
    });

    test('clear() borra y read() vuelve a null', () async {
      await creds.write(const ServerConfig(password: 'hunter2'));
      expect(await creds.read(), isNotNull);

      await creds.clear();
      expect(secure.deletes, 1);
      expect(await creds.read(), isNull);
    });

    test('sin nada guardado, read() es null y no toca nada', () async {
      expect(await creds.read(), isNull);
      expect(secure.writes, 0);
      expect(secure.deletes, 0);
    });

    test('un payload corrupto se trata como "sin credenciales"', () async {
      // La Keystore puede quedar ilegible (cambio de clave, restore de backup):
      // eso no puede ser la razón de que la app no abra.
      secure.values[CredsStore.storageKey] = 'no soy json';
      expect(await creds.read(), isNull);

      secure.values[CredsStore.storageKey] = '"solo un string"';
      expect(await creds.read(), isNull);

      secure.values[CredsStore.storageKey] = '';
      expect(await creds.read(), isNull);
    });

    test('tolera un payload con tipos raros', () async {
      secure.values[CredsStore.storageKey] =
          '{"host":"h","port":"4098","username":"u","password":"p"}';
      final back = await creds.read();
      expect(back!.port, 4098, reason: 'el puerto puede venir como texto');
      expect(back.apiPrefix, ServerConfig.defaultApiPrefix);
    });

    test('toString no filtra la contraseña', () async {
      await creds.write(const ServerConfig(password: 'hunter2'));
      expect(creds.toString(), isNot(contains('hunter2')));
      expect(creds.toString(), contains(CredsStore.storageKey));
      // Tampoco a través de la config que devolvió el store.
      expect((await creds.read())!.toString(), isNot(contains('hunter2')));
    });

    test('redactSecret borra el secreto y tolera el vacío', () {
      expect(redactSecret('falló con hunter2', 'hunter2'), 'falló con ***');
      expect(redactSecret('sin secreto', ''), 'sin secreto');
      expect(redactSecret('hunter2 y hunter2', 'hunter2'), '*** y ***');
    });
  });

  group('describeProbeError', () {
    test('desenvuelve la convención `Type: message`', () {
      expect(
        describeProbeError(const AuthError()),
        'Credenciales inválidas: revisá usuario y contraseña del servidor '
        'opencode.',
      );
      expect(
        describeProbeError(const NetworkError()),
        'No se pudo conectar con el servidor.',
      );
    });

    test('un tipo desconocido cae en su toString', () {
      expect(describeProbeError(Exception('boom')), 'Exception: boom');
      expect(describeProbeError(42), '42');
    });

    test('redacta el secreto que se le pase', () {
      expect(
        describeProbeError(Exception('me robaron hunter2'), secret: 'hunter2'),
        'Exception: me robaron ***',
      );
    });
  });
}

// ───────────────────────────── helpers ───────────────────────────────────────

Future<void> _neverProbe(ServerConfig config) async {}

/// Pump con un `MaterialApp` temado y una superficie alta: `ConnectView` no
/// scrollea, pero 500x1200 deja el formulario entero en un solo viewport.
Future<void> pumpConnect(
  WidgetTester tester,
  Widget view, {
  ThemeData? theme,
}) async {
  tester.view.physicalSize = const Size(500, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: theme ?? AppTheme.light(), home: view),
  );
  await tester.pump();
}

/// Texto del `TextFormField` de la clave [key].
String textOf(WidgetTester tester, Key key) =>
    tester.widget<TextFormField>(find.byKey(key)).controller?.text ?? '';

/// ¿Está tapada la contraseña? `TextFormField` no expone `obscureText`: lo tiene
/// el `TextField` que construye adentro.
bool passwordIsObscured(WidgetTester tester) => tester
    .widget<TextField>(
      find.descendant(
        of: find.byKey(ConnectView.passwordFieldKey),
        matching: find.byType(TextField),
      ),
    )
    .obscureText;

/// Texto de la caja de error, o `''` si no hay.
String errorMessage(WidgetTester tester) {
  final finder = find.descendant(
    of: find.byKey(ConnectView.errorKey),
    matching: find.byType(Text),
  );
  expect(finder, findsOneWidget, reason: 'no hay caja de error visible');
  return tester.widget<Text>(finder).data ?? '';
}
