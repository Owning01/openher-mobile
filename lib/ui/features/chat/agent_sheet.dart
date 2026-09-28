/// La hoja de agente (`surfaces.model.agent`): buscador sobre los agentes reales
/// que trae `GET /api/agent`, agrupados por modo.
///
/// No existía: los dos pills del composer llamaban al mismo callback y los dos
/// abrían la hoja de modelo, así que no había forma de elegir un agente. El
/// server trae 26 (medido 2026-09-28) y ahora se ven.
///
/// ## Por qué los ocultos no aparecen
///
/// El filtro de `hidden` vive en [AgentCatalog], no acá. `compaction`, `title`
/// y `summary` son internos del server, y los subagentes privados de los skills
/// vienen con `hidden: true`: son invocables por nombre desde un prompt, no
/// elegibles desde una lista. Si esta hoja filtrara por su cuenta, el filtro
/// quedaría duplicado y un cambio en el catálogo no se vería acá.
///
/// ## Los agentes no traen modelo
///
/// Medido: un agente es `id`, `name`, `mode`, `description`, `hidden` y
/// `permissions`. El modelo es de la sesión. Por eso esta hoja no muestra
/// niveles de pensamiento: no hay de dónde sacarlos.
library;

import 'package:flutter/material.dart';

import '../../../domain/models/agent_catalog.dart';
import '../../core/app_icon.dart';
import '../../core/layer_gate.dart';
import '../../core/tokens.dart';

/// Abre la hoja de agente y devuelve el id elegido, o `null` si se cerró sin
/// elegir.
Future<String?> showAgentSheet(
  BuildContext context, {
  required Future<AgentCatalog> Function() load,
  String? current,
}) => showModalBottomSheet<String>(
  context: context,
  showDragHandle: true,
  // Mismo `88%` que la hoja de modelo (`maxSheetFraction`), aunque acá la
  // lista es más corta: dejarlos alineados evita que una se sienta más
  // "alta" que la otra al alternar.
  isScrollControlled: true,
  builder: (sheetContext) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(sheetContext).height * maxAgentSheetFraction,
    ),
    child: LayerGate(
      'surfaces.model.agent',
      child: AgentSheet(
        load: load,
        current: current,
        onClose: () => Navigator.of(sheetContext).pop(),
        onPick: (id) => Navigator.of(sheetContext).pop(id),
      ),
    ),
  ),
);

/// `max-height:88%` del `.sheet-panel` del prototipo, igual que la de modelo.
const double maxAgentSheetFraction = 0.88;

/// La hoja de agente. Pública para poder pump-earla en un test sin levantar un
/// `showModalBottomSheet` ni un server: [load] entra inyectado.
class AgentSheet extends StatefulWidget {
  const AgentSheet({
    super.key,
    required this.load,
    required this.current,
    required this.onClose,
    required this.onPick,
  });

  final Future<AgentCatalog> Function() load;
  final String? current;
  final VoidCallback onClose;
  final ValueChanged<String> onPick;

  static const Key searchKey = Key('agent-sheet-search');
  static const Key loadingKey = Key('agent-sheet-loading');
  static const Key emptyKey = Key('agent-sheet-empty');
  static const Key errorKey = Key('agent-sheet-error');

  @override
  State<AgentSheet> createState() => _AgentSheetState();
}

class _AgentSheetState extends State<AgentSheet> {
  final TextEditingController _query = TextEditingController();

