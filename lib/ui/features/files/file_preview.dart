import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../../core/network/server_config.dart';
import '../../../domain/models/errors.dart';
import '../../../domain/models/file_type.dart';
import '../../core/app_icon.dart';
import '../../core/tokens.dart';
import 'html_view.dart';

/// El techo del HTML, 2 MB de marcado. Mas que el de un `.txt` a proposito: una
/// pagina de 300 KB de HTML es normal, y lo que no se debe dejar pasar es el
/// `.log` gigante, que usa [_TextView._kTextMaxChars].
///
/// Lo usan **las dos** vistas del HTML: si la vista y la fuente tuvieran topes
/// distintos, al alternar se veria el texto cambiar de largo solo.
const int kHtmlMaxChars = 2000000;

/// Baja un archivo de texto y lo devuelve recortado a [maxChars].
///
/// Compartida por la vista de texto y la de HTML, para que el corte por tamaño
/// y el `utf8` tolerante esten **una sola vez**: si divergen, un HTML gigante
/// pasa por un lado y se ve entero, y el otro lo corta.
///
/// `utf8` con `allowMalformed`: un byte raro se muestra con el caracter de
/// reemplazo en vez de romper la pantalla entera.
Future<String> loadTextFile(
  Uri url,
  Map<String, String> headers, {
  required int maxChars,
}) async {
  final res = await http.get(url, headers: headers);
  if (res.statusCode != 200) {
    throw StateError('HTTP ${res.statusCode}');
  }
  final text = utf8.decode(res.bodyBytes, allowMalformed: true);
  if (text.length <= maxChars) return text;
  // Un `.log` de 20 MB renderizado en un `Text` mata la pantalla: se corta y se
  // dice cuanto falto, en vez de dejar que el frame se caiga.
  return '${text.substring(0, maxChars)}\n\n'
      '[... ${_fmt(text.length - maxChars)} caracteres mas. '
      'El archivo completo tiene ${_fmt(text.length)}.]';
}

String _fmt(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

/// Baja [url] con [headers] y abre el compartir del sistema.
///
/// La usan el visor y la vista de "tipo no soportado" para el botón
/// Descargar: `share_plus` necesita un path en disco, no bytes. El error sale
/// genérico en español; el detalle crudo (un status o un fallo de red, nunca
/// la URL con el token) va al log redactado.
Future<void> shareUrlBytes(
  BuildContext context,
  Uri url,
  Map<String, String> headers, {
  required String filename,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final safe = filename.isEmpty ? 'archivo' : filename;
  try {
    final res = await http.get(url, headers: headers);
    if (res.statusCode != 200) throw StateError('HTTP ${res.statusCode}');
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}OpenHer-$safe',
    );
    await file.writeAsBytes(res.bodyBytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(files: <XFile>[XFile(file.path)], text: safe),
    );
  } on Object catch (e) {
    developer.log(
      'visor: no se pudo descargar $safe: ${sanitizeForDisplay('$e')}',
      name: 'openher.files',
    );
    messenger.showSnackBar(
      const SnackBar(
        content: Text('No se pudo descargar el archivo. Revisá la conexión.'),
      ),
    );
  }
}

/// El visor de archivos del workspace.
///
/// Se abre desde Archivos → "Abrir" y decide qué mostrar **por el tipo del
/// archivo**, no por el botón que se apretó.
///
/// La fuente de los bytes es `GET /api/fs/read/<path>`, que **medido** devuelve
/// los bytes crudos con el `Content-Type` correcto (verificado con un APK de
/// 56 MB), así que el visor puede trabajar contra la URL directo.
class FilePreview extends StatefulWidget {
  const FilePreview({
    super.key,
    required this.config,
    required this.path,
    required this.name,
    this.directory,
  });

  final ServerConfig config;
  final String path;

  /// La carpeta de la que sale el archivo, **absoluta**.
  ///
  /// Medido 2026-10-06: pedir `/api/fs/read/<ruta-absoluta>` contesta 500; lo
  /// que funciona es `<nombre>?location[directory]=<carpeta-absoluta>`. El
  /// visor no abría ningún archivo de un disco, y la causa era exactamente
  /// pedir la ruta absoluta entera.
  final String? directory;

  final String name;

  @override
  State<FilePreview> createState() => _FilePreviewState();
}

