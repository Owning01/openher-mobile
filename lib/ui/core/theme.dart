/// Tema Material3 monocromo del cliente Android. Traduce `tokens.dart` a un
/// `ThemeData`: el CSS del prototipo ya está resuelto en tokens, así que acá
/// solo se cablean superficies, tipografía y overlays.
///
/// Decisiones que vienen medidas del prototipo (`prototype/mobile.html`):
/// - Base 13px / line-height 1.5 (:46); título de app bar 14/w600/1.25 (:121);
///   metadatos 12 (:177, :277); rótulos 11 (:80, :157, :265); tab bar 10.5 (:138).
/// - App bar y bottom nav miden 56px (:116, :132) → [appBarHeight] y
///   [mobileBarHeight].
/// - Iconos 20px base, 14/16/24 para los tamaños sm/xs/lg (:57-60).
/// - `svg.ic` + `background:var(--surface)` + `border-bottom:1px solid
///   var(--border)` en `.appbar` (:114-119) → `AppBarTheme.shape` con borde.
///
/// Paridad con el cliente desktop
/// (`openher-flutter-desktop/lib/ui/core/app_theme.dart`): el `error` del
/// `ColorScheme` es el token `danger` del chrome (gris), NO el rojo del scope
/// de diffs, para que el tema no introduzca color donde el diseño no lo tiene.
/// El color real (verde/rojo/ámbar) se pide siempre con `AppColors.diffAddOf`,
/// `AppColors.diffDelOf` o `AppColors.warnOf`.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Alturas de las dos barras fijas del cliente (`.appbar` y `.bottomnav`).
abstract final class AppTheme {
  /// Alto del app bar (`.appbar`, `min-height:56px`).
  static const double appBarHeight = 56;

  /// Alto de la barra inferior de pestañas (`.bottomnav`, `height:56px`).
  static const double mobileBarHeight = 56;

  /// Radio de las esquinas superiores del bottom sheet. El `.sheet-panel` del
  /// prototipo web redondea a 16px; acá va 12 para dejarle lugar a los chips
  /// de 12/16px que ya existen en la misma pantalla.
  static const double sheetRadius = 12;

  /// Tema claro.
  static ThemeData light() => _light;
  static ThemeData dark() => _dark;

  static final ThemeData _light = _base(Brightness.light);
  static final ThemeData _dark = _base(Brightness.dark);