  AgentCatalog? _catalog;
  String _filter = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final c = await widget.load();
      if (!mounted) return;
      setState(() {
        _catalog = c;
        _loading = false;
      });
    } catch (e) {
      // Un fallo se muestra con su mensaje y un reintentar: se queda en la
      // hoja en vez de cerrarse sola, porque el usuario probablemente está
      // eligiendo justo ahora.
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// Filtra por nombre, id y descripción: el usuario busca "plan" o "auditor"
  /// o "revisar el código", y los tres tienen que encontrar algo.
  List<AgentInfo> _matches(List<AgentInfo> all) {
    if (_filter.isEmpty) return all;
    final q = _filter.toLowerCase();
    return [
      for (final a in all)
        if (a.name.toLowerCase().contains(q) ||
            a.id.toLowerCase().contains(q) ||
            a.description.toLowerCase().contains(q))
          a,
    ];
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _head(),
      _search(Theme.of(context).colorScheme),
      Flexible(child: _body()),
    ],
  );

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
          child: Text('Agente', style: Theme.of(context).textTheme.titleLarge),
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
      key: AgentSheet.searchKey,
      controller: _query,
      onChanged: (value) => setState(() => _filter = value.trim()),
      decoration: InputDecoration(
        hintText: 'Buscar agente…',
        prefixIcon: AppIcon('search', size: 18, color: scheme.onSurfaceVariant),
      ),
    ),
  );

  Widget _body() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: SizedBox(
          key: AgentSheet.loadingKey,
          height: 96,
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (_error != null) return _errorState();
    final catalog = _catalog ?? AgentCatalog(const []);
    final hits = _matches(catalog.selectable);
    if (hits.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Text(
          _filter.isEmpty
              ? 'El servidor no devolvió ningún agente.'
              : 'Sin resultados para «$_filter»',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    // Principales arriba, subagentes abajo. Es el mismo criterio del pill: lo
    // que se usa todos los días queda bajo el dedo.
    final primaries = hits.where((a) => a.mode == AgentMode.primary);
    final subagents = hits.where((a) => a.mode == AgentMode.subagent);
    return ListView(
      shrinkWrap: true,
      children: [
        if (primaries.isNotEmpty) ...[
          const _ModeHead('Principales'),
          for (final a in primaries)
            _AgentTile(
              key: ValueKey('agent-${a.id}'),
              agent: a,
              selected: a.id == widget.current,
              onTap: () => widget.onPick(a.id),
            ),
        ],
        if (subagents.isNotEmpty) ...[
          const _ModeHead('Subagentes'),
          for (final a in subagents)
            _AgentTile(
              key: ValueKey('agent-${a.id}'),
              agent: a,
              selected: a.id == widget.current,
              onTap: () => widget.onPick(a.id),
            ),
        ],
      ],
    );
  }

  Widget _errorState() => Padding(
    padding: const EdgeInsets.all(AppSpacing.xl),
    child: Column(
      key: AgentSheet.errorKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'No se pudieron cargar los agentes.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          _error!,
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall,
        ),
        const SizedBox(height: AppSpacing.sm),
        TextButton.icon(
          onPressed: _load,
          icon: AppIcon('refresh', size: 14),
          label: const Text('Reintentar'),
        ),
      ],
    ),
  );
}

/// `.secthead` del prototipo, igual que el encabezado de provider de la hoja
/// de modelo: 11 px, w700, con tracking.
class _ModeHead extends StatelessWidget {
  const _ModeHead(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.md,
      AppSpacing.md,
      AppSpacing.md,
      AppSpacing.xs,
    ),
    child: Text(
      label.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.66,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// `.srow2` del prototipo, la misma fila que usa la hoja de modelo: 52 px
/// mínimo, nombre 13/w500, detalle 12/muted.
class _AgentTile extends StatelessWidget {
  const _AgentTile({
    super.key,
    required this.agent,
    required this.selected,
    required this.onTap,
  });

  final AgentInfo agent;
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
                      Text(
                        agent.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (agent.description.isNotEmpty) ...[
                        const SizedBox(height: 1),
                        Text(
                          agent.description,
                          // Las descripciones de los subagentes son larguísimas
                          // (el de `code-review` es un párrafo entero): a dos
                          // líneas se lee el propósito sin empujar el resto de
                          // la lista fuera de la pantalla.
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                if (selected)
                  AppIcon('check', size: 16, color: scheme.primary)
                else
                  const SizedBox.shrink(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
