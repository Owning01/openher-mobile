/// Preferencias de la UI, en `shared_preferences` (plano, sin cifrar).
///
/// Acá va **sólo preferences de presentación**, nunca secretos: la contraseña
/// del server es cosa de [CredsStore]. Mezclarlas sería guardar la clave en un
/// archivo legible por cualquiera con acceso al dispositivo.
///
/// ## Una sola implementación por concepto
/// El acceso va por la interfaz [KeyValuePrefs] y no contra
/// `SharedPreferences` directo, para que los tests usen [InMemoryPrefs] sin
/// canal de plataforma y para que ninguna pantalla lea una clave cruda por su
/// cuenta: las claves viven acá ([PrefsStore.themeKey] y familia).
///
/// ## Sin dependencias de la capa de UI
/// [AppThemeMode] y [AppTextScale] son enums propios de este archivo y no sus
/// equivalentes de Material, y la variante de color se guarda como id crudo
/// ([PrefsStore.themeVariantId]) sin resolverla contra el catálogo: `core` no
/// importa de `ui`.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;
import 'package:shared_preferences/shared_preferences.dart';

/// Tema de la app. El valor guardado es [name], no el índice: si mañana se
/// inserta un modo en el medio, los datos guardados siguen siendo válidos.
enum AppThemeMode {
  system('Sistema'),
  light('Claro'),
  dark('Oscuro');

  const AppThemeMode(this.label);

  /// Rótulo para la fila de Ajustes.
  final String label;

  /// Valor persistido.
  String get wire => name;

  /// Tolera `null` y basura: una pref desconocida es `system`, no un crash.
  static AppThemeMode parse(String? value) => AppThemeMode.values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => AppThemeMode.system,
  );
}

/// Tamaño del texto. Los tres valores salen medidos del prototipo (0.85/1.0/1.15
/// sobre la base de 13 px) y el rótulo es el que pide el diseño.
enum AppTextScale {
  small(0.85, 'Chico'),
  medium(1.0, 'Medio'),
  large(1.15, 'Grande');

  const AppTextScale(this.value, this.label);

  /// Multiplicador que se aplica a la `TextTheme`.
  final double value;

  /// Rótulo para la fila de Ajustes.
  final String label;

  /// Valor persistido.
  double get wire => value;

  /// Acepta el número guardado; si no coincide con ninguno, `medium`.
  static AppTextScale parse(double? value) {
    for (final scale in AppTextScale.values) {
      if ((scale.value - (value ?? double.nan)).abs() < 0.001) return scale;
    }
    return AppTextScale.medium;
  }
}

/// Almacenamiento de preferencias en la forma mínima que necesita [PrefsStore].
abstract interface class KeyValuePrefs {
  String? getString(String key);
  bool? getBool(String key);
  double? getDouble(String key);
  Future<void> setString(String key, String value);
  Future<void> setBool(String key, bool value);
  Future<void> setDouble(String key, double value);
  Future<void> remove(String key);
}

/// Adaptador sobre `shared_preferences`.
///
/// Los getters son **síncronos** a propósito: `SharedPreferences` tiene la
/// instancia completa en memoria desde `getInstance()`, así que leer una pref no
/// necesita `await` y la UI puede pintar en el primer frame.
class SharedPreferencesStore implements KeyValuePrefs {
  const SharedPreferencesStore(this.prefs);

  final SharedPreferences prefs;

  @override
  String? getString(String key) => prefs.getString(key);

  @override
  bool? getBool(String key) => prefs.getBool(key);

  @override
  double? getDouble(String key) => prefs.getDouble(key);

  @override
  Future<void> setString(String key, String value) async {
    await prefs.setString(key, value);
  }

  @override
  Future<void> setBool(String key, bool value) async {
    await prefs.setBool(key, value);
  }

  @override
  Future<void> setDouble(String key, double value) async {
    await prefs.setDouble(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await prefs.remove(key);
  }
}

/// Backend de memoria, para tests. Habla el mismo idioma que
/// [SharedPreferencesStore].
class InMemoryPrefs implements KeyValuePrefs {
  InMemoryPrefs([Map<String, Object>? seed])
    : values = <String, Object>{...?seed};

  final Map<String, Object> values;

  @override
  String? getString(String key) {
    final value = values[key];
    return value is String ? value : null;
  }

