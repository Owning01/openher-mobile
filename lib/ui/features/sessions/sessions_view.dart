/// Pantalla de sesiones: la lista de las sesiones del server, agrupada por
/// fecha, con búsqueda, swipe para archivar y menú contextual por long-press.
///
/// Es el destino 1 de 4 del bottom nav. No conoce la red: recibe un
/// [SessionsViewModel] ya construido y avisa dos cosas, [onOpen] (tocar una
/// fila o el `+`) y [onAction] (swipe o menú contextual).
///
/// ## Lo que NO hace, y por qué
/// `Renombrar`, `Fork`, `Exportar markdown`, `Archivar` y `Cerrar` no existen
/// en el dialecto v2: `ApiClient` no expone esos endpoints. La pantalla los
/// **reporta** por [onAction] y vuelve; el swipe hace snap-back. No se borra una
/// fila por un gesto cuyo efecto no se puede persistir (el próximo poll la
/// volvería a pintar y el usuario perdería la fila sin avisar).
library;

import 'package:flutter/material.dart';

import '../../../domain/models/session.dart';
import '../../core/app_icon.dart';
import '../../core/layer_gate.dart';
import '../../core/tokens.dart';
import 'sessions_viewmodel.dart';

class SessionsView extends StatefulWidget {
  const SessionsView({
    super.key,
    required this.viewmodel,
    required this.onOpen,
    this.onAction,
  });

  final SessionsViewModel viewmodel;

  /// Abrir el chat de una sesión (fila tocada o `+` recién creada).
  final void Function(String sessionId) onOpen;

  /// Intención del swipe o del menú contextual. `null` = la pantalla todavía no
  /// conduce esos gestos a ninguna parte.
  final void Function(SessionAction action, SessionInfo session)? onAction;

  // Claves de los widgets que los tests apuntan directo, para no depender de un
  // texto que puede repetirse en pantalla.

  /// Botón de búsqueda del app bar.
  static const Key searchButtonKey = Key('sessions-appbar-search');

  /// Botón `+` del app bar.
  static const Key addButtonKey = Key('sessions-appbar-add');

  /// Campo de texto del buscador.
  static const Key searchFieldKey = Key('sessions-search-field');

  /// Lista agrupada (el contenedor scrolleable).
  static const Key listKey = Key('sessions-list');

  /// Estado vacío.
  static const Key emptyKey = Key('sessions-empty');

  /// Banner de error con su botón de reintento.
  static const Key errorKey = Key('sessions-error');

  @override
  State<SessionsView> createState() => _SessionsViewState();
}

