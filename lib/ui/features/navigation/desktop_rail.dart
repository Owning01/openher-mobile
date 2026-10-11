/// Rail de navegación para pantallas anchas (desktop/tablet apaisada).
///
/// Espejo de `MobileBottomNav` con los mismos 4 destinos (`MobileTab`) y la
/// misma regla (Chat sin sesión no se puede elegir). La vista móvil no se
/// toca: el shell elige rail o bottom-nav por ancho.
library;

import 'package:flutter/material.dart';

import '../../core/app_icon.dart';
import '../../core/layer_gate.dart';
import '../../core/tokens.dart';
import 'mobile_nav.dart';

/// Ancho a partir del cual el shell usa rail + master-detail en vez de
/// bottom-nav. 900 px lógicos: una tablet apaisada chica ya entra, un
/// teléfono grande acostado (844) no.
const double kDesktopBreakpoint = 900.0;

/// Ancho fijo del master (lista de sesiones) en el split desktop.
const double kDesktopMasterWidth = 380.0;

/// `true` con el ancho dado: la vista desktop.
bool isDesktopWidth(double maxWidth) => maxWidth >= kDesktopBreakpoint;

class DesktopRail extends StatelessWidget {
  const DesktopRail({
    super.key,
    required this.current,
    required this.onSelect,
    this.chatEnabled = true,
  });

  final MobileTab current;
  final ValueChanged<MobileTab> onSelect;

  /// Igual que en móvil: sin sesión el Chat no es destino.
  final bool chatEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayerGate(
      'app.bottomnav',
      child: NavigationRail(
        selectedIndex: MobileTab.values.indexOf(current),
        onDestinationSelected: (i) => onSelect(MobileTab.values[i]),
        labelType: NavigationRailLabelType.all,
        groupAlignment: 0.0,
        backgroundColor: theme.colorScheme.surface,
        selectedIconTheme: IconThemeData(color: theme.colorScheme.primary),
        destinations: [
          for (final tab in MobileTab.values)
            NavigationRailDestination(
              icon: AppIcon(
                tab.icon,
                size: 20,
                color: tab != MobileTab.chat || chatEnabled
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
              ),
              selectedIcon: AppIcon(
                tab.icon,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              label: Text(
                tab.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: tab == current ? FontWeight.w600 : null,
                ),
              ),
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            ),
        ],
      ),
    );
  }
}
