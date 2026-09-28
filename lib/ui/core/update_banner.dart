import 'package:flutter/material.dart';

import '../../core/update/update_service.dart';
import 'app_icon.dart';

/// Banda de autoupdate. **No bloquea**: no es un diálogo, no detiene la app y
/// no se roba el foco. Aparece arriba, se puede descartar con la `x`, y si la
/// descarga falla desaparece sola en vez de insistir.
///
/// Se oculta sola en `idle`, `checking` y `failed`: en esos estados no hay
/// nada que el usuario pueda hacer ni nada que haya que contarle.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({
    super.key,
    required this.state,
    required this.onDownload,
    required this.onInstall,
    required this.onDismiss,
  });

  final UpdateState state;
  final VoidCallback onDownload;
  final VoidCallback onInstall;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    if (!state.showsBanner) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  AppIcon(
                    'download',
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_headline, style: theme.textTheme.bodySmall),
                  ),
                  if (state.phase != UpdatePhase.downloading)
                    AppIconButton(
                      icon: 'x',
                      tooltip: 'Ahora no',
                      onPressed: onDismiss,
                      size: 16,
                      tapSize: 40,
                    ),
                ],
              ),
              if (state.phase == UpdatePhase.downloading) ...[
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: state.progress,
                    minHeight: 3,
                    backgroundColor: theme.colorScheme.surface,
                  ),
                ),
              ],
              if (state.phase == UpdatePhase.available ||
                  state.phase == UpdatePhase.ready) ...[
                const SizedBox(height: 2),
                _Action(
                  label: state.phase == UpdatePhase.ready
                      ? 'Instalar'
                      : 'Descargar y actualizar',
                  icon: state.phase == UpdatePhase.ready ? 'check' : 'download',
                  onPressed: state.phase == UpdatePhase.ready
                      ? onInstall
                      : onDownload,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Sólo se ve cuando hay una versión nueva lista para bajar, bajándose, o
  /// descargada esperando el instalador. La regla vive en
  /// [UpdateState.showsBannerFor], no acá.
  bool get visible => state.showsBanner;

  String get _headline => switch (state.phase) {
    UpdatePhase.downloading => _downloading,
    UpdatePhase.ready =>
      'OpenHer ${state.info?.version ?? ''} lista para instalar',
    _ =>
      'Hay OpenHer ${state.info?.version ?? ''} disponible'
          '${state.info?.notes.isNotEmpty == true ? ' · ${state.info!.notes}' : ''}',
  };

  String get _downloading {
    final p = state.progress;
    if (p == null) return 'Descargando la actualización...';
    return 'Descargando ${(p * 100).round()}%';
  }
}

/// Botón de texto plano, a la altura de la banda (no un `FilledButton` de 48 px
/// que rompería el ritmo de una línea de 28 px).
class _Action extends StatelessWidget {
  const _Action({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final String icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: AppIcon(icon, size: 14, color: theme.colorScheme.onSurface),
        label: Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface,
          ),
        ),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}