class _FilePreviewState extends State<FilePreview> {
  /// El HTML alterna entre renderizado y fuente. Se ofrece porque medio HTML del
  /// workspace son plantillas (Vue, Handlebars, JSX) donde el **codigo** es lo
  /// que se quiere ver, y el otro medio son paginas donde lo es la pagina.
  bool _htmlSource = false;

  ServerConfig get config => widget.config;
  String get path => widget.path;
  String? get directory => widget.directory;
  String get name => widget.name;
  Uri get url => config.fileUrl(path, directory: directory);
  Map<String, String> get headers => config.binaryHeaders;

  /// Carpeta del archivo para el subtítulo: en un disco es la carpeta
  /// absoluta, en la raíz del `location` el padre del path (o la raíz).
  String get _folder {
    if (directory != null && directory!.isNotEmpty) return directory!;
    final norm = path.replaceAll('\\', '/');
    final cut = norm.lastIndexOf('/');
    return cut <= 0 ? 'raíz' : path.substring(0, cut);
  }

  @override
  Widget build(BuildContext context) {
    final type = FileType.of(name);
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              '${type.kind == FileKind.html && _htmlSource ? '${type.label} - fuente' : type.label} · $_folder',
              style: Theme.of(context).textTheme.labelSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: <Widget>[
          if (type.kind == FileKind.html)
            AppIconButton(
              icon: _htmlSource ? 'image' : 'terminal',
              tooltip: _htmlSource ? 'Ver la pagina' : 'Ver el codigo',
              selected: _htmlSource,
              onPressed: () => setState(() => _htmlSource = !_htmlSource),
            ),
        ],
      ),
      body: switch (type.kind) {
        FileKind.image => _ImageView(
          url: url,
          headers: headers,
          onDownload: () =>
              shareUrlBytes(context, url, headers, filename: name),
        ),
        FileKind.svg => _SvgView(
          url: url,
          headers: headers,
          onDownload: () =>
              shareUrlBytes(context, url, headers, filename: name),
        ),
        FileKind.video ||
        FileKind.audio =>
          _MediaView(
            url: url,
            headers: headers,
            isAudio: type.kind == FileKind.audio,
            onDownload: () =>
                shareUrlBytes(context, url, headers, filename: name),
          ),
        FileKind.pdf => _PdfView(url: url, headers: headers),
        FileKind.html => _htmlSource
            ? _TextView(
                  url: url,
                  headers: headers,
                  isMarkdown: false,
                  maxChars: kHtmlMaxChars,
                  onDownload: () =>
                      shareUrlBytes(context, url, headers, filename: name),
                )
            : _HtmlPreview(
                config: config,
                path: path,
                url: url,
                headers: headers,
                onDownload: () =>
                    shareUrlBytes(context, url, headers, filename: name),
              ),
        FileKind.markdown ||
        FileKind.text ||
        FileKind.code =>
          _TextView(
            url: url,
            headers: headers,
            isMarkdown: type.kind == FileKind.markdown,
            onDownload: () =>
                shareUrlBytes(context, url, headers, filename: name),
          ),
        FileKind.binary => _Unsupported(
          name: name,
          type: type,
          url: url,
          headers: headers,
          path: directory != null ? '$directory/$name' : path,
        ),
      },
    );
  }

}

/// Carga el HTML una vez y lo muestra renderizado.
///
/// El texto se baja **una** sola vez y se reusa para las dos vistas: alternar
/// Vista/Fuente no puede volver a pegarle al server. Por eso vive aca y no
/// adentro de [HtmlView], que es puro.
class _HtmlPreview extends StatefulWidget {
  const _HtmlPreview({
    required this.config,
    required this.path,
    required this.url,
    required this.headers,
    this.onDownload,
  });

  final ServerConfig config;
  final String path;
  final Uri url;
  final Map<String, String> headers;
  final VoidCallback? onDownload;

  @override
  State<_HtmlPreview> createState() => _HtmlPreviewState();
}

class _HtmlPreviewState extends State<_HtmlPreview> {

  late Future<String> _html = _load();

