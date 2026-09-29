import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../../core/network/server_config.dart';
import '../../core/tokens.dart';

/// Renderiza un `.html` del workspace con los widgets de la app.
///
/// ## Por que no un WebView
///
/// Un WebView es lo obvio y **no funciona aca**, medido contra el server:
/// `GET /api/fs/read/<path>` sin header da **401**, y con `?auth_token=<base64>`
/// da **404** (ese carrier es solo del stream SSE, `/api/event`). Un WebView no
/// puede mandar el header Basic, asi que la pagina y todos sus subrecursos darian
/// 401: se veria un rectangulo blanco. Por eso se parsea el DOM y se dibuja con
/// widgets.
///
/// ## Que se pierde y que no
///
/// - **No**: CSS, JS, position absolute, flex/grid, iframes, forms. El CSS de la
///   pagina no se aplica: manda el tema de la app.
/// - **Si**: la estructura y el contenido. Encabezados, parrafos, listas
///   anidadas, tablas, codigo, citas, links e **imagenes del workspace** (esas si
///   cargan, porque aca el header Basic lo pone la app, no el WebView).
///
/// Un tag desconocido se renderiza por sus hijos: una etiqueta que no conozco no
/// puede hacer desaparecer el contenido.
///
/// ## Links
///
/// Se dibujan como link (color + subrayado) pero **no son apretables**: `Text.rich`
/// necesita un `TapGestureRecognizer` por span, y eso hay que liberarlo a mano;
/// sin un `State` que los libere cada rebuild filtraria uno. A cambio el cuerpo va
/// dentro de un `SelectionArea`, asi que un link largo se selecciona y se copia.
class HtmlView extends StatelessWidget {
  const HtmlView({
    super.key,
    required this.config,
    required this.path,
    required this.source,
  });

  final ServerConfig config;

  /// El path del `.html` en el workspace, relativo a la raiz del `location`.
  /// Hace falta para resolver los `src` relativos de las imagenes.
  final String path;

  /// El HTML ya bajado y decodificado (lo carga el visor, compartido con la vista
  /// de texto).
  final String source;

