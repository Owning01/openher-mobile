/// Catálogo de modelos de `GET /api/model` (dialecto v2 de opencode).
///
/// ## El "nivel de pensamiento" son las `variants`
///
/// El server **no** tiene un campo de nivel de pensamiento: lo modela como
/// `variants`, y cada una trae el `settings` que hay que mandar al provider.
/// Medido contra el server real (102 modelos, 75 con variantes) los ids que
/// aparecen son `none, low, medium, high, xhigh, max`, y el `settings` no
/// siempre trae lo mismo: `{"reasoningEffort":"low"}` en un caso,
/// `{"reasoningEffort":"none","reasoningSummary":"auto",
/// "include":["reasoning.encrypted_content"]}` en otro. Por eso el `settings`
/// crudo se conserva entero ([ModelVariant.settings]) y el nivel se lee de
/// `reasoningEffort` ([ModelVariant.reasoningEffort]), no del `id`.
///
/// ## Tolerancia
///
/// Este archivo es la **única** traducción entre el JSON crudo del catálogo y
/// el dominio, y todos sus `fromJson` son **totales**: un modelo sin
/// `variants` no tiene niveles, uno sin `limit` no declara ventana de
/// contexto, y ninguno de los dos casos puede voltear la hoja de modelo (un
/// `throw` acá es BLOCKER: la lista entera se cae).
///
/// Los valores ausentes son **"no declarado", nunca "infinito"**: un límite en
/// `0` significa que el server no lo mandó, así que la UI no lo inventa.
library;

import 'errors.dart';

/// Un nivel de pensamiento de un modelo (`variants[].id`).
///
/// Inmutable. Un nivel sin `settings` es un nivel sin `reasoningEffort`: la
/// etiqueta cae al `id` crudo, que es lo honesto para un valor que la app no
/// conoce.
final class ModelVariant {
  const ModelVariant({
    required this.id,
    this.reasoningEffort,
    this.settings = const <String, Object?>{},
  });

  /// Mapea una variante cruda. Tolera que no sea un mapa, que no traiga `id` y
  /// que `settings` sea cualquier cosa: lo que no se puede leer se deja vacío
  /// y el resto del modelo sigue siendo válido.
  factory ModelVariant.fromJson(Object? raw) {
    final json = asMap(raw) ?? const <String, Object?>{};
    final settings = asMap(json['settings']) ?? const <String, Object?>{};
    return ModelVariant(
      id: asStr(json['id']) ?? '',
      reasoningEffort: _nonEmpty(asStr(settings['reasoningEffort'])),
      settings: settings,
    );
  }

  /// `low`, `max`, `none`… Es lo que viaja como `model.variant` al crear la
  /// sesión.
  final String id;

  /// `settings.reasoningEffort`: el valor que el provider entiende. `null` si
  /// el build no lo mandó.
  final String? reasoningEffort;

  /// El `settings` **crudo** de la variante. Se conserva entero porque
  /// `reasoningSummary` e `include` no son nuestros: son del provider, y el día
  /// que el server los use para armar el request no hay que volver a leer el
  /// JSON.
  final Map<String, Object?> settings;

  /// El nivel en español, para pintar. Sin `reasoningEffort` se muestra el `id`
  /// tal cual.
  String get label {
    final effort = reasoningEffort;
    return effort == null ? id : thinkingLabel(effort);
  }

  @override
  String toString() => id;
}

/// Etiqueta en español de un nivel de razonamiento.
///
/// Un id que la app no conoce **se muestra tal cual**: inventarle un nombre a
/// un nivel que el server añadió después sería mentir sobre lo que se picked.
String thinkingLabel(String effort) => switch (effort) {
  'none' => 'Sin razonamiento',
  'low' => 'Bajo',
  'medium' => 'Medio',
  'high' => 'Alto',
  'xhigh' => 'Muy alto',
  'max' => 'Máximo',
  _ => effort,
};

/// `$0.50 / $1.50` (entrada / salida, por millón de tokens).
///
/// `''` cuando no hay precio declarado (los dos en 0), que es el caso de los
/// modelos de suscripción: la app no escribe "gratis" porque el server no lo
/// dijo. Una parte en 0 se omite en vez de mostrar `$0.00 / $1.50`.
///
/// Por debajo de un centavo hacen falta más decimales: `$0.0005` redondeado a
/// dos decimales es un precio que el server no cobró.
String formatPrice(double price) {
  if (price <= 0) return '';
  final text = price < 0.01
      ? price.toStringAsFixed(4)
      : price.toStringAsFixed(2);
  return '\$$text';
}

/// Ventana de contexto de un modelo, abreviada: `1M`, `131k`, `200k`.
///
/// `''` cuando el server no declaró `limit.context`: "no declarado" no es lo
/// mismo que "ilimitado", y la fila omite el dato en vez de inventarlo.
String formatLimit(int tokens) {
  if (tokens <= 0) return '';
  if (tokens >= 1000000) return '${_compact(tokens / 1000000)}M';
  if (tokens >= 1000) return '${_compact(tokens / 1000)}k';
  return '$tokens';
}

