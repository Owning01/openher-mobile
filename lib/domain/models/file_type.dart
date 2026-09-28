import 'package:flutter/foundation.dart';

/// Qué se puede hacer con un archivo, según lo que es.
///
/// La decisión va **por el tipo del archivo, no por el botón que se apretó**:
/// el mismo "Abrir" tiene que saber si tiene que mostrar una imagen, un video, un
/// PDF o markdown. Y una extensión desconocida tiene que decir que no sabe, en
/// vez de intentar renderizar bytes como si fueran texto.
enum FileKind {
  image,
  svg,
  video,
  audio,
  pdf,
  markdown,
  code,
  text,
  binary,
}

/// Clasificador de archivos. Archivo puro: sin Flutter, para poder testearlo.
@immutable
class FileType {
  const FileType(this.kind, {this.mime});

  final FileKind kind;
  final String? mime;

  /// El rótulo que se usa en la lista y en el encabezado del visor.
  String get label => switch (kind) {
    FileKind.image => 'Imagen',
    FileKind.svg => 'Vector',
    FileKind.video => 'Video',
    FileKind.audio => 'Audio',
    FileKind.pdf => 'PDF',
    FileKind.markdown => 'Markdown',
    FileKind.code => 'Codigo',
    FileKind.text => 'Texto',
    FileKind.binary => 'Binario',
  };

  /// Clasifica por extensión, que es **lo único que hay**: `GET /api/fs/list`
  /// medido devuelve `{"path": "test_media\\degradado.png", "type": "file"}`,
  /// sin mime ni tamaño ni nombre. Una extensión desconocida no se adivina: sale
  /// [FileKind.binary] y la vista lo dice, en vez de intentar renderizar bytes
  /// como si fueran texto.
  static FileType of(String name) {
    final ext = _ext(name);
    if (ext.isEmpty) return const FileType(FileKind.binary);
    return _byExt[ext] ?? const FileType(FileKind.binary);
  }

  static String _ext(String name) {
    final base = name.split(RegExp(r'[/\\]')).last;
    final dot = base.lastIndexOf('.');
    if (dot <= 0 || dot == base.length - 1) return '';
    return base.substring(dot).toLowerCase();
  }

  /// El mime es el **estándar** de esa extensión (tabla IANA/MIME), no lo que el
  /// server contestó: se usa para el rótulo del tipo y para que el error diga
  /// qué se esperaba, nunca para decidir el visor.
  static const Map<String, FileType> _byExt = {
    // imagenes que decodifica Flutter solo
    '.jpg': FileType(FileKind.image, mime: 'image/jpeg'),
    '.jpeg': FileType(FileKind.image, mime: 'image/jpeg'),
    '.png': FileType(FileKind.image, mime: 'image/png'),
    '.gif': FileType(FileKind.image, mime: 'image/gif'),
    '.webp': FileType(FileKind.image, mime: 'image/webp'),
    '.bmp': FileType(FileKind.image, mime: 'image/bmp'),
    // vector
    '.svg': FileType(FileKind.svg, mime: 'image/svg+xml'),
    // heic: el decoder de Android lo tiene, Flutter no siempre
    '.heic': FileType(FileKind.image, mime: 'image/heic'),
    '.heif': FileType(FileKind.image, mime: 'image/heif'),
    // video
    '.mp4': FileType(FileKind.video, mime: 'video/mp4'),
    '.m4v': FileType(FileKind.video, mime: 'video/mp4'),
    '.mov': FileType(FileKind.video, mime: 'video/quicktime'),
    '.webm': FileType(FileKind.video, mime: 'video/webm'),
    '.mkv': FileType(FileKind.video, mime: 'video/x-matroska'),
    // audio
    '.mp3': FileType(FileKind.audio, mime: 'audio/mpeg'),
    '.m4a': FileType(FileKind.audio, mime: 'audio/mp4'),
    '.wav': FileType(FileKind.audio, mime: 'audio/wav'),
    '.ogg': FileType(FileKind.audio, mime: 'audio/ogg'),
    '.flac': FileType(FileKind.audio, mime: 'audio/flac'),
    // documentos
    '.pdf': FileType(FileKind.pdf, mime: 'application/pdf'),
    // markdown y texto
    '.md': FileType(FileKind.markdown, mime: 'text/markdown'),
    '.markdown': FileType(FileKind.markdown, mime: 'text/markdown'),
    '.txt': FileType(FileKind.text, mime: 'text/plain'),
    '.log': FileType(FileKind.text, mime: 'text/plain'),
    '.csv': FileType(FileKind.text, mime: 'text/csv'),
    '.json': FileType(FileKind.text, mime: 'application/json'),
    '.yaml': FileType(FileKind.text, mime: 'text/yaml'),
    '.yml': FileType(FileKind.text, mime: 'text/yaml'),
    '.toml': FileType(FileKind.text, mime: 'text/plain'),
    '.html': FileType(FileKind.code, mime: 'text/html'),
    '.css': FileType(FileKind.code, mime: 'text/css'),
    '.xml': FileType(FileKind.code, mime: 'text/xml'),
    // codigo
    '.dart': FileType(FileKind.code, mime: 'text/plain'),
    '.js': FileType(FileKind.code, mime: 'text/javascript'),
    '.ts': FileType(FileKind.code, mime: 'text/javascript'),
    '.tsx': FileType(FileKind.code, mime: 'text/javascript'),
    '.jsx': FileType(FileKind.code, mime: 'text/javascript'),
    '.py': FileType(FileKind.code, mime: 'text/x-python'),
    '.rs': FileType(FileKind.code, mime: 'text/rust'),
    '.go': FileType(FileKind.code, mime: 'text/x-go'),
    '.tsv': FileType(FileKind.text, mime: 'text/tab-separated-values'),
    '.kt': FileType(FileKind.code, mime: 'text/x-kotlin'),
    '.swift': FileType(FileKind.code, mime: 'text/x-swift'),
    '.c': FileType(FileKind.code, mime: 'text/x-c'),
    '.h': FileType(FileKind.code, mime: 'text/x-c'),
    '.cpp': FileType(FileKind.code, mime: 'text/x-c'),
    '.sh': FileType(FileKind.code, mime: 'text/x-sh'),
    '.ps1': FileType(FileKind.code, mime: 'text/plain'),
  };
}
