import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'tokens.dart';

/// Iconografía de la app: SVG formal (Lucide 1.5px sobre `currentColor`),
/// extraído del prototipo aprobado. Cero emojis en la UI (regla del repo).
///
/// Se cargan por nombre desde `assets/icons/<nombre>.svg`. Un nombre inexistente
/// no revienta la pantalla: dibuja un `Icons.help_outline` de respaldo, para
/// que un typo sea visible pero no rompa el chat.
class AppIcon extends StatelessWidget {
  const AppIcon(this.name, {super.key, this.size = 20, this.color});

  /// Nombre del asset sin extensión (p.ej. `send`, `arrow-left`).
  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? IconTheme.of(context).color ?? AppColors.lightPrimary;
    return SvgPicture.asset(
      'assets/icons/$name.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
      // Si el asset no está, no reventamos la pantalla entera.
      placeholderBuilder: (_) =>
          Icon(Icons.help_outline, size: size, color: tint),
    );
  }
}

/// Los mismos iconos en su versión "botón": área táctil de 44 px (mínimo
/// accesible en móvil) con el glifo centrado y `Semantics` para TalkBack.
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 20,
    this.tapSize = 44,
    this.color,
    this.selected = false,
  });

  final String icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double tapSize;
  final Color? color;

  /// Botón con estado (el buscador abierto, por ejemplo). Cuando es `true` el
  /// glifo se pinta con el primario del tema, igual que el resto del chrome
  /// activo, y no se pierde el monocromo: es el mismo token, sólo que marcado.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = selected ? theme.colorScheme.primary : color;
    return Semantics(
      button: true,
      selected: selected,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: InkResponse(
          onTap: onPressed,
          radius: tapSize / 2,
          containedInkWell: true,
          // Sin ripple de tinte: el chrome es monocromo por diseño.
          child: SizedBox(
            width: tapSize,
            height: tapSize,
            child: Center(
              child: AppIcon(icon, size: size, color: tint),
            ),
          ),
        ),
      ),
    );
  }
}