  @override
  bool? getBool(String key) {
    final value = values[key];
    return value is bool ? value : null;
  }

  @override
  double? getDouble(String key) {
    final value = values[key];
    return value is double
        ? value
        : (value is int
              ? value.toDouble()
              : (value is String ? double.tryParse(value) : null));
  }

  @override
  Future<void> setString(String key, String value) async => values[key] = value;

  @override
  Future<void> setBool(String key, bool value) async => values[key] = value;

  @override
  Future<void> setDouble(String key, double value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);
}

/// Lectura de todas las preferencias de una vez.
///
/// Sirve para el arranque: la UI pinta con un [PrefsSnapshot] y después
/// escucha los cambios, en vez de hacer un `await` por fila.
@immutable
class PrefsSnapshot {
  const PrefsSnapshot({
    required this.themeMode,
    required this.themeVariantId,
    required this.textScale,
    required this.animations,
    required this.translateEsEn,
    required this.defaultAgent,
    required this.defaultModel,
    required this.lastDirectory,
    required this.layerSwitches,
  });

  final AppThemeMode themeMode;

  /// Id de la variante de color; vacío = automática (ver [themeVariantId]).
  final String themeVariantId;

  final AppTextScale textScale;

  /// Animaciones de la UI. Default **ON** (el diseño las da por activas).
  final bool animations;

  /// Traducir ES→EN. Default **OFF** (arrancar en el idioma del server).
  final bool translateEsEn;

  final String defaultAgent;
  final String defaultModel;

  /// Directorio de trabajo elegido en el server; vacío = el que reporta
  /// `/api/location`.
  final String lastDirectory;

  /// Overrides de capas: `clave → encendido`. Lo que **no** está acá usa el
  /// default de la spec aprobada (90 encendidas, 4 apagadas).
  final Map<String, bool> layerSwitches;
}

/// Preferencias de la UI.
///
/// Inyectable por constructor ([prefs] para tests, [shared] para producción).
/// Los getters son síncronos y los setters asincrónicos: la UI pinta de una y
/// la escritura no bloquea.
class PrefsStore {
  /// Exactamente uno de los dos backends. [prefs] gana si vienen ambos.
  PrefsStore({KeyValuePrefs? prefs, SharedPreferences? shared})
    : _prefs = _resolve(prefs, shared);

  /// Constructor de arranque: carga la instancia real de
  /// `shared_preferences`.
  static Future<PrefsStore> load() async =>
      PrefsStore(shared: await SharedPreferences.getInstance());

  static KeyValuePrefs _resolve(
    KeyValuePrefs? prefs,
    SharedPreferences? shared,
  ) {
    if (prefs != null) return prefs;
    if (shared != null) return SharedPreferencesStore(shared);
    throw ArgumentError('PrefsStore necesita un backend: prefs o shared');
  }

  final KeyValuePrefs _prefs;

  /// Backend efectivo, para tests.
  KeyValuePrefs get backend => _prefs;

  // ───────────────────────────── claves ──────────────────────────────────────

  static const String themeKey = 'openher.theme';
  static const String themeVariantKey = 'openher.theme_variant';
  static const String textScaleKey = 'openher.text_scale';
  static const String animationsKey = 'openher.animations';
  static const String translateKey = 'openher.translate_es_en';
  static const String defaultAgentKey = 'openher.default_agent';
  static const String defaultModelKey = 'openher.default_model';
  static const String lastDirectoryKey = 'openher.last_directory';
  static const String layersKey = 'openher.layers';

  /// Defaults de modelo/agente mientras no haya selector (M7).
  static const String defaultAgentValue = 'build';
  static const String defaultModelValue = 'space-bunny-free';

  // ───────────────────────────── lectura ─────────────────────────────────────

  AppThemeMode get themeMode => AppThemeMode.parse(_prefs.getString(themeKey));

  /// Id de la variante de color elegida; vacío = la automática, o sea el
  /// monocromo de `AppTheme.light()`/`AppTheme.dark()` según la preferencia del
  /// sistema.
  ///
  /// Se guarda el **id** y no la paleta: el catálogo son 61 entradas fijas, así
  /// que el dato es el id y serializar 16 colores por variante sería un formato
  /// que nadie escribe. Acá no se resuelve contra el catálogo —eso es de la
  /// capa de UI, igual que `AppThemeMode` es un enum propio de este archivo y no
  /// un `ThemeMode` de Material—: un id desconocido (app vieja, catálogo
  /// editado) se devuelve tal cual y el que lo pinte cae en automático.
  String get themeVariantId => _prefs.getString(themeVariantKey) ?? '';

