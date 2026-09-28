import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:pdfrx/pdfrx.dart';
import 'package:video_player/video_player.dart';

import '../../../core/network/server_config.dart';
import '../../../domain/models/file_type.dart';
import '../../core/app_icon.dart';
import '../../core/tokens.dart';

/// El visor de archivos del workspace.
///
/// Se abre desde Archivos → "Abrir" y decide qué mostrar **por el tipo del
/// archivo**, no por el botón que se apretó.
///
/// La fuente de los bytes es `GET /api/fs/read/<path>`, que **medido** devuelve
/// los bytes crudos con el `Content-Type` correcto (verificado con un APK de
/// 56 MB), así que el visor puede trabajar contra la URL directo.
class FilePreview extends StatelessWidget {
  const FilePreview({
    super.key,
    required this.config,
    required this.path,
    required this.name,
  });

  final ServerConfig config;
  final String path;
  final String name;

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
            Text(type.label, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
      body: switch (type.kind) {
        FileKind.image => _ImageView(url: url, headers: headers),
        FileKind.svg => _SvgView(url: url, headers: headers),
        FileKind.video ||
        FileKind.audio =>
          _MediaView(
            url: url,
            headers: headers,
            isAudio: type.kind == FileKind.audio,
          ),
        FileKind.pdf => _PdfView(url: url, headers: headers),
        FileKind.markdown ||
        FileKind.text ||
        FileKind.code =>
          _TextView(
            url: url,
            headers: headers,
            isMarkdown: type.kind == FileKind.markdown,
          ),
        FileKind.binary => _Unsupported(name: name, type: type),
      },
    );
  }

  Uri get url => config.fileUrl(path);
  Map<String, String> get headers => config.binaryHeaders;
}

/// Imagen: `Image.network` decodifica jpg, png, gif y webp sin mas.
class _ImageView extends StatelessWidget {
  const _ImageView({required this.url, required this.headers});
  final Uri url;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) => ColoredBox(
    // Sin fondo, una foto con canal alpha se pierde contra el surface.
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: Center(
      child: InteractiveViewer(
        minScale: 0.5,
        maxScale: 6,
        child: Image.network(
          url.toString(),
          headers: headers,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stack) => _LoadError(error: '$error'),
          loadingBuilder: (context, child, progress) => progress == null
              ? child
              : const Center(child: _Spinner()),
        ),
      ),
    ),
  );
}

/// SVG: `flutter_svg` los dibuja vectoriales de verdad, no los rasteriza.
class _SvgView extends StatelessWidget {
  const _SvgView({required this.url, required this.headers});
  final Uri url;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: SvgPicture.network(
        url.toString(),
        headers: headers,
        fit: BoxFit.contain,
        placeholderBuilder: (context) => const Center(child: _Spinner()),
        // Sin esto, un SVG invalido se dibuja como un cuadro vacio y el
        // usuario no tiene ni idea de que fallo.
        errorBuilder: (context, error, stack) => _LoadError(error: '$error'),
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
  });
  final Uri url;
  final Map<String, String> headers;
  final bool isAudio;

  @override
  State<_MediaView> createState() => _MediaViewState();
}

class _MediaViewState extends State<_MediaView> {
  late final VideoPlayerController _controller;
  late final Future<void> _ready;
  String? _error;

  @override
  void initState() {
    super.initState();
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
    if (_error != null) return _LoadError(error: _error!);
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
  });
  final Uri url;
  final Map<String, String> headers;
  final bool isMarkdown;

  @override
  State<_TextView> createState() => _TextViewState();
}

class _TextViewState extends State<_TextView> {
  late Future<String> _text = _load();

  Future<String> _load() async {
    final res = await http.get(widget.url, headers: widget.headers);
    if (res.statusCode != 200) {
      throw StateError('HTTP ${res.statusCode}');
    }
    // utf8 con replacement: un byte raro se muestra con el caracter de
    // reemplazo en vez de romper la pantalla entera.
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    if (text.length <= _kMaxChars) return text;
    // Un `.log` de 20 MB renderizado en un `Text` mata la pantalla: se corta y
    // se dice cuanto falto, en vez de dejar que el frame se caiga.
    final cut = text.substring(0, _kMaxChars);
    return '$cut\n\n[... ${_fmt(text.length - _kMaxChars)} caracteres mas. '
        'El archivo completo tiene ${_fmt(text.length)}.]';
  }

  /// Techo de texto renderizado. Medido: 200 KB de texto ya son ~12.000 lineas
  /// de `Text`, que en un handset es seconds de frame.
  static const int _kMaxChars = 200000;

  static String _fmt(int n) =>
      n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<String>(
      future: _text,
      builder: (context, snapshot) {
        if (snapshot.hasError) return _LoadError(error: '${snapshot.error}');
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
class _Unsupported extends StatelessWidget {
  const _Unsupported({required this.name, required this.type});
  final String name;
  final FileType type;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
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
            'Se puede copiar la ruta y abrirlo fuera.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.error});
  final String error;

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
            error,
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
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
