/// Design tokens. Port exacto de `web/src/styles/tokens.css` + Apéndice A,
/// transcrito desde `openher-flutter-desktop/lib/ui/core/tokens.dart` (el
/// espejo canónico del CSS; hex y nombres no se reinterpretan).
///
/// Monocromo: en el chrome el color solo aparece como gris; los semánticos
/// reales (verde/rojo/ámbar) viven en el scope de diffs/código.
///
/// Archivo puro a propósito: depende solo de `dart:ui` y `painting` (Color,
/// Brightness, Radius, BorderRadius, BoxShadow), nunca de `BuildContext` ni de
/// `Theme`. Así los tokens se pueden usar desde un `const` de tema, desde un
/// test sin widget y desde cualquier capa sin arrastrar Material.
library;

import 'dart:ui' show Brightness, Color, Offset, Radius;
import 'package:flutter/painting.dart' show BorderRadius, BoxShadow;

/// Espaciado (espejo de `--space-*`: 4/8/12/16/20/24/32).
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
}

/// Breakpoints responsivos (Apéndice A). El cliente Android vive casi siempre
/// en el rango `mobile`; los otros dos quedan para tablets y para la vista
/// web equivalente.
abstract final class AppBreakpoints {
  static const double mobileMax = 600;
  static const double tabletMax = 1024;

  static bool isMobile(double width) => width <= mobileMax;
  static bool isTablet(double width) => width > mobileMax && width <= tabletMax;
  static bool isDesktop(double width) => width > tabletMax;
}

/// Radios (espejo de `--radius-*`).
abstract final class AppRadius {
  static const double sm = 4;
  static const double md = 6;
  static const double lg = 8;
  static const Radius smRadius = Radius.circular(sm);
  static const Radius mdRadius = Radius.circular(md);
  static const Radius lgRadius = Radius.circular(lg);

  static const BorderRadius smAll = BorderRadius.all(smRadius);
  static const BorderRadius mdAll = BorderRadius.all(mdRadius);
  static const BorderRadius lgAll = BorderRadius.all(lgRadius);
}

/// Sombras sutiles (espejo de `--shadow-*` light :71-73 y dark :129-131).
abstract final class AppShadows {
  // Light.
  static const List<BoxShadow> sm = [
    BoxShadow(color: Color(0x0A000000), blurRadius: 2, offset: Offset(0, 1)),
  ];
  static const List<BoxShadow> md = [
    BoxShadow(color: Color(0x0F000000), blurRadius: 3, offset: Offset(0, 1)),
    BoxShadow(color: Color(0x0A000000), blurRadius: 2, offset: Offset(0, 1)),
  ];
  static const List<BoxShadow> lg = [
    BoxShadow(color: Color(0x0F000000), blurRadius: 12, offset: Offset(0, 4)),
    BoxShadow(color: Color(0x0A000000), blurRadius: 6, offset: Offset(0, 2)),
  ];

  // Dark: overrides exactos de tokens.css.
  static const List<BoxShadow> smDark = [
    BoxShadow(color: Color(0x80000000), blurRadius: 2, offset: Offset(0, 1)),
  ];
  static const List<BoxShadow> mdDark = [
    BoxShadow(color: Color(0x99000000), blurRadius: 12, offset: Offset(0, 4)),
  ];
  static const List<BoxShadow> lgDark = [
    BoxShadow(color: Color(0xB3000000), blurRadius: 24, offset: Offset(0, 8)),
  ];
}

/// Paleta completa monocroma + acentos solo-diffs. Espejo de `tokens.css`.
abstract final class AppColors {
  // ===== Light (:root, tokens.css :5-79) =====

  // Fondos.
  static const Color lightBg = Color(0xFFFFFFFF); // --bg
  static const Color lightSurface = Color(0xFFFFFFFF); // --surface
  static const Color lightSurfaceSubtle = Color(0xFFFAFAFB); // --surface-subtle
  static const Color lightSurfaceStrong = Color(0xFFF4F4F5); // --surface-strong
  static const Color lightSurfaceHover = Color(0xFFE9E9EC); // --surface-hover
  static const Color lightSurfaceSoft = Color(0xFFF9F9FB); // --surface-soft

