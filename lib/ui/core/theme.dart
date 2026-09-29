/// Tema Material3 del cliente Android. Traduce `tokens.dart` a un `ThemeData`:
/// el CSS del prototipo ya está resuelto en tokens, así que acá solo se
/// cablean superficies, tipografía y overlays. Es el tema monocromo
/// (`light()`/`dark()`) y también la estructura que reutiliza cualquier
/// variante de color de [ThemeVariants].
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
///
/// ## Las variantes de color
/// [AppTheme.variantOf] mete una de las 61 paletas de
/// [ThemeVariants.builtIn] en la misma estructura, y lo hace por el mismo
/// camino: [_AppPalette] resuelve los slots y [_base] arma el `ThemeData` una
/// sola vez para las tres fuentes (tokens claros, tokens oscuros y variante).
/// Por eso elegir un tema no puede cambiar el layout ni el alto de las barras:
/// sólo los colores, y sólo los que trae la paleta.
library;

import 'package:flutter/material.dart';

import 'theme_variants.dart';
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

  static final ThemeData _light = _base(
    Brightness.light,
    _AppPalette.tokens(Brightness.light),
  );
  static final ThemeData _dark = _base(
    Brightness.dark,
    _AppPalette.tokens(Brightness.dark),
  );

  /// Tema de una variante de [ThemeVariants]: la estructura de siempre con
  /// otra paleta.
  ///
  /// Como la variante fija su propio brillo ([ThemeVariantKind.brightness]),
  /// el mismo `ThemeData` va en los dos slots de `MaterialApp` y da igual cuál
  /// sea el `themeMode` del sistema — igual que en el cliente desktop.
  /// [brightness] fuerza el brillo del `ColorScheme` cuando el que se quiere no
  /// es el del tipo de la variante.
  ///
  /// Se cachea por (id, brillo): `ThemeData` no tiene igualdad por valor, así
  /// que reconstruirlo en cada build del `MaterialApp` lo haría creer que el
  /// tema cambió y re-temaría el árbol entero en cada frame.
  static ThemeData variantOf(ThemeVariant variant, {Brightness? brightness}) {
    final resolved = brightness ?? variant.kind.brightness;
    final cacheKey = '${variant.id}|${resolved.name}';
    return _variantCache.putIfAbsent(
      cacheKey,
      () => _base(resolved, _AppPalette.ofVariant(variant.colors, resolved)),
    );
  }

  /// Los **dos** temas que necesita el `MaterialApp` para que la variante
  /// elegida se vea con cualquier brillo del sistema, o `null` si el id no
  /// existe en el catálogo.
  ///
  /// Existe por una razón medida. Cada variante tiene **un** brillo (36 dark y
  /// 29 light en el catálogo) y el `MaterialApp` pide **dos** temas: `theme`
  /// (claro) y `darkTheme` (oscuro), y elige uno según el brillo de la
  /// plataforma. Si la variante se asigna al slot que le corresponde por su
  /// `kind`, el otro slot queda con el chrome por defecto y **el tema elegido
  /// se descarta en silencio**: con `themeMode: system` y el teléfono en
  /// oscuro, una variante clara no se veía, y al revés tampoco. Medido sobre
  /// las 61 variantes por los dos brillos: **61 de 122 casos** quedaban con el
  /// gris de siempre, o sea la mitad.
  ///
  /// Acá la variante se **traduce** a cada brillo, que es justo para lo que
  /// [variantOf] acepta. Los colores son los de la variante en los dos slots:
  /// lo que se elige es lo que se ve, y el ajuste claro/oscuro decide en qué
  /// brillo se pinta.
  static ({ThemeData light, ThemeData dark})? variantPair(String? variantId) {
    final v = ThemeVariants.byId(variantId);
    if (v == null) return null;
    return (
      light: variantOf(v, brightness: Brightness.light),
      dark: variantOf(v, brightness: Brightness.dark),
    );
  }

  static final Map<String, ThemeData> _variantCache = <String, ThemeData>{};

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

  static ThemeData _base(Brightness brightness, _AppPalette palette) {
    final dark = brightness == Brightness.dark;
    final scheme = palette.scheme;
    final text = palette.text;
    final muted = palette.muted;
    final mutedStrong = palette.mutedStrong;
    final border = palette.border;
    final borderStrong = palette.borderStrong;
    final surface = palette.surface;
    final hover = palette.surfaceHover;
    final sheetBackdrop = palette.scrim;
    final textTheme = _textTheme(text, muted);

    OutlineInputBorder field(BorderSide side) =>
        OutlineInputBorder(borderRadius: AppRadius.mdAll, borderSide: side);

    return (dark ? ThemeData.dark() : ThemeData.light()).copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: palette.bg,
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

/// Los slots que [AppTheme._base] cablea, resueltos para un tema concreto.
///
/// Hay dos fuentes y **una sola** forma de consumirlas: los tokens del chrome
/// ([_AppPalette.tokens]) y la paleta de una variante
/// ([_AppPalette.ofVariant]). Por eso `light()`, `dark()` y
/// [AppTheme.variantOf] comparten la construcción del `ThemeData`: la
/// estructura no puede derivar entre un tema y otro, y el `ColorScheme` se arma
/// en un único lugar en vez de en dos que se van pareciendo cada vez menos.
@immutable
class _AppPalette {
  const _AppPalette({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surfaceSubtle,
    required this.surfaceStrong,
    required this.surfaceSoft,
    required this.surfaceHover,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.muted,
    required this.mutedStrong,
    required this.primary,
    required this.onPrimary,
    required this.secondary,
    required this.onSecondary,
    required this.tertiary,
    required this.error,
    required this.onError,
    required this.scrim,
  });

  /// Paleta monocroma del chrome: los tokens de `tokens.dart`, sin cambiar ni
  /// uno. Es lo que pintan `light()` y `dark()`.
  factory _AppPalette.tokens(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return _AppPalette(
      brightness: brightness,
      bg: dark ? AppColors.darkBg : AppColors.lightBg,
      surface: dark ? AppColors.darkSurface : AppColors.lightSurface,
      surfaceSubtle: dark
          ? AppColors.darkSurfaceSubtle
          : AppColors.lightSurfaceSubtle,
      surfaceStrong: dark
          ? AppColors.darkSurfaceStrong
          : AppColors.lightSurfaceStrong,
      surfaceSoft: dark
          ? AppColors.darkSurfaceSoft
          : AppColors.lightSurfaceSoft,
      surfaceHover: dark
          ? AppColors.darkSurfaceHover
          : AppColors.lightSurfaceHover,
      border: dark ? AppColors.darkBorder : AppColors.lightBorder,
      borderStrong: dark
          ? AppColors.darkBorderStrong
          : AppColors.lightBorderStrong,
      text: dark ? AppColors.darkText : AppColors.lightText,
      muted: dark ? AppColors.darkMuted : AppColors.lightMuted,
      mutedStrong: dark
          ? AppColors.darkMutedStrong
          : AppColors.lightMutedStrong,
      primary: dark ? AppColors.darkPrimary : AppColors.lightPrimary,
      onPrimary: dark ? AppColors.darkOnPrimary : AppColors.lightOnPrimary,
      secondary: dark ? AppColors.darkSecondary : AppColors.lightSecondary,
      onSecondary: dark ? AppColors.darkOnPrimary : AppColors.lightOnPrimary,
      tertiary: dark ? AppColors.darkMuted : AppColors.lightMuted,
      // `danger` del chrome: gris monocromo por diseño.
      error: dark ? AppColors.darkDanger : AppColors.lightDanger,
      onError: dark ? AppColors.darkOnPrimary : AppColors.lightOnPrimary,
      scrim: dark ? AppColors.darkSheetBackdrop : AppColors.lightSheetBackdrop,
    );
  }

  /// Paleta de una variante. Los slots que la variante no trae salen de su
  /// propia paleta o de los tokens, nunca inventados:
  ///
  /// - `mutedStrong` → `muted`. La variante no tiene un muted "más fuerte" y
  ///   su `muted` ya salió del `resolveTheme` con contraste garantizado, así que
  ///   usarlo para el ícono del app bar no pierde legibilidad.
  /// - `surfaceSubtle` → la mezcla de `bg` y `surfaceStrong` a mitades: es la
  ///   misma interpolación con la que el escritorio armaba
  ///   `surfaceContainerLow` de una paleta.
  /// - `surfaceSoft` → igual que `surfaceSubtle`. Sólo alimenta `surfaceDim`, y
  ///   no hacía falta traer un slot que ninguna de las 61 paletas tiene.
  /// - `scrim` → el token `--sheet-backdrop`. Es negro con alfa en los tokens y
  ///   en las 61 paletas: el scrim no lo define la variante.
  factory _AppPalette.ofVariant(
    ThemeVariantColors colors,
    Brightness brightness,
  ) {
    final subtle =
        Color.lerp(colors.bg, colors.surfaceStrong, 0.5) ?? colors.bg;
    return _AppPalette(
      brightness: brightness,
      bg: colors.bg,
      surface: colors.surface,
      surfaceSubtle: subtle,
      surfaceStrong: colors.surfaceStrong,
      surfaceSoft: subtle,
      surfaceHover: colors.surfaceHover,
      border: colors.border,
      borderStrong: colors.borderStrong,
      text: colors.text,
      muted: colors.muted,
      mutedStrong: colors.muted,
      primary: colors.primary,
      onPrimary: ThemeVariantColors.onColor(colors.primary),
      secondary: colors.secondary,
      onSecondary: ThemeVariantColors.onColor(colors.secondary),
      tertiary: colors.muted,
      // Con variante el chrome deja de ser monocromo: `error` es el `danger`
      // real de la paleta, como en el escritorio.
      error: colors.danger,
      onError: ThemeVariantColors.onColor(colors.danger),
      scrim: brightness == Brightness.dark
          ? AppColors.darkSheetBackdrop
          : AppColors.lightSheetBackdrop,
    );
  }

  final Brightness brightness;
  final Color bg;
  final Color surface;
  final Color surfaceSubtle;
  final Color surfaceStrong;
  final Color surfaceSoft;
  final Color surfaceHover;
  final Color border;
  final Color borderStrong;
  final Color text;
  final Color muted;
  final Color mutedStrong;
  final Color primary;
  final Color onPrimary;
  final Color secondary;
  final Color onSecondary;
  final Color tertiary;
  final Color error;
  final Color onError;
  final Color scrim;

  /// `ColorScheme` a partir de una semilla neutra (gris) y luego sobrescrito con
  /// los slots, para que el color resuelto sea exactamente el de la paleta en
  /// vez de una paleta tonal derivada. `surfaceContainer*` se fija también:
  /// Material3 las usa por defecto para cards, dialogs y menús, y saldrían
  /// desviadas si se dejaran generadas desde la semilla.
  ColorScheme get scheme =>
      ColorScheme.fromSeed(seedColor: primary, brightness: brightness).copyWith(
        primary: primary,
        onPrimary: onPrimary,
        secondary: secondary,
        onSecondary: onSecondary,
        tertiary: tertiary,
        error: error,
        onError: onError,
        surface: surface,
        onSurface: text,
        onSurfaceVariant: muted,
        surfaceContainerLowest: bg,
        surfaceContainerLow: surfaceSubtle,
        surfaceContainer: surfaceStrong,
        surfaceContainerHigh: surfaceHover,
        surfaceContainerHighest: surfaceHover,
        surfaceDim: surfaceSoft,
        surfaceBright: surface,
        outline: border,
        outlineVariant: borderStrong,
        scrim: scrim,
        shadow: const Color(0xFF000000),
      );
}
