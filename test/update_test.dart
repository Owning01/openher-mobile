import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/update/update_service.dart';
import 'package:openher_mobile/ui/core/update_banner.dart';

/// El manifiesto real que publica `scripts/publish-update.ps1`.
/// El sha256 por defecto es el de los bytes que sirve [_ManifestoYApk] (3 MB
/// de `0x41`): así la verificación pasa en los tests de descarga entera y el
/// test de mismatch lo rompe a propósito pasándole otro.
String manifest(Map<String, Object?> over) => jsonEncode({
  'version': '1.1.0',
  'versionCode': 2,
  'url': 'https://example.test/app-release.apk',
  'sha256': kApkSha,
  'notes': 'modelos y nivel de pensamiento',
  'published_at': '2026-09-28T12:00:00.000Z',
  ...over,
});

/// SHA-256 de lo que sirve el mock de APK (3 MB de `0x41`, precomputado con
/// `hashlib`: calcularlo en Dart-JIT en cada carga colgaba el runner).
/// Así la verificación pasa en los tests de descarga entera y el test de
/// mismatch lo rompe a propósito pasándole otro.
const String kApkSha =
    'a57493c037eb3a8a86ff87072edde226110455cd7fdab2f87bb4df072f67ffb0';

UpdateService service({required MockClient mock, int versionCode = 1}) {
  final s = UpdateService(client: mock, fallbackVersionCode: versionCode);
  s.manifestUrl = Uri.parse('https://example.test/latest.json');
  return s;
}

