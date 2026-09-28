/// La hoja de modelo (`surfaces.sheet.model`): buscador sobre el catálogo real
/// que trae `GET /api/model`, agrupado por provider, con los **niveles de
/// pensamiento** de cada modelo debajo.
///
/// Antes era un andamiaje que repetía el modelo de la sesión; ahora lista los
/// 102 modelos del build. El andamiaje murió con el: lo único que sabía era
/// decir "elegí modelo" mientras el server ya tenía la respuesta.
///
/// ## Dos niveles
///
/// El server no tiene un campo "nivel de pensamiento": tiene `variants`, y cada
/// una trae el `settings` del provider. Por eso tocar un modelo **con**
/// variantes despliega la lista de niveles en vez de elegirlo directo: elegir
/// el modelo sin nivel cuando el usuario lo pidió con nivel es peor que un
/// toque de más.
///
/// Tocar un modelo **sin** variantes elige directo (no hay nada más que
/// decidir), y tocar un nivel elige modelo + nivel.
///
/// Lo que devuelve la hoja es un [ModelPick] y nada más: la app no crea la
/// sesión ni guarda la preferencia (el server es el dueño de las dos).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/repositories/catalog_repository.dart';
import '../../../domain/models/errors.dart';
import '../../../domain/models/message.dart' show ModelRef;
import '../../../domain/models/model_catalog.dart';
import '../../core/app_icon.dart';
import '../../core/layer_gate.dart';
import '../../core/tokens.dart';

/// Lo que devuelve la hoja. `variantId` es `null` si el modelo no tiene
/// niveles, o si se eligió sin nivel.
typedef ModelPick = ({String providerId, String modelId, String? variantId});

/// Abre la hoja de modelo y devuelve la elección, o `null` si se cerró sin
/// elegir.
Future<ModelPick?> showModelSheet(
  BuildContext context, {
  required CatalogRepository catalog,
  ModelRef? current,
}) => showModalBottomSheet<ModelPick>(
  context: context,
  showDragHandle: true,
  // La hoja del prototipo es `max-height:88%` (`.sheet-panel`): con 102 modelos
  // el 9/16 de `isScrollControlled: false` no alcanza.
  isScrollControlled: true,
  builder: (sheetContext) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(sheetContext).height * maxSheetFraction,
    ),
    child: LayerGate(
      'surfaces.sheet.model',
      child: ModelSheet(
        catalog: catalog,
        current: current,
        onClose: () => Navigator.of(sheetContext).pop(),
        onPick: (pick) => Navigator.of(sheetContext).pop(pick),
      ),
    ),
  ),
);

/// `max-height:88%` del `.sheet-panel` del prototipo (`prototype/mobile.html`).
const double maxSheetFraction = 0.88;

/// La hoja de modelo. Pública para poder pump-earla en un test sin levantar
/// un `showModalBottomSheet` ni un server: [catalog] entra inyectado.
class ModelSheet extends StatefulWidget {
  const ModelSheet({
    super.key,
    required this.catalog,
    required this.onClose,
    required this.onPick,
    this.current,
  });

  /// De dónde sale el catálogo. Cachea solo: abrir la hoja dos veces seguidas
  /// no pega dos veces al server.
  final CatalogRepository catalog;

  /// El modelo que la sesión ya usa, para marcarlo. `null` = la sesión no
  /// tiene modelo todavía.
  final ModelRef? current;

  /// Cierra sin elegir (devuelve `null`).
  final VoidCallback onClose;

  /// Devuelve la elección y cierra.
  final ValueChanged<ModelPick> onPick;

  // Claves de widget: los tests apuntan al elemento, no al texto.
  static const Key searchKey = Key('model-sheet-search');
  static const Key listKey = Key('model-sheet-list');
  static const Key loadingKey = Key('model-sheet-loading');
  static const Key emptyKey = Key('model-sheet-empty');
  static const Key errorKey = Key('model-sheet-error');

