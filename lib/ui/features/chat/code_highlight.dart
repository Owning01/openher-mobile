/// Resaltado de sintaxis para los bloques de cÃ³digo del markdown del chat.
///
/// ## Por quÃ© existe
///
/// Los tokens `--code-*` de `tokens.dart` (keyword, string, comment, number,
/// builtin, attr, en los dos brillos) estaban portados desde `tokens.css` desde
/// el primer dÃ­a y **nada los leÃ­a**: el bloque de cÃ³digo se pintaba entero del
/// color del texto, que es justo la parte de un mensaje de agente que mÃ¡s se lee
/// para saber quÃ© lÃ­nea hay que tocar. El cliente desktop sÃ­ lo tiene, con este
/// mismo paquete.
///
/// ## Por quÃ© un archivo aparte
///
/// `message_bubble.dart` ya tiene mÃ¡s de 1.300 lÃ­neas y el resaltado son ~150
/// mÃ¡s de lÃ³gica pura, sin widgets. Dejarla en un archivo propio la hace
/// testeable sin montar el chat entero: [CodeHighlighter.colorFor] es una
/// funciÃ³n pura de tabla, y eso es lo que hay que verificar (que un keyword sea
/// keyword y no texto plano), no el Ã¡rbol de widgets.
///
/// ## El cachÃ©
///
/// `highlight.parse` con autodetecciÃ³n es lo mÃ¡s caro del primer paint: una
/// pantalla de chat puede tener 30 bloques, y el resultado se vuelve a pedir en
/// cada rebuild, scroll y delta de streaming. El [TextSpan] es inmutable, asÃ­ que
/// compartir la instancia es seguro. El LRU estÃ¡ acotado porque la clave retiene
/// el cÃ³digo entero.
library;

import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:highlight/highlight.dart' show highlight, Node;

import '../../core/tokens.dart';

/// Convierte cÃ³digo en [TextSpan] con los colores de los tokens `--code-*`.
class CodeHighlighter {
  const CodeHighlighter();

  /// Entradas mÃ¡ximas del cachÃ© (LRU por re-inserciÃ³n).
  static const int _kMaxEntries = 200;

  /// Bloques mÃ¡s grandes no se cachean: la clave retendrÃ­a el cÃ³digo entero.
  static const int _kMaxCachedChars = 8000;

  /// Por encima de esto ni se intenta: un `highlight.parse` de 60 KB de JSON es
  /// unetisegundo de jank en un telÃ©fono.
  static const int _kMaxParsedChars = 20000;

  /// Spans ya parseados por (cÃ³digo, lenguaje, brillo, estilo base).
  ///
  /// El estilo base va en la clave a propÃ³sito: el `TextSpan` lo lleva embebido,
  /// y si el tema o el tamaÃ±o de fuente cambian y se sirviera el rancio, el
  /// cÃ³digo quedarÃ­a con la fuente del tema anterior.
  static final LinkedHashMap<_CacheKey, TextSpan> _cache =
      LinkedHashMap<_CacheKey, TextSpan>();

  @visibleForTesting
  static int get cacheSize => _cache.length;

  @visibleForTesting
  static void clearCache() => _cache.clear();

  /// El span del bloque. Si algo falla (lenguaje desconocido, parseo vacÃ­o),
  /// devuelve el texto plano: **nunca** una excepciÃ³n.
  ///
  /// Un bloque de cÃ³digo sin colorear se lee; una burbuja que no se pinta
  /// tambiÃ©n se lee, y es peor.
  static TextSpan spanFor(
    String code,
    String? language,
    TextStyle base, {
    bool dark = false,
  }) {
    if (code.length > _kMaxParsedChars) {
      return TextSpan(text: code, style: base);
    }
    if (code.length <= _kMaxCachedChars) {
      final key = _CacheKey(code, language ?? '', dark, base);
      final hit = _cache.remove(key);
      if (hit != null) {
        // Re-inserta: marca como reciente (LRU).
        _cache[key] = hit;
        return hit;
      }
      final span = _build(code, language, base, dark: dark);
      _cache[key] = span;
      while (_cache.length > _kMaxEntries) {
        _cache.remove(_cache.keys.first);
      }
      return span;
    }
    return _build(code, language, base, dark: dark);
  }

  static TextSpan _build(
    String code,
    String? language,
    TextStyle base, {
    required bool dark,
  }) {
    List<Node>? nodes;
    try {
      nodes = highlight
          .parse(code, language: language, autoDetection: language == null)
          .nodes;
    } catch (e) {
      // `catch` con cuerpo porque el paquete lanza de todo y un bloque de texto
      // no puede romper la burbuja.
      assert(() {
        debugPrint('CodeHighlighter: ${e.runtimeType} con "$language"');
        return true;
      }());
      nodes = null;
    }
    if (nodes == null || nodes.isEmpty) {
      return TextSpan(text: code, style: base);
    }
    return TextSpan(
      style: base,
      children: [for (final n in nodes) _spanForNode(n, base, dark)],
    );
  }

  static TextSpan _spanForNode(Node node, TextStyle base, bool dark) {
    final color = colorFor(node.className, dark);
    // Comentarios y citas en itÃ¡lica: es la convenciÃ³n que ya usa el cliente
    // desktop y lo que separa "esto es spoken" de "esto es cÃ³digo".
    final italic = node.className == 'comment' || node.className == 'quote';
    final style = (color == null && !italic)
        ? base
        : base.copyWith(color: color, fontStyle: italic ? FontStyle.italic : null);
    if (node.children != null && node.children!.isNotEmpty) {
      return TextSpan(
        style: style,
        children: [for (final c in node.children!) _spanForNode(c, base, dark)],
      );
    }
    return TextSpan(text: node.value ?? '', style: style);
  }

  /// El color de un token, desde los tokens `--code-*` de `tokens.dart`.
  ///
  /// Puro y total, para poder testear la tabla sin parsear nada: es lo que
  /// decide si el bloque se ve en colores o sale plano.
  static Color? colorFor(String? className, bool dark) => switch (className) {
    'keyword' || 'selector-tag' => dark
        ? AppColors.darkCodeKeyword
        : AppColors.lightCodeKeyword,
    'string' || 'regexp' || 'subst' => dark
        ? AppColors.darkCodeString
        : AppColors.lightCodeString,
    'comment' || 'quote' => AppColors.darkCodeComment,
    'number' || 'literal' => dark
        ? AppColors.darkCodeNumber
        : AppColors.lightCodeNumber,
    'title' || 'function' || 'section' => dark
        ? AppColors.darkCodeFunction
        : AppColors.lightCodeFunction,
    'built_in' || 'type' || 'class' => dark
        ? AppColors.darkCodeBuiltin
        : AppColors.lightCodeBuiltin,
    'attr' || 'attribute' || 'variable' => dark
        ? AppColors.darkCodeAttr
        : AppColors.lightCodeAttr,
    _ => null,
  };
}

/// El cachÃ© depende de estos cuatro: el mismo cÃ³digo con otra fuente, otro tema u
/// otro brillo da un span distinto.
@immutable
class _CacheKey {
  const _CacheKey(this.code, this.language, this.dark, this.base);

  final String code;
  final String language;
  final bool dark;
  final TextStyle base;

  @override
  bool operator ==(Object other) =>
      other is _CacheKey &&
      other.code == code &&
      other.language == language &&
      other.dark == dark &&
      other.base == base;

  @override
  int get hashCode => Object.hash(code, language, dark, base);
}
