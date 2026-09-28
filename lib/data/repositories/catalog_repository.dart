/// Repositorio del catálogo de modelos (`GET /api/model`).
///
/// Es la única traducción entre el JSON crudo de la ruta y [ModelInfo], y el
/// **único** dueño de la caché: la red no cachea y la UI no sabe que hay TTL.
///
/// ## Por qué cachea
///
/// `/api/model` devuelve los 102 modelos del build en una sola respuesta, y el
/// usuario abre la hoja de modelo una y otra vez mientras arma la sesión. Sin
/// caché, cada apertura es un request completo; con TTL corto ([defaultTtl]) el
/// catálogo se relee solo cada 5 minutos, que es de sobra para que un build
/// cambie.
///
/// Un criterio y uno solo: **si está en memoria y no venció, no se pega al
/// server**. No hay refresco manual, ni caché por provider, ni cache en disco:
/// un catálogo viejo de un build viejo es peor que uno de hace 5 minutos.
///
/// Un fallo **no** se cachea: si el server no respondió, la próxima llamada
/// reintenta. Cachear el error dejaría la hoja "sin modelos" hasta que venciera
/// el TTL.
library;

import '../../core/network/api_client.dart';
import '../../domain/models/model_catalog.dart';

class CatalogRepository {
  CatalogRepository(
    this._api, {
    this.ttl = defaultTtl,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Vida de la caché. Corto a propósito: el server puede cambiar de build
  /// (o de credenciales) en cualquier momento y 5 minutos es imperceptible.
  static const Duration defaultTtl = Duration(minutes: 5);

  final ApiClient _api;

  /// Cuánto vive lo cacheado. Inyectable para los tests.
  final Duration ttl;

  final DateTime Function() _now;

  List<ModelInfo>? _cached;

  /// Cuándo se llenó [_cached]. `null` = no hay nada cacheado.
  DateTime? _fetchedAt;

  /// El request en vuelo, para que dos pantallas que abren la hoja al mismo
  /// tiempo no peguen dos veces al endpoint. No es un criterio de caché: es el
  /// mismo criterio aplicado a una respuesta que todavía no llegó.
  Future<List<ModelInfo>>? _pending;

  /// El catálogo de modelos, en el orden que lo manda el server.
  ///
  /// Lanza [OchError] si el server no respondió: la lista vacía significaría
  /// "no hay modelos", y es mejor que la UI diga "no se pudo cargar" a que
  /// prometa un catálogo vacío.
  Future<List<ModelInfo>> models() {
    final cached = _cached;
    if (cached != null && !_expired) {
      return Future<List<ModelInfo>>.value(cached);
    }
    final pending = _pending;
    if (pending != null) return pending;
    final future = _load();
    _pending = future;
    return future.whenComplete(() {
      if (identical(_pending, future)) _pending = null;
    });
  }

  /// El modelo de un par `providerId`/`modelId`, o `null` si el catálogo no lo
  /// tiene.
  ///
  /// Busca por `id` primero en **todo** el catálogo y recién después por
  /// `modelID`, en dos pasadas: en un mismo provider el `modelID` de un modelo
  /// puede ser el `id` de otro, y el `id` exacto es el que se manda al crear
  /// la sesión.
  Future<ModelInfo?> findModel({
    required String providerId,
    required String modelId,
  }) async {
    final wanted = modelId.trim();
    if (wanted.isEmpty) return null;
    final catalog = await models();
    for (final model in catalog) {
      if (model.providerID == providerId && model.id == wanted) return model;
    }
    for (final model in catalog) {
      if (model.providerID == providerId && model.modelID == wanted) {
        return model;
      }
    }
    return null;
  }

  Future<List<ModelInfo>> _load() async {
    final raw = await _api.listModels();
    final models = [for (final item in raw) ModelInfo.fromJson(item)];
    _cached = models;
    _fetchedAt = _now();
    return models;
  }

  bool get _expired =>
      _fetchedAt == null || _now().difference(_fetchedAt!) >= ttl;
}