  Future<String> _load() => loadTextFile(
    widget.url,
    widget.headers,
    maxChars: kHtmlMaxChars,
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: _html,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return _LoadError(
          error: '${snapshot.error}',
          onRetry: () => setState(() => _html = _load()),
          onDownload: widget.onDownload,
        );
      }
      if (!snapshot.hasData) return const Center(child: _Spinner());
      return HtmlView(
        config: widget.config,
        path: widget.path,
        source: snapshot.data!,
      );
    },
  );
}

/// Imagen: `Image.network` decodifica jpg, png, gif y webp sin mas.
class _ImageView extends StatefulWidget {
  const _ImageView({required this.url, required this.headers, this.onDownload});
  final Uri url;
  final Map<String, String> headers;
  final VoidCallback? onDownload;

  @override
  State<_ImageView> createState() => _ImageViewState();
}

class _ImageViewState extends State<_ImageView> {
  /// Cada reintento cambia la key y `Image.network` vuelve a pedir los bytes.
  int _attempt = 0;

  @override
  Widget build(BuildContext context) => ColoredBox(
    // Sin fondo, una foto con canal alpha se pierde contra el surface.
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Center(
      child: InteractiveViewer(
        minScale: 0.5,
        maxScale: 6,
        child: Image.network(
          widget.url.toString(),
          key: ValueKey('preview-img-$_attempt'),
          headers: widget.headers,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stack) => _LoadError(
            error: '$error',
            onRetry: () => setState(() => _attempt++),
            onDownload: widget.onDownload,
          ),
          loadingBuilder: (context, child, progress) => progress == null
              ? child
              : const Center(child: _Spinner()),
        ),
      ),
    ),
  );
}

/// SVG: `flutter_svg` los dibuja vectoriales de verdad, no los rasteriza.
class _SvgView extends StatefulWidget {
  const _SvgView({required this.url, required this.headers, this.onDownload});
  final Uri url;
  final Map<String, String> headers;
  final VoidCallback? onDownload;

  @override
  State<_SvgView> createState() => _SvgViewState();
}

class _SvgViewState extends State<_SvgView> {
  int _attempt = 0;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: SvgPicture.network(
        widget.url.toString(),
        key: ValueKey('preview-svg-$_attempt'),
        headers: widget.headers,
        fit: BoxFit.contain,
        placeholderBuilder: (context) => const Center(child: _Spinner()),
        // Sin esto, un SVG invalido se dibuja como un cuadro vacio y el
        // usuario no tiene ni idea de que fallo.
        errorBuilder: (context, error, stack) => _LoadError(
          error: '$error',
          onRetry: () => setState(() => _attempt++),
          onDownload: widget.onDownload,
        ),
      ),
    ),
  );
}

/// Video y audio: mismo plugin, misma URL. El audio no necesita imagen.
class _MediaView extends StatefulWidget {
  const _MediaView({
    required this.url,
    required this.headers,
    required this.isAudio,
    this.onDownload,
  });
  final Uri url;
  final Map<String, String> headers;
  final bool isAudio;
  final VoidCallback? onDownload;

  @override
  State<_MediaView> createState() => _MediaViewState();
}

class _MediaViewState extends State<_MediaView> {
  late VideoPlayerController _controller;
  late Future<void> _ready;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  void _open() {
    _error = null;
    _controller = VideoPlayerController.networkUrl(
      widget.url,
      httpHeaders: widget.headers,
    );
    _ready = _controller.initialize().then((_) {
      // `setState` despues de dispose es el crash clasico de este plugin: la
      // inicializacion es asincrona y la pantalla puede haberse cerrado.
      if (mounted) setState(() {});
    }).catchError((Object e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _LoadError(
        error: _error!,
        onRetry: () => setState(() {
          _controller.dispose();
          _open();
        }),
        onDownload: widget.onDownload,
      );
    }
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: _Spinner());
        }
        return Column(
          children: [
            if (!widget.isAudio)
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: _controller.value.aspectRatio,
                    child: VideoPlayer(_controller),
                  ),
                ),
              )
            else
              const Spacer(),
            VideoProgressIndicator(
              _controller,
              allowScrubbing: true,
              padding: const EdgeInsets.all(AppSpacing.md),
            ),
            IconButton(
              onPressed: () => setState(() {
                _controller.value.isPlaying
                    ? _controller.pause()
                    : _controller.play();
              }),
              iconSize: 32,
              icon: Icon(
                _controller.value.isPlaying
                    ? Icons.pause
                    : Icons.play_arrow,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
        );
      },
    );
  }
}