  /// Fila de un modelo. `providerId` + `modelId` la identifican (es el par
  /// que se manda al crear la sesión).
  static Key rowKey(String providerId, String modelId) =>
      Key('model-row-$providerId/$modelId');

  /// Fila de un nivel de pensamiento, debajo de su modelo.
  static Key variantKey(String providerId, String modelId, String variantId) =>
      Key('model-variant-$providerId/$modelId#$variantId');

  @override
  State<ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<ModelSheet> {
  final TextEditingController _query = TextEditingController();

  List<ModelInfo> _models = const <ModelInfo>[];
  bool _loading = true;
  String? _error;
  String _filter = '';

  /// `provider/id` del modelo con los niveles desplegados. Uno a la vez: dos
  /// listas de niveles abiertas no son información, es ruido.
  String? _open;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// Carga el catálogo. Un [OchError] va al estado de error con su mensaje
  /// (los de la red ya están en español); cualquier otra cosa también, porque
  /// un payload raro no puede dejar la hoja girando para siempre.
  Future<void> _load() async {
    if (!_loading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final models = await widget.catalog.models();
      if (!mounted) return;
      setState(() {
        _models = models;
        _loading = false;
        _error = null;
      });
    } on OchError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } on Object catch (e) {
      // Un error no tipado no se muestra crudo (son nombres de tipos de Dart,
      // no algo que el usuario pueda arreglar): se avisa que no se pudo cargar
      // y el motivo crudo queda en el log.
      debugPrint('model_sheet: fallo no tipado al cargar el catálogo: $e');
      if (!mounted) return;
      setState(() {
        _error = 'No se pudo cargar el catálogo de modelos.';
        _loading = false;
      });
    }
  }

  /// El catálogo filtrado, agrupado por `providerID`.
  ///
  /// El orden es el del server: los grupos aparecen en el orden en que el
  /// server nombró su primer modelo y los modelos en el suyo. Ordenar por
  /// nombre sería inventar una preferencia que nadie pidió.
  List<({String provider, List<ModelInfo> models})> _groups() {
    final needle = _filter.toLowerCase();
    final byProvider = <String, List<ModelInfo>>{};
    for (final model in _models) {
      if (needle.isNotEmpty && !_matches(model, needle)) continue;
      byProvider.putIfAbsent(model.providerID, () => <ModelInfo>[]).add(model);
    }
    return [
      for (final entry in byProvider.entries)
        (provider: entry.key, models: entry.value),
    ];
  }

  /// Busca por nombre, id, `modelID`, familia y provider: el usuario recuerda
  /// cualquiera de los cinco.
  static bool _matches(ModelInfo model, String needle) =>
      model.name.toLowerCase().contains(needle) ||
      model.id.toLowerCase().contains(needle) ||
      model.modelID.toLowerCase().contains(needle) ||
      model.family.toLowerCase().contains(needle) ||
      model.providerID.toLowerCase().contains(needle);

  /// La lista plana que se pinta: encabezado de provider, modelo, y los
  /// niveles del modelo abierto.
  ///
  /// Se repiten los items que el server mandó dos veces (mismo par
  /// provider/id, o mismo nivel dentro de un modelo): la lista es más corta y
  /// las claves de widget siguen siendo únicas.
  List<_Row> _rows(List<({String provider, List<ModelInfo> models})> groups) {
    final seen = <String>{};
    final rows = <_Row>[];
    for (final group in groups) {
      if (group.models.isEmpty) continue;
      rows.add(_RowHead(group.provider));
      for (final model in group.models) {
        if (!seen.add(model.ref)) continue;
        rows.add(_RowModel(model));
        if (_open != model.ref) continue;
        for (final variant in model.variants) {
          if (!seen.add('${model.ref}#${variant.id}')) continue;
          rows.add(_RowVariant(model, variant));
        }
      }
    }
    return rows;
  }

  bool _isOpen(ModelInfo model) => _open == model.ref;

