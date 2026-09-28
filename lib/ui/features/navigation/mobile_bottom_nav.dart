import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/app_icon.dart';
import '../../core/layer_gate.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import 'mobile_nav.dart';

/// Bottom-nav de 4 destinos.
///
/// Réplica exacta del prototipo (`bottomnav` en `mobile.html`): 56px,
/// `blur(12px)` sobre `--bottom-nav-bg`, 1px de borde arriba, label 10.5px,
/// activo en `--text` con w600 y una barrita de 22×2px arriba del icono.
///
/// Capa: `app.bottomnav`.
class MobileBottomNav extends StatelessWidget {
  const MobileBottomNav({
    super.key,
    required this.current,
    required this.onSelect,
    this.chatEnabled = true,
  });

  final MobileTab current;
  final ValueChanged<MobileTab> onSelect;

  /// El destino Chat sin sesión no se puede seleccionar (lo cubre la lista).
  final bool chatEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return LayerGate(
      'app.bottomnav',
      child: Container(
        height: AppTheme.mobileBarHeight,
        decoration: BoxDecoration(
          color: isDark
              ? AppColors.darkBottomNavBg
              : AppColors.lightBottomNavBg,
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Row(
              children: [
                for (final tab in MobileTab.values)
                  Expanded(
                    child: _NavItem(
                      tab: tab,
                      selected: tab == current,
                      enabled: tab != MobileTab.chat || chatEnabled,
                      onTap: () => onSelect(tab),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.tab,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final MobileTab tab;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = !enabled
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)
        : selected
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;

    return Semantics(
      selected: selected,
      button: true,
      label: tab.label,
      child: InkWell(
        onTap: enabled ? onTap : null,
        // El chrome es monocromo: sin splash de tinte.
        splashFactory: NoSplash.splashFactory,
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AppIcon(tab.icon, size: 20, color: color),
                const SizedBox(height: 2),
                Text(
                  tab.label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10.5,
                    color: color,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
            // Barrita del destino activo (22×2, redondeada).
            if (selected)
              Positioned(
                top: 6,
                child: Container(
                  width: 22,
                  height: 2,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
