"""Genera `test_media/` con un archivo de cada tipo que el visor debe abrir.

El visor los baja del workspace por `GET /api/fs/read/<path>`, asi que para
probarlos en un handset real tienen que existir en disco. Todo se arma con
la stdlib (zlib + struct para el PNG, bytes crudos para el PDF).

    python scripts/make_test_media.py
"""
import io
import os
import struct
import zlib

DEST = r'G:\Proyectos\openher-mobile\test_media'
os.makedirs(DEST, exist_ok=True)


def write(name, data):
    p = os.path.join(DEST, name)
    with io.open(p, 'wb') as f:
        f.write(data)
    print('  %-22s %8d bytes' % (name, len(data)))


# --- PNG: un degradado 240x160 escrito a mano (zlib + CRC, stdlib) --------
def png(w, h):
    raw = b''
    for y in range(h):
        raw += b'\x00'  # filtro None
        for x in range(w):
            r = int(255 * x / (w - 1))
            g = int(255 * y / (h - 1))
            b = 160
            raw += bytes((r, g, b))

    def chunk(tag, data):
        c = tag + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c))

    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


# --- PDF minimo valido, con una pagina de texto ---------------------------
PDF = (b"""%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 144]/Resources<</Font<</F1 5 0 R>>>>/Contents 4 0 R>>endobj
4 0 obj<</Length 74>>stream
BT /F1 18 Tf 24 90 Td (OpenHer PDF) Tj 0 -28 Td (visor de archivos) Tj ET
endstream
endobj
5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj
trailer<</Root 1 0 R/Size 6>>
%%EOF
""")

# --- SVG: circulos y texto -----------------------------------------------
SVG = b"""<svg xmlns="http://www.w3.org/2000/svg" width="320" height="200" viewBox="0 0 320 200">
  <rect width="320" height="200" fill="#12141c"/>
  <circle cx="90" cy="100" r="52" fill="#7c9cff" opacity="0.85"/>
  <circle cx="180" cy="70" r="34" fill="#ffb37c" opacity="0.8"/>
  <text x="24" y="180" font-family="monospace" font-size="18" fill="#e8eaf2">SVG vectorial</text>
</svg>
"""

MD = b"""# Markdown de prueba

Este archivo se abre desde **Archivos -> Abrir** y tiene que renderizarse como
markdown, no como texto crudo.

## Lo que prueba

- **Negrita**, *cursiva* y `codigo`
- Una lista de 3 puntos
- Un link a [OpenHer](https://github.com/Owning01/openher-mobile)

> Una cita, para ver el blockquote.

```dart
void main() => print('un bloque de codigo');
```

| columna | otra |
|---|---|
| 1 | 2 |
"""

TXT = ("linea " * 20000).encode('utf-8')  # ~140 KB: prueba el teto de texto

write('degradado.png', png(240, 160))
write('documento.pdf', PDF)
write('vector.svg', SVG)
write('notas.md', MD)
write('grande.txt', TXT)
print('  listo')
