import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/core/tokens.dart';

void main() {
  group('colorScheme', () {
    test('light resuelve exactamente los tokens', () {
      final scheme = AppTheme.light().colorScheme;
      expect(scheme.surface, AppColors.lightSurface);
      expect(scheme.onSurface, AppColors.lightText);
      expect(scheme.primary, AppColors.lightPrimary);
      expect(scheme.onPrimary, AppColors.lightOnPrimary);
      expect(scheme.outline, AppColors.lightBorder);
      // `error` es el `danger` del chrome (gris), NO el rojo del scope de diffs.
      expect(scheme.error, AppColors.lightDanger);
      expect(scheme.error, isNot(AppColors.diffDel));
      expect(scheme.outlineVariant, AppColors.lightBorderStrong);
      expect(scheme.onSurfaceVariant, AppColors.lightMuted);
      expect(scheme.secondary, AppColors.lightSecondary);
      expect(scheme.surfaceContainerLowest, AppColors.lightBg);
      expect(scheme.surfaceContainerLow, AppColors.lightSurfaceSubtle);
      expect(scheme.surfaceContainerHigh, AppColors.lightSurfaceHover);
    });

    test('dark resuelve exactamente los tokens', () {
      final scheme = AppTheme.dark().colorScheme;
      expect(scheme.surface, AppColors.darkSurface);
      expect(scheme.onSurface, AppColors.darkText);
      expect(scheme.primary, AppColors.darkPrimary);
      expect(scheme.onPrimary, AppColors.darkOnPrimary);
      expect(scheme.outline, AppColors.darkBorder);
      expect(scheme.error, AppColors.darkDanger);
      expect(scheme.error, isNot(AppColors.diffDelDark));
      expect(scheme.outlineVariant, AppColors.darkBorderStrong);
      expect(scheme.onSurfaceVariant, AppColors.darkMuted);
      expect(scheme.secondary, AppColors.darkSecondary);
      expect(scheme.surfaceContainerLowest, AppColors.darkBg);
      expect(scheme.surfaceContainerLow, AppColors.darkSurfaceSubtle);
      expect(scheme.surfaceContainerHigh, AppColors.darkSurfaceHover);
    });

    test('los hex esperados, literales', () {
      // Falla si alguien "corrige" un token sin darse cuenta.
      expect(AppTheme.light().colorScheme.surface, const Color(0xFFFFFFFF));
      expect(AppTheme.light().colorScheme.onSurface, const Color(0xFF18181B));
      expect(AppTheme.light().colorScheme.error, const Color(0xFF52525B));
      expect(AppTheme.dark().colorScheme.surface, const Color(0xFF121215));
      expect(AppTheme.dark().colorScheme.onSurface, const Color(0xFFF4F4F5));
      expect(AppTheme.dark().colorScheme.error, const Color(0xFFD4D4D8));
    });

    test('el brillo del scheme sigue al tema', () {
      expect(AppTheme.light().colorScheme.brightness, Brightness.light);
      expect(AppTheme.light().brightness, Brightness.light);
      expect(AppTheme.dark().colorScheme.brightness, Brightness.dark);
      expect(AppTheme.dark().brightness, Brightness.dark);
    });

    test('light y dark no son el mismo tema', () {
      expect(AppTheme.light(), isNot(same(AppTheme.dark())));
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

  group('scaffold y divisores', () {
    test('fondo del scaffold = --bg', () {
      expect(AppTheme.light().scaffoldBackgroundColor, AppColors.lightBg);
      expect(AppTheme.dark().scaffoldBackgroundColor, AppColors.darkBg);
    });

    test('dividerColor = --border', () {
      expect(AppTheme.light().dividerColor, AppColors.lightBorder);
      expect(AppTheme.dark().dividerColor, AppColors.darkBorder);
    });
  });

  group('textTheme', () {
    test('bodyMedium es 13px (base del prototipo, mobile.html :46)', () {
      expect(AppTheme.light().textTheme.bodyMedium?.fontSize, 13);
      expect(AppTheme.dark().textTheme.bodyMedium?.fontSize, 13);
    });

    test('la escala de labels', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final text = theme.textTheme;
        expect(text.labelSmall?.fontSize, 11, reason: 'labelSmall ~11px');
        expect(text.labelSmall?.fontWeight, FontWeight.w500);
        expect(text.labelMedium?.fontSize, 12);
        expect(text.labelMedium?.fontWeight, FontWeight.w500);
        expect(text.labelLarge?.fontSize, 13, reason: 'texto de botón 13/w500');
        expect(text.labelLarge?.fontWeight, FontWeight.w500);
      }
    });

    test('el título de app bar es 14/w600 (:121)', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        expect(theme.textTheme.titleLarge?.fontSize, 14);
        expect(theme.textTheme.titleLarge?.fontWeight, FontWeight.w600);
      }
    });

    test('el color del texto sale del token, no del default M3', () {
      expect(AppTheme.light().textTheme.bodyMedium?.color, AppColors.lightText);
      expect(AppTheme.light().textTheme.bodySmall?.color, AppColors.lightMuted);
      expect(AppTheme.dark().textTheme.bodyMedium?.color, AppColors.darkText);
      expect(AppTheme.dark().textTheme.bodySmall?.color, AppColors.darkMuted);
    });

    test('primaryTextTheme no se queda con el default de Material', () {
      // Si no se cablea, el texto sobre superficies oscuras sale a 22px.
      expect(
        AppTheme.dark().primaryTextTheme.bodyMedium?.fontSize,
        AppTheme.dark().textTheme.bodyMedium?.fontSize,
      );
      expect(AppTheme.dark().primaryTextTheme.bodyMedium?.fontSize, isNotNull);
    });

    test('ningún rol de texto se va de la escala del prototipo', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        for (final entry in _sizes(theme.textTheme).entries) {
          expect(
            entry.value,
            inInclusiveRange(11, 14),
            reason: '${entry.key} fuera de la escala 11-14px',
          );
        }
      }
    });
  });

  group('appBarTheme', () {
    test('toolbarHeight == 56 (:116)', () {
      expect(AppTheme.light().appBarTheme.toolbarHeight, 56);
      expect(AppTheme.dark().appBarTheme.toolbarHeight, 56);
      expect(AppTheme.appBarHeight, 56);
    });

    test('fondo = --surface, sin tinte M3 ni elevación', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        expect(theme.appBarTheme.backgroundColor, theme.colorScheme.surface);
        expect(theme.appBarTheme.surfaceTintColor, Colors.transparent);
        expect(theme.appBarTheme.elevation, 0);
        expect(theme.appBarTheme.scrolledUnderElevation, 0);
        expect(theme.appBarTheme.centerTitle, isFalse);
      }
      expect(
        AppTheme.light().appBarTheme.backgroundColor,
        AppColors.lightSurface,
      );
      expect(
        AppTheme.dark().appBarTheme.backgroundColor,
        AppColors.darkSurface,
      );
    });

    test('el borde inferior usa --border (:119)', () {
      final light = AppTheme.light().appBarTheme.shape as Border;
      expect(light.bottom.color, AppColors.lightBorder);
      final dark = AppTheme.dark().appBarTheme.shape as Border;
      expect(dark.bottom.color, AppColors.darkBorder);
    });
  });

  group('iconTheme', () {
    test('20px base y color = --muted-strong (:57, :125)', () {
      expect(AppTheme.light().iconTheme.size, 20);
      expect(AppTheme.dark().iconTheme.size, 20);
      expect(AppTheme.light().iconTheme.color, AppColors.lightMutedStrong);
      expect(AppTheme.dark().iconTheme.color, AppColors.darkMutedStrong);
    });
  });

  group('inputDecorationTheme', () {
    test('13px, denso y radio --r2', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final input = theme.inputDecorationTheme;
        expect(input.isDense, isTrue);
        expect(
          (input.border! as OutlineInputBorder).borderRadius,
          AppRadius.mdAll,
        );
        expect(
          (input.focusedBorder! as OutlineInputBorder).borderRadius,
          AppRadius.mdAll,
        );
        expect(input.hintStyle?.fontSize, 13);
        expect(input.errorStyle?.color, theme.colorScheme.error);
      }
    });

    test('el foco usa --primary y el error usa `danger`', () {
      expect(
        (AppTheme.light().inputDecorationTheme.focusedBorder!
                as OutlineInputBorder)
            .borderSide
            .color,
        AppColors.lightPrimary,
      );
      expect(
        (AppTheme.dark().inputDecorationTheme.focusedBorder!
                as OutlineInputBorder)
            .borderSide
            .color,
        AppColors.darkPrimary,
      );
      expect(
        (AppTheme.light().inputDecorationTheme.errorBorder!
                as OutlineInputBorder)
            .borderSide
            .color,
        AppColors.lightDanger,
      );
      expect(
        (AppTheme.dark().inputDecorationTheme.errorBorder!
                as OutlineInputBorder)
            .borderSide
            .color,
        AppColors.darkDanger,
      );
    });
  });

  group('bottomSheetTheme', () {
    test('scrim = --sheet-backdrop (:25, :38)', () {
      expect(
        AppTheme.light().bottomSheetTheme.modalBarrierColor,
        AppColors.lightSheetBackdrop,
      );
      expect(
        AppTheme.dark().bottomSheetTheme.modalBarrierColor,
        AppColors.darkSheetBackdrop,
      );
      expect(AppColors.lightSheetBackdrop, const Color(0x47000000));
      expect(AppColors.darkSheetBackdrop, const Color(0x99000000));
    });

    test('esquinas superiores a 12 y sin tinte M3', () {
      expect(AppTheme.sheetRadius, 12);
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final shape = theme.bottomSheetTheme.shape! as RoundedRectangleBorder;
        final radius = shape.borderRadius as BorderRadius;
        expect(radius.topLeft, const Radius.circular(12));
        expect(radius.topRight, const Radius.circular(12));
        expect(radius.bottomLeft, Radius.zero);
        expect(radius.bottomRight, Radius.zero);
        expect(theme.bottomSheetTheme.surfaceTintColor, Colors.transparent);
        expect(theme.bottomSheetTheme.elevation, 0);
        expect(
          theme.bottomSheetTheme.backgroundColor,
          theme.colorScheme.surface,
        );
        expect(theme.bottomSheetTheme.showDragHandle, isTrue);
      }
    });
  });

  group('constantes de barras', () {
    test('app bar y bottom nav miden 56 (:116, :132)', () {
      expect(AppTheme.appBarHeight, 56);
      expect(AppTheme.mobileBarHeight, 56);
    });
  });

  group('inmutabilidad', () {
    test('light()/dark() devuelven el mismo ThemeData cacheado', () {
      expect(AppTheme.light(), same(AppTheme.light()));
      expect(AppTheme.dark(), same(AppTheme.dark()));
    });

    test('modificar una copia no toca el tema compartido', () {
      final hacked = AppTheme.light().copyWith(
        scaffoldBackgroundColor: const Color(0xFFFF00FF),
      );
      expect(hacked.scaffoldBackgroundColor, const Color(0xFFFF00FF));
      expect(AppTheme.light().scaffoldBackgroundColor, AppColors.lightBg);
    });
  });
}

/// Extrae `fontSize` de cada rol definido del `TextTheme`.
Map<String, double> _sizes(TextTheme theme) => <String, double>{
  for (final entry in <String, TextStyle?>{
    'displayLarge': theme.displayLarge,
    'displayMedium': theme.displayMedium,
    'displaySmall': theme.displaySmall,
    'headlineLarge': theme.headlineLarge,
    'headlineMedium': theme.headlineMedium,
    'headlineSmall': theme.headlineSmall,
    'titleLarge': theme.titleLarge,
    'titleMedium': theme.titleMedium,
    'titleSmall': theme.titleSmall,
    'bodyLarge': theme.bodyLarge,
    'bodyMedium': theme.bodyMedium,
    'bodySmall': theme.bodySmall,
    'labelLarge': theme.labelLarge,
    'labelMedium': theme.labelMedium,
    'labelSmall': theme.labelSmall,
  }.entries)
    if (entry.value?.fontSize != null) entry.key: entry.value!.fontSize!,
};
