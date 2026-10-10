/// Tema papel de los planes: los colores del archivo, no los de la app.
///
/// Espejo de `htmlplan.css` (`:root` y su `prefers-color-scheme: dark`): papel,
/// tinta, línea, acento y los cinco colores de datos con sus variantes por
/// brillo. El visor envuelve su `Scaffold` (y las hojas que abre) en este
/// tema, así lo que se ve en el teléfono es lo mismo que en el navegador.
library;

import 'package:flutter/material.dart';

/// Colores de datos del CSS (`--green`, `--amber`, `--red`, `--blue`,
/// `--purple`), por brillo.
final class PlanPalette {
  const PlanPalette({
    required this.green,
    required this.amber,
    required this.red,
    required this.blue,
    required this.purple,
  });

  final Color green;
  final Color amber;
  final Color red;
  final Color blue;
  final Color purple;

  static PlanPalette of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return PlanPalette(
      green: dark ? const Color(0xFF6FB37A) : const Color(0xFF2C7A39),
      amber: dark ? const Color(0xFFD9A441) : const Color(0xFF946410),
      red: dark ? const Color(0xFFE5776E) : const Color(0xFFB3261E),
      blue: dark ? const Color(0xFF7AA7E0) : const Color(0xFF2A69B8),
      purple: dark ? const Color(0xFFA990E0) : const Color(0xFF6F4BB8),
    );
  }
}

/// `ThemeData` papel por brillo, con los roles que los bloques usan.
ThemeData planTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  const paperLight = Color(0xFFFAF9F5);
  const paperDark = Color(0xFF262624);
  const inkLight = Color(0xFF141413);
  const inkDark = Color(0xFFFAF9F5);
  const ink3Light = Color(0xFF73726C);
  const ink3Dark = Color(0xFF9C9A92);
  final base = dark ? ThemeData.dark() : ThemeData.light();
  final scheme = (dark ? const ColorScheme.dark() : const ColorScheme.light())
      .copyWith(
        primary: dark ? const Color(0xFFD97757) : const Color(0xFFC6613F),
        onPrimary: dark ? paperDark : Colors.white,
        primaryContainer: dark
            ? const Color(0xFF46302A)
            : const Color(0xFFF6E7DF),
        onPrimaryContainer: dark ? inkDark : inkLight,
        surface: dark ? paperDark : paperLight,
        onSurface: dark ? inkDark : inkLight,
        surfaceContainerLowest: dark
            ? const Color(0xFF1F1E1D)
            : const Color(0xFFF0EEE6),
        surfaceContainerLow: dark
            ? const Color(0xFF30302E)
            : const Color(0xFFFFFFFF),
        surfaceContainerHighest: dark
            ? const Color(0xFF1F1E1D)
            : const Color(0xFFF0EEE6),
        onSurfaceVariant: dark ? ink3Dark : ink3Light,
        outline: dark
            ? const Color(0x26DEDCD1)
            : const Color(0x261F1E1D),
        outlineVariant: dark
            ? const Color(0x14DEDCD1)
            : const Color(0x141F1E1D),
      );
  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    bottomSheetTheme: base.bottomSheetTheme.copyWith(
      backgroundColor: scheme.surface,
    ),
    dialogTheme: base.dialogTheme.copyWith(backgroundColor: scheme.surface),
  );
}
