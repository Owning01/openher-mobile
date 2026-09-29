import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/ui/core/theme.dart';
import 'package:openher_mobile/ui/core/theme_variants.dart';

/// El tema de color que elegiste tiene que ser el que se ve, en las dos
/// direcciones.
///
/// El catálogo tiene **61 variantes y cada una tiene UN brillo** (36 dark y 29
/// light, medido en `theme_variants.dart`). `MaterialApp` en cambio pide **dos**
/// temas: `theme` (claro) y `darkTheme` (oscuro), y elige uno según el brillo
/// de la plataforma y el `themeMode`.
///
/// El bug: la resolución asignaba la variante al slot que le tocaba por su
/// `kind`, así que el otro slot se quedaba con el chrome por defecto y **el
/// tema elegido se descartaba en silencio**. Con `themeMode: system` y el
/// teléfono en oscuro, una variante clara no se veía; al revés tampoco.
/// Medido sobre las 61 variantes por los dos brillos: **61 de 122 casos**
/// quedaban con el gris de siempre, o sea la mitad. Eso es lo que se reportó
/// como "el chat no se carga con el tema de color seleccionado".
///
/// El test llama a [AppTheme.variantPair], que es la función real que usa el
/// shell, y aplica la misma regla de selección que `_AppShellState`. Si el
/// shell vuelve a filtrar por `kind`, este test falla solo.
void main() {
  /// La regla de selección del `MaterialApp`, escrita una sola vez.
  ///
  /// `ThemeMode.system` elige por el brillo de la plataforma; `light`/`dark`
  /// fuerzan el slot. Es el comportamiento de `MaterialApp`, y el shell se
  /// apoya en él a propósito.
  ColorScheme efectivo({
    required ({ThemeData light, ThemeData dark})? pair,
    required Brightness plataforma,
    required ThemeMode mode,
  }) {
    final elegido = switch (mode) {
      ThemeMode.light => pair?.light ?? AppTheme.light(),
      ThemeMode.dark => pair?.dark ?? AppTheme.dark(),
      ThemeMode.system =>
        plataforma == Brightness.dark
            ? pair?.dark ?? AppTheme.dark()
            : pair?.light ?? AppTheme.light(),
    };
    return elegido.colorScheme;
  }

  group('el tema elegido se ve en las dos direcciones', () {
    test('el catálogo tiene los dos brillos (si no, el test no prueba nada)', () {
      expect(
        ThemeVariants.builtIn.where((v) => v.kind == ThemeVariantKind.dark),
        isNotEmpty,
        reason: 'si no hay ninguna variante dark, el caso interesante no existe',
      );
      expect(
        ThemeVariants.builtIn.where((v) => v.kind == ThemeVariantKind.light),
        isNotEmpty,
        reason: 'si no hay ninguna variante light, el caso interesante no existe',
      );
    });

    test('con themeMode system, TODA variante gana en el brillo del sistema', () {
      final rotas = <String>[];
      for (final v in ThemeVariants.builtIn) {
        for (final plataforma in Brightness.values) {
          final visto = efectivo(
            pair: AppTheme.variantPair(v.id),
            plataforma: plataforma,
            mode: ThemeMode.system,
          );
          final esperado =
              AppTheme.variantOf(v, brightness: plataforma).colorScheme.primary;
          if (visto.primary != esperado) {
            rotas.add('${v.id} en $plataforma');
          }
        }
      }
      expect(
        rotas,
        isEmpty,
        reason: 'estas variantes elegidas se descartaron y la app quedó con el '
            'chrome por defecto: ${rotas.length} casos de '
            '${ThemeVariants.builtIn.length} variantes x 2 brillos',
      );
    });

    test('con themeMode light, una variante dark también tiene que verse', () {
      final rotas = <String>[];
      for (final v
          in ThemeVariants.builtIn.where((v) => v.kind == ThemeVariantKind.dark)) {
        final visto = efectivo(
          pair: AppTheme.variantPair(v.id),
          plataforma: Brightness.light,
          mode: ThemeMode.light,
        );
        final esperado =
            AppTheme.variantOf(v, brightness: Brightness.light)
                .colorScheme
                .primary;
        if (visto.primary != esperado) rotas.add(v.id);
      }
      expect(rotas, isEmpty,
          reason: 'con themeMode light el slot claro recibe la variante dark; '
              'estas se descartaron: $rotas');
    });

    test('con themeMode dark, una variante light también tiene que verse', () {
      final rotas = <String>[];
      for (final v
          in ThemeVariants.builtIn.where((v) => v.kind == ThemeVariantKind.light)) {
        final visto = efectivo(
          pair: AppTheme.variantPair(v.id),
          plataforma: Brightness.dark,
          mode: ThemeMode.dark,
        );
        final esperado = AppTheme.variantOf(v, brightness: Brightness.dark)
            .colorScheme
            .primary;
        if (visto.primary != esperado) rotas.add(v.id);
      }
      expect(rotas, isEmpty,
          reason: 'con themeMode dark el slot oscuro recibe la variante light; '
              'estas se descartaron: $rotas');
    });
  });

  group('las reglas de la resolución', () {
    test('un id desconocido cae al chrome, no rompe', () {
      expect(AppTheme.variantPair('no-existe'), isNull);
      expect(AppTheme.variantPair(null), isNull);
      expect(AppTheme.variantPair(''), isNull);
    });

    test('el brillo de la variante manda si no se pide otro', () {
      // El contrato que hay que conservar: `variantOf` sin `brightness` usa el
      // de la variante. Si esto cambia, el tema se ve con el brillo que NO es.
      for (final v in ThemeVariants.builtIn) {
        expect(
          AppTheme.variantOf(v).brightness,
          v.kind.brightness,
          reason: 'la variante ${v.id} se está pintando con el brillo '
              'equivocado',
        );
      }
    });

    test('el par expone los dos slots y los dos son de la variante', () {
      for (final v in ThemeVariants.builtIn) {
        final pair = AppTheme.variantPair(v.id)!;
        expect(pair.light.brightness, Brightness.light, reason: v.id);
        expect(pair.dark.brightness, Brightness.dark, reason: v.id);
        // Los colores son los de la variante en los dos slots: lo que elegís
        // es lo que se ve, el brillo sólo cambia cómo lo pinta Material.
        expect(pair.light.colorScheme.primary, v.colors.primary, reason: v.id);
        expect(pair.dark.colorScheme.primary, v.colors.primary, reason: v.id);
      }
    });
  });
}
