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
String manifest(Map<String, Object?> over) => jsonEncode({
  'version': '1.1.0',
  'versionCode': 2,
  'url': 'https://example.test/app-release.apk',
  'notes': 'modelos y nivel de pensamiento',
  'published_at': '2026-09-28T12:00:00.000Z',
  ...over,
});

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
  });
}

/// El servicio de los tests de disco: el canal nativo de `updatesDir` lo
/// mockea el `setUp` del grupo.
UpdateService _servicio(http.Client cliente) =>
    UpdateService(client: cliente, fallbackVersionCode: 1)
      ..manifestUrl = Uri.parse('https://example.test/latest.json');

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
