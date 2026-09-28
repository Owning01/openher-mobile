import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/ui/core/tokens.dart';

void main() {
  group('AppColors light (tokens.css :5-79)', () {
    test('fondo y texto raiz', () {
      expect(AppColors.lightBg, const Color(0xFFFFFFFF));
      expect(AppColors.lightText, const Color(0xFF18181B));
      expect(AppColors.lightMuted, const Color(0xFF71717A));
      expect(AppColors.lightMutedStrong, const Color(0xFF52525B));
      expect(AppColors.lightPrimaryStrong, const Color(0xFF09090B));
    });

    test('superficies y bordes', () {
      expect(AppColors.lightSurface, const Color(0xFFFFFFFF));
      expect(AppColors.lightSurfaceSubtle, const Color(0xFFFAFAFB));
      expect(AppColors.lightSurfaceStrong, const Color(0xFFF4F4F5));
      expect(AppColors.lightSurfaceHover, const Color(0xFFE9E9EC));
      expect(AppColors.lightSurfaceSoft, const Color(0xFFF9F9FB));
      expect(AppColors.lightBorder, const Color(0xFFE4E4E7));
      expect(AppColors.lightBorderStrong, const Color(0xFFD4D4D8));
      expect(AppColors.lightBorderSubtle, const Color(0xFFE9E9EC));
    });

    test('primario, foco y translucidos', () {
      expect(AppColors.lightPrimary, const Color(0xFF18181B));
      expect(AppColors.lightOnPrimary, const Color(0xFFFFFFFF));
      expect(AppColors.lightSecondary, const Color(0xFF18181B));
      // rgba(24,24,27,.07) / .2 / .16 sobre negro.
      expect(AppColors.lightPrimarySoft, const Color(0x1218181B));
      expect(AppColors.lightPrimaryBorder, const Color(0x3318181B));
      expect(AppColors.lightFocusRing, const Color(0x2918181B));
      expect(AppColors.lightAccentSoft, const Color(0x1218181B));
      // rgba(255,255,255,.8) / .85 y scrims.
      expect(AppColors.lightNavBg, const Color(0xCCFFFFFF));
      expect(AppColors.lightBottomNavBg, const Color(0xD9FFFFFF));
      expect(AppColors.lightModalBackdrop, const Color(0x52000000));
      expect(AppColors.lightSheetBackdrop, const Color(0x47000000));
    });

    test('chrome semantico es GRIS en light', () {
      // El rojo/verde/ambar reales viven en el scope de diffs, no en el chrome.
      expect(AppColors.lightSuccess, const Color(0xFF52525B));
      expect(AppColors.lightDanger, const Color(0xFF52525B));
      expect(AppColors.lightInfo, const Color(0xFF52525B));
      expect(AppColors.lightWarning, const Color(0xFF71717A));
      expect(AppColors.lightThinkingHeader, const Color(0xFF52525B));
      expect(AppColors.lightSuccessSoft, const Color(0x1F52525B));
      expect(AppColors.lightDangerSoft, const Color(0x1F52525B));
      expect(AppColors.lightWarningSoft, const Color(0x1F71717A));
      expect(AppColors.lightDangerBorder, const Color(0x3318181B));
    });

    test('codigo light (:46-54)', () {
      expect(AppColors.lightCodeBg, const Color(0xFFF4F4F5));
      expect(AppColors.lightCodeText, const Color(0xFF18181B));
      expect(AppColors.lightCodeKeyword, const Color(0xFF5E6AD2));
      expect(AppColors.lightCodeString, const Color(0xFF16A34A));
      expect(AppColors.lightCodeComment, const Color(0xFF71717A));
      expect(AppColors.lightCodeFunction, const Color(0xFF5E6AD2));
      expect(AppColors.lightCodeNumber, const Color(0xFFF59E0B));
      expect(AppColors.lightCodeBuiltin, const Color(0xFFE11D48));
      expect(AppColors.lightCodeAttr, const Color(0xFF0EA5E9));
    });
  });

  group('AppColors dark (tokens.css :83-132)', () {
    test('fondo y texto raiz', () {
      expect(AppColors.darkBg, const Color(0xFF09090B));
      expect(AppColors.darkText, const Color(0xFFF4F4F5));
      expect(AppColors.darkMuted, const Color(0xFFA1A1AA));
      expect(AppColors.darkMutedStrong, const Color(0xFFD4D4D8));
      expect(AppColors.darkPrimaryStrong, const Color(0xFFFFFFFF));
    });

    test('superficies y bordes', () {
      // Ojo: `darkSurface` (--surface) NO es `darkBg` (--bg); el token CSS los
      // distingue y el tema depende de la diferencia.
      expect(AppColors.darkSurface, const Color(0xFF121215));
      expect(AppColors.darkBg, isNot(AppColors.darkSurface));
      expect(AppColors.darkSurfaceSubtle, const Color(0xFF18181C));
      expect(AppColors.darkSurfaceStrong, const Color(0xFF222226));
      expect(AppColors.darkSurfaceHover, const Color(0xFF27272A));
      expect(AppColors.darkSurfaceSoft, const Color(0xFF18181C));
      expect(AppColors.darkBorder, const Color(0xFF222226));
      expect(AppColors.darkBorderStrong, const Color(0xFF333338));
      expect(AppColors.darkBorderSubtle, const Color(0xFF1C1C20));
    });

    test('primario, foco y translucidos', () {
      expect(AppColors.darkPrimary, const Color(0xFFF4F4F5));
      expect(AppColors.darkOnPrimary, const Color(0xFF09090B));
      expect(AppColors.darkSecondary, const Color(0xFFF4F4F5));
      expect(AppColors.darkPrimarySoft, const Color(0x1AF4F4F5));
      expect(AppColors.darkPrimaryBorder, const Color(0x38F4F4F5));
      expect(AppColors.darkFocusRing, const Color(0x38F4F4F5));
      expect(AppColors.darkAccentSoft, const Color(0x1AF4F4F5));
      expect(AppColors.darkNavBg, const Color(0xD909090B));
      expect(AppColors.darkBottomNavBg, const Color(0xE609090B));
      expect(AppColors.darkModalBackdrop, const Color(0xB3000000));
      expect(AppColors.darkSheetBackdrop, const Color(0x99000000));
    });

    test('chrome semantico es GRIS en dark', () {
      expect(AppColors.darkSuccess, const Color(0xFFA1A1AA));
      expect(AppColors.darkDanger, const Color(0xFFD4D4D8));
      expect(AppColors.darkWarning, const Color(0xFFA1A1AA));
      expect(AppColors.darkInfo, const Color(0xFFA1A1AA));
      expect(AppColors.darkThinkingHeader, const Color(0xFFA1A1AA));
      expect(AppColors.darkSecondary, const Color(0xFFF4F4F5));
      expect(AppColors.darkSuccessSoft, const Color(0x1FA1A1AA));
      expect(AppColors.darkDangerSoft, const Color(0x1FD4D4D8));
      expect(AppColors.darkWarningSoft, const Color(0x1FA1A1AA));
      expect(AppColors.darkDangerBorder, const Color(0x38F4F4F5));
    });

    test('codigo dark (:118-126)', () {
      expect(AppColors.darkCodeBg, const Color(0xFF0E0E11));
      expect(AppColors.darkCodeText, const Color(0xFFF4F4F5));
      expect(AppColors.darkCodeKeyword, const Color(0xFF818CF8));
      expect(AppColors.darkCodeString, const Color(0xFF4ADE80));
      expect(AppColors.darkCodeComment, const Color(0xFF71717A));
      expect(AppColors.darkCodeFunction, const Color(0xFF818CF8));
      expect(AppColors.darkCodeNumber, const Color(0xFFFBBF24));
      expect(AppColors.darkCodeBuiltin, const Color(0xFFFB7185));
      expect(AppColors.darkCodeAttr, const Color(0xFF38BDF8));
    });
  });

  group('scope de diffs (tokens.css :138-162)', () {
    test('light', () {
      expect(AppColors.diffAdd, const Color(0xFF16A34A));
      expect(AppColors.diffDel, const Color(0xFFE11D48));
      expect(AppColors.warn, const Color(0xFFF59E0B));
      expect(AppColors.diffAddSoft, const Color(0x1416A34A));
      expect(AppColors.diffDelSoft, const Color(0x14E11D48));
      expect(AppColors.warnSoft, const Color(0x1AF59E0B));
    });

    test('dark', () {
      expect(AppColors.diffAddDark, const Color(0xFF4ADE80));
      expect(AppColors.diffDelDark, const Color(0xFFFB7185));
      expect(AppColors.warnDark, const Color(0xFFFBBF24));
      expect(AppColors.diffAddSoftDark, const Color(0x1A4ADE80));
      expect(AppColors.diffDelSoftDark, const Color(0x1AFB7185));
      expect(AppColors.warnSoftDark, const Color(0x1AFBBF24));
    });

    test('el color real NO se filtra al chrome', () {
      // Si estos dos fueran iguales, el tema monocromo se rompería: el chrome
      // debe quedar gris y el color solo en el scope de diffs.
      expect(AppColors.lightDanger, isNot(AppColors.diffDel));
      expect(AppColors.darkDanger, isNot(AppColors.diffDelDark));
      expect(AppColors.lightDanger, isNot(AppColors.diffAdd));
      expect(AppColors.darkDanger, isNot(AppColors.diffAddDark));
    });

    test('terminal embebida', () {
      expect(AppColors.terminal, const Color(0xFF0D1117));
    });
  });

  group('helpers *Of(Brightness)', () {
    test('scope semantico resuelve por brillo', () {
      expect(AppColors.diffAddOf(Brightness.light), AppColors.diffAdd);
      expect(AppColors.diffAddOf(Brightness.dark), AppColors.diffAddDark);
      expect(AppColors.diffDelOf(Brightness.light), AppColors.diffDel);
      expect(AppColors.diffDelOf(Brightness.dark), AppColors.diffDelDark);
      expect(AppColors.warnOf(Brightness.light), AppColors.warn);
      expect(AppColors.warnOf(Brightness.dark), AppColors.warnDark);
    });

    test('chrome semantico resuelve por brillo', () {
      expect(AppColors.successOf(Brightness.light), AppColors.lightSuccess);
      expect(AppColors.successOf(Brightness.dark), AppColors.darkSuccess);
      expect(AppColors.dangerOf(Brightness.light), AppColors.lightDanger);
      expect(AppColors.dangerOf(Brightness.dark), AppColors.darkDanger);
      expect(AppColors.warningOf(Brightness.light), AppColors.lightWarning);
      expect(AppColors.warningOf(Brightness.dark), AppColors.darkWarning);
    });

    test('los dos lados difieren de verdad', () {
      expect(
        AppColors.diffAddOf(Brightness.light),
        isNot(AppColors.diffAddOf(Brightness.dark)),
      );
      expect(
        AppColors.diffDelOf(Brightness.light),
        isNot(AppColors.diffDelOf(Brightness.dark)),
      );
      expect(
        AppColors.warnOf(Brightness.light),
        isNot(AppColors.warnOf(Brightness.dark)),
      );
    });
  });

  group('AppSpacing', () {
    test('escala --space-* 4/8/12/16/20/24/32', () {
      expect(AppSpacing.xs, 4);
      expect(AppSpacing.sm, 8);
      expect(AppSpacing.md, 12);
      expect(AppSpacing.lg, 16);
      expect(AppSpacing.xl, 20);
      expect(AppSpacing.xxl, 24);
      expect(AppSpacing.xxxl, 32);
    });

    test('es estrictamente creciente', () {
      const scale = [
        AppSpacing.xs,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xl,
        AppSpacing.xxl,
        AppSpacing.xxxl,
      ];
      for (var i = 1; i < scale.length; i++) {
        expect(scale[i], greaterThan(scale[i - 1]), reason: 'índice $i');
      }
    });
  });

  group('AppRadius', () {
    test('escala --radius-* 4/6/8', () {
      expect(AppRadius.sm, 4);
      expect(AppRadius.md, 6);
      expect(AppRadius.lg, 8);
    });

    test('los BorderRadiusderivados coinciden con el radio', () {
      expect(AppRadius.smAll, BorderRadius.circular(4));
      expect(AppRadius.mdAll, BorderRadius.circular(6));
      expect(AppRadius.lgAll, BorderRadius.circular(8));
      expect(AppRadius.smRadius, const Radius.circular(4));
      expect(AppRadius.mdRadius, const Radius.circular(6));
      expect(AppRadius.lgRadius, const Radius.circular(8));
    });
  });

  group('AppBreakpoints', () {
    test('limites', () {
      expect(AppBreakpoints.mobileMax, 600);
      expect(AppBreakpoints.tabletMax, 1024);
    });

    test('isMobile es <= 600 (600 incluido)', () {
      expect(AppBreakpoints.isMobile(400), isTrue);
      expect(AppBreakpoints.isMobile(360), isTrue);
      expect(AppBreakpoints.isMobile(600), isTrue);
      expect(AppBreakpoints.isMobile(601), isFalse);
      expect(AppBreakpoints.isMobile(1025), isFalse);
    });

    test('isTablet cubre (600, 1024]', () {
      expect(AppBreakpoints.isTablet(601), isTrue);
      expect(AppBreakpoints.isTablet(1024), isTrue);
      expect(AppBreakpoints.isTablet(600), isFalse);
      expect(AppBreakpoints.isTablet(400), isFalse);
      expect(AppBreakpoints.isTablet(1025), isFalse);
    });

    test('isDesktop arranca en 1025', () {
      expect(AppBreakpoints.isDesktop(1025), isTrue);
      expect(AppBreakpoints.isDesktop(1024), isFalse);
      expect(AppBreakpoints.isDesktop(601), isFalse);
    });

    test('son excluyentes y cubren todo el eje', () {
      for (final width in [
        320.0,
        400.0,
        600.0,
        601.0,
        800.0,
        1024.0,
        1025.0,
        1600.0,
      ]) {
        final hits = [
          AppBreakpoints.isMobile(width),
          AppBreakpoints.isTablet(width),
          AppBreakpoints.isDesktop(width),
        ].where((h) => h).length;
        expect(hits, 1, reason: 'ancho $width debe caer en una sola banda');
      }
    });
  });

  group('AppShadows', () {
    test('light usa negro con alfa bajo', () {
      expect(AppShadows.sm, hasLength(1));
      expect(AppShadows.sm.single.color, const Color(0x0A000000));
      expect(AppShadows.sm.single.blurRadius, 2);
      expect(AppShadows.sm.single.offset, const Offset(0, 1));
      expect(AppShadows.md, hasLength(2));
      expect(AppShadows.lg.first.blurRadius, 12);
      expect(AppShadows.lg.first.offset, const Offset(0, 4));
    });

    test('dark es mas opaca y mas difusa', () {
      expect(AppShadows.smDark.single.color, const Color(0x80000000));
      expect(AppShadows.mdDark.single.color, const Color(0x99000000));
      expect(AppShadows.mdDark.single.blurRadius, 12);
      expect(AppShadows.lgDark.single.color, const Color(0xB3000000));
      expect(AppShadows.lgDark.single.blurRadius, 24);
      expect(AppShadows.lgDark.single.offset, const Offset(0, 8));
    });

    test('dark >= light en alfa a igual escala', () {
      expect(
        AppShadows.smDark.single.color.a,
        greaterThanOrEqualTo(AppShadows.sm.single.color.a),
      );
      expect(
        AppShadows.lgDark.single.color.a,
        greaterThanOrEqualTo(AppShadows.lg.first.color.a),
      );
    });
  });
}