class _SessionsViewState extends State<SessionsView> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _queryFocus = FocusNode();

  /// El buscador está oculto hasta que se toque la lupa.
  bool _searchOpen = false;

  @override
  void initState() {
    super.initState();
    // `load()` pone `loading` de forma síncrona, así que el primer frame ya
    // sale con el spinner y no hay un parpadeo de "vacío" antes.
    if (!widget.viewmodel.loaded) widget.viewmodel.load();
    // El polling arranca con la pantalla, no antes: antes de `initState` no hay
    // árbol al que repintar.
    widget.viewmodel.startPolling();
  }

  @override
  void dispose() {
    // El `Timer` de `active` es del viewmodel, no de la pantalla: si otro dueño
    // lo reusa lo sigue usando, pero nadie mirando no gasta requests.
    widget.viewmodel.stopPolling();
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() => _searchOpen = !_searchOpen);
    if (_searchOpen) {
      _queryFocus.requestFocus();
    } else {
      _queryFocus.unfocus();
      _query.clear();
      widget.viewmodel.search('');
    }
  }

  Future<void> _create() async {
    final id = await widget.viewmodel.create();
    if (!mounted || id == null || id.isEmpty) return;
    widget.onOpen(id);
  }

  /// Swipe a la izquierda. El snap-back es **intencional**: archivar no existe
  /// todavía en el server, así que la fila no puede desaparecer.
  Future<bool> _swiped(SessionInfo session) async {
    _action(SessionAction.archive, session);
    return false;
  }

  void _action(SessionAction action, SessionInfo session) =>
      widget.onAction?.call(action, session);

  void _openMenu(SessionInfo session) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => _SessionMenu(
        onPick: (action) {
          Navigator.of(sheetContext).pop();
          _action(action, session);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // El `ListenableBuilder` envuelve **todo** el Scaffold, app bar incluido:
    // el botón `+` se deshabilita mientras carga, y si el builder sólo cubriera
    // el body el app bar quedaría congelado con el `loading` del primer frame.
    return ListenableBuilder(
      listenable: widget.viewmodel,
      builder: (context, _) => Scaffold(
        appBar: LayerGate(
          'sessions.appbar',
          child: AppBar(
            title: const Text('Sesiones'),
            actions: [
              LayerGate(
                'sessions.appbar.search',
                child: AppIconButton(
                  key: SessionsView.searchButtonKey,
                  icon: 'search',
                  tooltip: 'Buscar sesiones',
                  selected: _searchOpen,
                  onPressed: _toggleSearch,
                ),
              ),
              LayerGate(
                'sessions.appbar.add',
                child: AppIconButton(
                  key: SessionsView.addButtonKey,
                  icon: 'plus',
                  tooltip: 'Nueva sesión',
                  onPressed: widget.viewmodel.loading ? null : _create,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
            ],
          ),
        ),
        body: Column(
          children: [
            if (_searchOpen)
              LayerGate(
                'sessions.search',
                child: _SearchBar(
                  controller: _query,
                  focusNode: _queryFocus,
                  onChanged: widget.viewmodel.search,
                  onClose: _toggleSearch,
                ),
              ),
            if (widget.viewmodel.error != null) _ErrorBanner(widget.viewmodel),
            Expanded(child: _body(widget.viewmodel)),
          ],
        ),
      ),
    );
  }

  /// Spinner, lista o estado vacío. Los tres son scrolleables salvo el spinner
  /// para que el pull-to-refresh funcione incluso con la lista vacía.
  Widget _body(SessionsViewModel vm) {
    if (vm.loading && vm.sessions.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final groups = vm.groups;
    return RefreshIndicator(
      onRefresh: vm.refresh,
      child: groups.isEmpty ? const _EmptyBody() : _groupedList(vm, groups),
    );
  }

  Widget _groupedList(SessionsViewModel vm, List<SessionGroup> groups) =>
      ListView.builder(
        key: SessionsView.listKey,
        // `alwaysScrollable`: con una lista corta que no llena la pantalla, el
        // pull-to-refresh no llegaría sin esto.
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: groups.length,
        itemBuilder: (context, index) {
          final group = groups[index];
          return _Group(
            bucket: group.bucket,
            children: [
              for (final session in group.sessions)
                _SessionRow(
                  key: ValueKey<String>(session.id),
                  session: session,
                  running: vm.isRunning(session),
                  attention: vm.needsAttention(session),
                  relativeTime: vm.relativeTime(session),
                  cost: vm.costOf(session),
                  onTap: () => widget.onOpen(session.id),
                  onMenu: () => _openMenu(session),
                  onArchive: () => _swiped(session),
                ),
            ],
          );
        },
      );
}

/// Encabezado de grupo + sus filas.
class _Group extends StatelessWidget {
  const _Group({required this.bucket, required this.children});

  final SessionBucket bucket;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayerGate(
          'sessions.group.headers',
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.xs,
            ),
            child: Text(
              bucket.label,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
                // `.grouphead` del prototipo: 11px uppercase con
                // `letter-spacing:.66px` para que las letras no se peguen.
                letterSpacing: 0.66,
              ),
            ),
          ),
        ),
        ...children,
      ],
    );
  }
}

/// Una fila de sesión: título, meta, estado de ejecución y costo.
class _SessionRow extends StatelessWidget {
  const _SessionRow({
    super.key,
    required this.session,
    required this.running,
    required this.attention,
    required this.relativeTime,
    required this.cost,
    required this.onTap,
    required this.onMenu,
    required this.onArchive,
  });

  final SessionInfo session;
  final bool running;
  final bool attention;

  /// Ya formateado por el viewmodel: la fila y el encabezado de grupo tienen
  /// que usar el mismo reloj.
  final String relativeTime;
  final String cost;

  final VoidCallback onTap;
  final VoidCallback onMenu;
  final Future<bool> Function() onArchive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final meta = _metaLine();

