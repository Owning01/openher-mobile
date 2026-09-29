/// Detección del disparador de los menús del compositor (`/` y `@`) y el modelo
/// de lo que ofrecen.
///
/// Va en su propio archivo, y sin `BuildContext`, por una razón concreta: la
/// parte que decide **qué se ofrece y en qué momento** es la que tiene reglas
/// que se rompen en silencio (un menú que se reabre y traga el Enter, un `@`
/// que se dispara en medio de un email). Si esa lógica vive metida en el
/// `State` del compositor, probarla obliga a levantar el árbol de widgets
/// entero y los tests se vuelven tautológicos: verifican que el widget no
/// rompe, no que el menú offerzca lo correcto.
///
/// Reglas medidas contra el cliente web de OpenHer, que es el que las tiene
/// resueltas y también las tiene documentadas con sus trampas:
///
/// - `/` sólo cuenta **al principio del texto o después de un espacio**. Un
///   `http://` o una ruta `C:/Users` no abren el menú de comandos.
/// - Con `/` ya se eligió un comando y se escribieron argumentos
///   (`/compact foco`), el menú **no** se reabre. Si se reabriera, el Enter
///   quedaba atrapado en un ciclo completar → reabrir → completar y había que
///   apretarlo dos o tres veces para mandar el comando.
/// - `@` también sólo al principio o tras espacio, y su consulta termina en el
///   primer espacio (los nombres de archivo con espacio no se pueden Elegir a
///   medias; se acepta el prefijo hasta el espacio).
library;

/// Qué abrió el menú.
enum ComposerTriggerKind {
  /// `/comando`: los comandos de barra del server.
  slash,

  /// `@mencion`: agentes, skills, archivos y recursos MCP.
  at,
}

/// El disparador detectado en el texto: desde dónde va el reemplazo, hasta
/// dónde llega lo que el usuario escribió, y qué está buscando.
final class ComposerTrigger {
  const ComposerTrigger({
    required this.kind,
    required this.start,
    required this.end,
    required this.query,
  });

  final ComposerTriggerKind kind;

  /// Índice del `/` o del `@`. Desde acá arranca el texto a reemplazar.
  final int start;

  /// Índice del cursor. Hasta acá llega lo que el usuario escribió después del
  /// disparador.
  final int end;

  /// Lo escrito entre [start] y [end], sin el disparador. Es el filtro.
  final String query;

  /// El carácter que abre el menú.
  String get char => kind == ComposerTriggerKind.slash ? '/' : '@';

  @override
  String toString() =>
      'ComposerTrigger(${kind.name}, $start..$end, "$query")';
}

/// Qué ofrece un ítem del menú.
enum ComposerSuggestionKind {
  /// Comando de barra del server (`GET /api/command`).
  command,

  /// Acción local que el usuario busca por nombre (`compact`, deshacer). No
  /// viaja al server como comando: cada una tiene su endpoint.
  action,

  /// Agente del server (`GET /api/agent`).
  agent,

  /// Skill del server (`GET /api/skill`).
  skill,

  /// Archivo del proyecto (`GET /api/fs/find`).
  file,

  /// Recurso MCP (`GET /api/mcp/resource`).
  mcp,
}

/// Un ítem del menú.
final class ComposerSuggestion {
  const ComposerSuggestion({
    required this.label,
    required this.kind,
    this.detail = '',
    this.insert = '',
    this.runCommand,
  });

  /// Lo que se ve en negrita. Para un comando es `review`, sin la barra.
  final String label;

  final ComposerSuggestionKind kind;

  /// La línea chica de abajo: la descripción del server.
  final String detail;

  /// Con qué se reemplaza el disparador. Por defecto es el `label`.
  final String insert;

  /// Nombre a mandar en `POST /api/session/{id}/command`, **sin barra**.
  ///
  /// `null` para todo lo que no es un comando del server: las skills y los
  /// agentes se mencionan en el texto y las acciones locales no van al server.
  /// Es la diferencia entre "esto se manda" y "esto se ejecuta acá", y
  /// mandarlo al revés es lo que rompía antes.
  final String? runCommand;

  /// El texto a insertar, resuelto.
  String get insertion => insert.isEmpty ? label : insert;
}

/// Detecta el disparador bajo el cursor, o `null` si no hay ninguno.
///
/// [caret] es la posición del cursor en [text]. Se usa el **texto hasta el
/// cursor**: un `/` que se está escribiendo después de la mitad de la frase
/// cuenta, uno que quedó atrás no.
///
/// [firstWordOnly] es lo que mantiene cerrado el menú de un comando ya
/// elegido con argumentos: la consulta de `/` se corta en el primer espacio,
/// así que `/compact foco` da consulta `compact` y, si además el nombre ya
/// está completo, el caller puede decidir no reabrir.
ComposerTrigger? detectComposerTrigger(
  String text,
  int caret, {
  bool firstWordOnly = true,
}) {
  if (caret < 0 || caret > text.length) return null;
  final upto = text.substring(0, caret);
  if (upto.isEmpty) return null;

  final at = upto.lastIndexOf(RegExp(r'[/@]'));
  if (at < 0) return null;

  final char = upto[at];
  final kind = char == '/'
      ? ComposerTriggerKind.slash
      : ComposerTriggerKind.at;
  if (char != '/' && char != '@') return null;

  // Sólo al principio o después de un espacio. Sin esto, `http://` y
  // `C:/Users` abren el menú de comandos, y `usuario@dominio` abre el de
  // menciones.
  if (at > 0 && !_isBoundary(upto[at - 1])) return null;

  var tail = upto.substring(at + 1);
  if (firstWordOnly) {
    final cut = tail.indexOf(_espacio);
    if (cut >= 0) tail = tail.substring(0, cut);
  }

  return ComposerTrigger(kind: kind, start: at, end: caret, query: tail);
}

final RegExp _espacio = RegExp(r'\s');

bool _isBoundary(String ch) => ch.trim().isEmpty;

/// El nombre de un comando ya escrito con sus argumentos, o `null` si el texto
/// no es un comando completo.
///
/// Es lo que usa el compositor para no reabrir el menú: `/compact ` trae
/// espacio, o sea que el comando ya está elegido y hay argumentos en camino.
///
/// Diferencia con [detectComposerTrigger]: acá no importa el cursor, se
/// analiza el texto entero. `/compact` sin espacio **no** está elegido todavía
/// (el menú tiene que seguir abierto para completarlo); `/compact ` sí.
({String name, String args})? parseSlashCommand(String text) {
  final match = RegExp(r'^/(\S+)(\s+([\s\S]*))?$').firstMatch(text.trim());
  if (match == null) return null;
  return (
    name: match.group(1)!,
    args: (match.group(3) ?? '').trim(),
  );
}

/// Filtra [items] por [query], sin distinguir mayúsculas, contra el `label` y
/// contra el `detail`.
///
/// El corte es de 8: es lo que cabe en el menú, y traer 40 resultados de un
/// `/a` no ayuda a nadie. Un término vacío devuelve los primeros 8, que es el
/// estado en el que se abre el menú recién tipeada la barra.
List<ComposerSuggestion> filterSuggestions(
  List<ComposerSuggestion> items,
  String query, {
  int limit = 8,
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return items.take(limit).toList();
  final out = <ComposerSuggestion>[
    for (final i in items)
      if (i.label.toLowerCase().contains(q) ||
          i.detail.toLowerCase().contains(q))
        i,
  ];
  return out.take(limit).toList();
}