  // Bordes.
  static const Color lightBorder = Color(0xFFE4E4E7); // --border
  static const Color lightBorderStrong = Color(0xFFD4D4D8); // --border-strong
  static const Color lightBorderSubtle = Color(0xFFE9E9EC); // --border-subtle

  // Texto.
  static const Color lightText = Color(0xFF18181B); // --text
  static const Color lightMuted = Color(0xFF71717A); // --muted
  static const Color lightMutedStrong = Color(0xFF52525B); // --muted-strong

  // Primario / foco.
  static const Color lightPrimary = Color(0xFF18181B); // --primary
  static const Color lightPrimaryStrong = Color(0xFF09090B); // --primary-strong
  static const Color lightOnPrimary = Color(0xFFFFFFFF); // --on-primary
  static const Color lightPrimarySoft = Color(0x1218181B); // rgba(24,24,27,.07)
  static const Color lightPrimaryBorder = Color(
    0x3318181B,
  ); // rgba(24,24,27,.2)
  static const Color lightFocusRing = Color(0x2918181B); // rgba(24,24,27,.16)
  static const Color lightAccentSoft = Color(0x1218181B); // --accent-soft

  // Chrome semántico: en cromo es GRIS (el color real vive en diffs).
  static const Color lightSuccess = Color(0xFF52525B); // --success
  static const Color lightSuccessSoft = Color(0x1F52525B); // rgba(82,82,91,.12)
  static const Color lightDanger = Color(0xFF52525B); // --danger
  static const Color lightDangerSoft = Color(0x1F52525B);
  static const Color lightDangerBorder = Color(0x3318181B); // --danger-border
  static const Color lightWarning = Color(0xFF71717A); // --warning
  static const Color lightWarningSoft = Color(0x1F71717A);
  static const Color lightInfo = Color(0xFF52525B); // --info
  static const Color lightThinkingHeader = Color(0xFF52525B);
  static const Color lightSecondary = Color(0xFF18181B); // --secondary

  // Superficies translúcidas.
  static const Color lightNavBg = Color(0xCCFFFFFF); // rgba(255,255,255,.8)
  static const Color lightBottomNavBg = Color(
    0xD9FFFFFF,
  ); // rgba(255,255,255,.85)
  static const Color lightModalBackdrop = Color(0x52000000);
  static const Color lightSheetBackdrop = Color(0x47000000);

  // Código (:46-54).
  static const Color lightCodeBg = Color(0xFFF4F4F5);
  static const Color lightCodeText = Color(0xFF18181B);
  static const Color lightCodeKeyword = Color(0xFF5E6AD2);
  static const Color lightCodeString = Color(0xFF16A34A);
  static const Color lightCodeComment = Color(0xFF71717A);
  static const Color lightCodeFunction = Color(0xFF5E6AD2);
  static const Color lightCodeNumber = Color(0xFFF59E0B);
  static const Color lightCodeBuiltin = Color(0xFFE11D48);
  static const Color lightCodeAttr = Color(0xFF0EA5E9);

  // ===== Dark (:root[data-theme="dark"], tokens.css :83-132) =====

  // Fondos.
  static const Color darkBg = Color(0xFF09090B); // --bg
  static const Color darkSurface = Color(0xFF121215); // --surface
  static const Color darkSurfaceSubtle = Color(0xFF18181C); // --surface-subtle
  static const Color darkSurfaceStrong = Color(0xFF222226); // --surface-strong
  static const Color darkSurfaceHover = Color(0xFF27272A); // --surface-hover
  static const Color darkSurfaceSoft = Color(0xFF18181C); // --surface-soft

  // Bordes.
  static const Color darkBorder = Color(0xFF222226); // --border
  static const Color darkBorderStrong = Color(0xFF333338); // --border-strong
  static const Color darkBorderSubtle = Color(0xFF1C1C20); // --border-subtle

  // Texto.
  static const Color darkText = Color(0xFFF4F4F5); // --text
  static const Color darkMuted = Color(0xFFA1A1AA); // --muted
  static const Color darkMutedStrong = Color(0xFFD4D4D8); // --muted-strong