    return Dismissible(
      key: ValueKey<String>('swipe-${session.id}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => onArchive(),
      background: Container(
        alignment: Alignment.centerRight,
        color: AppColors.dangerOf(brightness),
        child: LayerGate(
          'sessions.swipe.action',
          child: SizedBox(
            width: 96,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AppIcon('list-checks', size: 14, color: _onDanger(brightness)),
                const SizedBox(height: 2),
                Text(
                  'Archivar',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _onDanger(brightness),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: GestureDetector(
          // Long-press y click derecho abren el mismo menú: en Android sólo
          // llega el primero, pero el mismo server se puede mirar desde un
          // cliente de escritorio.
          onLongPress: onMenu,
          onSecondaryTapUp: (_) => onMenu(),
          behavior: HitTestBehavior.opaque,
          child: Semantics(
            button: true,
            label: session.title,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: theme.dividerColor)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Barra de atención: 3px pegadas al borde izquierdo de la
                  // fila, como el `.bar` del prototipo.
                  if (attention) ...[
                    Container(
                      width: 3,
                      height: 38,
                      margin: const EdgeInsets.only(right: AppSpacing.sm),
                      decoration: BoxDecoration(
                        color: AppColors.warningOf(brightness),
                        borderRadius: AppRadius.smAll,
                      ),
                    ),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LayerGate(
                          'sessions.row.title',
                          child: Text(
                            session.title.isEmpty
                                ? 'Sesión sin título'
                                : session.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        if (meta != null)
                          LayerGate(
                            'sessions.row.meta',
                            child: Text(
                              meta,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        if (running)
                          LayerGate(
                            'sessions.row.status',
                            child: Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Row(
                                children: [
                                  const _PulseDot(),
                                  const SizedBox(width: 5),
                                  Text(
                                    'En ejecución',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurface,
                                      fontWeight: FontWeight.w500,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (attention)
                          LayerGate(
                            'sessions.row.attention',
                            child: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: _AttentionPill(
                                brightness: brightness,
                                theme: theme,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      LayerGate(
                        'sessions.row.time',
                        child: Text(
                          relativeTime,
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                      LayerGate(
                        'sessions.row.cost',
                        child: Text(
                          cost,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// `directorio · agente` (el `.smeta` del prototipo: `openher-mobile · build`).
  ///
  /// `null` si no hay ninguno de los dos: una sesión sin directorio ni agente no
  /// necesita segunda línea.
  String? _metaLine() {
    final parts = <String>[
      if (session.directory.isNotEmpty) _basename(session.directory),
      if (session.agent != null && session.agent!.isNotEmpty) session.agent!,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// Último segmento de un path: `G:/code/openher-mobile` → `openher-mobile`.
  static String _basename(String path) {
    final parts = path
        .replaceAll(RegExp(r'[/\\]+$'), '')
        .split(RegExp(r'[/\\]'));
    return parts.isEmpty ? path : parts.last;
  }

  /// Texto sobre el fondo `danger`. En claro el token es un gris oscuro (va
  /// blanco); en oscuro es un gris claro (va negro).
  static Color _onDanger(Brightness brightness) => brightness == Brightness.dark
      ? AppColors.darkBg
      : AppColors.lightOnPrimary;
}

/// `1 pregunta` en un chip: el subagente esperando que su padre lo mire.
class _AttentionPill extends StatelessWidget {
  const _AttentionPill({required this.brightness, required this.theme});

  final Brightness brightness;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final color = AppColors.warningOf(brightness);
    return Container(
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: brightness == Brightness.dark
            ? AppColors.darkWarningSoft
            : AppColors.lightWarningSoft,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon('message-square', size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            '1 pregunta',
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Punto de 6px que late mientras el server dice que la sesión corre.
class _PulseDot extends StatefulWidget {
  const _PulseDot();

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween<double>(
      begin: 0.45,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
    child: Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        shape: BoxShape.circle,
      ),
    ),
  );
}

/// Buscador: campo con lupa adentro, debajo del app bar.
class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: TextField(
        key: SessionsView.searchFieldKey,
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: theme.textTheme.bodyMedium,
        decoration: InputDecoration(
          hintText: 'Buscar sesiones…',
          prefixIcon: const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: AppIcon('search', size: 14),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 0),
          suffixIcon: AppIconButton(
            icon: 'x',
            tooltip: 'Cerrar búsqueda',
            tapSize: 32,
            size: 16,
            onPressed: onClose,
          ),
        ),
      ),
    );
  }
}

/// Estado vacío dentro de un scroller, para que el pull-to-refresh siga
/// funcionando cuando no hay nada que mostrar.
class _EmptyBody extends StatelessWidget {
  const _EmptyBody();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: const Center(child: _EmptyState()),
      ),
    ),
  );
}

/// Sin sesiones en el server.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      key: SessionsView.emptyKey,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(
              'folder',
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text('Sin sesiones', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Toca + para crear una sesión en el directorio actual.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Error de carga: el motivo y un botón para reintentar.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.vm);

  final SessionsViewModel vm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: SessionsView.errorKey,
      width: double.infinity,
      color: theme.colorScheme.error.withValues(alpha: 0.06),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.sm,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              vm.error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
          AppIconButton(
            icon: 'refresh',
            tooltip: 'Reintentar',
            tapSize: 36,
            size: 16,
            onPressed: vm.loading ? null : vm.refresh,
          ),
        ],
      ),
    );
  }
}

/// Las cinco acciones del menú contextual de una fila.
class _SessionMenu extends StatelessWidget {
  const _SessionMenu({required this.onPick});

  final ValueChanged<SessionAction> onPick;

  static const List<(SessionAction, String, String)> _items = [
    (SessionAction.rename, 'Renombrar', 'edit'),
    (SessionAction.fork, 'Fork', 'git-branch'),
    (SessionAction.exportMarkdown, 'Exportar markdown', 'download'),
    (SessionAction.archive, 'Archivar', 'list-checks'),
    (SessionAction.close, 'Cerrar', 'x'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (action, label, icon) in _items)
            ListTile(
              key: Key('sessions-menu-${action.name}'),
              dense: true,
              leading: AppIcon(icon, size: 16),
              title: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: action == SessionAction.close
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w500,
                ),
              ),
              onTap: () => onPick(action),
            ),
        ],
      ),
    );
  }
}