void main() {
  group('UpdateInfo.tryParse', () {
    test('lee el manifiesto publicado', () {
      final info = UpdateInfo.tryParse(manifest({}))!;
      expect(info.version, '1.1.0');
      expect(info.versionCode, 2);
      expect(info.apkUrl, 'https://example.test/app-release.apk');
      expect(info.notes, 'modelos y nivel de pensamiento');
    });

    test('acepta build_number como alias de versionCode', () {
      final body = jsonEncode({
        'version': '2.0.0',
        'build_number': 7,
        'apk': 'https://example.test/a.apk',
      });
      final info = UpdateInfo.tryParse(body)!;
      expect(info.versionCode, 7);
      expect(info.apkUrl, 'https://example.test/a.apk');
      expect(info.notes, isEmpty);
    });

    // Un manifiesto a medias es peor que ninguno: instalaría un APK sin poder
    // compararlo. Por eso se rechaza entero en vez de rellenando ceros.
    test('rechaza un manifiesto incompleto', () {
      expect(
        UpdateInfo.tryParse(jsonEncode({'version': '1.1.0'})),
        isNull,
        reason: 'sin versionCode ni url',
      );
      expect(
        UpdateInfo.tryParse(jsonEncode({'versionCode': 2, 'url': 'u'})),
        isNull,
        reason: 'sin version',
      );
      expect(
        UpdateInfo.tryParse(jsonEncode({'version': '1.1.0', 'versionCode': 2})),
        isNull,
        reason: 'sin url',
      );
      expect(
        UpdateInfo.tryParse(
          jsonEncode({'version': '', 'versionCode': 2, 'url': 'u'}),
        ),
        isNull,
        reason: 'version vacía',
      );
    });

    test('no tira con basura ni con un array', () {
      expect(UpdateInfo.tryParse('<!doctype html><html>'), isNull);
      expect(UpdateInfo.tryParse('[]'), isNull);
      expect(UpdateInfo.tryParse(''), isNull);
    });
  });

  group('check: cuándo hay versión nueva', () {
    test('versionCode mayor => hay actualización', () async {
      final s = service(
        mock: MockClient((_) async => http.Response(manifest({}), 200)),
        versionCode: 1,
      );
      expect(await s.check(), isTrue);
      expect(s.state.phase, UpdatePhase.available);
      expect(s.state.info?.version, '1.1.0');
    });

    test(
      'el mismo versionCode NO es actualización (no repetir cada arranque)',
      () async {
        final s = service(
          mock: MockClient((_) async => http.Response(manifest({}), 200)),
          versionCode: 2,
        );
        expect(await s.check(), isFalse);
        expect(s.state.phase, isNot(UpdatePhase.available));
      },
    );

    // Android rechaza un APK con versionCode menor: ofrecerlo sería un botón
    // que no puede hacer nada.
    test('un versionCode menor (release viejo) tampoco', () async {
      final s = service(
        mock: MockClient((_) async => http.Response(manifest({}), 200)),
        versionCode: 9,
      );
      expect(await s.check(), isFalse);
      expect(s.state.phase, isNot(UpdatePhase.available));
    });

    test('un 404 no es una actualización ni un error visible', () async {
      final s = service(
        mock: MockClient((_) async => http.Response('nope', 404)),
      );
      expect(await s.check(), isFalse);
      expect(s.state.phase, UpdatePhase.failed);
      expect(
        s.state.busy,
        isFalse,
        reason: 'no debe quedar "chequeando" colgado',
      );
    });

    // El caso que más importa en un móvil: sin red (o con DNS colgado) la app
    // de chat tiene que seguir funcionando y no quedarse "chequeando".
    test('un timeout no tira y no deja la fase en checking', () async {
      final s = UpdateService(
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(seconds: 30));
          return http.Response(manifest({}), 200);
        }),
        checkTimeout: const Duration(milliseconds: 80),
      );
      s.manifestUrl = Uri.parse('https://example.test/latest.json');
      expect(await s.check(), isFalse);
      expect(s.state.phase, UpdatePhase.failed);
    });

    test('una excepción de red no tira', () async {
      final s = service(
        mock: MockClient((_) async => throw const SocketException('sin red')),
      );
      expect(await s.check(), isFalse);
      expect(s.state.phase, UpdatePhase.failed);
    });

    test('un manifiesto ilegible no tira', () async {
      final s = service(
        mock: MockClient((_) async => http.Response('{ roto', 200)),
      );
      expect(await s.check(), isFalse);
      expect(s.state.phase, UpdatePhase.failed);
    });

    test('sin sha256 no hay update: no se instala a ciegas', () async {
      // ADJUDICADO 2026-10-11: el manifiesto trae sha256 (lo genera
      // publish-update.ps1) y el check lo exige. Sin huella no hay qué
      // verificar antes de `ready`, así que es fallo claro, no update.
      final s = service(
        mock: MockClient(
          (_) async => http.Response(manifest({'sha256': ''}), 200),
        ),
        versionCode: 1,
      );
      expect(await s.check(), isFalse);
      expect(s.state.phase, UpdatePhase.failed);
      expect(s.state.error, contains('sha256'));
    });

    test('una URL de APK que no es https no es update', () async {
      final s = service(
        mock: MockClient(
          (_) async => http.Response(
            manifest({'url': 'http://example.test/app-release.apk'}),
            200,
          ),
        ),
        versionCode: 1,
      );
      expect(await s.check(), isFalse);
      expect(s.state.phase, UpdatePhase.failed);
      expect(s.state.error, contains('https'));
    });

    test('el throttle no repega a la red antes de 24 h', () async {
      var calls = 0;
      final s = service(
        mock: MockClient((_) async {
          calls++;
          return http.Response(manifest({}), 200);
        }),
        versionCode: 1,
      );
      expect(await s.check(), isTrue);
      expect(await s.check(), isTrue, reason: 'sale de lo ya sabido');
      expect(calls, 1, reason: 'el segundo check no toca la red');
    });

    test('force salta el throttle ("buscar ahora")', () async {
      var calls = 0;
      final s = service(
        mock: MockClient((_) async {
          calls++;
          return http.Response(manifest({}), 200);
        }),
        versionCode: 1,
      );
      expect(await s.check(), isTrue);
      expect(await s.check(force: true), isTrue);
      expect(calls, 2);
    });

    test('un fallo no consume la ventana del throttle', () async {
      var calls = 0;
      final s = service(
        mock: MockClient((_) async {
          calls++;
          if (calls == 1) return http.Response('caído', 500);
          return http.Response(manifest({}), 200);
        }),
        versionCode: 1,
      );
      expect(await s.check(), isFalse);
      expect(await s.check(), isTrue, reason: 'el fallo no silencia 24 h');
      expect(calls, 2);
    });
  });

  group('UpdateState', () {
    test('progreso null cuando el server no manda Content-Length', () {
      const s = UpdateState(phase: UpdatePhase.downloading, received: 900);
      expect(s.progress, isNull, reason: '0/0 no debe pintar progreso falso');
    });

    test('progreso acotado entre 0 y 1', () {
      const s = UpdateState(
        phase: UpdatePhase.downloading,
        received: 50,
        total: 100,
      );
      expect(s.progress, 0.5);
      const over = UpdateState(
        phase: UpdatePhase.downloading,
        received: 200,
        total: 100,
      );
      expect(over.progress, 1.0);
    });

    test('clearError borra el error anterior', () {
      const s = UpdateState(phase: UpdatePhase.failed, error: 'HTTP 500');
      expect(
        s.copyWith(phase: UpdatePhase.checking, clearError: true).error,
        isNull,
      );
      expect(s.copyWith(phase: UpdatePhase.checking).error, 'HTTP 500');
    });
  });

  group('sha256 sin dependencias', () {
    test('vectores del estándar', () {
      expect(
        UpdateService.sha256Hex(utf8.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        UpdateService.sha256Hex(const <int>[]),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('fingerprint es la huella corta', () {
      final info = UpdateInfo(
        version: '1.1.0',
        versionCode: 2,
        apkUrl: 'https://example.test/a.apk',
        sha256: kApkSha,
      );
      expect(info.fingerprint, '${kApkSha.substring(0, 12)}…');
      expect(info.fingerprint.length, lessThan(info.sha256.length));
    });
  });

  group('la banda no bloquea', () {
    test('se ve sólo cuando hay algo que hacer', () {
      bool shows(UpdatePhase p) => UpdateState.showsBannerFor(p);
      expect(shows(UpdatePhase.idle), isFalse);
      expect(shows(UpdatePhase.checking), isFalse);
      expect(
        shows(UpdatePhase.failed),
        isFalse,
        reason: 'un fallo no se muestra: es ruido, no información',
      );
      expect(shows(UpdatePhase.available), isTrue);
      expect(shows(UpdatePhase.downloading), isTrue);
      expect(shows(UpdatePhase.ready), isTrue);
      expect(
        shows(UpdatePhase.installDenied),
        isTrue,
        reason: 'hay un permiso que conceder: es algo que hacer',
      );
    });

    // `showsBannerFor` es la regla **por fase** y sigue igual: un fallo de
    // `failed` a secas no se muestra. Lo que lo cambia es `canRetry`, que sí
    // necesita mirar si hay `info`: son dos fallos distintos y antes se
    // trataban como uno.
    group('un fallo se puede reintentar sólo si hay algo que bajar', () {
      test('falló la descarga: hay info, se puede volver a bajar', () {
        const s = UpdateState(
          phase: UpdatePhase.failed,
          error: 'SocketException: corte',
          info: UpdateInfo(
            version: '1.1.0',
            versionCode: 2,
            apkUrl: 'https://example.test/app-release.apk',
          ),
        );
        expect(s.canRetry, isTrue);
        expect(s.showsBanner, isTrue);
      });

      test('falló el chequeo: no hay info, no hay nada que reintentar', () {
        // Sin manifest no hay URL, y sin URL un botón "Volver a descargar"
        // sería un botón que no puede hacer nada.
        const s = UpdateState(phase: UpdatePhase.failed, error: 'HTTP 500');
        expect(s.canRetry, isFalse);
        expect(s.showsBanner, isFalse);
      });

      test('sin error no se ofrece reintentar', () {
        const s = UpdateState(
          phase: UpdatePhase.failed,
          info: UpdateInfo(
            version: '1.1.0',
            versionCode: 2,
            apkUrl: 'https://example.test/app-release.apk',
          ),
        );
        expect(s.canRetry, isFalse, reason: 'no hay motivo que contar');
      });
    });

    test('en `idle` la banda no ocupa ni un píxel', () {
      const banner = UpdateBanner(
        state: UpdateState(),
        onDownload: _noop,
        onInstall: _noop,
        onDismiss: _noop,
      );
      expect(banner.visible, isFalse);
    });

    // Un APK de 30 MB en datos móviles se corta seguido. Sin botón de reintento
    // el usuario se queda sin update hasta cerrar y reabrir la app, que es lo
    // único que reiniciaba el chequeo.
    testWidgets('con la descarga cortada aparece el botón de volver a bajar', (
      tester,
    ) async {
      var descargas = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UpdateBanner(
              state: const UpdateState(
                phase: UpdatePhase.failed,
                error: 'SocketException: se perdió la conexión',
                info: UpdateInfo(
                  version: '1.1.0',
                  versionCode: 2,
                  apkUrl: 'https://example.test/app-release.apk',
                ),
              ),
              onDownload: () => descargas++,
              onInstall: () {},
              onDismiss: () {},
            ),
          ),
        ),
      );

      expect(find.byKey(UpdateBanner.retryKey), findsOneWidget);
      expect(find.text('Volver a descargar'), findsOneWidget);
      // El motivo va **en la banda**: el usuario mira la banda justo cuando
      // decide si reintentar, y ahí es donde tiene que estar el dato.
      expect(find.textContaining('se perdió la conexión'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Volver a descargar'));
      await tester.pump();
      expect(descargas, 1, reason: 'el botón tiene que reintentar la descarga');
      // Y no puede instalar: no hay archivo.
      expect(find.text('Instalar'), findsNothing);
    });

    testWidgets('con el chequeo fallido NO aparece el botón', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UpdateBanner(
              state: const UpdateState(
                phase: UpdatePhase.failed,
                error: 'HTTP 500',
              ),
              onDownload: () {},
              onInstall: () {},
              onDismiss: () {},
            ),
          ),
        ),
      );
      expect(find.byKey(UpdateBanner.retryKey), findsNothing);
      expect(find.text('Volver a descargar'), findsNothing);
    });

    testWidgets('descargando muestra MB totales y el fingerprint', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UpdateBanner(
              state: UpdateState(
                phase: UpdatePhase.downloading,
                received: 1572864,
                total: 3145728,
                info: UpdateInfo(
                  version: '1.1.0',
                  versionCode: 2,
                  apkUrl: 'https://example.test/a.apk',
                  sha256: kApkSha,
                ),
              ),
              onDownload: () {},
              onInstall: () {},
              onDismiss: () {},
            ),
          ),
        ),
      );
      expect(find.text('Descargando 1.5 MB de 3.0 MB (50%)'), findsOneWidget);
    });

    testWidgets('lista para instalar muestra el fingerprint', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UpdateBanner(
              state: UpdateState(
                phase: UpdatePhase.ready,
                info: UpdateInfo(
                  version: '1.1.0',
                  versionCode: 2,
                  apkUrl: 'https://example.test/a.apk',
                  sha256: kApkSha,
                ),
              ),
              onDownload: () {},
              onInstall: () {},
              onDismiss: () {},
            ),
          ),
        ),
      );
      expect(find.textContaining('SHA-256 ${kApkSha.substring(0, 12)}'), findsOneWidget);
      expect(find.text('Instalar'), findsOneWidget);
    });

    testWidgets('sin permiso la banda lo dice y ofrece abrir ajustes', (
      tester,
    ) async {
      var installs = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UpdateBanner(
              state: const UpdateState(
                phase: UpdatePhase.installDenied,
                error: 'Falta el permiso para instalar aplicaciones.',
                info: UpdateInfo(
                  version: '1.1.0',
                  versionCode: 2,
                  apkUrl: 'https://example.test/a.apk',
                ),
              ),
              onDownload: () {},
              onInstall: () => installs++,
              onDismiss: () {},
            ),
          ),
        ),
      );
      expect(
        find.text('Falta el permiso para instalar aplicaciones.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Permitir instalación'));
      await tester.pump();
      expect(installs, 1);
    });
  });

  // ─────────────────────── el archivo a medias en el disco ───────────────────

  group('una descarga cortada no deja un archivo que parezca completo', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('openher-update');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('ai.openher/install'),
            (call) async => call.method == 'updatesDir' ? dir.path : null,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('ai.openher/install'),
              null,
            ),
      );
    });

    File apk() => File('${dir.path}${Platform.pathSeparator}openher-1.1.0.apk');

    test('la descarga se corta a mitad y el archivo se borra', () async {
      // **Por qué importa.** Sin el borrado queda un archivo con el nombre
      // correcto. Pasa el piso de los 2 MB de `_alreadyDownloaded`, y el
      // próximo arranque —o el reintento— lo da por bueno y saltea la descarga:
      // el instalador recibe un APK truncado y falla sin explicar nada.
      final s = _servicio(_ManifestoYApk(cortaApkEnElIntento: 1));
      expect(await s.check(), isTrue);
      expect(await s.download(), isFalse);
      expect(s.state.phase, UpdatePhase.failed);
      expect(
        apk().existsSync(),
        isFalse,
        reason: 'un archivo de 3 MB con el nombre del APK es un APK truncado',
      );
    });

    test('una descarga que termina sí deja el archivo', () async {
      // El otro lado del mismo invariante: si el borrado fuera incondicional,
      // la app nunca podría instalar y esto no lo denunciaría nadie.
      final s = _servicio(_ManifestoYApk(cortaApkEnElIntento: 0));
      expect(await s.check(), isTrue);
      expect(await s.download(), isTrue);
      expect(s.state.phase, UpdatePhase.ready);
      expect(apk().existsSync(), isTrue);
    });

    test('reintentar tras un corte vuelve a bajar y queda lista', () async {
      final cliente = _ManifestoYApk(cortaApkEnElIntento: 1);
      final s = _servicio(cliente);
      expect(await s.check(), isTrue);
      expect(await s.download(), isFalse, reason: 'el primer intento se corta');
      expect(s.state.canRetry, isTrue, reason: 'y se puede volver a intentar');

      expect(await s.download(), isTrue, reason: 'el segundo va completo');
      expect(s.state.phase, UpdatePhase.ready);
      // **Volver a descargar es volver a pegarle al server**, no aceptar lo que
      // quedó en el disco. Sin esta cuenta el test pasa aunque el reintento se
      // salte la descarga por el archivo a medias y deje el APK truncado listo
      // para instalar: `intentosApk` se quedaría en 1.
      expect(
        cliente.intentosApk,
        2,
        reason:
            'el reintento tiene que descargar de nuevo, no aceptar el parcial',
      );
      expect(apk().existsSync(), isTrue);
    });

    test('un sha256 distinto no llega a ready y el archivo se borra', () async {
      // El guard: sin verificación, un APK inyectado en el medio llegaría al
      // instalador. Si este test cae con `ready`, la verificación se perdió.
      final s = UpdateService(
        client: _ShaFalso(_ManifestoYApk(cortaApkEnElIntento: 0)),
        fallbackVersionCode: 1,
      )..manifestUrl = Uri.parse('https://example.test/latest.json');
      expect(await s.check(), isTrue);
      expect(await s.download(), isFalse);
      expect(s.state.phase, UpdatePhase.failed);
      expect(s.state.error, contains('sha256'));
      expect(
        apk().existsSync(),
        isFalse,
        reason: 'el APK que no coincide no se guarda',
      );
    });

    test('cancelar cierra y borra el parcial', () async {
      final s = _servicio(_ApkLento());
      expect(await s.check(), isTrue);
      final pendiente = s.download();
      // Deja que la descarga arranque de verdad antes de cancelarla.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(s.state.phase, UpdatePhase.downloading);
      s.cancelDownload();
      expect(await pendiente, isFalse);
      expect(s.state.phase, UpdatePhase.failed);
      expect(s.state.error, contains('cancelada'));
      expect(
        apk().existsSync(),
        isFalse,
        reason: 'cancelar no deja un parcial con el nombre correcto',
      );
    });

    test('tras descargar ok sólo queda el APK nuevo', () async {
      final viejo = File(
        '${dir.path}${Platform.pathSeparator}openher-0.9.0.apk',
      );
      viejo.writeAsBytesSync(const <int>[1, 2, 3]);
      final s = _servicio(_ManifestoYApk(cortaApkEnElIntento: 0));
      expect(await s.check(), isTrue);
      expect(await s.download(), isTrue);
      expect(apk().existsSync(), isTrue, reason: 'el nuevo queda');
      expect(viejo.existsSync(), isFalse, reason: 'el viejo se limpia');
    });

    test('sin permiso de instalar queda en installDenied con motivo', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('ai.openher/install'),
            (call) async {
              return switch (call.method) {
                'updatesDir' => dir.path,
                'canRequestPackageInstalls' => false,
                'openInstallSettings' => true,
                _ => null,
              };
            },
          );
      apk().writeAsBytesSync(const <int>[1, 2, 3]);
      final s = _servicio(_ManifestoYApk(cortaApkEnElIntento: 0));
      expect(await s.check(), isTrue);
      expect(await s.install(), isFalse);
      expect(s.state.phase, UpdatePhase.installDenied);
      expect(s.state.error, contains('permiso'));
      expect(s.state.showsBanner, isTrue);
    });
  });
}

