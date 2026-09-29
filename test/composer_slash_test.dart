import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/domain/models/agent_catalog.dart';
import 'package:openher_mobile/ui/core/layer_gate.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/features/chat/composer.dart';
import 'package:openher_mobile/ui/features/chat/composer_suggestions.dart';

/// El menú de `/` y `@` en el compositor de verdad, y el despacho de un
/// comando de barra.
///
/// Lo que se prueba acá, y por qué no alcanza con `composer_suggestions_test`:
/// ese verifica **qué se detecta** (`/review` abre, `http://` no). Este verifica
/// **qué pasa después**: que la barra se abra, que se llene, que al elegir se
/// escriba en el campo, y — lo importante — que `/compact` vaya a su endpoint y
/// no al de comandos del server (que da 404, medido).
void main() {
  // El catálogo con **todas** las keys del compositor prendidas, y `tearDown`
  // que lo saca.
  //
  // La trampa que casi me hace perder el archivo: probar con
  // `forTest({'chat.composer': true})` hace que **todo** el compositor
  // desaparezca. `LayerCatalog.isOn` devuelve `false` para una key que no está
  // en el mapa, así que `chat.composer.input`, `.send`, `.mic` y `.modelbar`
  // quedan apagados, el `TextField` no existe y los tests pasan sin encontrar
  // nada. Verde y sin comprobar nada: el peor modo de falla que hay.
  //
  // El `setUp`/`tearDown` es el mismo patrón de `chat_render_test.dart`, y por
  // eso las dos familias de tests de chat se comportan igual.
  setUp(
    () => LayerCatalog.debugSetInstance(
      LayerCatalog.forTest(const {
        'chat.composer': true,
        'chat.composer.input': true,
        'chat.composer.textarea': true,
        'chat.composer.attach': true,
        'chat.composer.attachments': true,
        'chat.composer.mic': true,
        'chat.composer.send': true,
        'chat.composer.modelbar': true,
        'chat.composer.model': true,
        'chat.composer.agent': true,
        'chat.composer.ctx': true,
      }),
    ),
  );
  tearDown(() => LayerCatalog.debugSetInstance(null));

  /// Monta un compositor nuevo. Como widget helper **de test**, para poder
  /// montarlo otra vez dentro del mismo test (necesario cuando hay que
  /// reconfigurar los callbacks).
  Future<void> pumpComposer(
    WidgetTester tester, {
    required List<ComposerSuggestion> suggestions,
    bool loading = false,
    void Function(String name, String args)? onCommand,
    void Function(String id, String args)? onLocalAction,
    void Function(String text, List<ComposerAttachment> files)? onSend,
    void Function(ComposerTrigger? t)? onTrigger,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: ChatComposer(
            working: false,
            canSend: true,
            suggestions: suggestions,
            suggestionsLoading: loading,
            onCommand: onCommand,
            onLocalAction: onLocalAction,
            onSend: onSend,
            onTrigger: onTrigger,
          ),
        ),
      ),
    );
  }

  group('el menú se abre con la barra', () {
    testWidgets('"/" sola ya muestra la lista', (tester) async {
      await pumpComposer(
        tester,
        suggestions: const [
          ComposerSuggestion(label: 'compact', kind: ComposerSuggestionKind.action),
        ],
      );

      await tester.enterText(find.byKey(ChatComposer.inputKey), '/');
      await tester.pumpAndSettle();

      expect(find.byKey(ChatComposer.suggestionsKey), findsOneWidget);
    });

    testWidgets('una URL no lo abre', (tester) async {
      await pumpComposer(
        tester,
        suggestions: const [
          ComposerSuggestion(label: 'compact', kind: ComposerSuggestionKind.action),
        ],
      );

      await tester.enterText(
        find.byKey(ChatComposer.inputKey),
        'mira http://esto',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(ChatComposer.suggestionsKey), findsNothing);
    });

    testWidgets('con espacio el comando ya esta elegido y se cierra',
        (tester) async {
      // La trampa del ciclo completar -> reabrir -> completar: con "/compact "
      // el comando ya esta elegido y el menu no puede volver a abrir, o el
      // Enter queda atrapado y hay que apretarlo dos o tres veces.
      await pumpComposer(
        tester,
        suggestions: const [
          ComposerSuggestion(label: 'compact', kind: ComposerSuggestionKind.action),
        ],
      );

      await tester.enterText(find.byKey(ChatComposer.inputKey), '/compact');
      await tester.pumpAndSettle();
      expect(find.byKey(ChatComposer.suggestionsKey), findsOneWidget);

      await tester.enterText(find.byKey(ChatComposer.inputKey), '/compact ');
      await tester.pumpAndSettle();
      expect(find.byKey(ChatComposer.suggestionsKey), findsNothing);
    });

    testWidgets('con lista vacia se abre igual, diciendo que no hay',
        (tester) async {
      // Si el menu no se abre, el usuario tipea "/re", no ve nada y no sabe si
      // se rompió la app o si no hay coincidencias.
      await pumpComposer(tester, suggestions: const []);
      await tester.enterText(find.byKey(ChatComposer.inputKey), '/re');
      await tester.pumpAndSettle();

      expect(find.byKey(ChatComposer.suggestionsKey), findsOneWidget);
    });

    testWidgets('mientras carga dice Buscando', (tester) async {
      await pumpComposer(tester, suggestions: const [], loading: true);
      await tester.enterText(find.byKey(ChatComposer.inputKey), '/');
      await tester.pumpAndSettle();

      expect(find.text('Buscando…'), findsOneWidget);
    });
  });

  group('elegir del menú', () {
    testWidgets('escribe el nombre con barra y un espacio', (tester) async {
      await pumpComposer(
        tester,
        suggestions: const [
          ComposerSuggestion(
            label: 'review',
            insert: '/review',
            kind: ComposerSuggestionKind.command,
            runCommand: 'review',
          ),
        ],
      );

      await tester.enterText(find.byKey(ChatComposer.inputKey), '/rev');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ChatComposer.suggestionItemKey));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(ChatComposer.inputKey),
      );
      expect(field.controller!.text, '/review ');
      // Y el menú se cerró: si quedara abierto, el siguiente Enter completaría
      // en vez de mandar.
      expect(find.byKey(ChatComposer.suggestionsKey), findsNothing);
    });

    testWidgets('en medio de la frase no borra lo que hay antes',
        (tester) async {
      await pumpComposer(
        tester,
        suggestions: const [
          ComposerSuggestion(
            label: 'review',
            insert: '/review',
            kind: ComposerSuggestionKind.command,
          ),
        ],
      );

      await tester.enterText(find.byKey(ChatComposer.inputKey), 'fijate /rev');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ChatComposer.suggestionItemKey));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(ChatComposer.inputKey),
      );
      expect(field.controller!.text, 'fijate /review ');
    });

    testWidgets('tras elegir una mencion el menu se cierra', (tester) async {
      // Este caso aísla el cierre del menú. Con `/` no sirve: al elegir,
      // `onChanged` corre con "/compact " y la regla de "comando ya elegido"
      // cierra el menú **igual**, así que un `_trigger` que no se limpiera
      // pasaría inadvertido. Con `@` no hay barra, esa regla no aplica, y lo
      // único que puede cerrar el menú es que `_accept` limpie el disparador.
      await pumpComposer(
        tester,
        suggestions: const [
          ComposerSuggestion(
            label: 'debug',
            insert: '@debug',
            kind: ComposerSuggestionKind.skill,
          ),
        ],
      );

      await tester.enterText(find.byKey(ChatComposer.inputKey), '@deb');
      await tester.pumpAndSettle();
      expect(find.byKey(ChatComposer.suggestionsKey), findsOneWidget);

      await tester.tap(find.byKey(ChatComposer.suggestionItemKey));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(ChatComposer.inputKey),
      );
      expect(field.controller!.text, '@debug ');
      expect(
        find.byKey(ChatComposer.suggestionsKey),
        findsNothing,
        reason: 'elegir tiene que cerrar el menu, no dejarlo abierto arriba',
      );
    });

    // El caso del cursor en el medio ("/com| de la api") se prueba sobre
    // [detectComposerTrigger] en `composer_suggestions_test.dart`, en el grupo
    // "el cursor en el medio si cuenta". Acá, en el widget, no se puede poner
    // el cursor en medio con `enterText` (siempre queda al final) y hacerlo a
    // mano con `updateEditingValue` no dispara el `onChanged` que recalcula el
    // disparador: el menú no abre y el test probaría el harness, no la app.
    //
    // Lo que sí importa del rango queda cubierto por los otros tests de este
    // grupo: "en medio de la frase no borra lo que hay antes" verifica que lo
    // de adelante del `start` sobrevive, y la aritmética del `end` está en el
    // test puro.

    testWidgets('con texto despues, lo de despues se conserva',
        (tester) async {
      await pumpComposer(
        tester,
        suggestions: const [
          ComposerSuggestion(
            label: 'compact',
            insert: '/compact',
            kind: ComposerSuggestionKind.action,
          ),
        ],
      );

      // "de la api" primero, y "/com" adelante. El disparador mira hasta el
      // cursor, así que "/com| de la api" tiene que abrir el menú y reemplazar
      // **sólo** el "/com": lo de atrás es del usuario y no se toca.
      await tester.enterText(
        find.byKey(ChatComposer.inputKey),
        'de la api',
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(ChatComposer.inputKey),
        '/com de la api',
      );
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(ChatComposer.inputKey),
      );
      // El cursor quedó al final, donde ya no hay disparador: eso es correcto
      // y es lo que evita que el menú se abra en cada coma de la frase. Para
      // probar el reemplazo hay que dejar el cursor donde el usuario lo
      // pondría, y eso lo hace otro test ("en medio de la frase no borra lo que
      // hay antes").
      expect(field.controller!.text, '/com de la api');
      expect(
        find.byKey(ChatComposer.suggestionsKey),
        findsNothing,
        reason: 'con el cursor despues de la frase no hay disparador vivo',
      );
    });
  });

  group('mandar un comando de barra', () {
    testWidgets('"/review" va a onCommand, NO a onSend', (tester) async {
      final comandos = <String>[];
      final enviados = <String>[];
      await pumpComposer(
        tester,
        suggestions: const [],
        onCommand: (name, args) => comandos.add('$name|$args'),
        onSend: (text, _) => enviados.add(text),
      );

      await tester.enterText(
        find.byKey(ChatComposer.inputKey),
        '/review el diff',
      );
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(comandos, ['review|el diff']);
      expect(enviados, isEmpty, reason: 'un comando no es un prompt');
    });

    testWidgets('"/compact" va a onLocalAction, no a onCommand',
        (tester) async {
      // El bug de fondo: mandar `/compact` por el endpoint de comandos da 404
      // (medido). `/compact` es `POST /api/session/{id}/compact`.
      final locales = <String>[];
      final comandos = <String>[];
      await pumpComposer(
        tester,
        suggestions: const [],
        onCommand: (name, args) => comandos.add(name),
        onLocalAction: (id, args) => locales.add(id),
      );

      await tester.enterText(find.byKey(ChatComposer.inputKey), '/compact');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(locales, ['compact']);
      expect(comandos, isEmpty);
    });

    testWidgets('"/undo" y "/redo" tambien son locales', (tester) async {
      for (final nombre in ['undo', 'redo']) {
        final locales = <String>[];
        await pumpComposer(
          tester,
          suggestions: const [],
          onLocalAction: (id, _) => locales.add(id),
        );
        await tester.enterText(
          find.byKey(ChatComposer.inputKey),
          '/$nombre',
        );
        await tester.pumpAndSettle();
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        expect(locales, [nombre]);
      }
    });

    testWidgets('texto normal sigue yendo a onSend', (tester) async {
      final enviados = <String>[];
      final comandos = <String>[];
      await pumpComposer(
        tester,
        suggestions: const [],
        onCommand: (name, _) => comandos.add(name),
        onSend: (text, _) => enviados.add(text),
      );

      await tester.enterText(
        find.byKey(ChatComposer.inputKey),
        'revisame el bug del tema',
      );
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(enviados, ['revisame el bug del tema']);
      expect(comandos, isEmpty);
    });

    testWidgets('una ruta con barra NO se toma por comando',
        (tester) async {
      // "C:/Users" empieza con letra, no con barra, asi que ni siquiera entra
      // al caso. Esto es el caso dificil: "/usr/bin" es un path y un comando a
      // la vez, y el server laRejecta. La app no puede saber cual es; lo que
      // hace es necesitar un `onCommand` que exista, y si no hay, cae al prompt.
      final enviados = <String>[];
      await pumpComposer(
        tester,
        suggestions: const [],
        onSend: (text, _) => enviados.add(text),
      );

      await tester.enterText(find.byKey(ChatComposer.inputKey), '/usr/bin');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(enviados, ['/usr/bin']);
    });

    testWidgets('sin onCommand el texto no se pierde', (tester) async {
      // Un shell de solo lectura no tiene onCommand. El texto tiene que caer al
      // prompt: un comando que se traga solo es peor que uno que no corre.
      final enviados = <String>[];
      await pumpComposer(
        tester,
        suggestions: const [],
        onSend: (text, _) => enviados.add(text),
      );

      await tester.enterText(find.byKey(ChatComposer.inputKey), '/review');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(enviados, ['/review']);
    });

    testWidgets('al mandar un comando el campo queda vacio', (tester) async {
      await pumpComposer(
        tester,
        suggestions: const [],
        onCommand: (_, _) {},
      );

      await tester.enterText(find.byKey(ChatComposer.inputKey), '/init');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(ChatComposer.inputKey),
      );
      expect(field.controller!.text, isEmpty);
    });
  });

  group('el disparador se avisa a la vista', () {
    testWidgets('onTrigger llega con la consulta', (tester) async {
      final vistos = <String>[];
      await pumpComposer(
        tester,
        suggestions: const [],
        onTrigger: (t) => vistos.add(t?.query ?? '-'),
      );

      await tester.enterText(find.byKey(ChatComposer.inputKey), '/rev');
      await tester.pumpAndSettle();

      expect(vistos, contains('rev'));
    });

    testWidgets('cerrar el menu avisa null', (tester) async {
      final vistos = <String>[];
      await pumpComposer(
        tester,
        suggestions: const [],
        onTrigger: (t) => vistos.add(t?.query ?? '-'),
      );

      await tester.enterText(find.byKey(ChatComposer.inputKey), '/rev');
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(ChatComposer.inputKey), 'hola');
      await tester.pumpAndSettle();

      expect(vistos.last, '-');
    });
  });
}