  AppTextScale get textScale =>
      AppTextScale.parse(_prefs.getDouble(textScaleKey));

  /// Multiplicador listo para aplicar a la `TextTheme`.
  double get textScaleValue => textScale.value;

  bool get animations => _prefs.getBool(animationsKey) ?? true;

  bool get translateEsEn => _prefs.getBool(translateKey) ?? false;

  String get defaultAgent =>
      _prefs.getString(defaultAgentKey) ?? defaultAgentValue;

  String get defaultModel =>
      _prefs.getString(defaultModelKey) ?? defaultModelValue;

  String get lastDirectory => _prefs.getString(lastDirectoryKey) ?? '';

  /// Overrides de capas guardados. **No** incluye las claves que nunca se
  /// tocaron: ésas siguen el default de la spec (ver [layerEnabled]).
  Map<String, bool> get layerSwitches {
    final raw = _prefs.getString(layersKey);
    if (raw == null || raw.isEmpty) return const <String, bool>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, bool>{};
      final out = <String, bool>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is bool) out[entry.key.toString()] = value;
      }
      return out;
    } on FormatException {
      // Pref corrupta: se ignora en vez de romper la pantalla de ajustes.
      return const <String, bool>{};
    }
  }

  /// Estado efectivo de una capa: el override del usuario si lo hay, si no el
  /// [fallback] que pasó la spec.
  bool layerEnabled(String key, {required bool fallback}) =>
      layerSwitches[key] ?? fallback;

  /// Las 94 claves de la spec: default + override.
  Map<String, bool> resolveLayers(Map<String, bool> spec) => <String, bool>{
    for (final entry in spec.entries)
      entry.key: layerEnabled(entry.key, fallback: entry.value),
  };

  /// Todo de una vez, para pintar el arranque sin `await` por fila.
  PrefsSnapshot snapshot() => PrefsSnapshot(
    themeMode: themeMode,
    themeVariantId: themeVariantId,
    textScale: textScale,
    animations: animations,
    translateEsEn: translateEsEn,
    defaultAgent: defaultAgent,
    defaultModel: defaultModel,
    lastDirectory: lastDirectory,
    layerSwitches: layerSwitches,
  );

  // ───────────────────────────── escritura ───────────────────────────────────

  Future<void> setThemeMode(AppThemeMode mode) =>
      _prefs.setString(themeKey, mode.wire);

  /// Elige la variante de color por id. `''` vuelve a la automática.
  Future<void> setThemeVariant(String id) =>
      _prefs.setString(themeVariantKey, id);

  Future<void> setTextScale(AppTextScale scale) =>
      _prefs.setDouble(textScaleKey, scale.wire);

  Future<void> setAnimations(bool value) =>
      _prefs.setBool(animationsKey, value);

  Future<void> setTranslateEsEn(bool value) =>
      _prefs.setBool(translateKey, value);

  Future<void> setDefaultAgent(String value) =>
      _prefs.setString(defaultAgentKey, value);

  Future<void> setDefaultModel(String value) =>
      _prefs.setString(defaultModelKey, value);

  Future<void> setLastDirectory(String value) =>
      _prefs.setString(lastDirectoryKey, value);

  /// Override de una capa. Es lo que escribe un switch de Ajustes.
  Future<void> setLayer(String key, bool value) async {
    final next = Map<String, bool>.of(layerSwitches);
    if (next[key] == value) return;
    next[key] = value;
    await _prefs.setString(layersKey, jsonEncode(next));
  }

  /// Reemplaza el mapa entero de overrides (restaurar defaults, o el `persist`
  /// que inyecta el catálogo de capas).
  Future<void> setLayers(Map<String, bool> overrides) =>
      _prefs.setString(layersKey, jsonEncode(overrides));

  /// Olvida los overrides de capas (vuelven al default de la spec). El resto
  /// de las preferencias se conserva: restaurar capas no es un logout.
  Future<void> resetLayers() => _prefs.remove(layersKey);

  /// Sólo la clave de capas. No hay secretos acá, pero tampoco se loguea nada.
  @override
  String toString() => 'PrefsStore(${_prefs.runtimeType})';
}
