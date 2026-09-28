import 'package:flutter/widgets.dart';

import '../../../domain/models/session.dart';

/// Los 4 destinos del bottom-nav. Es la decisión D5 del plan: un pulgar, una
/// tarea por pantalla. La activity-bar de 12 items del escritorio no es táctil.
enum MobileTab {
  // El prototipo repite `message-square` en Sesiones y Chat; en un pulgar los
  // dos destinos quedan indistinguibles, así que el chat toma su propio glifo
  // (`sparkles`: el agente), que ya existe en `assets/icons/`.
  sessions('Sesiones', 'message-square'),
  chat('Chat', 'sparkles'),
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

  /// La sesion abierta, con su `agent` y su `model`.
  ///
  /// Se guarda **entera** y no solo el id porque el server si trae esas dos
  /// cosas en la lista (medido: las claves de una sesion en la lista son id,
  /// projectID, agent, model, cost, tokens, time, location). Pasando solo el
  /// id, el chat se abria sin modelo ni agente y los pills volvia a decir
  /// "Elegir" aunque el usuario ya los hubiera elegido.
  SessionInfo? chatSession;

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

  /// Abre una sesión en el destino Chat. La lista la llama con el id que
  /// acaba de crear o de tocar; no hace falta un `openNewSession` aparte.
  void openSession(SessionInfo session) {
    chatSession = session;
    chatSessionId = session.id;
    _tab = MobileTab.chat;
    _stack.add(MobileTab.chat);
    if (_stack.length > 16) _stack.removeAt(0);
    notifyListeners();
  }

  /// El boton atras del sistema. Devuelve `true` si el nav consumio el gesto.
  ///
  /// Antes no habia nada: el gesto cerraba la app desde cualquier pestana y
  /// desde el chat ademas perdias la sesion. La regla es la de Android: el nav
  /// recorre su propia pila ([_stack]); solo en la raiz devuelve `false`, que
  /// es lo que le deja al sistema cerrar.
  ///
  /// En el chat, cerrar el destino **no** borra la sesion: `chatSession` se
  /// conserva para que al volver entre sea el mismo chat con su modelo y su
  /// agente, en vez de uno recien creado sin nada.
  bool handleBack() {
    if (_stack.length > 1) {
      _stack.removeLast();
      _tab = _stack.last;
      if (_tab != MobileTab.chat) chatSessionId = null;
      notifyListeners();
      return true;
    }
    return false;
  }
}
