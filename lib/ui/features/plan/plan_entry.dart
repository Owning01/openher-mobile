/// Entrada al visor desde el chat: detectar la ruta y abrir el plan.
///
/// Cuando en el chat aparece una ruta a un `.html` (absoluta o relativa, con
/// `/` o `\`), la burbuja muestra **Ver plan**. Al tocarlo se bajan los bytes
/// con la misma resolución de rutas que Archivos y se abre el `PlanView`; si
/// no es un plan html-plan, se sigue al visor de archivos normal.
library;

import '../files/fs_path.dart';

/// `C:/docs/plan.html`, `G:\x\plan.packed.html`, `docs/plan.html`,
/// `./plan.html`. Devuelve la primera que aparece, o null.
String? findPlanPath(String text) {
  final pattern = RegExp(
    r'''(?:[A-Za-z]:[\\/]|\/|\.\/|\.\\.\\|[\w.\-]+\/)[\w.\-\\\/ ]*?\.html\b''',
  );
  final match = pattern.firstMatch(text);
  if (match == null) return null;
  return match.group(0)!.trim();
}

/// Separa una ruta en `(directory?, name)` como lo espera `readFileBytes`.
///
/// Absoluta → carpeta + nombre (`C:/a/plan.html` → `C:/a`, `plan.html`).
/// Relativa → sin carpeta (raíz del `location`) y el path tal cual.
({String? directory, String name}) splitPlanTarget(String path) {
  final clean = path.trim().replaceAll('\\', '/');
  final absolute = RegExp(r'^[A-Za-z]:/').hasMatch(clean) || clean.startsWith('/');
  if (!absolute) return (directory: null, name: clean);
  final parent = carpetaPadre(clean);
  return (directory: parent, name: nombreDeRuta(clean));
}
