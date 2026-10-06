import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/ui/features/chat/turn_activity.dart';

/// Los cinco bugs que reportó el usuario, fijados uno por uno.
///
/// Ninguno de estos tests existía, y los cinco bugsuveñeron porque el código
/// se había escrito leyendo el spec en vez de contra el server.
void main() {
  group('1) cargar los mensajes anteriores', () {
    test('con cursor NO manda order: el server los rechaza juntos', () async {
      // Medido 2026-09-28 contra `:4098`:
      //   ...&order=asc&cursor=eyJ...  ->  InvalidCursorError:
      //                                    "Cursor cannot be combined with order"
      // El cursor es un base64 que ya lleva `order` y `direction` adentro, así
      // que mandar `order` además es redundante **y** prohibido.
      final seen = <Uri>[];
      final api = ApiClient(
        config: const ServerConfig(host: 'h', port: 1, password: 'p'),
        client: MockClient((req) async {
          seen.add(req.url);
          return http.Response(
            jsonEncode({'data': <Object?>[]}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        backoff: (_) => Duration.zero,
      );

      // La primera página: cursor todavía no hay, `order` sí.
      await api.listMessages('ses_1', limit: 30, order: 'desc');
      expect(seen.last.queryParameters['order'], 'desc');
      expect(seen.last.queryParameters.containsKey('cursor'), isFalse);

      // La segunda página: hay cursor, así que `order` desaparece solo.
      await api.listMessages(
        'ses_1',
        limit: 30,
        order: 'asc',
        cursor: 'eyJpZCI6Im1zZ18iLCJvcmRlciI6ImRlc2MifQ',
      );
      expect(
        seen.last.queryParameters.containsKey('order'),
        isFalse,
        reason: 'con cursor, order no se manda: da 400',
      );
      expect(
        seen.last.queryParameters['cursor'],
        'eyJpZCI6Im1zZ18iLCJvcmRlciI6ImRlc2MifQ',
      );
    });
  });

  group('3) las herramientas van en un bloque con alto fijo', () {
    // Adjudicado 2026-10-03. El criterio original era `lessThan(260)`, atado al
    // tope de 148 px. Se|subió a 900 px **por pedido explícito**: con 148 la lista
    // cortaba a menos de cinco filas, así que un turno normal de agente (8+ tools)
    // se leía a medias y había que scrollear DENTRO de la caja, que es un scroll
    // anidado dentro del scroll del chat.
    //
    // Lo que este test protege **no cambia**: que siga siendo un **tope** y no un
    // mínimo. Si dejara de serlo, un turno con 40 tools vuelve a medir 40 filas y
    // el chat se hace largo, que es el síntoma que se reportó originalmente. Para
    // que eso sea verificable hace falta un techo, no un suelo: por eso ahora se
    // afirma el techo y que la caja exists, y elalto que de verdad toma la lista
    // con 14 tools lo mide `chat_render_test.dart`, grupo 'la caja del turno'.
    test('kToolListMaxHeight es un tope real, no un mínimo', () {
      expect(kToolListMaxHeight, greaterThan(0));
      expect(
        kToolListMaxHeight,
        lessThanOrEqualTo(1000),
        reason:
            'tiene que haber un techo: sin él, 40 tools miden 40 filas y el chat '
            'se hace largo. El techo es 900 px, no 148, a pedido del usuario.',
      );
      expect(TurnActivityBox.headKey, isNotNull);
    });
  });

  group('2) el manifest habilita el dictado', () {
    // El motivo por el que el micrófono no funcionaba no estaba en el código
    // Dart sino en el manifest: Android 11+ (API 30) exige declarar
    // `android.speech.RecognitionService` en `<queries>` para siquiera poder
    // **ver** el servicio. Sin eso, `speech_to_text` responde que no hay
    // dictado y el botón queda muerto sin mostrar error.
    test('declara el servicio de dictado y el permiso de audio', () {
      final manifest = _readManifest();
      expect(manifest, isNotEmpty, reason: 'no se encontró el AndroidManifest');
      expect(
        manifest,
        contains('android.speech.RecognitionService'),
        reason: 'sin esta query, Android 11+ no deja ver el servicio de voz',
      );
      expect(
        manifest,
        contains('android.permission.RECORD_AUDIO'),
        reason: 'sin permiso de audio no hay dictado',
      );
    });
  });
}

/// Lee el manifest desde el repo, sin depender del directorio de trabajo.
String _readManifest() {
  const candidates = <String>[
    'android/app/src/main/AndroidManifest.xml',
    'G:/Proyectos/openher-mobile/android/app/src/main/AndroidManifest.xml',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) return file.readAsStringSync();
  }
  return '';
}
