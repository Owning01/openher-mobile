/// Split desktop: master (sesiones) + detalle (chat).
///
/// Vive acá y no como métodos privados del shell por una razón: el shell ya
/// es dueño de la navegación, las bandas y las cuatro pestañas. El split es
/// otro concepto (ancho arrastrable + colapso) con sus propias constantes y
/// sus propios gestos, y merece su propio archivo testeable.
///
/// El estado (`masterWidth`, `sidebarVisible`) vive en el shell, que es quien
/// lo persiste en prefs: este widget sólo avisa (`onResize`, `onToggle`).
library;

import 'package:flutter/material.dart';

import '../../core/app_icon.dart';

/// Ancho mínimo y máximo del master. El clamp de `PrefsStore.sidebarWidth`
/// usa los mismos números (ver su comentario).
const double kDesktopMasterMinWidth = 240.0;
const double kDesktopMasterMaxWidth = 600.0;

/// Acota un ancho al rango del master.
double clampMasterWidth(double value) =>
    value.clamp(kDesktopMasterMinWidth, kDesktopMasterMaxWidth);

class DesktopSplit extends StatelessWidget {
  const DesktopSplit({
    super.key,
    required this.sessions,
    required this.chat,
    required this.masterWidth,
    required this.sidebarVisible,
    required this.onResize,
    required this.onResizeEnd,
    required this.onToggle,
  });

  /// La lista de sesiones (columna izquierda).
  final Widget sessions;

  /// El chat (columna derecha, siempre visible).
  final Widget chat;

  /// Ancho actual del master, ya acotado.
  final double masterWidth;

  /// Master visible o colapsado.
  final bool sidebarVisible;

  /// Arrastre horizontal del divisor, en píxeles lógicos (positivo = más
  /// ancho). El dueño suma, acota y repinta; el persistido va en `onResizeEnd`
  /// para no escribir prefs en cada píxel del gesto.
  final ValueChanged<double> onResize;

  /// Fin del arrastre: el dueño persiste el ancho final.
  final VoidCallback onResizeEnd;

  /// Colapsar/mostrar el master (botón del rail, doble toque, Ctrl+B: todos
  /// caen acá).
  final VoidCallback onToggle;

  /// Divisor arrastrable, para tests.
  static const Key resizeHandleKey = Key('desktop-split-resize');

  /// Tira de reapertura con el master oculto, para tests.
  static const Key expandStripKey = Key('desktop-split-expand');

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (sidebarVisible) ...[
          SizedBox(width: masterWidth, child: sessions),
          _ResizeHandle(
            masterWidth: masterWidth,
            onResize: onResize,
            onResizeEnd: onResizeEnd,
            onToggle: onToggle,
          ),
        ] else
          _ExpandStrip(onToggle: onToggle),
        Expanded(child: chat),
      ],
    );
  }
}

/// Divisor arrastrable entre master y chat. Doble toque = colapsar.
class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({
    required this.masterWidth,
    required this.onResize,
    required this.onResizeEnd,
    required this.onToggle,
  });

  final double masterWidth;
  final ValueChanged<double> onResize;
  final VoidCallback onResizeEnd;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    // Ajustable por lector de pantalla: sin esto el divisor es un gesto de
    // mouse invisible (sin semántica) y redimensionar sólo se podía
    // arrastrando. Con NVDA/Narrador, Insert+flechas lo mueven de a 24 px.
    return Semantics(
      label: 'Ancho de la lista de sesiones',
      value: '${masterWidth.round()} píxeles',
      // El framework exige los tres para un ajustable: sin valor futuro
      // revienta el árbol de semántica (medido en test).
      increasedValue: '${(masterWidth + 24).round()} píxeles',
      decreasedValue: '${(masterWidth - 24).round()} píxeles',
      onIncrease: () => onResize(24),
      onDecrease: () => onResize(-24),
      child: GestureDetector(
        key: DesktopSplit.resizeHandleKey,
        onHorizontalDragUpdate: (details) => onResize(details.delta.dx),
        onHorizontalDragEnd: (_) => onResizeEnd(),
        onDoubleTap: onToggle,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          child: Tooltip(
            message: 'Arrastrar para redimensionar · doble toque oculta',
            child: Container(
              width: 9,
              color: Colors.transparent,
              alignment: Alignment.center,
              child: const VerticalDivider(width: 1),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tira fina cuando el master está oculto: cómo volver sin acordarse de Ctrl+B.
class _ExpandStrip extends StatelessWidget {
  const _ExpandStrip({required this.onToggle});

  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Mostrar lista (Ctrl+B)',
      child: Material(
        key: DesktopSplit.expandStripKey,
        color: scheme.surface,
        child: InkWell(
          onTap: onToggle,
          child: SizedBox(
            width: 32,
            child: Center(
              child: AppIcon(
                'chevron-right',
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