/// El servicio de los tests de disco: el canal nativo de `updatesDir` lo
/// mockea el `setUp` del grupo.
UpdateService _servicio(http.Client cliente) =>
    UpdateService(client: cliente, fallbackVersionCode: 1)
      ..manifestUrl = Uri.parse('https://example.test/latest.json');

/// Envuelve un cliente y le cambia el sha256 del manifiesto por uno falso: el
/// APK que baja es el bueno pero el manifiesto miente, como en un MITM.
class _ShaFalso extends http.BaseClient {
  _ShaFalso(this.inner);

  final http.BaseClient inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final res = await inner.send(request);
    if (!request.url.toString().endsWith('.json')) return res;
    final body = await res.stream.bytesToString();
    final map = jsonDecode(body) as Map<String, dynamic>;
    map['sha256'] = '0' * 64;
    final fixed = utf8.encode(jsonEncode(map));
    return http.StreamedResponse(
      Stream<List<int>>.value(fixed),
      res.statusCode,
      contentLength: fixed.length,
      request: request,
    );
  }
}

/// Cliente con un APK lento (100 × 64 KB con pausas): deja que el test
/// cancele a mitad de la descarga, que con el mock instantáneo no se puede.
class _ApkLento extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.toString().endsWith('.json')) {
      final cuerpo = utf8.encode(manifest({}));
      return http.StreamedResponse(
        Stream<List<int>>.value(cuerpo),
        200,
        contentLength: cuerpo.length,
        request: request,
      );
    }
    Stream<List<int>> flujo() async* {
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        yield List<int>.filled(64 * 1024, 0x41);
      }
    }
    return http.StreamedResponse(
      flujo(),
      200,
      contentLength: 100 * 64 * 1024,
      request: request,
    );
  }
}

