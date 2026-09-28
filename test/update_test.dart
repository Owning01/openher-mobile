import 'dart:convert';
import 'dart:io';

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

    test('en `idle` la banda no ocupa ni un píxel', () {
      const banner = UpdateBanner(
        state: UpdateState(),
        onDownload: _noop,
        onInstall: _noop,
        onDismiss: _noop,
      );
      expect(banner.visible, isFalse);
    });
  });
}

void _noop() {}
