import 'package:flutter/material.dart';

import 'app_icon.dart';

/// Banda que aparece **sólo con datos móviles**, para que se entienda por qué
/// la app se está recurtando (sin streaming, polling cada 12 s, página de 15).
///
/// Con Wi-Fi o Ethernet no se muestra: es información, no un interruptor.
class LowDataBanner extends StatelessWidget {
  const LowDataBanner({
    super.key,
    required this.onCellular,
    required this.onDisable,
  });

  /// `true` cuando el sistema dice que la red activa es celular.
  final bool onCellular;

  /// Apaga el modo a mano (el usuario manda; no se auto-desactiva solo).
  final VoidCallback onDisable;

  @override
  Widget build(BuildContext context) {
    if (!onCellular) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            AppIcon('zap', size: 14, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Modo de bajo consumo: datos móviles',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            TextButton(
              onPressed: onDisable,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                foregroundColor: theme.colorScheme.onSurface,
              ),
              child: Text(
                'Desactivar',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
