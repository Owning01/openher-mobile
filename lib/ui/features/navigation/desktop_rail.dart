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

/// Ancho inicial del master. El rango vivo está en `desktop_split.dart`
/// (`kDesktopMasterMinWidth/MaxWidth`); el default de prefs es el mismo 380.
const double kDesktopMasterWidth = 380.0;

/// `true` con el ancho dado: la vista desktop.
bool isDesktopWidth(double maxWidth) => maxWidth >= kDesktopBreakpoint;

class DesktopRail extends StatelessWidget {
  const DesktopRail({
    super.key,
    required this.current,
    required this.onSelect,
    this.chatEnabled = true,
    this.sidebarVisible = true,
    this.onToggleSidebar,
    this.onShortcuts,
  });

  final MobileTab current;
  final ValueChanged<MobileTab> onSelect;

  /// Igual que en móvil: sin sesión el Chat no es destino.
  final bool chatEnabled;

  /// Colapsar el master del split (sólo desktop). `null` = sin botón.
  final bool sidebarVisible;
  final VoidCallback? onToggleSidebar;

  /// Abrir la ayuda de atajos. `null` = sin botón.
  final VoidCallback? onShortcuts;

  /// Botón "?" de atajos, para tests.
  static const Key shortcutsKey = Key('desktop-rail-shortcuts');

  /// Botón de colapso del master, para tests.
  static const Key collapseKey = Key('desktop-rail-collapse');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trailing = <Widget>[
      if (onShortcuts != null)
        IconButton(
          key: DesktopRail.shortcutsKey,
          tooltip: 'Atajos de teclado (Ctrl+/)',
          onPressed: onShortcuts,
          // No hay glifo de teclado en `assets/icons/` y un SVG inventado
          // para un "?" es ruido: el signo dice lo mismo.
          icon: Text(
            '?',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      if (onToggleSidebar != null)
        IconButton(
          key: DesktopRail.collapseKey,
          tooltip: sidebarVisible
              ? 'Ocultar lista (Ctrl+B)'
              : 'Mostrar lista (Ctrl+B)',
          onPressed: onToggleSidebar,
          icon: AppIcon(
            sidebarVisible ? 'arrow-left' : 'chevron-right',
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
    ];
    return LayerGate(
      'app.bottomnav',
      child: NavigationRail(
        selectedIndex: MobileTab.values.indexOf(current),
        onDestinationSelected: (i) => onSelect(MobileTab.values[i]),
        labelType: NavigationRailLabelType.all,
        groupAlignment: 0.0,
        backgroundColor: theme.colorScheme.surface,
        selectedIconTheme: IconThemeData(color: theme.colorScheme.primary),
        // Colapsar el master sin ir al divisor: a 2k el divisor queda lejos.
        trailing: trailing.isEmpty
            ? null
            : Column(mainAxisSize: MainAxisSize.min, children: trailing),
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

/// Diálogo de atajos de teclado (desktop).
///
/// Los atajos existen pero no se documentaban en ningún lado: un atajo que
/// no se puede descubrir es un atajo que no existe (Nielsen: ayuda y
/// documentación). Se abre con Ctrl+/ o con el "?" del rail.
Future<void> showKeyboardShortcuts(BuildContext context) {
  const rows = <List<String>>[
    ['Enter', 'Enviar mensaje'],
    ['Shift + Enter', 'Salto de línea'],
    ['Ctrl + V', 'Pegar imagen del portapapeles'],
    ['Ctrl + B', 'Mostrar / ocultar la lista'],
    ['Ctrl + W', 'Cerrar la pestaña de chat actual'],
    ['F11', 'Pantalla completa'],
    ['Ctrl + /', 'Esta ayuda'],
    ['↑ / ↓', 'Navegar sugerencias (/ y @)'],
    ['Esc', 'Cerrar el menú de sugerencias'],
    ['Doble toque en el divisor', 'Ocultar la lista'],
  ];
  return showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Atajos de teclado'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 170,
                      child: Text(
                        row[0],
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Expanded(child: Text(row[1])),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(),
          child: const Text('Cerrar'),
        ),
      ],
    ),
  );
}
