/// La hoja de modelo, de punta a punta: se abre con un server de laboratorio
/// y se toca como un usuario.
///
/// Lo que se verifica acá es lo que **no** se ve leyendo el código:
/// - que los 102 modelos del server real entren en un teléfono chico sin
///   desbordar (un `RenderFlex overflow` en la fila más larga es un bug real,
///   no un detalle de estilo);
/// - que tocar un modelo con niveles despliegue los niveles y **no** lo elija
///   (elegir sin nivel cuando hay niveles es decidir por el usuario);
/// - que cerrar sin tocar devuelva `null` y no "el modelo de la sesión".
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/data/repositories/catalog_repository.dart';
import 'package:openher_mobile/domain/models/message.dart' show ModelRef;
import 'package:openher_mobile/ui/core/app_icon.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/features/chat/model_sheet.dart';

const ServerConfig kConfig = ServerConfig(
  host: '127.0.0.1',
  port: 4098,
  password: 's3cr3t',
);

String modelJson({
  required String id,
  required String providerID,
  required String name,
  String? modelID,
  List<String> efforts = const ['low', 'max'],
  double inputCost = 0,
  double outputCost = 0,
  int context = 1000000,
  String status = 'active',
  bool enabled = true,
}) => jsonEncode({
  'id': id,
  'modelID': modelID ?? id,
  'providerID': providerID,
  'name': name,
  'family': 'longcat',
  'capabilities': {
    'tools': true,
    'input': ['text', 'image'],
    'output': ['text'],
  },
  'variants': [
    for (final effort in efforts)
      {
        'id': effort,
        'settings': {'reasoningEffort': effort},
      },
  ],
  'cost': [
    {'input': inputCost, 'output': outputCost},
  ],
  'status': status,
  'enabled': enabled,
  'limit': {'context': context, 'output': 131072},
});

/// Un server de laboratorio: cuenta los requests y responde lo que le digan.
class FakeServer {
  FakeServer(this.body, {this.status = 200});

  String body;
  int status;
  int calls = 0;

  CatalogRepository repository() => CatalogRepository(
    ApiClient(
      config: kConfig,
      client: MockClient((_) async {
        calls++;
        return http.Response(
          body,
          status,
          headers: {'content-type': 'application/json'},
        );
      }),
      backoff: (_) => Duration.zero,
    ),
  );
}

/// El `space-bunny-free` medido + dos que se le parecen.
const String kSmallCatalog =
    '{"location":{"directory":"G:/code/openher-mobile"},"data":['
    '{"id":"space-bunny-free","modelID":"space-bunny-free",'
    '"providerID":"opencode-go","name":"Space Bunny Free",'
    '"capabilities":{"input":["text","image"]},'
    '"variants":[{"id":"low","settings":{"reasoningEffort":"low"}},'
    '{"id":"max","settings":{"reasoningEffort":"max"}}],'
    '"cost":[{"input":0,"output":0}],"status":"active","enabled":true,'
    '"limit":{"context":1000000,"output":131072}},'
    '{"id":"gpt-5.1-codex","modelID":"gpt-5.1-codex",'
    '"providerID":"openai","name":"GPT 5.1 Codex (una versión larguísima)",'
    '"capabilities":{"input":["text","image","pdf","audio","video"]},'
    '"variants":[],"cost":[{"input":1.25,"output":10}],"status":"beta",'
    '"enabled":true,"limit":{"context":400000,"output":128000}},'
    '{"id":"muse-spark","modelID":"muse-spark-1.3",'
    '"providerID":"opencode-zen","name":"Muse Spark",'
    '"variants":[{"id":"none","settings":{"reasoningEffort":"none"}}],'
    '"cost":[{"input":0,"output":0}],"status":"active","enabled":false,'
    '"limit":{"context":200000,"output":64000}}]}';

/// 102 modelos, con nombres largos y de los dos providers: el caso que rompe
/// una fila.
String bigCatalog(int count) => jsonEncode({
  'location': {'directory': 'G:/code/openher-mobile'},
  'data': [
    for (var i = 0; i < count; i++)
      jsonDecode(
        modelJson(
          id: 'modelo-con-nombre-largo-$i',
          providerID: i.isEven ? 'opencode-go' : 'openai',
          name: 'Modelo de nombre realmente largo número $i para el chat',
          efforts: const ['none', 'low', 'medium', 'high', 'xhigh', 'max'],
          inputCost: 0.5,
          outputCost: 1.5,
        ),
      ),
  ],
});

