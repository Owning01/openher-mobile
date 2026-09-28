import 'package:flutter/widgets.dart';

/// Los 4 destinos del bottom-nav. Es la decisión D5 del plan: un pulgar, una
/// tarea por pantalla. La activity-bar de 12 items del escritorio no es táctil.
enum MobileTab {
  sessions('Sesiones', 'message-square'),
  chat('Chat', 'message-square'),
  files('Archivos', 'folder'),
  settings('Ajustes', 'settings');

  const MobileTab(this.label, this.icon);

  /// Etiqueta EXACTA del prototipo.
  final String label;

  /// Basename del SVG en `assets/icons/`.
  final String icon;
}

/// Pila de navegación con las 4 pestañas.
///
/// Es el equivalente móvil del `AppNav` del escritorio: un stack de vistas con
/// `push/pop` y un índice de pestaña. Sin `go_router` (D7: cero dependencias
/// nuevas).
class MobileNav extends ChangeNotifier {
  MobileTab _tab = MobileTab.sessions;
  final List<MobileTab> _stack = [MobileTab.sessions];

  MobileTab get tab => _tab;

  /// SessionID abierto en la pestaña Chat (null = sin sesión).
  String? chatSessionId;

  /// Si el usuario puede volver atrás (Android: botón atrás).
  bool get canPop => _stack.length > 1;

  /// El header del chat llama a esto desde la `arrow-left`.
  void leaveChat() {
    if (_tab == MobileTab.chat) {
      _stack.removeLast();
      _tab = _stack.isEmpty ? MobileTab.sessions : _stack.last;
      chatSessionId = null;
      notifyListeners();
    }
  }

  void select(MobileTab next) {
    if (next == MobileTab.chat && chatSessionId == null) {
      // El chat sin sesión no es un destino vacío: la lista lo cubre.
      return;
    }
    if (_tab == next) return;
    _tab = next;
    _stack.add(next);
    if (_stack.length > 16) _stack.removeAt(0);
    notifyListeners();
  }

  /// Abre una sesión en el destino Chat.
  void openSession(String sessionId) {
    chatSessionId = sessionId;
    _tab = MobileTab.chat;
    _stack.add(MobileTab.chat);
    if (_stack.length > 16) _stack.removeAt(0);
    notifyListeners();
  }

  /// El `+` de la lista crea sesión y abre el chat.
  void openNewSession(String sessionId) => openSession(sessionId);
}
