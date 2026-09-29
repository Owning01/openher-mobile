import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/storage/prefs_store.dart';

/// Las sesiones favoritas, **en orden**.
///
/// Es el port exacto de como lo guarda el escritorio: un `string[]` de ids de
/// sesión en el almacenamiento local del navegador
/// (`web/src/hooks/useSessions.ts`, `useLocalStorage(FAVORITES_KEY, [])`), con
/// un `Set<string>` derivado sólo para las consultas de "¿es favorita?".
///
/// ## Por qué el orden importa y no es un detalle
///
/// El escritorio tiene un gestor (`FavoritesManager`) con subir/bajar para
/// reordenar, y el orden se persiste. Si acá se guardara un `Set` se perdería
/// al serializar, y las favoritas volverían en el orden en que’llegó la lista.
///
/// ## Por qué es local y no del server
///
/// **Medido 2026-09-29**: el server no tiene favoritas. `GET /shell/fs/favorites`
/// devuelve el HTML del SPA (el catch-all, no un 404) y el `openapi.json` no
/// menciona `favorite` en ningún lado. O sea que las del escritorio viven en el
/// `localStorage` de su WebView, que la app no puede leer: son dos listas
/// distintas y no hay puente.
class SessionFavorites extends ChangeNotifier {
  SessionFavorites(this._prefs, {List<String>? initial})
    : _order = List<String>.of(initial ?? _read(_prefs));

  final KeyValuePrefs _prefs;

  static const String key = 'openher.sessions.favorites';

  /// El id es la clave: la misma forma de id que usa el server (`ses_…`).
  final List<String> _order;

  static List<String> _read(KeyValuePrefs prefs) {
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <String>[];
      return decoded.whereType<String>().toList();
    } on FormatException {
      // Una lista corrupta no puede romper la pantalla de sesiones: se pierde
      // sola y el usuario vuelve a marcar. Perder preferencias es mejor que no
      // abrir la app.
      return const <String>[];
    }
  }

  /// Los ids, en el orden que los puso el usuario.
  List<String> get order => List<String>.unmodifiable(_order);

  Set<String> get ids => _order.toSet();

  int get count => _order.length;

  bool contains(String sessionId) => _order.contains(sessionId);

  /// Marca o desmarca. La lista no tiene tope: el escritorio tampoco.
  ///
  /// Desmarcar saca el id ** wherever esté** y reacomoda el resto, para que el
  /// orden de las otras no cambie.
  void toggle(String sessionId) {
    final at = _order.indexOf(sessionId);
    if (at >= 0) {
      _order.removeAt(at);
    } else {
      _order.add(sessionId);
    }
    _persist();
    notifyListeners();
  }

  /// Mueve una favorita de lugar. Es lo que hace el gestor de reordenar.
  ///
  /// Devuelve `false` si el índice no es válido, para que la UI no finja que
  /// movió algo.
  bool move(int from, int to) {
    if (from < 0 || from >= _order.length) return false;
    if (to < 0 || to >= _order.length) return false;
    if (from == to) return true;
    _order.insert(to, _order.removeAt(from));
    _persist();
    notifyListeners();
    return true;
  }

  void _persist() {
    _prefs.setString(key, jsonEncode(_order));
  }

  /// Sólo para tests.
  @visibleForTesting
  void debugSetOrder(List<String> value) {
    _order
      ..clear()
      ..addAll(value);
    notifyListeners();
  }
}