  // Primario / foco.
  static const Color darkPrimary = Color(0xFFF4F4F5); // --primary
  static const Color darkPrimaryStrong = Color(0xFFFFFFFF); // --primary-strong
  static const Color darkOnPrimary = Color(0xFF09090B); // --on-primary
  static const Color darkPrimarySoft = Color(
    0x1AF4F4F5,
  ); // rgba(244,244,245,.1)
  static const Color darkPrimaryBorder = Color(
    0x38F4F4F5,
  ); // rgba(244,244,245,.22)
  static const Color darkFocusRing = Color(0x38F4F4F5); // rgba(244,244,245,.22)
  static const Color darkAccentSoft = Color(0x1AF4F4F5); // --accent-soft

  // Chrome semántico: en cromo es GRIS.
  static const Color darkSuccess = Color(0xFFA1A1AA); // --success
  static const Color darkSuccessSoft = Color(0x1FA1A1AA);
  static const Color darkDanger = Color(0xFFD4D4D8); // --danger
  static const Color darkDangerSoft = Color(0x1FD4D4D8);
  static const Color darkDangerBorder = Color(0x38F4F4F5); // --danger-border
  static const Color darkWarning = Color(0xFFA1A1AA); // --warning
  static const Color darkWarningSoft = Color(0x1FA1A1AA);
  static const Color darkInfo = Color(0xFFA1A1AA); // --info
  static const Color darkThinkingHeader = Color(0xFFA1A1AA);
  static const Color darkSecondary = Color(0xFFF4F4F5); // --secondary

  // Superficies translúcidas.
  static const Color darkNavBg = Color(0xD909090B); // rgba(9,9,11,.85)
  static const Color darkBottomNavBg = Color(0xE609090B); // rgba(9,9,11,.9)
  static const Color darkModalBackdrop = Color(0xB3000000);
  static const Color darkSheetBackdrop = Color(0x99000000);

  // Código (:118-126).
  static const Color darkCodeBg = Color(0xFF0E0E11);
  static const Color darkCodeText = Color(0xFFF4F4F5);
  static const Color darkCodeKeyword = Color(0xFF818CF8);
  static const Color darkCodeString = Color(0xFF4ADE80);
  static const Color darkCodeComment = Color(0xFF71717A);
  static const Color darkCodeFunction = Color(0xFF818CF8);
  static const Color darkCodeNumber = Color(0xFFFBBF24);
  static const Color darkCodeBuiltin = Color(0xFFFB7185);
  static const Color darkCodeAttr = Color(0xFF38BDF8);

  // ===== Scope semántico de diffs (tokens.css :138-162) =====
  // Light (:143-148).
  static const Color diffAdd = Color(0xFF16A34A); // --success
  static const Color diffDel = Color(0xFFE11D48); // --danger
  static const Color warn = Color(0xFFF59E0B); // --warning
  static const Color diffAddSoft = Color(0x1416A34A); // rgba(22,163,74,.08)
  static const Color diffDelSoft = Color(0x14E11D48); // rgba(225,29,72,.08)
  static const Color warnSoft = Color(0x1AF59E0B); // rgba(245,158,11,.1)

  // Dark (:151-162).
  static const Color diffAddDark = Color(0xFF4ADE80);
  static const Color diffDelDark = Color(0xFFFB7185);
  static const Color warnDark = Color(0xFFFBBF24);
  static const Color diffAddSoftDark = Color(0x1A4ADE80); // rgba(74,222,128,.1)
  static const Color diffDelSoftDark = Color(
    0x1AFB7185,
  ); // rgba(251,113,133,.1)
  static const Color warnSoftDark = Color(0x1AFBBF24); // rgba(251,191,36,.1)

  // Terminal embebida (fondo fijo del panel).
  static const Color terminal = Color(0xFF0D1117);

  /// Semántico adaptado al brillo (scope diff/código, no chrome).
  static Color diffAddOf(Brightness brightness) =>
      brightness == Brightness.dark ? diffAddDark : diffAdd;
  static Color diffDelOf(Brightness brightness) =>
      brightness == Brightness.dark ? diffDelDark : diffDel;
  static Color warnOf(Brightness brightness) =>
      brightness == Brightness.dark ? warnDark : warn;

  /// Chrome semántico adaptado al brillo (grises por diseño).
  static Color successOf(Brightness brightness) =>
      brightness == Brightness.dark ? darkSuccess : lightSuccess;
  static Color dangerOf(Brightness brightness) =>
      brightness == Brightness.dark ? darkDanger : lightDanger;
  static Color warningOf(Brightness brightness) =>
      brightness == Brightness.dark ? darkWarning : lightWarning;
}