/// PDF con `pdfrx`, que renderiza el documento real con scroll y zoom.
///
/// `PdfViewer.uri` **acepta headers** (medido en el paquete 2.4.8), asi que la
/// autenticacion va como header y no hay que meter el token en el query.
class _PdfView extends StatelessWidget {
  const _PdfView({required this.url, required this.headers});
  final Uri url;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) => PdfViewer.uri(
    url,
    headers: headers,
    // El PDF se descarga entero igual que en cualquier visor: el server no
    // expone range requests en `/api/fs/read`, asi que pedir paginas sueltas
    // seria adivinar.
    useProgressiveLoading: true,
  );
}

/// Markdown se renderiza; el codigo y el texto plano van monoespaciados con
/// scroll horizontal, que es como se lee un archivo de codigo.
class _TextView extends StatefulWidget {
  const _TextView({
    required this.url,
    required this.headers,
    required this.isMarkdown,
    this.maxChars = _kTextMaxChars,
    this.onDownload,
  });
  final Uri url;
  final Map<String, String> headers;
  final bool isMarkdown;
  final VoidCallback? onDownload;

  /// Techo de texto renderizado. Medido: 200 KB ya son ~12.000 lineas de `Text`,
  /// que en un handset son segundos de frame.
  final int maxChars;

  static const int _kTextMaxChars = 200000;

  @override
  State<_TextView> createState() => _TextViewState();
}

class _TextViewState extends State<_TextView> {
  late Future<String> _text;

  @override
  void initState() {
    super.initState();
    _text = _load();
  }

  Future<String> _load() => loadTextFile(
    widget.url,
    widget.headers,
    maxChars: widget.maxChars,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<String>(
      future: _text,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _LoadError(
            error: '${snapshot.error}',
            onRetry: () => setState(() => _text = _load()),
            onDownload: widget.onDownload,
          );
        }
        if (!snapshot.hasData) return const Center(child: _Spinner());
        final text = snapshot.data!;
        if (widget.isMarkdown) {
          return SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: MarkdownBody(data: text),
            ),
          );
        }
        return ColoredBox(
          color: scheme.surfaceContainerLow,
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Text(
                  text,
                  softWrap: false,
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.55,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// El tipo que el server sirve y la app no sabe mostrar.
///
/// Dice qué sí muestra (y con qué topes) en vez de un "no se puede" pelado, y
/// ofrece Copiar ruta y Compartir: el archivo sale igual del teléfono aunque
/// no tenga visor.
class _Unsupported extends StatelessWidget {
  const _Unsupported({
    required this.name,
    required this.type,
    required this.url,
    required this.headers,
    required this.path,
  });
  final String name;
  final FileType type;
  final Uri url;
  final Map<String, String> headers;

  /// Ruta completa para copiar (con carpeta cuando se conoce).
  final String path;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(
            'file',
            size: 32,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'No hay visor para este tipo de archivo',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'La app no sabe mostrar ${type.mime ?? type.label.toLowerCase()}. '
            'Se puede copiar la ruta y abrirlo fuera, o compartirlo.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'El visor muestra imágenes, vectores, video, audio, PDF, '
            'Markdown, HTML, texto y código. El texto se corta en 200 KB '
            'y el HTML en 2 MB.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: path));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Ruta copiada')),
                    );
                  }
                },
                child: const Text('Copiar ruta'),
              ),
              TextButton(
                onPressed: () => shareUrlBytes(
                  context,
                  url,
                  headers,
                  filename: name,
                ),
                child: const Text('Compartir'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.error, this.onRetry, this.onDownload});
  final String error;
  final VoidCallback? onRetry;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(
            'alert-triangle',
            size: 28,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'No se pudo abrir',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            // El detalle crudo puede traer la URL con el token: sale redactado
            // y el mensaje fijo de arriba es el que se lee primero.
            sanitizeForDisplay(error),
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          if (onRetry != null || onDownload != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onRetry != null)
                  TextButton(
                    onPressed: onRetry,
                    child: const Text('Reintentar'),
                  ),
                if (onDownload != null)
                  TextButton(
                    onPressed: onDownload,
                    child: const Text('Descargar'),
                  ),
              ],
            ),
          ],
        ],
      ),
    ),
  );
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 24,
    width: 24,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}
