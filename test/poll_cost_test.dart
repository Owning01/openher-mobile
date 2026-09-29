import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/data/connectivity/network_monitor.dart';
import 'package:openher_mobile/domain/models/message.dart';
import 'package:openher_mobile/ui/features/chat/chat_viewmodel.dart';

/// El poll no puede volver a ser un re-fetch de la página entera.
///
/// La optimización del poll (preguntar con `cursor.previous` en vez de bajar la
/// página) es **silenciosa**: si algo la rompe, la app sigue funcionando igual
/// de *bien*, sólo que vuelve a gastar 25 KB cada 2 s. Nadie lo nota hasta que
/// aparece la factura del teléfono. Por eso el guard mira la **forma de la
/// consulta**, que es lo único que delata la regresión.
///
/// Números medidos contra el server real (2026-09-29), no estimados:
/// - re-fetch de la página (`order=desc, limit=15`): **25.511 bytes**
/// - `cursor.previous` sin nada nuevo: **50 bytes**  → 510x
/// - `cursor.previous` con mensajes nuevos: trae sólo esos
void main() {
  const kConfig = ServerConfig(
    host: '127.0.0.1',
    port: 4098,
    password: 's3cr3t',
  );
  const kSession = 'ses_1';

  /// Cursors opacos, como los que emite el server (base64 que la app no
  /// interpreta). Distintos para poder notar si el ancla se movió.
  const cursorA = 'eyJpZCI6Im1zZ18wMDAiLCJkaXJlY3Rpb24iOiJwcmV2aW91cyJ9';
  const cursorB = 'eyJpZCI6Im1zZ18wMDIiLCJkaXJlY3Rpb24iOiJwcmV2aW91cyJ9';

  /// Un mensaje del server, como objeto (no como texto: si se metiera el JSON
  /// ya encodeado dentro del array, `data` sería una lista de strings y el
  /// viewmodel no parsearía nada).
  Map<String, Object?> userMsg(String id, String texto) => {
    'id': id,
    'type': 'user',
    'time': {'created': 1759000000000, 'completed': 1759000000000},
    'text': texto,
  };

  /// El sobre del server: `data` + `cursor`.
  String page(
    List<Map<String, Object?>> mensajes, {
    String? previous,
    String? next,
  }) => jsonEncode({
    'data': mensajes,
    'cursor': {'previous': previous, 'next': next},
  });

  /// La página completa, con su ancla. Es lo que devuelve `load()` y
  /// `refresh()`, y es la única fuente de `_newerCursor`.
  const paginaCompleta =
      '{"data":[{"id":"msg_0","type":"user",'
      '"time":{"created":1759000000000,"completed":1759000000000},'
      '"text":"hola"}],"cursor":{"previous":"$cursorA","next":"bmV4dA=="}}';

  /// El poll ocioso: 0 ítems y **`previous: null`**, que es lo que devuelve el
  /// server de verdad (medido). El `null` no puede borrar el ancla.
  const pollVacio = '{"data":[],"cursor":{"previous":null,"next":null}}';

  late List<Uri> consultas;
  late List<int> tamanos;

  /// El VM contra un server falso. [respuesta] recibe la consulta para poder
  /// distinguir un poll con cursor de una página completa.
  Future<ChatViewModel> vmCon(
    String Function(Uri) respuesta, {
    int pageSize = 15,
    Duration poll = const Duration(milliseconds: 20),
  }) async {
    consultas = [];
    tamanos = [];
    final cliente = MockClient((req) async {
      consultas.add(req.url);
      final cuerpo = respuesta(req.url);
      tamanos.add(cuerpo.length);
      return http.Response(
        cuerpo,
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final vm = ChatViewModel(
      ApiClient(
        config: kConfig,
        client: cliente,
        timeout: const Duration(seconds: 1),
      ),
      sessionId: kSession,
      // `streamingEnabled: false` fuerza el camino de polling (el mismo que
      // entra con datos móviles). Intervalo cortísimo: el test no espera 2 s.
      policy: DataPolicy(
        onCellular: false,
        pollInterval: poll,
        pageSize: pageSize,
        streamingEnabled: false,
      ),
    );
    addTearDown(vm.dispose);
    return vm;
  }

  /// Deja correr el timer del poll un rato.
  Future<void> tick() =>
      Future<void>.delayed(const Duration(milliseconds: 120));

  /// Las consultas que fueron al server **con cursor**: o sea los polls().
  List<Uri> polls() =>
      consultas.where((u) => u.queryParameters.containsKey('cursor')).toList();

  group('el poll no re-descarga la pagina', () {
    test('la carga inicial es pagina completa y deja el ancla', () async {
      final vm = await vmCon((_) => paginaCompleta);

      await vm.load();

      expect(consultas, hasLength(1));
      final u = consultas.single;
      expect(
        u.queryParameters['order'],
        'desc',
        reason: 'la carga inicial es la verdad de fondo: pagina entera',
      );
      expect(
        u.queryParameters.containsKey('cursor'),
        isFalse,
        reason: 'sin cursor no hay previous que usar',
      );
      expect(u.queryParameters['limit'], '15');
    });

    test('el poll va con cursor y sin order', () async {
      final vm = await vmCon(
        (u) => u.queryParameters.containsKey('cursor')
            ? pollVacio
            : paginaCompleta,
      );

      await vm.load();
      vm.setVisible(true);
      await tick();

      expect(
        polls(),
        isNotEmpty,
        reason: 'el poll tiene que haber disparado. Requests: $consultas',
      );

      for (final u in polls()) {
        expect(
          u.queryParameters.containsKey('order'),
          isFalse,
          reason:
              'con cursor el server lo rechaza: "Cursor cannot be '
              'combined with order" (medido)',
        );
        expect(
          u.queryParameters['cursor'],
          cursorA,
          reason:
              'el poll tiene que ir con el ancla; sin cursor vuelve a '
              'bajar la pagina entera de 25 KB cada 2 s',
        );
      }
    });

    test('el poll ocioso pesa una fraccion de la pagina', () async {
      final vm = await vmCon(
        (u) => u.queryParameters.containsKey('cursor')
            ? pollVacio
            : paginaCompleta,
      );

      await vm.load();
      final bytesPagina = tamanos.first;
      vm.setVisible(true);
      await tick();

      final bytesPoll = polls().length * pollVacio.length;
      expect(
        bytesPoll,
        greaterThan(0),
        reason: 'el poll tiene que pegarle al server',
      );
      expect(
        bytesPoll,
        lessThan(bytesPagina * polls().length ~/ 4),
        reason:
            'un poll ocioso no puede pesar como la pagina entera: '
            'la pagina pesó $bytesPagina y el poll $bytesPoll por vuelta',
      );
    });

    test('el ancla sobrevive a un poll vacio', () async {
      // El punto donde la optimizacion se apaga sola: si `previous: null`
      // borrara el ancla, el poll volveria a la pagina de 25 KB en la vuelta
      // siguiente y nadie se enteraria.
      final vm = await vmCon(
        (u) => u.queryParameters.containsKey('cursor')
            ? pollVacio
            : paginaCompleta,
      );

      await vm.load();
      vm.setVisible(true);
      await tick();

      expect(
        polls().length,
        greaterThanOrEqualTo(3),
        reason:
            'despues de un poll vacio tiene que haber otro poll con el '
            'MISMO cursor (si el ancla se perdio, el siguiente cae en la '
            'pagina entera). Hubo ${polls().length} polls() de '
            '${consultas.length} requests',
      );
      for (final u in polls().skip(1)) {
        expect(
          u.queryParameters['cursor'],
          cursorA,
          reason: 'el ancla no se pierde cuando no hay nada nuevo',
        );
      }
    });

    test(
      'el ancla no se pisa con un previous null que viene con datos',
      () async {
        // El otro camino al mismo bug, y el que el `if (page.data.isEmpty)`
        // **no** tapa: una respuesta que trae mensajes pero cuyo `previous` es
        // null. Si el poll asignara el ancla a ciegas, el siguiente poll caería en
        // la página entera. Acá el server sí puede hacerlo (la página que
        // devuelve es el techo de la conversación), así que se defiende igual.
        var primeraVez = true;
        final vm = await vmCon((u) {
          if (!u.queryParameters.containsKey('cursor')) return paginaCompleta;
          if (primeraVez) {
            primeraVez = false;
            return page([userMsg('msg_1', 'una cosa nueva')], previous: null);
          }
          return page([]);
        });

        await vm.load();
        vm.setVisible(true);
        await tick();

        expect(
          vm.messages,
          hasLength(2),
          reason: 'el mensaje nuevo tiene que entrar',
        );
        final conCursor = polls()
            .map((u) => u.queryParameters['cursor'])
            .toList();
        expect(
          conCursor.length,
          greaterThanOrEqualTo(2),
          reason:
              'hubo ${conCursor.length} polls de ${consultas.length} requests',
        );
        for (final c in conCursor) {
          expect(
            c,
            isNotNull,
            reason:
                'un poll sin cursor vuelve a bajar la pagina entera: '
                'los cursores fueron $conCursor',
          );
        }

        // El invariante que de verdad importa. Mirar sólo si cada poll trae
        // cursor NO alcanza: al perderse el ancla el poll cae a la página
        // completa, y esa página completa **restaura** el cursor, así que a la
        // vuelta siguiente todo parece bien. La regresión se ve en el
        // intermedio: una sola página completa de 25 KB colada en el medio.
        final primeroDelPoll = consultas.indexWhere(
          (u) => u.queryParameters.containsKey('cursor'),
        );
        expect(
          primeroDelPoll,
          greaterThan(0),
          reason: 'hubo que arrancar polleando: $consultas',
        );
        final despues = consultas.sublist(primeroDelPoll);
        final sinCursor = despues
            .where((u) => !u.queryParameters.containsKey('cursor'))
            .toList();
        expect(
          sinCursor,
          isEmpty,
          reason:
              'despues de arrancar el poll con cursor no puede volver a '
              'pedir la pagina completa. Las peticiones sin cursor fueron: '
              '$sinCursor',
        );
      },
    );

    test('el poll trae los mensajes nuevos y en orden', () async {
      // Un poll que nunca trae nada nuevo es un poll roto. Ademas el ancla
      // tiene que avanzar al `previous` de la respuesta con datos.
      var pollsVacios = 0;
      final vm = await vmCon((u) {
        if (!u.queryParameters.containsKey('cursor')) return paginaCompleta;
        if (pollsVacios++ == 0) return pollVacio;
        return page([
          userMsg('msg_1', 'respuesta del agente'),
        ], previous: cursorB);
      });

      await vm.load();
      expect(vm.messages, hasLength(1));

      vm.setVisible(true);
      await tick();

      expect(
        vm.messages,
        hasLength(2),
        reason: 'el poll con cursor tiene que sumar lo nuevo, no filtrarse',
      );
      expect(
        (vm.messages.last as UserMessage).text,
        'respuesta del agente',
        reason:
            'y en orden: el poll con previous llega DESC (medido) y se '
            'invierte antes de ingerir',
      );
      expect(
        polls().last.queryParameters['cursor'],
        cursorB,
        reason: 'el ancla tiene que avanzar al mensaje mas nuevo',
      );
    });
  });
}