  /// Un modelo sin niveles se elige directo; con niveles, el toque los despliega
  /// (elegir sin nivel cuando hay niveles sería decidir por el usuario).
  void _onModelTap(ModelInfo model) {
    if (!model.hasVariants) {
      widget.onPick((
        providerId: model.providerID,
        modelId: model.id,
        variantId: null,
      ));
      return;
    }
    setState(() => _open = _isOpen(model) ? null : model.ref);
  }

  void _onVariantTap(ModelInfo model, ModelVariant variant) => widget.onPick((
    providerId: model.providerID,
    modelId: model.id,
    variantId: variant.id,
  ));

  bool _isCurrent(ModelInfo model) {
    final current = widget.current;
    return current != null &&
        current.id == model.id &&
        current.providerID == model.providerID;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final groups = _groups();
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _head(),
          _search(scheme),
          Flexible(child: _body(scheme, groups)),
        ],
      ),
    );
  }

  Widget _head() => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.lg,
      0,
      AppSpacing.sm,
      AppSpacing.sm,
    ),
    child: Row(
      children: [
        Expanded(
          child: Text('Modelo', style: Theme.of(context).textTheme.titleLarge),
        ),
        AppIconButton(
          icon: 'x',
          tooltip: 'Cerrar',
          onPressed: widget.onClose,
          size: 20,
        ),
      ],
    ),
  );

  Widget _search(ColorScheme scheme) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
    child: TextField(
      key: ModelSheet.searchKey,
      controller: _query,
      onChanged: (value) => setState(() => _filter = value.trim()),
      decoration: InputDecoration(
        hintText: 'Buscar modelo…',
        prefixIcon: AppIcon('search', size: 18, color: scheme.onSurfaceVariant),
      ),
    ),
  );

  Widget _body(
    ColorScheme scheme,
    List<({String provider, List<ModelInfo> models})> groups,
  ) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: SizedBox(
          key: ModelSheet.loadingKey,
          height: 96,
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    final error = _error;
    if (error != null) return _errorState(scheme, error);

    final rows = _rows(groups);
    if (rows.isEmpty) {
      return Padding(
        key: ModelSheet.emptyKey,
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Text(
          _filter.isEmpty
              ? 'Sin resultados: el servidor no devolvió modelos.'
              : 'Sin resultados para "$_filter".',
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      key: ModelSheet.listKey,
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      itemCount: rows.length,
      itemBuilder: (context, index) => switch (rows[index]) {
        _RowHead(:final provider) => _ProviderHead(provider),
        _RowModel(:final model) => _ModelTile(
          key: ModelSheet.rowKey(model.providerID, model.id),
          model: model,
          open: _isOpen(model),
          selected: _isCurrent(model),
          onTap: () => _onModelTap(model),
        ),
        _RowVariant(:final model, :final variant) => _VariantTile(
          key: ModelSheet.variantKey(model.providerID, model.id, variant.id),
          label: variant.label,
          effort: variant.reasoningEffort ?? variant.id,
          selected: widget.current?.variant == variant.id && _isCurrent(model),
          onTap: () => _onVariantTap(model, variant),
        ),
      },
    );
  }

  Widget _errorState(ColorScheme scheme, String message) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.lg,
      AppSpacing.sm,
      AppSpacing.sm,
      AppSpacing.lg,
    ),
    child: Column(
      key: ModelSheet.errorKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message, style: TextStyle(fontSize: 13, color: scheme.onSurface)),
        const SizedBox(height: AppSpacing.xs),
        TextButton.icon(
          onPressed: _load,
          icon: AppIcon('refresh', size: 16, color: scheme.onSurfaceVariant),
          label: Text(
            'Reintentar',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    ),
  );
}

/// Un ítem de la lista plana de la hoja.
sealed class _Row {
  const _Row();
}

/// Encabezado de grupo: el `providerID`.
final class _RowHead extends _Row {
  const _RowHead(this.provider);