/// Cliente que responde el **manifiesto** con el JSON de siempre y el **APK**
/// con un stream que se puede cortar.
///
/// Hace falta uno propio porque `MockClient` devuelve la respuesta entera de
/// una: nunca falla en el medio del `await for`, que es exactamente donde se
/// corta una descarga en producción.
class _ManifestoYApk extends http.BaseClient {
  _ManifestoYApk({required this.cortaApkEnElIntento});

  /// En qué intento del APK se corta. `0` = nunca (la descarga va entera).
  final int cortaApkEnElIntento;

  static const int _bytesApk = 3 * 1024 * 1024;

  int intentosApk = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url.toString();
    if (url.endsWith('.json')) {
      final cuerpo = utf8.encode(manifest({}));
      return http.StreamedResponse(
        Stream<List<int>>.value(cuerpo),
        200,
        contentLength: cuerpo.length,
        request: request,
      );
    }
    intentosApk++;
    final hayQueCortar = intentosApk == cortaApkEnElIntento;
    Stream<List<int>> flujo() async* {
      yield List<int>.filled(_bytesApk, 0x41);
      if (hayQueCortar) throw const SocketException('corte a mitad');
    }

    return http.StreamedResponse(
      flujo(),
      200,
      // Promete el doble de lo que manda cuando corta: el `Content-Length` no
      // es la defensa, el borrado del archivo sí.
      contentLength: hayQueCortar ? _bytesApk * 2 : _bytesApk,
      request: request,
    );
  }
}

void _noop() {}
