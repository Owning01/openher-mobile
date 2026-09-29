import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_icon.dart';

/// Banda de aviso: "no estás conectado a Tailscale", con un botón que lo abre.
///
/// Aparece **sólo** cuando se sabe que el server no responde y el sistema no
/// reporta VPN (ver `TailscaleMonitor.notice`). No es un aviso genérico de red:
/// si hay VPN, el problema es el server y esta banda se calla.
///
/// El botón hace dos cosas, en este orden:
/// 1. `tailscale://`, que abre la app si está instalada.
/// 2. Si no, la ficha de la app en Play, para que al menos se pueda instalar.
///
/// Un aviso que dice "conectate a Tailscale" y no abre nada es la mitad del
/// trabajo.
class TailscaleBanner extends StatelessWidget {
  const TailscaleBanner({
    super.key,
    required this.message,
    required this.onOpenTailscale,
    this.onRetry,
  });

  /// El texto que ya decidió el monitor (distingue "es cosa de Tailscale" de
  /// "no se llega al server", según si el host parece del tailnet).
  final String message;

  final Future<void> Function() onOpenTailscale;
  final VoidCallback? onRetry;

  /// El scheme de la app de Tailscale en Android.
  static const String scheme = 'tailscale://';

  /// La ficha en Play, para cuando no está instalada.
  static const String storeUrl = 'market://details?id=com.tailscale.ipn';

  /// Abre Tailscale, o su ficha en Play si no está instalada.
  ///
  /// Devuelve `true` si se logró abrir algo. Nunca tira: el botón tiene que
  /// seguir siendo usable aunque el dispositivo no tenga ni una cosa ni la otra.
  static Future<bool> openTailscale() async {
    for (final candidate in <String>[scheme, storeUrl]) {
      try {
        final uri = Uri.parse(candidate);
        if (await canLaunchUrl(uri) && await launchUrl(uri)) return true;
      } on Object {
        // Sin handler para el scheme, o sin Play: se prueba el siguiente.
        continue;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Row(
          children: <Widget>[
            AppIcon(
              'alert-triangle',
              size: 16,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
            if (onRetry != null)
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.onErrorContainer,
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: const Text('Reintentar'),
              ),
            TextButton(
              onPressed: onOpenTailscale,
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.onErrorContainer,
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: const Text('Abrir Tailscale'),
            ),
          ],
        ),
      ),
    );
  }
}