  @override
  Widget build(BuildContext context) {
    dom.Document doc;
    try {
      doc = html_parser.parse(source);
    } on Object catch (error) {
      // `html` es tolerante y casi nunca tira; si tira, el usuario tiene que ver
      // el motivo, no una pantalla en blanco.
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Text(
            'No se pudo leer el HTML: $error',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final root = doc.body ?? doc.documentElement;
    if (root == null) return const SizedBox.shrink();

    final blocks = _Renderer(
      config: config,
      basePath: path,
      scheme: Theme.of(context).colorScheme,
    ).blocks(root.nodes);

    if (blocks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Text(
            'El HTML no tiene contenido visible',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: blocks,
      ),
    );
  }
}

/// La viñeta de la lista sin ordenar: un punto pintado, no un guion.
///
/// El guion se veía como markdown, y un glifo de viñeta es tipografía, no
/// formalidad SVG. Pintear un `Container` de 4 px sale mas barato y es lo que
/// hace que la lista se lea como lista.
class _Bullet extends StatelessWidget {
  const _Bullet();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, left: 6),
    child: Container(
      width: 4,
      height: 4,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// Tags que no son contenido: no se renderizan.
const Set<String> _skipped = <String>{
  'head',
  'script',
  'style',
  'noscript',
  'template',
  'meta',
  'link',
  'title',
  'base',
  'iframe',
  'object',
  'embed',
  'param',
  'canvas',
  'svg',
  'math',
  'video',
  'audio',
  'source',
  'track',
  'picture',
  'map',
  'area',
  'form',
  'input',
  'button',
  'select',
  'textarea',
  'option',
  'label',
  'nav',
  'footer',
};

/// Convierte el DOM en widgets.
///
/// Son dos recorridos porque HTML tiene dos niveles: los **bloques** son widgets
/// apilados y los **inline** son `InlineSpan` dentro de un `Text`. Un solo
/// recorrido no puede hacer las dos cosas.
class _Renderer {
  _Renderer({
    required this.config,
    required this.basePath,
    required this.scheme,
  });

  final ServerConfig config;
  final String basePath;
  final ColorScheme scheme;

  /// El directorio del archivo con separador al final, o `''` si esta en la raiz
  /// del workspace.
  late final String dir = () {
    final norm = basePath.replaceAll('\\', '/');
    final cut = norm.lastIndexOf('/');
    return cut < 0 ? '' : norm.substring(0, cut + 1);
  }();

  // ---------------------------------------------------------------- bloques

  List<Widget> blocks(List<dom.Node> nodes) {
    final out = <Widget>[];
    for (final node in nodes) {
      out.addAll(_blockOf(node));
    }
    return out;
  }

  List<Widget> _blockOf(dom.Node node) {
    if (node is dom.Text) {
      final text = _collapse(node.text).trim();
      if (text.isEmpty) return const <Widget>[];
      // Texto suelto al nivel de bloque (sin `<p>`): igual tiene que verse.
      return <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: Text(text),
        ),
      ];
    }
    if (node is! dom.Element) return const <Widget>[];
    final tag = node.localName?.toLowerCase() ?? '';
    if (_skipped.contains(tag)) return const <Widget>[];

    return switch (tag) {
      'br' => const <Widget>[SizedBox(height: AppSpacing.sm)],
      'hr' => const <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
          child: Divider(height: 1),
        ),
      ],
      'img' => _image(node),
      'h1' => _heading(node, 1),
      'h2' => _heading(node, 2),
      'h3' => _heading(node, 3),
      'h4' => _heading(node, 4),
      'h5' => _heading(node, 5),
      'h6' => _heading(node, 6),
      'p' ||
      'div' ||
      'section' ||
      'article' ||
      'header' ||
      'main' ||
      'aside' ||
      'center' ||
      'address' ||
      'figure' ||
      'figcaption' ||
      'details' ||
      'summary' ||
      'fieldset' => _paragraph(node),
      'pre' => _pre(node),
      'blockquote' => _quote(node),
      'ul' => _list(node, ordered: false),
      'ol' => _list(node, ordered: true),
      'li' => _listItem(node, marker: const SizedBox.shrink(), depth: 0),
      'table' => _table(node),
      // Tags que pueden ser bloque o inline segun donde esten: se resuelve por
      // el nivel de bloque, que es como lo muestra un navegador.
      'a' ||
      'strong' ||
      'b' ||
      'em' ||
      'i' ||
      'u' ||
      's' ||
      'del' ||
      'strike' ||
      'small' ||
      'mark' ||
      'sub' ||
      'sup' ||
      'code' ||
      'span' ||
      'font' ||
      'bdi' ||
      'bdo' ||
      'label' ||
      'legend' ||
      'dt' ||
      'dd' ||
      'dl' ||
      'nav' ||
      'footer' => _paragraph(node),
      _ => blocks(node.nodes),
    };
  }

  List<Widget> _heading(dom.Element el, int level) {
    final size = switch (level) {
      1 => 26.0,
      2 => 21.0,
      3 => 18.0,
      _ => 16.0,
    };
    return <Widget>[
      Padding(
        padding: EdgeInsets.only(
          top: level <= 2 ? AppSpacing.lg : AppSpacing.md,
          bottom: AppSpacing.sm,
        ),
        child: Text.rich(
          TextSpan(
            children: _trimEdges(
              spans(el.nodes, TextStyle(fontSize: size, height: 1.28)),
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _paragraph(dom.Element el) {
    final inline = _trimEdges(spans(el.nodes, const TextStyle(height: 1.55)));
    if (inline.isEmpty) return const <Widget>[];
    // Un `<div>` que solo envuelve bloque no debe comerse un padding extra: si
    // tiene hijos de bloque, se devuelven como bloques.
    if (_hasBlockChild(el)) return blocks(el.nodes);
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: Text.rich(TextSpan(children: inline)),
      ),
    ];
  }

  List<Widget> _pre(dom.Element el) {
    final text = el.text.trimRight();
    if (text.trim().isEmpty) return const <Widget>[];
    return <Widget>[
      Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: AppRadius.mdAll,
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(
            text,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12.5,
              height: 1.5,
            ),
            softWrap: false,
          ),
        ),
      ),
    ];
  }

  List<Widget> _quote(dom.Element el) => <Widget>[
    Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.only(left: AppSpacing.md),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: scheme.primary.withValues(alpha: 0.55),
            width: 3,
          ),
        ),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: blocks(el.nodes),
        ),
      ),
    ),
  ];

  List<Widget> _list(dom.Element el, {required bool ordered}) {
    final items = el.children
        .where((e) => e.localName?.toLowerCase() == 'li')
        .toList();
    if (items.isEmpty) return blocks(el.nodes);
    var n = 1;
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(
          bottom: AppSpacing.sm,
          left: AppSpacing.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final li in items)
              ...ordered
                  ? _listItem(li, marker: Text('${n++}.'), depth: 1)
                  : _listItem(li, marker: const _Bullet(), depth: 1),
          ],
        ),
      ),
    ];
  }

  List<Widget> _listItem(
    dom.Element li, {
    required Widget marker,
    required int depth,
  }) {
    // Un `<li>` puede traer `<ul>`/`<ol>` anidados: esos van como bloque propio,
    // no como texto del item.
    final own = <dom.Node>[];
    final nested = <dom.Element>[];
    for (final child in li.nodes) {
      final tag = child is dom.Element ? child.localName?.toLowerCase() : '';
      if (child is dom.Element && (tag == 'ul' || tag == 'ol')) {
        nested.add(child);
      } else {
        own.add(child);
      }
    }
    return <Widget>[
      Padding(
        padding: EdgeInsets.only(
          left: depth * AppSpacing.md,
          bottom: AppSpacing.xs,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(width: 22, child: marker),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (!_noContent(own))
                    Text.rich(
                      TextSpan(
                        children: _trimEdges(
                          spans(own, const TextStyle(height: 1.5)),
                        ),
                      ),
                    ),
                  for (final n in nested)
                    ..._list(n, ordered: n.localName == 'ol'),
                ],
              ),
            ),
          ],
        ),
      ),
    ];
  }

  /// Tabla con borde, scrolleable en horizontal cuando no entra.
  List<Widget> _table(dom.Element table) {
    final rows = <List<List<InlineSpan>>>[];

    void walk(dom.Element parent) {
      for (final child in parent.children) {
        final t = child.localName?.toLowerCase();
        if (t == 'thead' || t == 'tbody' || t == 'tfoot') {
          walk(child);
        } else if (t == 'tr') {
          final cells = <List<InlineSpan>>[];
          for (final c in child.children) {
            final ct = c.localName?.toLowerCase();
            if (ct != 'th' && ct != 'td') continue;
            cells.add(
              spans(
                c.nodes,
                TextStyle(fontWeight: ct == 'th' ? FontWeight.w600 : null),
              ),
            );
          }
          if (cells.isNotEmpty) rows.add(cells);
        }
      }
    }

    walk(table);
    if (rows.isEmpty) return const <Widget>[];

    // `Table` exige columnas parejas: la fila mas corta se completa con celdas
    // vacias, en vez de dejar la tabla desalineada.
    var cols = 0;
    for (final r in rows) {
      if (r.length > cols) cols = r.length;
    }

    return <Widget>[
      Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: AppRadius.smAll,
        ),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: scheme.outlineVariant),
            children: <TableRow>[
              for (final r in rows)
                TableRow(
                  children: <Widget>[
                    for (var i = 0; i < cols; i++)
                      Padding(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        child: Text.rich(
                          TextSpan(
                            children: i < r.length
                                ? r[i]
                                : const <InlineSpan>[],
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    ];
  }

  // --------------------------------------------------------------- imagenes

  List<Widget> _image(dom.Element img) {
    final src = img.attributes['src']?.trim() ?? '';
    if (src.isEmpty) return const <Widget>[];
    final alt = img.attributes['alt']?.trim() ?? '';

    final inline = _dataUri(src);
    if (inline != null)
      return <Widget>[
        _imageBox(Image.memory(inline, fit: BoxFit.contain), alt),
      ];

    if (src.startsWith('http://') || src.startsWith('https://')) {
      // **Nunca** el header Basic aca: mandarlo a un host de terceros le
      // regalaria al sitio la password del server.
      return <Widget>[
        _imageBox(
          Image.network(src, fit: BoxFit.contain, errorBuilder: _noImage),
          alt,
        ),
      ];
    }

    final target = _resolve(src);
    if (target == null) return const <Widget>[];
    return <Widget>[
      _imageBox(
        Image.network(
          config.fileUrl(target).toString(),
          headers: config.binaryHeaders,
          fit: BoxFit.contain,
          errorBuilder: _noImage,
        ),
        alt,
      ),
    ];
  }

  Widget _imageBox(Widget child, String alt) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.md),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: double.infinity,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72, maxHeight: 320),
            child: child,
          ),
        ),
        // El `alt` es contenido, no decoracion: sin el, una imagen rota no dice
        // nada.
        if (alt.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              alt,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    ),
  );

  Widget _noImage(BuildContext context, Object error, StackTrace? stack) =>
      Container(
        height: 72,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: AppRadius.smAll,
        ),
        child: Text(
          'No se pudo cargar la imagen',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      );

  // ----------------------------------------------------------------- inline

  List<InlineSpan> spans(List<dom.Node> nodes, TextStyle base) {
    final out = <InlineSpan>[];
    for (final node in nodes) {
      if (node is dom.Text) {
        final text = _collapse(node.text);
        if (text.isEmpty) continue;
        out.add(TextSpan(text: text, style: base));
        continue;
      }
      if (node is! dom.Element) continue;
      final tag = node.localName?.toLowerCase() ?? '';
      if (_skipped.contains(tag)) continue;

      out.addAll(switch (tag) {
        'br' => <InlineSpan>[const TextSpan(text: '\n')],
        'strong' ||
        'b' => spans(node.nodes, base.copyWith(fontWeight: FontWeight.w700)),
        'em' ||
        'i' => spans(node.nodes, base.copyWith(fontStyle: FontStyle.italic)),
        'u' => spans(
          node.nodes,
          base.copyWith(decoration: TextDecoration.underline),
        ),
        'del' || 's' || 'strike' => spans(
          node.nodes,
          base.copyWith(decoration: TextDecoration.lineThrough),
        ),
        'small' => spans(
          node.nodes,
          base.copyWith(fontSize: (base.fontSize ?? 14) - 1.5),
        ),
        'big' => spans(
          node.nodes,
          base.copyWith(fontSize: (base.fontSize ?? 14) + 2),
        ),
        'mark' => spans(
          node.nodes,
          base.copyWith(
            backgroundColor: scheme.primary.withValues(alpha: 0.16),
          ),
        ),
        // Sin desplazamiento vertical: mover el span agranda el interlineado y
        // rompe el ritmo de la pagina. Sub y supra se ven mas chicos, nada mas.
        'sub' || 'sup' => spans(
          node.nodes,
          base.copyWith(fontSize: (base.fontSize ?? 14) - 2),
        ),
        'code' => spans(
          node.nodes,
          base.copyWith(
            fontFamily: 'monospace',
            fontSize: (base.fontSize ?? 14) - 1,
            color: scheme.primary,
            backgroundColor: scheme.primary.withValues(alpha: 0.10),
          ),
        ),
        'a' => _link(node, base),
        _ => spans(node.nodes, base),
      });
    }
    return out;
  }

  List<InlineSpan> _link(dom.Element a, TextStyle base) {
    final style = base.copyWith(
      color: scheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: scheme.primary.withValues(alpha: 0.5),
    );
    // El href no se muestra: se ofrece para copiar con el menu de seleccion. La
    // app no puede abrir una URL arbitraria sin meter `url_launcher`, y no
    // queremos que un HTML del workspace pueda navegar al usuario a cualquier
    // lado con un solo toque.
    return spans(a.nodes, style);
  }

  // ------------------------------------------------------------------ utils

  /// Colapsa espacios en blanco entre nodos inline, como hace un navegador:
  /// una tanda de espacios, tabs y saltos se vuelve **un** espacio.
  ///
  /// **No hace `trim`**: el espacio entre `con <strong>negrita</strong> y` es
  /// parte de la frase y sin el sale "connegritay" (medido, con un HTML de
  /// prueba). El recorte va en los bordes del bloque, en [_trimEdges].
  static String _collapse(String raw) =>
      raw.replaceAll(RegExp(r'[ \t\r\n]+'), ' ');

  /// ¿Esta lista de nodos no aporta nada visible? Un `<li>` con un `<ul>` y nada
  /// de texto propio no es un item vacio: tiene contenido.
  static bool _noContent(List<dom.Node> nodes) {
    for (final n in nodes) {
      if (n is dom.Text) {
        if (n.text.trim().isNotEmpty) return false;
      } else if (n is dom.Element) {
        final tag = n.localName?.toLowerCase();
        if (!_skipped.contains(tag)) return false;
      }
    }
    return true;
  }

  /// Poda el espacio en blanco de los bordes del bloque, que es la otra mitad
  /// del colapso de un navegador: el espacio **entre** nodos inline se
  /// conserva, el de los bordes no (un `<h1>\n  Titulo\n</h1>` no arranca
  /// indentado).
  static List<InlineSpan> _trimEdges(List<InlineSpan> spans) {
    final out = List<InlineSpan>.of(spans);
    final lead = RegExp(r'^[ \t\r\n]+');
    final tail = RegExp(r'[ \t\r\n]+$');
    while (out.isNotEmpty) {
      final first = out.first;
      if (first is! TextSpan) break;
      final text = first.text ?? '';
      final cut = text.replaceFirst(lead, '');
      if (cut.isEmpty) {
        out.removeAt(0);
        continue;
      }
      if (cut != text) {
        out[0] = TextSpan(
          text: cut,
          style: first.style,
          children: first.children,
        );
      }
      break;
    }
    while (out.isNotEmpty) {
      final last = out.last;
      if (last is! TextSpan) break;
      final text = last.text ?? '';
      final cut = text.replaceFirst(tail, '');
      if (cut.isEmpty) {
        out.removeLast();
        continue;
      }
      if (cut != text) {
        out[out.length - 1] = TextSpan(
          text: cut,
          style: last.style,
          children: last.children,
        );
      }
      break;
    }
    return out;
  }

  static bool _hasBlockChild(dom.Element el) {
    const blockish = <String>{
      'p',
      'div',
      'ul',
      'ol',
      'li',
      'pre',
      'blockquote',
      'table',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'hr',
      'img',
      'section',
      'article',
      'header',
      'figure',
      'details',
    };
    return el.children.any(
      (c) => blockish.contains(c.localName?.toLowerCase()),
    );
  }

  /// Resuelve un `src` relativo contra la carpeta del `.html` y devuelve el path
  /// relativo a la raiz del location, que es lo que espera `fileUrl`.
  String? _resolve(String src) {
    var s = src.trim();
    while (s.startsWith('./')) {
      s = s.substring(2);
    }
    var base = dir;
    while (s.startsWith('../')) {
      s = s.substring(3);
      final cut = base.lastIndexOf('/', base.length - 2);
      if (cut < 0) {
        base = '';
        break;
      }
      base = base.substring(0, cut + 1);
    }
    // Una ruta que arranca con `/` es relativa a la **raiz del location**, no a la
    // carpeta del archivo: el navegador hace lo mismo.
    final rel = s.startsWith('/') ? s.substring(1) : '$base$s';
    if (rel.isEmpty) return null;
    // `encodeComponent` escapa las `/`; se vuelven a poner para que el path del
    // workspace siga siendo legible en el log del server.
    return Uri.encodeComponent(rel).replaceAll('%2F', '/');
  }

  /// `data:` URI embebida (los `img src="data:image/png;base64,..."` de un HTML
  /// con la imagen pegada adentro). `null` si no es `data:` o si no decodifica.
  Uint8List? _dataUri(String src) {
    if (!src.startsWith('data:')) return null;
    final comma = src.indexOf(',');
    if (comma < 0) return null;
    final header = src.substring(5, comma);
    final data = src.substring(comma + 1);
    try {
      if (header.endsWith(';base64')) return base64Decode(data);
      return Uint8List.fromList(Uri.decodeComponent(data).codeUnits);
    } on FormatException {
      return null;
    }
  }
}
