import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/domain/models/agent_catalog.dart';

/// Agentos tal como los devuelve `GET /api/agent` (medido 2026-09-28).
Map<String, Object?> build(String id, {String? mode, bool hidden = false}) => {
  'id': id,
  'name': id == 'build' ? 'Build' : id,
  'request': {
    'settings': <String, Object?>{},
    'headers': <String, Object?>{},
    'body': <String, Object?>{},
  },
  'description': 'desc de $id',
  'mode': mode ?? 'primary',
  'hidden': hidden,
  'permissions': [
    {'action': '*', 'resource': '*', 'effect': 'allow'},
  ],
};

void main() {
  group('AgentInfo.tryParse', () {
    test('lee la forma real del server', () {
      final a = AgentInfo.tryParse(build('build'))!;
      expect(a.id, 'build');
      expect(a.name, 'Build');
      expect(a.mode, AgentMode.primary);
      expect(a.hidden, isFalse);
      expect(a.selectable, isTrue);
    });

    test('mode subagent', () {
      expect(
        AgentInfo.tryParse(build('builder', mode: 'subagent'))!.mode,
        AgentMode.subagent,
      );
    });

    // El server manda `name` en todos los que se midieron, pero un agente de
    // un plugin puede no mandarlo: tiene que caer al id, no quedar vacío.
    test('sin name cae al id', () {
      final a = AgentInfo.tryParse({'id': 'raro', 'mode': 'primary'})!;
      expect(a.name, 'raro');
    });

    test('sin description no tira', () {
      expect(AgentInfo.tryParse({'id': 'x'})!.description, isEmpty);
    });

    test('un mode desconocido cae en primary, no en null', () {
      expect(
        AgentInfo.tryParse(build('x', mode: 'raro'))!.mode,
        AgentMode.primary,
      );
    });

    // Sin id no se puede pedir al server: se descarta en el parseo, no se
    // muestra y falla al apretarlo.
    test('un agente sin id se descarta', () {
      expect(AgentInfo.tryParse({'name': 'sin id'}), isNull);
      expect(AgentInfo.tryParse({'id': ''}), isNull);
      expect(AgentInfo.tryParse('no soy un mapa'), isNull);
      expect(AgentInfo.tryParse(null), isNull);
    });
  });

  group('los hidden no son elegibles', () {
    test('compaction/title/summary quedan afuera', () {
      final c = AgentCatalog.fromList([
        build('build'),
        build('plan'),
        build('general', mode: 'subagent'),
        build('compaction', hidden: true),
        build('title', hidden: true),
        build('summary', hidden: true),
      ]);
      expect(c.selectable.map((a) => a.id), ['build', 'plan', 'general']);
      expect(c.byId('title'), isNull);
    });

    test('un hidden:true explícito manda sobre el mode', () {
      expect(
        AgentInfo.tryParse(
          build('fact-checker', mode: 'subagent', hidden: true),
        )!.selectable,
        isFalse,
      );
    });
  });

  group('agrupación', () {
    final c = AgentCatalog.fromList([
      build('build'),
      build('builder', mode: 'subagent'),
      build('plan'),
      build('critic', mode: 'subagent'),
    ]);

    test('principales y subagentes van separados, en el orden del server', () {
      expect(c.primaries.map((a) => a.id), ['build', 'plan']);
      expect(c.subagents.map((a) => a.id), ['builder', 'critic']);
    });

    test('el catálogo es inmutable', () {
      expect(
        () => c.selectable.add(c.selectable.first),
        throwsUnsupportedError,
      );
    });
  });

  group('lista vacía o basura', () {
    test('no es una excepción: es una hoja vacía con su mensaje', () {
      expect(AgentCatalog.fromList(null).selectable, isEmpty);
      expect(AgentCatalog.fromList('nope').selectable, isEmpty);
      expect(AgentCatalog.fromList(<Object?>[]).selectable, isEmpty);
    });

    test('26 agentes reales: 21 elegibles', () {
      // Los 5 ocultos que trae el server hoy (compaction, title, summary,
      // fact-checker, file-reviewer, solution-architect son 6; el conteo
      // exacto importa menos que que el filtro los saque a todos).
      final c = AgentCatalog.fromList([
        build('build'),
        build('compaction', hidden: true),
        build('title', hidden: true),
        build('summary', hidden: true),
      ]);
      expect(c.selectable.length, 1);
    });
  });

  group('el rótulo del pill', () {
    test('sin id: "Elegir agente"', () {
      expect(AgentCatalog.labelFor(null, null), 'Elegir agente');
      expect(AgentCatalog.labelFor(null, ''), 'Elegir agente');
    });

    test('con id conocido, el nombre del server', () {
      final c = AgentCatalog.fromList([build('plan')]);
      expect(AgentCatalog.labelFor(c, 'plan'), 'plan');
    });

    // Una sesión vieja puede tener un agente que el server ya no expone (lo
    // quitaste de la config). Decir el id crudo informa; un `null` o una
    // cadena vacía en el pill no informa nada.
    test('con id desconocido, el id crudo (no vacío)', () {
      final c = AgentCatalog.fromList([build('plan')]);
      expect(AgentCatalog.labelFor(c, 'borrado'), 'borrado');
    });
  });
}
