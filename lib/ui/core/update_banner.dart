import 'package:flutter/material.dart';

import '../../core/update/update_service.dart';
import 'app_icon.dart';

/// Banda de autoupdate. **No bloquea**: no es un diálogo, no detiene la app y
/// no se roba el foco. Aparece arriba, se puede descartar con la `x`, y si la
/// **descarga** falla se queda con un botón de **Volver a descargar** en vez de
/// desaparecer.
///
/// Se oculta sola en `idle`, `checking` y en el fallo del **chequeo**: en esos
/// estados no hay nada que el usuario pueda hacer ni nada que haya que
/// contarle. La descarga cortada es el único caso donde sí hay algo que hacer
/// ([UpdateState.canRetry]).
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({
    super.key,
    required this.state,
    required this.onDownload,
    required this.onInstall,
    required this.onDismiss,
  });

  /// El botón de reintento. Por key y no por texto: el rótulo puede cambiar con
  /// el tamaño de pantalla sin que el test pierda el botón.
  static const Key retryKey = Key('update-retry');

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
              // El reintento. Solo aparece si la descarga se pudo empezar y se
              // corto (`canRetry`): un fallo del chequeo no tiene URL, asi que
              // no hay nada que volver a bajar y un boton ahi seria mentir.
              //
              // Sin esto el usuario se quedaba sin update hasta cerrar y volver
              // a abrir la app, que es lo único que reiniciaba el chequeo.
              if (state.canRetry) ...[
                const SizedBox(height: 2),
                _Action(
                  label: 'Volver a descargar',
                  icon: 'refresh',
                  onPressed: onDownload,
                  // `key` propio: el botón tiene que ser alcanzable por
                  // nombre, y hay otro `_Action` en esta misma columna con la
                  // misma forma.
                  key: UpdateBanner.retryKey,
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
    // El motivo va en la banda, no en un toast que se va solo: el usuario va a
    // mirar la banda justo cuando decide si reintentar, y ahí está el dato.
    UpdatePhase.failed when state.canRetry =>
      'No se pudo descargar OpenHer ${state.info?.version ?? ''} · '
          '${state.error ?? 'sin detalle'}',
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
    super.key,
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