  final String provider;
}

/// Un modelo del catálogo.
final class _RowModel extends _Row {
  const _RowModel(this.model);

  final ModelInfo model;
}

/// Un nivel de pensamiento de un modelo.
final class _RowVariant extends _Row {
  const _RowVariant(this.model, this.variant);

  final ModelInfo model;
  final ModelVariant variant;
}

/// `.secthead` del prototipo: 11px, w700, mayúsculas, tracking .66.
class _ProviderHead extends StatelessWidget {
  const _ProviderHead(this.provider);

  final String provider;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.md,
      AppSpacing.md,
      AppSpacing.md,
      AppSpacing.xs,
    ),
    child: Text(
      // Sin provider declarado no hay contra qué agrupar, y el encabezado lo
      // dice en vez de dejar un rótulo vacío arriba de los modelos.
      provider.isEmpty ? 'Sin proveedor' : provider.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.66,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// `.srow2` del prototipo: 52 px de alto, nombre 13/w500, detalle 12/muted,
/// precio 11/muted-strong con cifras tabulares a la derecha.
class _ModelTile extends StatelessWidget {
  const _ModelTile({
    super.key,
    required this.model,
    required this.open,
    required this.selected,
    required this.onTap,
  });

  final ModelInfo model;

  /// ¿Tienen sus niveles desplegados? (Sólo hay levels si el modelo los trae.)
  final bool open;

  /// Es el modelo de la sesión.
  final bool selected;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Material(
      color: selected ? scheme.primary.withValues(alpha: 0.07) : null,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // `.srow2 .n`: 13px / w500 / `--text`.
                      Text(
                        model.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 1),
                      // `.srow2 .pv`: 12px / `--muted`.
                      Text(
                        _detail(model),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (model.priceLabel.isNotEmpty) ...[
                  const SizedBox(width: AppSpacing.sm),
                  // `.srow2 .pr`: 11px, cifras tabulares, a la derecha.
                  Text(
                    model.priceLabel,
                    style: text.labelSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
                if (model.hasVariants) ...[
                  const SizedBox(width: AppSpacing.xs),
                  // El descriptor de que hay un segundo nivel: sin este
                  // chevron, tocar la fila no parece hacer nada.
                  AppIcon(
                    open ? 'chevron-down' : 'chevron-right',
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
                if (selected) ...[
                  const SizedBox(width: AppSpacing.xs),
                  AppIcon('check', size: 16),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// `opencode-go · 1M ctx · deshabilitado`. La ventana de contexto sólo se
  /// muestra si el server la declaró.
  static String _detail(ModelInfo model) {
    final parts = <String>[model.providerID];
    final limit = formatLimit(model.contextLimit);
    if (limit.isNotEmpty) parts.add('$limit ctx');
    if (!model.isAvailable) {
      parts.add(model.status == 'deprecated' ? 'deprecado' : 'deshabilitado');
    }
    return parts.join(' · ');
  }
}

/// Un nivel de pensamiento, un paso adentro del modelo. El `reasoningEffort`
/// crudo va en la línea de abajo: es el valor que viaja al server, y esconderlo
/// detrás de "Muy alto" haría imposible distinguir dos niveles parecidos.
class _VariantTile extends StatelessWidget {
  const _VariantTile({
    super.key,
    required this.label,
    required this.effort,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String effort;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Material(
      color: selected ? scheme.primary.withValues(alpha: 0.07) : null,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.xxl,
              right: AppSpacing.md,
              top: AppSpacing.xs,
              bottom: AppSpacing.xs,
            ),
            child: Row(
              children: [
                AppIcon('sparkles', size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                // El `settings.reasoningEffort` crudo: es lo que viaja al
                // server, y sin él "Muy alto" y "Max" no se distinguen.
                if (effort != label) Text(effort, style: text.labelSmall),
                if (selected) ...[
                  const SizedBox(width: AppSpacing.xs),
                  AppIcon('check', size: 16),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
