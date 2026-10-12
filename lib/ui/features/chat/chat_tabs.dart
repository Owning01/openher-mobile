/// Tira de pestañas de chats (desktop, arriba del detalle, estilo Chrome).
///
/// Una pestaña por sesión abierta, sin duplicados (eso lo garantiza el nav:
/// abrir dos veces la misma activa la que ya está). Tocar cambia de chat,
/// la × cierra. El estado de cada chat (scroll, viewmodel) lo conserva el
/// `IndexedStack` del shell: la tira sólo dice cuál va al frente.
library;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../../domain/models/session.dart';
import '../../core/app_icon.dart';
import '../../core/tokens.dart';

class ChatTabStrip extends StatelessWidget {
  const ChatTabStrip({
    super.key,
    required this.tabs,
    required this.activeId,
    required this.onSelect,
    required this.onClose,
  });

  /// Pestañas abiertas, en orden (la última es la más reciente).
  final List<SessionInfo> tabs;

  /// Id de la pestaña al frente.
  final String? activeId;

  /// Tocar una pestaña.
  final ValueChanged<String> onSelect;

  /// La × de una pestaña.
  final ValueChanged<String> onClose;

  /// Una pestaña, para tests.
  static Key tabKey(String id) => Key('chat-tab-$id');

  /// La × de una pestaña, para tests.
  static Key closeKey(String id) => Key('chat-tab-close-$id');

  /// Título visible: el que puso el server, o el prefijo del id.
  static String titleOf(SessionInfo session) {
    final title = session.title.trim();
    if (title.isNotEmpty) return title;
    final id = session.id;
    return id.length > 12 ? '${id.substring(0, 12)}…' : id;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outline)),
        ),
        child: SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.sm,
              AppSpacing.xs,
              AppSpacing.sm,
              0,
            ),
            itemCount: tabs.length,
            separatorBuilder: (_, _) => const SizedBox(width: 4),
            itemBuilder: (context, i) {
              final session = tabs[i];
              final active = session.id == activeId;
              return ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: 120,
                  maxWidth: 220,
                ),
                child: Semantics(
                  button: true,
                  selected: active,
                  label: 'Chat: ${titleOf(session)}',
                  child: Material(
                    key: ChatTabStrip.tabKey(session.id),
                    color: active
                        ? scheme.surfaceContainer
                        : Colors.transparent,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(8),
                    ),
                    // La × NO va dentro del InkWell de selección: dos InkWell
                    // anidados compiten en la arena y el toque en la × también
                    // cambiaría de pestaña. Van como hermanos.
                    child: Container(
                      padding: const EdgeInsets.only(left: 10),
                      decoration: BoxDecoration(
                        border: active
                            ? Border(
                                bottom: BorderSide(
                                  color: scheme.primary,
                                  width: 2,
                                ),
                              )
                            : null,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              onTap: active ? null : () => onSelect(session.id),
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(8),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                child: Text(
                                  titleOf(session),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: active
                                        ? FontWeight.w600
                                        : null,
                                    color: active
                                        ? scheme.onSurface
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          AppIconButton(
                            key: ChatTabStrip.closeKey(session.id),
                            icon: 'x',
                            tooltip:
                                'Cerrar ${titleOf(session)} (Ctrl+W cierra la actual)',
                            onPressed: () => onClose(session.id),
                            size: 13,
                            tapSize: 28,
                            color: scheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Barra de título desktop con las pestañas adentro (estilo Chrome).
///
/// Vive en la zona de la barra nativa oculta (`TitleBarStyle.hidden`): a la
/// izquierda las pestañas (o `OpenHer` sin chats), al medio área vacía que
/// arrastra la ventana (doble toque = maximizar), y a la derecha los botones
/// min/max/cerrar dibujados por nosotros (los nativos no existen con la
/// caption oculta). Solo desktop: en móvil no se construye.
class DesktopTitleBar extends StatelessWidget {
  const DesktopTitleBar({
    super.key,
    required this.tabs,
    required this.activeId,
    required this.onSelect,
    required this.onClose,
    required this.maximized,
    required this.onToggleMaximize,
    this.fullScreen = false,
  });

  final List<SessionInfo> tabs;
  final String? activeId;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onClose;

  /// Ventana maximizada: el botón muestra restaurar.
  final bool maximized;
  final VoidCallback onToggleMaximize;

  /// En pantalla completa el sistema esconde todo: la barra sólo arrastra.
  final bool fullScreen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    return Material(
      color: scheme.surface,
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outline)),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: tabs.isEmpty
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: AppSpacing.md),
                        child: Semantics(
                          header: true,
                          child: Text(
                            'OpenHer',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    )
                  : ChatTabStrip(
                      tabs: tabs,
                      activeId: activeId,
                      onSelect: onSelect,
                      onClose: onClose,
                    ),
            ),
            // Área vacía: de acá se arrastra la ventana. Las pestañas quedan
            // fuera a propósito: arrastrar para mover no puede pelear con el
            // scroll/toque de las pestañas.
            const Expanded(
              flex: 2,
              child: DragToMoveArea(child: SizedBox.expand()),
            ),
            if (!fullScreen) ...[
              WindowCaptionButton.minimize(
                brightness: brightness,
                onPressed: () => _guard(windowManager.minimize),
              ),
              if (maximized)
                WindowCaptionButton.unmaximize(
                  brightness: brightness,
                  onPressed: onToggleMaximize,
                )
              else
                WindowCaptionButton.maximize(
                  brightness: brightness,
                  onPressed: onToggleMaximize,
                ),
              WindowCaptionButton.close(
                brightness: brightness,
                onPressed: () => _guard(windowManager.close),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Los botones de caption no pueden reventar el shell: si el canal nativo
  /// falla, se loguea y la ventana sigue viva.
  static Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (e) {
      debugPrint('desktop: acción de ventana falló: $e');
    }
  }
}