/// Monta la hoja en un teléfono chico (el `max-width` del `mobile` del
/// prototipo) y devuelve lo que se elige.
Future<List<ModelPick>> pumpSheet(
  WidgetTester tester,
  CatalogRepository catalog, {
  ModelRef? current,
  Size size = const Size(360, 640),
}) async {
  final picks = <ModelPick>[];
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: ModelSheet(
          catalog: catalog,
          current: current,
          onClose: () {},
          onPick: picks.add,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return picks;
}

void main() {
  testWidgets('lista el catálogo real, agrupado por provider', (tester) async {
    final server = FakeServer(kSmallCatalog);
    await pumpSheet(tester, server.repository());

    // Los dos providers, con su encabezado.
    expect(find.text('OPENCODE-GO'), findsOneWidget);
    expect(find.text('OPENAI'), findsOneWidget);
    expect(find.text('OPENCODE-ZEN'), findsOneWidget);
    expect(find.text('Space Bunny Free'), findsOneWidget);
    // Contexto formateado y precio: sólo el modelo que lo declara.
    expect(find.textContaining('1M ctx'), findsOneWidget);
    expect(find.textContaining(r'$1.25 / $10.00'), findsOneWidget);
    // Un modelo apagado se muestra y se avisa: no se esconde.
    expect(find.textContaining('deshabilitado'), findsOneWidget);
  });

  testWidgets('tocar un modelo con niveles los despliega, no lo elige', (
    tester,
  ) async {
    final picks = await pumpSheet(
      tester,
      FakeServer(kSmallCatalog).repository(),
    );

    await tester.tap(
      find.byKey(ModelSheet.rowKey('opencode-go', 'space-bunny-free')),
    );
    await tester.pumpAndSettle();

    expect(picks, isEmpty, reason: 'el primer toque despliega, no elige');
    expect(find.text('Bajo'), findsOneWidget);
    expect(find.text('Máximo'), findsOneWidget);

    // El segundo toque elige modelo + nivel.
    await tester.tap(
      find.byKey(
        ModelSheet.variantKey('opencode-go', 'space-bunny-free', 'max'),
      ),
    );
    await tester.pumpAndSettle();

    expect(picks, hasLength(1));
    expect(picks.single.providerId, 'opencode-go');
    expect(picks.single.modelId, 'space-bunny-free');
    expect(picks.single.variantId, 'max');
  });

  testWidgets('tocar un modelo sin niveles lo elige directo', (tester) async {
    final picks = await pumpSheet(
      tester,
      FakeServer(kSmallCatalog).repository(),
    );

    await tester.tap(find.byKey(ModelSheet.rowKey('openai', 'gpt-5.1-codex')));
    await tester.pumpAndSettle();

    expect(picks, hasLength(1));
    expect(picks.single.modelId, 'gpt-5.1-codex');
    expect(picks.single.variantId, isNull);
  });

  testWidgets('tocar dos veces el mismo modelo lo colapsa', (tester) async {
    await pumpSheet(tester, FakeServer(kSmallCatalog).repository());

    await tester.tap(
      find.byKey(ModelSheet.rowKey('opencode-go', 'space-bunny-free')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Máximo'), findsOneWidget);

    await tester.tap(
      find.byKey(ModelSheet.rowKey('opencode-go', 'space-bunny-free')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Máximo'), findsNothing);
  });

  testWidgets('el buscador filtra por nombre, id y provider', (tester) async {
    await pumpSheet(tester, FakeServer(kSmallCatalog).repository());

    await tester.enterText(find.byKey(ModelSheet.searchKey), 'muse');
    await tester.pumpAndSettle();

    expect(find.text('Muse Spark'), findsOneWidget);
    expect(find.text('Space Bunny Free'), findsNothing);

    await tester.enterText(find.byKey(ModelSheet.searchKey), 'openai');
    await tester.pumpAndSettle();

    expect(find.text('Muse Spark'), findsNothing);
    expect(find.textContaining('GPT 5.1'), findsOneWidget);
  });

  testWidgets('sin coincidencias dice "Sin resultados"', (tester) async {
    await pumpSheet(tester, FakeServer(kSmallCatalog).repository());

    await tester.enterText(find.byKey(ModelSheet.searchKey), 'zzz-no-existe');
    await tester.pumpAndSettle();

    expect(find.byKey(ModelSheet.emptyKey), findsOneWidget);
    expect(find.textContaining('Sin resultados'), findsOneWidget);
    expect(find.byKey(ModelSheet.listKey), findsNothing);
  });

  testWidgets('el modelo de la sesión queda marcado', (tester) async {
    await pumpSheet(
      tester,
      FakeServer(kSmallCatalog).repository(),
      current: const ModelRef(
        id: 'space-bunny-free',
        providerID: 'opencode-go',
      ),
    );

    // El check vive en la fila del modelo actual: se busca el glifo por nombre
    // (es un SVG, no un `Icon` de Material).
    List<String> iconsIn(String providerId, String modelId) => [
      for (final icon in tester.widgetList<AppIcon>(
        find.descendant(
          of: find.byKey(ModelSheet.rowKey(providerId, modelId)),
          matching: find.byType(AppIcon),
        ),
      ))
        icon.name,
    ];

    expect(iconsIn('opencode-go', 'space-bunny-free'), contains('check'));
    expect(iconsIn('openai', 'gpt-5.1-codex'), isNot(contains('check')));
  });

  testWidgets('si el server falla, lo dice y deja reintentar', (tester) async {
    final server = FakeServer('{"message":"se rompió"}', status: 500);
    await pumpSheet(tester, server.repository());

    expect(find.byKey(ModelSheet.errorKey), findsOneWidget);
    expect(find.textContaining('El servidor falló'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
    expect(server.calls, 1);

    // Reintentar con el server arriba trae el catálogo.
    server
      ..body = kSmallCatalog
      ..status = 200;
    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();

    expect(server.calls, 2);
    expect(find.text('Space Bunny Free'), findsOneWidget);
  });

  testWidgets('un catálogo vacío lo dice, sin romper la hoja', (tester) async {
    await pumpSheet(tester, FakeServer('{"data":[]}').repository());

    expect(find.byKey(ModelSheet.emptyKey), findsOneWidget);
    expect(find.text('Reintentar'), findsNothing);
  });

  testWidgets('el HTML del catch-all no rompe la hoja', (tester) async {
    // El server devuelve HTML 200 en vez de JSON: es el error más común contra
    // un build viejo y no puede comerse la pantalla.
    final repo = CatalogRepository(
      ApiClient(
        config: kConfig,
        client: MockClient(
          (_) async => http.Response(
            '<!doctype html><html><body>opencode</body></html>',
            200,
            headers: {'content-type': 'text/html'},
          ),
        ),
        backoff: (_) => Duration.zero,
      ),
    );
    await pumpSheet(tester, repo);

    expect(find.byKey(ModelSheet.errorKey), findsOneWidget);
    expect(find.textContaining('HTML'), findsOneWidget);
  });

  testWidgets('102 modelos entran en un teléfono chico sin desbordar', (
    tester,
  ) async {
    final picks = await pumpSheet(
      tester,
      FakeServer(bigCatalog(102)).repository(),
    );

    expect(find.byKey(ModelSheet.listKey), findsOneWidget);
    // Lo que un `RenderFlex overflow` se come: la excepción del render.
    expect(tester.takeException(), isNull);

    // Y se puede elegir uno del final de la lista, scrolleando. El 101 es
    // impar: es del provider `openai` (el fixture reparte por paridad).
    const last = ('openai', 'modelo-con-nombre-largo-101');
    await tester.dragUntilVisible(
      find.byKey(ModelSheet.rowKey(last.$1, last.$2)),
      find.byKey(ModelSheet.listKey),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ModelSheet.rowKey(last.$1, last.$2)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(picks, isEmpty, reason: 'tiene 6 niveles: el toque los despliega');

    // Los niveles se abren **debajo** de la última fila, o sea fuera de
    // pantalla: hay que scrollear para verlos.
    await tester.drag(find.byKey(ModelSheet.listKey), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('Máximo'), findsOneWidget);
    expect(
      tester.takeException(),
      isNull,
      reason: 'ni la fila del último modelo ni sus niveles desbordan',
    );
  });
}
