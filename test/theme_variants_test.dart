/// Catálogo de variantes de tema + el `ThemeData` que produce cada una.
///
/// Lo que se verifica acá es el contrato del port contra el cliente desktop:
/// cuántas variantes hay y cómo se llaman, que la paleta de cada una sea la del
/// escritorio (no una reinterpretación), que los valores derivados no estén
/// hardcodeados, y que `light()`/`dark()` sigan siendo exactamente los de antes
/// de que existiera este archivo.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/core/theme_variants.dart';
import 'package:openher_mobile/ui/core/tokens.dart';

void main() {
  group('el catálogo tiene lo mismo que el escritorio', () {
    test('61 variantes: 33 oscuras y 28 claras', () {
      // El cliente desktop trae 33 temas del original más las paletas claras
      // que sus JSON definían aparte. Si el número se mueve, el port dejó de
      // copiar algo: hay que revisarlo, no actualizar el número.
      expect(ThemeVariants.builtIn, hasLength(61));
      expect(ThemeVariants.ofKind(ThemeVariantKind.dark), hasLength(33));
      expect(ThemeVariants.ofKind(ThemeVariantKind.light), hasLength(28));
    });

    test('los 33 nombres del cliente desktop, en el mismo orden', () {
      expect(ThemeVariants.builtIn.map((variant) => variant.id), <String>[
        'aura',
        'ayu',
        'carbonfox',
        'carbonfox-light',
        'catppuccin',
        'catppuccin-light',
        'catppuccin-frappe',
        'catppuccin-macchiato',
        'cobalt2',
        'cobalt2-light',
        'cursor',
        'cursor-light',
        'dracula',
        'dracula-light',
        'everforest',
        'everforest-light',
        'flexoki',
        'flexoki-light',
        'github',
        'github-light',
        'gruvbox',
        'gruvbox-light',
        'kanagawa',
        'kanagawa-light',
        'lucent-orng',
        'lucent-orng-light',
        'material',
        'material-light',
        'matrix',
        'matrix-light',
        'mercury',
        'mercury-light',
        'monokai',
        'monokai-light',
        'nightowl',
        'nord',
        'nord-light',
        'one-dark',
        'one-dark-light',
        'opencode',
        'opencode-light',
        'orng',
        'orng-light',
        'osaka-jade',
        'osaka-jade-light',
        'palenight',
        'palenight-light',
        'rosepine',
        'rosepine-light',
        'solarized',
        'solarized-light',
        'synthwave84',
        'synthwave84-light',
        'tokyonight',
        'tokyonight-light',
        'vercel',
        'vercel-light',
        'vesper',
        'vesper-light',
        'zenburn',
        'zenburn-light',
      ]);
    });

    test(
      'los ids son únicos y el nombre de la paleta clara lleva el sufijo',
      () {
        final ids = ThemeVariants.builtIn.map((variant) => variant.id).toList();
        expect(ids.toSet(), hasLength(61), reason: 'ningún id repetido');

        for (final variant in ThemeVariants.builtIn.where(
          (variant) => variant.id.endsWith('-light'),
        )) {
          expect(variant.name, endsWith('(claro)'));
          expect(variant.kind, ThemeVariantKind.light);
          // Toda paleta clara tiene su gemela oscura: menos la original, que es
          // la que no cambió de nombre.
          expect(
            ThemeVariants.byId(variant.id.substring(0, variant.id.length - 6)),
            isNotNull,
            reason: '${variant.id} sin gemelo oscuro',
          );
        }
      },
    );

    test('byId resuelve, y tolera null, vacío y basura', () {
      expect(ThemeVariants.byId('dracula')!.name, 'Dracula');
      expect(ThemeVariants.byId('dracula-light')!.kind, ThemeVariantKind.light);
      expect(ThemeVariants.byId(null), isNull);
      expect(ThemeVariants.byId(''), isNull);
      expect(
        ThemeVariants.byId('no-existe'),
        isNull,
        reason: 'una pref vieja no rompe la pantalla',
      );
    });

    test('el tipo de cada variante sale del que le corresponde', () {
      for (final variant in ThemeVariants.builtIn) {
        final expected = variant.id.endsWith('-light')
            ? ThemeVariantKind.light
            : ThemeVariantKind.dark;
        expect(variant.kind, expected, reason: variant.id);
      }
      expect(ThemeVariantKind.dark.brightness, Brightness.dark);
      expect(ThemeVariantKind.light.brightness, Brightness.light);
      expect(ThemeVariantKind.dark.label, 'Oscuro');
      expect(ThemeVariantKind.light.label, 'Claro');
      expect(ThemeVariantKind.fromWire('light'), ThemeVariantKind.light);
      expect(
        ThemeVariantKind.fromWire(null),
        ThemeVariantKind.dark,
        reason: 'un tipo desconocido no es un crash',
      );
    });
  });

  group('las paletas son las del escritorio, no una reinterpretación', () {
    test('Dracula', () {
      final colors = ThemeVariants.byId('dracula')!.colors;
      expect(colors.bg, const Color(0xFF282A36));
      expect(colors.surface, const Color(0xFF21222C));
      expect(colors.surfaceStrong, const Color(0xFF44475A));
      expect(colors.border, const Color(0xFF44475A));
      expect(colors.borderStrong, const Color(0xFFBD93F9));
      expect(colors.text, const Color(0xFFF8F8F2));
      expect(colors.muted, const Color(0xFF8995BB));
      expect(colors.primary, const Color(0xFFBD93F9));
      expect(colors.accent, const Color(0xFF8BE9FD));
      expect(colors.secondary, const Color(0xFFFF79C6));
      expect(colors.danger, const Color(0xFFFF5555));
      expect(colors.warning, const Color(0xFFF1FA8C));
      expect(colors.success, const Color(0xFF50FA7B));
      expect(colors.info, const Color(0xFFFFB86C));
      expect(colors.codeBg, const Color(0xFF44475A));
      expect(colors.codeText, const Color(0xFFF8F8F2));
    });

    test('GitHub (claro)', () {
      final colors = ThemeVariants.byId('github-light')!.colors;
      expect(colors.bg, const Color(0xFFFFFFFF));
      expect(colors.surface, const Color(0xFFF6F8FA));
      expect(colors.surfaceStrong, const Color(0xFFF0F3F6));
      expect(colors.border, const Color(0xFFD0D7DE));
      expect(colors.text, const Color(0xFF24292F));
      expect(colors.muted, const Color(0xFF57606A));
      expect(colors.primary, const Color(0xFF0969DA));
      expect(colors.secondary, const Color(0xFF8250DF));
      expect(colors.danger, const Color(0xFFCF222E));
      expect(colors.surfaceHover, isNot(colors.surfaceStrong));
    });

    test('OpenCode: el monocromo de la casa como tema con acento', () {
      // El `opencode` del catálogo comparte el fondo, la superficie y el texto
      // del chrome oscuro (`--bg`/`--surface`/`--text`): es el tema de la casa.
      // Lo que lo distingue como variante es el primario índigo.
      final dark = ThemeVariants.byId('opencode')!.colors;
      expect(dark.bg, AppColors.darkBg);
      expect(dark.surface, AppColors.darkSurface);
      expect(dark.text, AppColors.darkText);
      expect(dark.muted, AppColors.darkMuted);
      expect(dark.primary, const Color(0xFF6366F1));
      expect(dark.primary, isNot(AppColors.darkPrimary));

      final light = ThemeVariants.byId('opencode-light')!.colors;
      expect(light.bg, const Color(0xFFFFFFFF));
      expect(light.text, const Color(0xFF1A1A1A));
      expect(light.primary, const Color(0xFF3B7DD8));
    });

    test('ninguna variante repite el primario del chrome', () {
      // El fondo puede coincidir (diez paletas claras son blanco sobre blanco y
      // `opencode` es el propio monocromo), pero el primario es lo que
      // identifica un tema: si alguno repitiera el gris del chrome, elegirlo no
      // cambiaría nada y sería una variante muerta.
      const monoPrimary = <Color>[
        AppColors.lightPrimary,
        AppColors.darkPrimary,
      ];
      for (final variant in ThemeVariants.builtIn) {
        expect(
          monoPrimary,
          isNot(contains(variant.colors.primary)),
          reason: '${variant.id} repite el primario del chrome',
        );
      }
    });
  });

  group('los derivados se calculan, no se repiten', () {
    test('surfaceHover es la mezcla de surfaceStrong y borderStrong', () {
      for (final variant in ThemeVariants.builtIn) {
        final colors = variant.colors;
        expect(
          colors.surfaceHover,
          Color.lerp(colors.surfaceStrong, colors.borderStrong, 0.5),
          reason: variant.id,
        );
      }
    });

    test('onColor elige el de más contraste', () {
      const white = Color(0xFFFFFFFF);
      const black = Color(0xFF0A0A0A);
      expect(ThemeVariantColors.onColor(const Color(0xFF000000)), white);
      expect(ThemeVariantColors.onColor(const Color(0xFFFFFFFF)), black);
      // Dracula: primario claro -> texto oscuro encima.
      expect(ThemeVariantColors.onColor(const Color(0xFFBD93F9)), isNot(white));
      // Cobalt2: danger saturado -> texto oscuro encima.
      expect(ThemeVariantColors.onColor(const Color(0xFFFF0088)), isNot(white));
    });

    test('swatch son cuatro muestras de la propia paleta', () {
      for (final variant in ThemeVariants.builtIn) {
        expect(variant.colors.swatch, hasLength(4), reason: variant.id);
        expect(variant.colors.swatch, <Color>[
          variant.colors.bg,
          variant.colors.surfaceStrong,
          variant.colors.primary,
          variant.colors.accent,
        ], reason: variant.id);
      }
    });
  });

  group('variantOf: la paleta entra, la estructura no se mueve', () {
    final dracula = ThemeVariants.byId('dracula')!;
    final catppuccinLatte = ThemeVariants.byId('catppuccin-light')!;

    test('el ColorScheme es el de la variante', () {
      final scheme = AppTheme.variantOf(dracula).colorScheme;
      expect(scheme.brightness, Brightness.dark);
      expect(scheme.primary, dracula.colors.primary);
      expect(
        scheme.onPrimary,
        ThemeVariantColors.onColor(dracula.colors.primary),
      );
      expect(scheme.secondary, dracula.colors.secondary);
      expect(scheme.tertiary, dracula.colors.muted);
      expect(scheme.surface, dracula.colors.surface);
      expect(scheme.onSurface, dracula.colors.text);
      expect(scheme.onSurfaceVariant, dracula.colors.muted);
      expect(scheme.outline, dracula.colors.border);
      expect(scheme.outlineVariant, dracula.colors.borderStrong);
      expect(scheme.surfaceContainerLowest, dracula.colors.bg);
      expect(scheme.surfaceContainerHigh, dracula.colors.surfaceHover);
      // Con variante el chrome sí lleva color: `error` es el `danger` real.
      expect(scheme.error, dracula.colors.danger);
      expect(scheme.error, isNot(AppColors.darkDanger));
    });

    test('una paleta clara pinta un scheme claro', () {
      final scheme = AppTheme.variantOf(catppuccinLatte).colorScheme;
      expect(scheme.brightness, Brightness.light);
      expect(scheme.primary, catppuccinLatte.colors.primary);
      expect(scheme.onSurface, catppuccinLatte.colors.text);
      expect(scheme.error, catppuccinLatte.colors.danger);
    });

    test('el fondo del scaffold y los divisores son de la variante', () {
      final theme = AppTheme.variantOf(dracula);
      expect(theme.scaffoldBackgroundColor, dracula.colors.bg);
      expect(theme.dividerColor, dracula.colors.border);
      expect(theme.colorScheme.brightness, dracula.kind.brightness);
    });

    test('la estructura es la misma que la del tema monocromo', () {
      final variant = AppTheme.variantOf(dracula);
      final mono = AppTheme.dark();
      // Radios, alturas y escala: identical entre todos los temas, porque salen
      // de los tokens y no de la paleta.
      expect(variant.appBarTheme.toolbarHeight, mono.appBarTheme.toolbarHeight);
      expect(variant.appBarTheme.toolbarHeight, AppTheme.appBarHeight);
      expect(variant.cardTheme.shape, mono.cardTheme.shape);
      expect(variant.cardTheme.elevation, mono.cardTheme.elevation);
      expect(variant.dialogTheme.shape, mono.dialogTheme.shape);
      expect(
        variant.inputDecorationTheme.contentPadding,
        mono.inputDecorationTheme.contentPadding,
      );
      expect(variant.bottomSheetTheme.backgroundColor, dracula.colors.surface);
      expect(
        variant.bottomSheetTheme.shape,
        mono.bottomSheetTheme.shape,
        reason: 'el radio de la hoja no lo define la paleta',
      );
      expect(
        variant.bottomSheetTheme.showDragHandle,
        isTrue,
        reason: 'el handle va siempre',
      );
      expect(variant.splashFactory, same(NoSplash.splashFactory));
      // La tipografía conserva la escala del prototipo móvil (título 14/w600),
      // no la del escritorio: la variante cambia colores, no el layout.
      expect(variant.textTheme.titleLarge!.fontSize, 14);
      expect(variant.textTheme.titleLarge!.fontWeight, FontWeight.w600);
      expect(variant.textTheme.bodyMedium!.fontSize, 13);
      // Sólo cambia el color del texto.
      expect(variant.textTheme.bodyMedium!.color, dracula.colors.text);
      expect(
        mono.textTheme.bodyMedium!.fontSize,
        variant.textTheme.bodyMedium!.fontSize,
      );
    });

    test('el texto de los iconos y de las barras usa la paleta', () {
      final variant = AppTheme.variantOf(dracula);
      expect(variant.appBarTheme.backgroundColor, dracula.colors.surface);
      expect(variant.appBarTheme.foregroundColor, dracula.colors.text);
      expect(
        variant.appBarTheme.shape,
        isA<Border>().having(
          (Border border) => border.bottom.color,
          'borde inferior',
          dracula.colors.border,
        ),
      );
    });

    test('el scrim sigue siendo el token, no lo define la variante', () {
      for (final id in <String>['dracula', 'catppuccin-light']) {
        final variant = ThemeVariants.byId(id)!;
        final theme = AppTheme.variantOf(variant);
        expect(
          theme.colorScheme.scrim,
          variant.kind == ThemeVariantKind.dark
              ? AppColors.darkSheetBackdrop
              : AppColors.lightSheetBackdrop,
          reason: id,
        );
        expect(
          theme.bottomSheetTheme.modalBarrierColor,
          theme.colorScheme.scrim,
          reason: id,
        );
      }
    });

    test('surfaces que la variante no trae salen de su propia paleta', () {
      // `surfaceContainerLow` no tiene slot en el catálogo: es la mezcla de
      // `bg` y `surfaceStrong` a mitades, como en el escritorio.
      final colors = dracula.colors;
      expect(
        AppTheme.variantOf(dracula).colorScheme.surfaceContainerLow,
        Color.lerp(colors.bg, colors.surfaceStrong, 0.5),
      );
    });

    test('cada variante produce un tema distinto del monocromo', () {
      for (final variant in ThemeVariants.builtIn) {
        final theme = AppTheme.variantOf(variant);
        final mono = variant.kind == ThemeVariantKind.dark
            ? AppTheme.dark()
            : AppTheme.light();
        expect(
          theme.colorScheme.primary,
          isNot(mono.colorScheme.primary),
          reason: '${variant.id} debe verse distinto al monocromo',
        );
      }
    });

    test('el brillo forjado manda sobre el de la variante', () {
      // Con el brillo del sistema encima, la misma paleta se puede pintar en
      // los dos slots de MaterialApp.
      expect(
        AppTheme.variantOf(
          catppuccinLatte,
          brightness: Brightness.dark,
        ).colorScheme.brightness,
        Brightness.dark,
      );
      expect(
        AppTheme.variantOf(
          catppuccinLatte,
          brightness: Brightness.dark,
        ).colorScheme.primary,
        catppuccinLatte.colors.primary,
        reason: 'la paleta no cambia, sólo su sección de brillo',
      );
    });

    test(
      'el mismo tema se devuelve siempre igual (para no re-temar el árbol)',
      () {
        // `ThemeData` no tiene igualdad por valor: sin cachear, el MaterialApp
        // creería que el tema cambió en cada build.
        expect(
          identical(AppTheme.variantOf(dracula), AppTheme.variantOf(dracula)),
          isTrue,
        );
        expect(
          identical(
            AppTheme.variantOf(dracula),
            AppTheme.variantOf(dracula, brightness: dracula.kind.brightness),
          ),
          isTrue,
          reason: 'el brillo por defecto es el de la variante',
        );
        expect(
          identical(
            AppTheme.variantOf(dracula),
            AppTheme.variantOf(ThemeVariants.byId('dracula')!),
          ),
          isTrue,
        );
        expect(
          identical(
            AppTheme.variantOf(dracula),
            AppTheme.variantOf(catppuccinLatte),
          ),
          isFalse,
          reason: 'paletas distintas, temas distintos',
        );
      },
    );
  });

  group('light() y dark() siguen siendo los de antes', () {
    test('los tokens no se movieron al portar las variantes', () {
      // Es el contrato de `theme_test.dart` repetido acá: el port no puede
      // cambiar el monocromo. Los valores literales son los de `tokens.dart`.
      expect(AppTheme.light().colorScheme.surface, AppColors.lightSurface);
      expect(AppTheme.light().colorScheme.onSurface, AppColors.lightText);
      expect(AppTheme.light().colorScheme.primary, AppColors.lightPrimary);
      expect(AppTheme.light().colorScheme.error, AppColors.lightDanger);
      expect(AppTheme.light().scaffoldBackgroundColor, AppColors.lightBg);
      expect(AppTheme.dark().colorScheme.surface, AppColors.darkSurface);
      expect(AppTheme.dark().colorScheme.onSurface, AppColors.darkText);
      expect(AppTheme.dark().colorScheme.primary, AppColors.darkPrimary);
      expect(AppTheme.dark().colorScheme.error, AppColors.darkDanger);
      expect(AppTheme.dark().scaffoldBackgroundColor, AppColors.darkBg);
      expect(
        AppTheme.light().colorScheme.surfaceContainerLow,
        AppColors.lightSurfaceSubtle,
      );
      expect(
        AppTheme.dark().colorScheme.surfaceContainerLow,
        AppColors.darkSurfaceSubtle,
      );
      expect(
        AppTheme.light().colorScheme.surfaceDim,
        AppColors.lightSurfaceSoft,
      );
      expect(AppTheme.dark().colorScheme.surfaceDim, AppColors.darkSurfaceSoft);
      expect(AppTheme.light().colorScheme.scrim, AppColors.lightSheetBackdrop);
      expect(AppTheme.dark().colorScheme.scrim, AppColors.darkSheetBackdrop);
    });

    test('el mono sigue siendo monocromo: `error` es el gris del chrome', () {
      expect(AppTheme.light().colorScheme.error, isNot(AppColors.diffDel));
      expect(AppTheme.dark().colorScheme.error, isNot(AppColors.diffDelDark));
      expect(AppTheme.light().colorScheme.primary, isNot(AppColors.diffAdd));
      expect(AppTheme.dark().colorScheme.primary, isNot(AppColors.diffAddDark));
    });

    test('el mono ignora el catálogo por completo', () {
      // Elegir un tema no puede contaminar el monocromo: se calcula aparte.
      AppTheme.variantOf(ThemeVariants.byId('dracula')!);
      expect(
        AppTheme.light().colorScheme.surface,
        AppColors.lightSurface,
        reason: 'light() ya estaba cacheado y no se toca',
      );
      expect(AppTheme.dark().colorScheme.surface, AppColors.darkSurface);
    });

    test('`light()` y `dark()` no se parecen entre sí', () {
      expect(AppTheme.light().brightness, Brightness.light);
      expect(AppTheme.dark().brightness, Brightness.dark);
      expect(
        AppTheme.light().colorScheme.surface,
        isNot(AppTheme.dark().colorScheme.surface),
      );
      expect(
        AppTheme.light().colorScheme.onSurface,
        isNot(AppTheme.dark().colorScheme.onSurface),
      );
    });
  });
}
