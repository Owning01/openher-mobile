import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';

/// Una capa de la UI (clave de la spec aprobada). Las claves vienen de
/// `spec/layers.json`, que exportaste del prototipo.
@immutable
class LayerSpec {
  const LayerSpec(this.key, this.defaultOn, this.label);

  final String key;
  final bool defaultOn;
  final String label;

  /// Identificador de widget para los tests: `layer:<key>`.
  @override
  String toString() => 'layer:$key';
}

/// Catálogo de capas: la config aprobada + el override en vivo (lo que el
/// usuario apaga/enciende en Ajustes). Se inicializa una vez leyendo el asset.
class LayerCatalog extends ChangeNotifier {
  LayerCatalog._(this._defaults, this._overrides, this._persist);

  final Map<String, bool> _defaults;
  final Map<String, bool> _overrides;

  /// Persistencia de los overrides. Se inyecta (lo cablea `main` contra el
  /// `PrefsStore`) para que el catálogo no dependa del almacenamiento.
  final Future<void> Function(Map<String, bool> overrides)? _persist;

  static const String assetPath = 'assets/spec/layers.json';

  /// Se inyecta en `main()` (o en tests) antes de usar la app.
  static LayerCatalog? _instance;

  static LayerCatalog get instance {
    final c = _instance;
    if (c == null) {
      throw StateError(
        'LayerCatalog no inicializado: llamá a LayerCatalog.load()',
      );
    }
    return c;
  }

  /// Inyecta (o limpia, con `null`) el catálogo. Sólo para tests.
  @visibleForTesting
  static void debugSetInstance(LayerCatalog? c) => _instance = c;

  /// Carga `spec/layers.json` del bundle y aplica los overrides persistidos.
  static Future<LayerCatalog> load({
    Map<String, bool> overrides = const {},
    Future<void> Function(Map<String, bool>)? persist,
  }) async {
    final raw = await rootBundle.loadString(assetPath);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final layers = json['layers'] as Map<String, dynamic>;
    final defaults = <String, bool>{
      for (final e in layers.entries) e.key: e.value == true,
    };
    final catalog = LayerCatalog._(defaults, {...overrides}, persist);
    _instance = catalog;
    return catalog;
  }

  /// Constructor para tests, sin bundle.
  @visibleForTesting
  factory LayerCatalog.forTest(
    Map<String, bool> defaults, {
    Map<String, bool> overrides = const {},
    Future<void> Function(Map<String, bool>)? persist,
  }) => LayerCatalog._(defaults, {...overrides}, persist);

  List<LayerSpec> get all => _defaults.entries
      .map((e) => LayerSpec(e.key, e.value, _labelFor(e.key)))
      .toList();

  /// ¿Está la capa activa? (default de la spec, o el override del usuario).
  bool isOn(String key) => _overrides[key] ?? _defaults[key] ?? false;

  /// El usuario enciende/apaga una capa en runtime. Persiste.
  Future<void> toggle(String key, bool value) async {
    if (_defaults[key] == null) {
      throw ArgumentError('Capa desconocida: $key');
    }
    if (value == _defaults[key]) {
      _overrides.remove(key); // vuelve al default de la spec
    } else {
      _overrides[key] = value;
    }
    notifyListeners();
    await _persist?.call(_overrides);
  }

  /// Restaura los defaults de la spec aprovada.
  Future<void> resetAll() async {
    _overrides.clear();
    notifyListeners();
    await _persist?.call(_overrides);
  }

  static String _labelFor(String key) {
    final tail = key.split('.').last;
    return tail
        .replaceAllMapped(
          RegExp(r'([a-z])([A-Z])'),
          (m) => '${m[1]} ${(m[2] ?? '').toLowerCase()}',
        )
        .replaceAll('-', ' ');
  }
}

/// Envuelve un subárbol y lo quita de pantalla si su capa está apagada.
///
/// Es el equivalente en Flutter del `[data-layer]` del prototipo: el mismo
/// sistema de toggles, pero dentro de la app real.
class LayerGate extends StatelessWidget {
  const LayerGate(this.layerKey, {super.key, required this.child});

  /// Clave de la capa en `spec/layers.json` (p.ej. `chat.appbar.title`).
  final String layerKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final catalog = LayerCatalog.instance;
    return ListenableBuilder(
      listenable: catalog,
      builder: (context, _) =>
          catalog.isOn(layerKey) ? child : const SizedBox.shrink(),
    );
  }
}