  /// `ColorScheme` a partir de una semilla neutra (gris) y luego sobrescrito
  /// con los tokens, para que el color resuelto sea exactamente el del CSS en
  /// vez de una paleta tonal derivada. `surfaceContainer*` se fija también:
  /// Material3 las usa por defecto para cards, dialogs y menús, y saldrían
  ///-deviates- si se dejaran generadas desde la semilla.
  static ColorScheme _scheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return ColorScheme.fromSeed(
      seedColor: dark ? AppColors.darkPrimary : AppColors.lightPrimary,
      brightness: brightness,
    ).copyWith(
      primary: dark ? AppColors.darkPrimary : AppColors.lightPrimary,
      onPrimary: dark ? AppColors.darkOnPrimary : AppColors.lightOnPrimary,
      secondary: dark ? AppColors.darkSecondary : AppColors.lightSecondary,
      onSecondary: dark ? AppColors.darkOnPrimary : AppColors.lightOnPrimary,
      tertiary: dark ? AppColors.darkMuted : AppColors.lightMuted,
      // `danger` del chrome: gris monocromo por diseño.
      error: dark ? AppColors.darkDanger : AppColors.lightDanger,
      onError: dark ? AppColors.darkOnPrimary : AppColors.lightOnPrimary,
      surface: dark ? AppColors.darkSurface : AppColors.lightSurface,
      onSurface: dark ? AppColors.darkText : AppColors.lightText,
      onSurfaceVariant: dark ? AppColors.darkMuted : AppColors.lightMuted,
      surfaceContainerLowest: dark ? AppColors.darkBg : AppColors.lightBg,
      surfaceContainerLow: dark
          ? AppColors.darkSurfaceSubtle
          : AppColors.lightSurfaceSubtle,
      surfaceContainer: dark
          ? AppColors.darkSurfaceStrong
          : AppColors.lightSurfaceStrong,
      surfaceContainerHigh: dark
          ? AppColors.darkSurfaceHover
          : AppColors.lightSurfaceHover,
      surfaceContainerHighest: dark
          ? AppColors.darkSurfaceHover
          : AppColors.lightSurfaceHover,
      surfaceDim: dark ? AppColors.darkSurfaceSoft : AppColors.lightSurfaceSoft,
      surfaceBright: dark ? AppColors.darkSurface : AppColors.lightSurface,
      outline: dark ? AppColors.darkBorder : AppColors.lightBorder,
      outlineVariant: dark
          ? AppColors.darkBorderStrong
          : AppColors.lightBorderStrong,
      // El scrim del tema es el `--sheet-backdrop` del prototipo.
      scrim: dark ? AppColors.darkSheetBackdrop : AppColors.lightSheetBackdrop,
      shadow: const Color(0xFF000000),
    );
  }

  /// Escala tipográfica del prototipo móvil (:46, :70-71, :121-122, :138,
  /// :176-180). Material3 por defecto arranca en 22px, así que display/headline
  /// se colapsan al único título que el prototipo define: 14/w600.
  static TextTheme _textTheme(Color text, Color muted) {
    const base = TextStyle(fontSize: 13, height: 1.5, color: Colors.black);
    // letter-spacing em → px: título 14 × -0.01 = -0.14 (:70, :176).
    TextStyle title() => base.copyWith(
      color: text,
      fontSize: 14,
      height: 1.25,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.14,
    );
    TextStyle body() => base.copyWith(color: text);
    TextStyle meta() => base.copyWith(color: muted, fontSize: 12, height: 1.4);
    TextStyle label() => base.copyWith(
      color: muted,
      fontSize: 11,
      height: 1.3,
      fontWeight: FontWeight.w500,
    );
    return TextTheme(
      displayLarge: title(),
      displayMedium: title(),
      displaySmall: title(),
      headlineLarge: title(),
      headlineMedium: title(),
      headlineSmall: title(),
      titleLarge: title(),
      titleMedium: title(),
      titleSmall: meta().copyWith(fontWeight: FontWeight.w600),
      bodyLarge: body(),
      bodyMedium: body(),
      bodySmall: meta(),
      // 13/w500: el texto de los botones del prototipo (:70 base + w500).
      labelLarge: body().copyWith(fontWeight: FontWeight.w500),
      labelMedium: meta().copyWith(fontWeight: FontWeight.w500),
      labelSmall: label(),
    );
  }

  static ThemeData _base(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = _scheme(brightness);
    final text = dark ? AppColors.darkText : AppColors.lightText;
    final muted = dark ? AppColors.darkMuted : AppColors.lightMuted;
    final mutedStrong = dark
        ? AppColors.darkMutedStrong
        : AppColors.lightMutedStrong;
    final border = dark ? AppColors.darkBorder : AppColors.lightBorder;
    final borderStrong = dark
        ? AppColors.darkBorderStrong
        : AppColors.lightBorderStrong;
    final surface = dark ? AppColors.darkSurface : AppColors.lightSurface;
    final hover = dark
        ? AppColors.darkSurfaceHover
        : AppColors.lightSurfaceHover;
    final sheetBackdrop = dark
        ? AppColors.darkSheetBackdrop
        : AppColors.lightSheetBackdrop;
    final textTheme = _textTheme(text, muted);

    OutlineInputBorder field(BorderSide side) =>
        OutlineInputBorder(borderRadius: AppRadius.mdAll, borderSide: side);

    return (dark ? ThemeData.dark() : ThemeData.light()).copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: dark ? AppColors.darkBg : AppColors.lightBg,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      dividerColor: border,
      // `svg.ic` mide 20px en el prototipo (:57).
      iconTheme: IconThemeData(color: mutedStrong, size: 20),
      // `.appbar`: surface + borde inferior de 1px, sin elevación ni tinte M3.
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: appBarHeight,
        titleTextStyle: textTheme.titleLarge,
        iconTheme: IconThemeData(color: mutedStrong, size: 20),
        shape: Border(bottom: BorderSide(color: border)),
      ),
      // Ripple fuera (paridad web): sin splash, el pulsado queda en el
      // `highlightColor` al 8% del acento, igual que el desktop.
      splashFactory: NoSplash.splashFactory,
      highlightColor: scheme.primary.withValues(alpha: 0.08),
      // Inputs 13px, radio `--r2`, foco con `--primary` (:152-155, base.css).
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 10,
        ),
        labelStyle: textTheme.bodyMedium!.copyWith(color: muted),
        floatingLabelStyle: textTheme.bodySmall!.copyWith(color: text),
        hintStyle: textTheme.bodyMedium!.copyWith(color: muted),
        helperStyle: textTheme.bodySmall,
        errorStyle: textTheme.bodySmall!.copyWith(
          color: scheme.error,
          fontWeight: FontWeight.w500,
        ),
        border: field(BorderSide(color: border)),
        enabledBorder: field(BorderSide(color: border)),
        focusedBorder: field(BorderSide(color: scheme.primary)),
        errorBorder: field(BorderSide(color: scheme.error)),
        focusedErrorBorder: field(BorderSide(color: scheme.error)),
      ),
      // `.sheet`: scrim `--sheet-backdrop`, panel sin tinte y con handle.
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: sheetBackdrop,
        modalElevation: 0,
        elevation: 0,
        showDragHandle: true,
        dragHandleColor: borderStrong,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(sheetRadius),
          ),
        ),
      ),
      // Superficies: sin tinte M3 y con el radio de `--r2`.
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.lgAll),
      ),
      hoverColor: hover,
    );
  }
}