/// Un decimal hasta las 100 unidades, entero de ahí en más: `16.0k` es ruido
/// cuando lo que se quiere leer es `16k`.
String _compact(double value) {
  if (value >= 100) return value.round().toString();
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

/// Un modelo del catálogo (`ModelV2Info` de `GET /api/model`).
final class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.modelID,
    required this.providerID,
    required this.name,
    required this.variants,
    required this.inputModalities,
    required this.status,
    this.family = '',
    this.contextLimit = 0,
    this.outputLimit = 0,
    this.inputCost = 0,
    this.outputCost = 0,
    this.enabled = true,
  });

  /// Mapea un modelo crudo. **Nunca tira**: todo campo ausente o de otro tipo
  /// deja su valor por defecto.
  factory ModelInfo.fromJson(Map<String, Object?> json) {
    final id = asStr(json['id']) ?? '';
    final limit = asMap(json['limit']) ?? const <String, Object?>{};
    final capabilities =
        asMap(json['capabilities']) ?? const <String, Object?>{};
    final costs = asList(json['cost']);
    final cost = (costs == null || costs.isEmpty)
        ? const <String, Object?>{}
        : asMap(costs.first) ?? const <String, Object?>{};
    return ModelInfo(
      id: id,
      // `modelID` es el nombre del modelo **en el provider**; `id` es el del
      // catálogo de opencode. Los dos se buscan: ver `CatalogRepository`.
      modelID: asStr(json['modelID']) ?? '',
      providerID: asStr(json['providerID']) ?? '',
      family: asStr(json['family']) ?? '',
      // Sin `name` se muestra el id: es mejor un id feo que una fila muda.
      name: _nonEmpty(asStr(json['name'])) ?? id,
      variants: _variants(json['variants']),
      inputModalities: [
        for (final modality
            in asList(capabilities['input']) ?? const <Object?>[])
          if (asStr(modality) case final String value) value,
      ],
      contextLimit: asInt(limit['context']) ?? 0,
      outputLimit: asInt(limit['output']) ?? 0,
      // Un precio que viene como string no se castea: se trata como no
      // declarado (0) y no como un número inventado.
      inputCost: asNum(cost['input']) ?? 0,
      outputCost: asNum(cost['output']) ?? 0,
      status: asStr(json['status']) ?? '',
      // Un build que no manda `enabled` no está deshabilitando nada: lo que el
      // server no prohíbe, la app lo muestra.
      enabled: asBool(json['enabled']) ?? true,
    );
  }

  /// `space-bunny-free`: el id del catálogo, y el que va como `model.id` al
  /// crear la sesión.
  final String id;

  /// `modelID`: cómo llama el provider a este modelo.
  final String modelID;

  /// `opencode-go`, `openai`… Agrupa la lista y es la otra mitad del par que
  /// identifica un modelo.
  final String providerID;

  /// `Space Bunny Free`: el nombre para humanos.
  final String name;

  /// `longcat`. Se usa en el buscador.
  final String family;

  /// Los niveles de pensamiento, en el orden que manda el server. Vacío si el
  /// modelo no declara ninguno (o si vino algo que no es una lista).
  final List<ModelVariant> variants;

  /// `limit.context`. `0` = no declarado.
  final int contextLimit;

  /// `limit.output`. `0` = no declarado.
  final int outputLimit;

  /// `cost[0].input` en USD por millón de tokens. `0` = no declarado.
  final double inputCost;

  /// `cost[0].output` en USD por millón de tokens. `0` = no declarado.
  final double outputCost;

  /// `capabilities.input`: `text`, `image`… Vacío si no lo declaró.
  final List<String> inputModalities;

  /// `active`, `beta`, `deprecated`, `alpha`… `''` si no vino.
  final String status;

  /// `enabled` del server. Default `true` (ver [ModelInfo.fromJson]).
  final bool enabled;

  /// ¿El modelo declara niveles de pensamiento?
  bool get hasVariants => variants.isNotEmpty;

  /// ¿Se puede elegir? Un modelo `deprecated` o `enabled: false` se muestra
  /// marcado como tal, pero la fila no se esconde: decidir qué hacer con un
  /// modelo apagado es del server, no de la lista.
  bool get isAvailable => enabled && status != 'deprecated';

  /// El precio de la fila, o `''` si no hay precio declarado.
  String get priceLabel {
    final parts = [formatPrice(inputCost), formatPrice(outputCost)];
    return parts.where((part) => part.isNotEmpty).join(' / ');
  }

  /// `opencode-go/space-bunny-free`.
  String get ref => providerID.isEmpty ? id : '$providerID/$id';

  @override
  String toString() => ref;

  /// Las variantes, **en el orden del server**, y sólo las que se pueden pedir:
  /// una variante sin `id` no se puede mandar como `model.variant`, así que no
  /// se ofrece.
  static List<ModelVariant> _variants(Object? raw) {
    final variants = <ModelVariant>[];
    for (final item in asMapList(raw)) {
      final variant = ModelVariant.fromJson(item);
      if (variant.id.isNotEmpty) variants.add(variant);
    }
    return variants;
  }
}

/// `''` → `null`. Evita que un string vacío se lea como "el server lo mandó y
/// está vacío", que no es lo mismo que "no lo mandó".
String? _nonEmpty(String? value) =>
    (value == null || value.isEmpty) ? null : value;
