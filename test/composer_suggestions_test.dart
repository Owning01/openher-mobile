import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/ui/features/chat/composer_suggestions.dart';

/// El menú de `/` y `@`: cuándo se abre, cuándo **no**, y qué se ofrece.
///
/// La parte que se prueba acá es la que se rompe en silencio. Un menú que se
/// reabre después de elegir un comando traga el Enter y obliga a apretarlo dos o
/// tres veces (la trampa está documentada en el cliente web, que la sufrió); un
/// `@` que se dispara en medio de un `usuario@dominio` mete una mención
/// fantasma en el prompt.
void main() {
  group('detectComposerTrigger', () {
    test('la barra al principio abre el menú de comandos', () {
      final t = detectComposerTrigger('/re', 3);
      expect(t, isNotNull);
      expect(t!.kind, ComposerTriggerKind.slash);
      expect(t.start, 0);
      expect(t.query, 're');
    });

    test('la barra después de un espacio también', () {
      // "revisá /re" -> el comando va al final de la frase.
      final t = detectComposerTrigger('revisá /re', 10);
      expect(t, isNotNull);
      expect(t!.kind, ComposerTriggerKind.slash);
      expect(t.query, 're');
    });

    test('una URL NO abre el menú de comandos', () {
      // La barra doble de "http://" y la de "C:/Users" no son comandos.
      expect(detectComposerTrigger('http://x', 8), isNull);
      expect(detectComposerTrigger('C:/Users/perca', 12), isNull);
    });

    test('un email NO abre el menú de menciones', () {
      expect(detectComposerTrigger('escribime a maria@gmail.com', 26), isNull);
    });

    test('la arroba al principio o tras espacio abre menciones', () {
      final a = detectComposerTrigger('@rev', 4);
      expect(a!.kind, ComposerTriggerKind.at);
      final b = detectComposerTrigger('fijate @rev', 11);
      expect(b!.kind, ComposerTriggerKind.at);
      expect(b.query, 'rev');
    });

    test('sin cursor después del disparador no hay menú', () {
      // Escribir "/review" y mover el cursor al principio: no hay nada que
      // ofrecer donde el cursor está.
      expect(detectComposerTrigger('/review', 0), isNull);
    });

    test('el cursor en el medio sí cuenta, y la consulta se corta', () {
      // "/compact foco" con el cursor después de "compact": la consulta es la
      // primera palabra, no "compact foco".
      final t = detectComposerTrigger('/compact foco', 8);
      expect(t!.query, 'compact');
    });

    test('el rango cubre SOLO el disparador, no lo que sigue', () {
      // Este es el rango que usa el compositor para reemplazar. Si `end`
      // fuera el largo del texto, elegir un comando se comería la frase que
      // venía después: "/com| de la api" -> "/compact de la api".
      const text = '/com de la api';
      final t = detectComposerTrigger(text, 4)!;
      expect(t.start, 0);
      expect(t.end, 4);

      final antes = text.substring(0, t.start);
      final despues = text.substring(t.end);
      // El doble espacio es correcto y a propósito: `_accept` mete el
      // insertion **con** su espacio de cierre, y lo que sigue al cursor ya
      // traía un espacio. Quitarlo sería adivinar; lo que se verifica acá es
      // que la frase de atrás sobreviva íntegra, y eso se lee mejor sin el
      // ruido del separador.
      expect('$antes/compact$despues', '/compact de la api');
    });

    test('con frase antes, el rango no la toca', () {
      // Con el cursor al final de "/rev": el rango arranca en la barra, no en el
      // principio de la frase. Ese 7 es el error que hay que cazar: si `start`
      // fuera 0, elegir el comando se comería "fijate " y el mensaje quedaría
      // "/review" suelto.
      const text = 'fijate /rev';
      final t = detectComposerTrigger(text, text.length)!;
      expect(t.start, 7);
      expect(t.end, 11);
      expect(t.query, 'rev');

      final antes = text.substring(0, t.start);
      final despues = text.substring(t.end);
      expect('$antes/review$despues', 'fijate /review');
    });

    test('un disparador anterior no gana si ya se pasó', () {
      // "/uno /dos": el último gana, porque es el que está bajo el cursor.
      final t = detectComposerTrigger('/uno /dos', 9);
      expect(t!.start, 5);
      expect(t.query, 'dos');
    });
  });

  group('parseSlashCommand', () {
    test('comando sin argumentos', () {
      expect(parseSlashCommand('/compact'), (name: 'compact', args: ''));
    });

    test('comando con argumentos', () {
      expect(
        parseSlashCommand('/review el diff de la api'),
        (name: 'review', args: 'el diff de la api'),
      );
    });

    test('con espacio ya hay comando elegido', () {
      // La distinción que evita el ciclo completar->reabrir->completar:
      // "/compact" todavia se completa, "/compact " ya esta elegido.
      expect(parseSlashCommand('/compact ')!.args, '');
    });

    test('texto que no es comando', () {
      expect(parseSlashCommand('hola'), isNull);
      expect(parseSlashCommand('ver /compact'), isNull);
    });
  });

  group('filterSuggestions', () {
    const items = [
      ComposerSuggestion(
        label: 'review',
        kind: ComposerSuggestionKind.command,
        detail: 'review changes',
      ),
      ComposerSuggestion(
        label: 'init',
        kind: ComposerSuggestionKind.command,
        detail: 'guided AGENTS.md setup',
      ),
      ComposerSuggestion(
        label: 'compact',
        kind: ComposerSuggestionKind.action,
        detail: 'resume la conversacion',
      ),
    ];

    test('consulta vacia trae los primeros', () {
      expect(filterSuggestions(items, ''), hasLength(3));
    });

    test('filtra por label sin distinguir mayusculas', () {
      expect(filterSuggestions(items, 'REV').single.label, 'review');
    });

    test('filtra tambien por la descripcion', () {
      expect(filterSuggestions(items, 'guided').single.label, 'init');
    });

    test('corta a 8', () {
      final many = [
        for (var i = 0; i < 40; i++)
          ComposerSuggestion(label: 'c$i', kind: ComposerSuggestionKind.command),
      ];
      expect(filterSuggestions(many, 'c'), hasLength(8));
    });

    test('sin coincidencias devuelve vacio, no todos', () {
      expect(filterSuggestions(items, 'zzz'), isEmpty);
    });
  });

  group('ComposerSuggestion', () {
    test('sin insert propio usa el label', () {
      const s = ComposerSuggestion(
        label: 'review',
        kind: ComposerSuggestionKind.command,
      );
      expect(s.insertion, 'review');
    });

    test('runCommand es null salvo en los comandos del server', () {
      // La diferencia entre "esto se manda" y "esto se ejecuta aca": mandarlo
      // al reves es lo que rompia.
      const cmd = ComposerSuggestion(
        label: 'review',
        kind: ComposerSuggestionKind.command,
        runCommand: 'review',
      );
      const accion = ComposerSuggestion(
        label: 'compact',
        kind: ComposerSuggestionKind.action,
      );
      const skill = ComposerSuggestion(
        label: 'debug',
        kind: ComposerSuggestionKind.skill,
      );
      expect(cmd.runCommand, 'review');
      expect(accion.runCommand, isNull);
      expect(skill.runCommand, isNull);
    });
  });
}
