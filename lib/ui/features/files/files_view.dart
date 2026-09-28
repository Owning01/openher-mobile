/// Pantalla de **Archivos** (destino 3 de la bottom nav).
///
/// Reproduce `prototype/mobile.html` §3 (`data-screen="files"`): app bar de
/// 56px con título y dos acciones, fila de breadcrumbs y una lista plana que
/// mezcla carpetas y archivos.
///
/// ## Qué decide el view y qué decide el viewmodel
///
/// [FilesView] no habla con la red: todo el estado vive en [FilesViewModel] y la
/// vista sólo lo pinta y traduce gestos a ([FilesViewModel.load],
/// [FilesViewModel.navigateTo], [FilesViewModel.search], …). Por eso un test
/// puede inyectar un viewmodel y pump-ear la pantalla entera sin red.
///
/// ## Gestos
///
/// - **Tocar una carpeta** entra a ella. **Tocar un archivo** abre su hoja de
///   acciones: no hay visor de archivos todavía, así que la hoja *es* la
///   superficie de un archivo.
/// - **Tocar largo** (o el menú contextual de Android) abre la misma hoja.
/// - **Pull-to-refresh** vuelve a pedir el directorio.
///
/// ## Lo que todavía no está
///
/// `Abrir` y `Ver diff` salen en la hoja con el estilo de acción deshabilitada
/// (`prototype/mobile.html:429`): no hay visor ni diff que abrir en este
/// milestone, y un botón que finge funcionar es peor que uno que no se puede
/// apretar.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../../core/network/server_config.dart';
import '../../../data/repositories/file_repository.dart';
import '../../core/app_icon.dart';
import '../../core/layer_gate.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import 'files_viewmodel.dart';

/// Qué se pidió desde la hoja de acciones de una fila.
enum FileAction { open, copyPath, diff, addToChat }

class FilesView extends StatefulWidget {
  const FilesView({
    super.key,
    required this.config,
    required this.onAddToChat,
    this.viewModel,
  });

  /// Server conectado. Se usa para armar el [FileRepository] propio.
  final ServerConfig config;

  /// "Añadir al chat": la app pone la ruta en el composer de la sesión.
  final ValueChanged<String> onAddToChat;

  /// Viewmodel ya hecho. Si viene, esta vista **no lo pide suelta ni lo
  /// descarta**: lo usa tal cual (tests, y navegación que quiera conservar el
  /// árbol en memoria).
  final FilesViewModel? viewModel;

  /// Espera antes de buscar: una request por tecla es una request por tecla.
  static const Duration searchDebounce = Duration(milliseconds: 250);

  // Claves de capa del diseño aprobado (`spec/layers.json`).
  static const String layerAppBar = 'files.appbar';
  static const String layerTitle = 'files.appbar.title';
  static const String layerSearch = 'files.appbar.search';
  static const String layerOverflow = 'files.appbar.overflow';
  static const String layerBreadcrumb = 'files.breadcrumb';
  static const String layerRowEntry = 'files.row.entry';
  static const String layerRowName = 'files.row.name';
  static const String layerRowExt = 'files.row.ext';
  static const String layerRowGit = 'files.row.git';
  static const String layerRowDiff = 'files.row.diff';
  static const String layerSheet = 'surfaces.sheet.file';

  // Claves de widget, para que los tests apunten al elemento y no al texto.
  static const Key breadcrumbKey = Key('files-breadcrumb');
  static const Key searchFieldKey = Key('files-search');
  static const Key listKey = Key('files-list');
  static const Key emptyKey = Key('files-empty');
  static const Key errorKey = Key('files-error');

  /// Fila de [path]: el path completo, que es único.
  static Key rowKey(String path) => Key('files-row-$path');

  /// Acción de una hoja, por nombre (`FileAction.name` /
  /// `_OverflowAction.name`): el rótulo se repite entre hojas.
  static Key sheetActionKey(String name) => Key('files-sheet-$name');

  @override
  State<FilesView> createState() => _FilesViewState();
}

class _FilesViewState extends State<FilesView> {
  late FilesViewModel _model;
  bool _ownsModel = false;
  bool _bound = false;

  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant FilesView old) {
    super.didUpdateWidget(old);
    // Un viewmodel nuevo, o un server nuevo mientras la vista es dueña del
    // suyo: en los dos casos el estado anterior dejó de servir. `ServerConfig`
    // no define `==`, así que acá se compara identidad, que es justo lo que
    // cambia cuando `main` relee las credenciales.
    if (widget.viewModel != old.viewModel ||
        (widget.viewModel == null && widget.config != old.config)) {
      _bind();
    }
  }

  /// Reengancha el viewmodel. Sólo lo pide la vista cuando nadie se lo pasó.
  void _bind() {
    _debounce?.cancel();
    if (_bound) {
      if (_ownsModel) _model.dispose();
      _bound = false;
    }
    _model =
        widget.viewModel ??
        FilesViewModel(repository: FileRepository(config: widget.config));
    _ownsModel = widget.viewModel == null;
    _bound = true;
    if (_ownsModel) unawaited(_model.load(FileRepository.rootPath));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    // Sólo se descarta lo que esta vista construyó: un viewmodel inyectado es
    // del caller.
    if (_ownsModel) _model.dispose();
    super.dispose();
  }

  // ───────────────────────────── gestos ──────────────────────────────────────

  void _openSearch() => setState(() => _searching = true);

  /// Cierra el buscador sin tocar la red. Se usa cuando el viewmodel ya está
  /// saliendo de la búsqueda por su cuenta (navegar a un resultado), para no
  /// pedir dos veces lo mismo.
  void _endSearchUi() {
    if (!_searching) return;
    _debounce?.cancel();
    _search.clear();
    setState(() => _searching = false);
  }

  void _closeSearch() {
    _endSearchUi();
    unawaited(_model.search(''));
  }

  /// `onChanged` con debounce: se busca cuando el usuario deja de tipear, no en
  /// cada tecla.
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(FilesView.searchDebounce, () {
      if (mounted) unawaited(_model.search(value));
    });
  }

  void _submitSearch(String value) {
    _debounce?.cancel();
    unawaited(_model.search(value));
  }

  Future<void> _refresh() =>
      _model.query.isEmpty ? _model.refresh() : _model.search(_model.query);

  void _onRowTap(FileNode node) {
    if (!node.isDirectory) return unawaited(_openSheet(node));
    if (_model.query.isNotEmpty) {
      // En una búsqueda los paths son relativos a la raíz, no al directorio de
      // arriba: unir con `path` abriría `lib/ui/test` en vez de `test`.
      _endSearchUi();
      unawaited(_model.load(node.path));
    } else {
      unawaited(_model.navigateTo(node.name));
    }
  }

  /// Hoja de acciones (`surfaces.sheet.file`).
  ///
  /// El gate va como pregunta y no como [LayerGate]: una hoja modal vacía es un
  /// borde redondeado sin nada adentro, así que si la capa está apagada no se
  /// abre.
  Future<void> _openSheet(FileNode node) async {
    if (!LayerCatalog.instance.isOn(FilesView.layerSheet)) return;
    final action = await showModalBottomSheet<FileAction>(
      context: context,
      builder: (sheet) => _FileActionsSheet(title: _labelOf(node)),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case FileAction.addToChat:
        widget.onAddToChat(node.path);
        break;
      case FileAction.copyPath:
        await Clipboard.setData(ClipboardData(text: node.path));
        if (!mounted) return;
        _toast('Ruta copiada');
        break;
      case FileAction.open:
      case FileAction.diff:
        // Sin destino todavía: se muestran, pero no se pueden apretar.
        break;
    }
  }

  /// Overflow del app bar: `Actualizar` e `Ir a la raíz`. Simple a propósito —
  /// el `+` de sesión nueva es de la pantalla de sesiones, no de esta.
  Future<void> _openOverflow() async {
    final action = await showModalBottomSheet<_OverflowAction>(
      context: context,
      builder: (sheet) => _OverflowSheet(canGoToRoot: !_model.isRoot),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _OverflowAction.refresh:
        await _model.refresh();
        break;
      case _OverflowAction.root:
        await _model.load(FileRepository.rootPath);
        break;
    }
  }

  void _toast(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  // ───────────────────────────── build ───────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _model,
      builder: (context, _) => Scaffold(
        appBar: _appBar(),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (_searching) _searchBar() else _breadcrumbBar(),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  /// `PreferredSize` porque [Scaffold.appBar] lo exige, y con el alto del
  /// prototipo ([AppTheme.appBarHeight]): los 56px tienen que ser los de la
  /// fila, no los que imponga el tema que esté puesto.
  PreferredSizeWidget _appBar() {
    return PreferredSize(
      preferredSize: const Size.fromHeight(AppTheme.appBarHeight),
      child: LayerGate(
        FilesView.layerAppBar,
        child: AppBar(
          toolbarHeight: AppTheme.appBarHeight,
          title: const LayerGate(FilesView.layerTitle, child: Text('Archivos')),
          actions: <Widget>[
            if (_searching)
              AppIconButton(
                icon: 'x',
                tooltip: 'Cerrar búsqueda',
                onPressed: _closeSearch,
              )
            else
              LayerGate(
                FilesView.layerSearch,
                child: AppIconButton(
                  icon: 'search',
                  tooltip: 'Buscar archivos',
                  onPressed: _openSearch,
                ),
              ),
            LayerGate(
              FilesView.layerOverflow,
              child: AppIconButton(
                icon: 'more-horizontal',
                tooltip: 'Más acciones',
                onPressed: _openOverflow,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// La fila bajo el app bar: el buscador si se está buscando, el path si no.
  Widget _searchBar() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: TextField(
        key: FilesView.searchFieldKey,
        controller: _search,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Buscar archivos por nombre',
          prefixIcon: AppIcon(
            'search',
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        onChanged: _onSearchChanged,
        onSubmitted: _submitSearch,
      ),
    );
  }

  /// `files.breadcrumb`: el path actual, scrolleable, y cada trozo navega a su
  /// ancestro. El directorio donde se está va en `text`/w500 y los ancestros en
  /// `muted` (`.crumbs`, `prototype/mobile.html:379-380`).
  Widget _breadcrumbBar() {
    final theme = Theme.of(context);
    final crumbs = _model.crumbs;
    return LayerGate(
      FilesView.layerBreadcrumb,
      child: Container(
        key: FilesView.breadcrumbKey,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(bottom: BorderSide(color: theme.dividerColor)),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              for (var i = 0; i < crumbs.length; i++) ...<Widget>[
                // La raíz ya es una `/`: entre la raíz y el primer segmento no
                // va otra, y el path se lee `/lib/ui/core` y no `//lib/ui/core`.
                if (i > 1)
                  Text(
                    '/',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                InkWell(
                  onTap: i == crumbs.length - 1
                      ? null
                      : () => unawaited(_model.load(crumbs[i].path)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                    ),
                    child: Text(
                      crumbs[i].label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: crumbs[i].isTail
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                        fontWeight: crumbs[i].isTail ? FontWeight.w500 : null,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    final error = _model.error;
    if (error != null) return _errorState(error);
    if (_model.loading && _model.nodes.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_model.nodes.isEmpty) return _emptyState();
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        key: FilesView.listKey,
        // Con pocos elementos la lista no scrollea y no se podría tirar hacia
        // abajo; `AlwaysScrollableScrollPhysics` deja el gesto disponible.
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _model.nodes.length,
        separatorBuilder: (context, index) =>
            Divider(height: 1, color: Theme.of(context).dividerColor),
        itemBuilder: (context, index) => _row(_model.nodes[index]),
      ),
    );
  }

  Widget _row(FileNode node) {
    final theme = Theme.of(context);
    return LayerGate(
      FilesView.layerRowEntry,
      child: InkWell(
        key: FilesView.rowKey(node.path),
        onTap: () => _onRowTap(node),
        onLongPress: () => unawaited(_openSheet(node)),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Row(
            children: <Widget>[
              AppIcon(
                node.isDirectory ? 'folder' : 'file',
                size: 16,
                color: node.isDirectory
                    ? _mutedStrongOf(theme.brightness)
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: LayerGate(
                  FilesView.layerRowName,
                  child: Text(
                    _labelOf(node),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: node.isDirectory
                        ? theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: _mutedStrongOf(theme.brightness),
                          )
                        : theme.textTheme.bodyMedium,
                  ),
                ),
              ),
              if (node.gitMarked) ...<Widget>[
                LayerGate(FilesView.layerRowGit, child: _gitDot(theme)),
                const SizedBox(width: 2),
              ],
              if (node.hasDiffCount) ...<Widget>[
                LayerGate(
                  FilesView.layerRowDiff,
                  child: _diffChip(node, theme),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              _extensionLabel(node, theme),
            ],
          ),
        ),
      ),
    );
  }

  /// `files.row.ext`: 12px apagado, alineado a la derecha con ancho fijo para
  /// que los nombres no bailen entre filas con y sin extensión (`.frow .ext`,
  /// `min-width:34px` en el prototipo).
  Widget _extensionLabel(FileNode node, ThemeData theme) {
    return LayerGate(
      FilesView.layerRowExt,
      child: SizedBox(
        width: 40,
        child: Text(
          node.extension,
          textAlign: TextAlign.right,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// Punto de 6px de "esto tiene cambios" (`files.row.git`).
  Widget _gitDot(ThemeData theme) => Container(
    width: 6,
    height: 6,
    decoration: BoxDecoration(
      // Ámbar del scope semántico, no el gris del chrome: es un dato.
      color: AppColors.warnOf(theme.brightness),
      shape: BoxShape.circle,
    ),
  );

  /// Chip `+12 -4` (`files.row.diff`).
  Widget _diffChip(FileNode node, ThemeData theme) {
    final style = theme.textTheme.labelSmall?.copyWith(
      height: 1,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    return Container(
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border.all(color: theme.colorScheme.outline, width: 1),
        borderRadius: AppRadius.smAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '+${node.additions}',
            style: style?.copyWith(
              color: AppColors.diffAddOf(theme.brightness),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '-${node.deletions}',
            style: style?.copyWith(
              color: AppColors.diffDelOf(theme.brightness),
            ),
          ),
        ],
      ),
    );
  }

  /// Lo que se ve de una fila. En un listado es el nombre (con la `/` de las
  /// carpetas del prototipo); en una búsqueda es el path completo, que es lo
  /// único que distingue dos resultados con el mismo nombre.
  String _labelOf(FileNode node) {
    if (_model.query.isNotEmpty) return node.path;
    return node.isDirectory ? '${node.name}/' : node.name;
  }

  /// Carpeta vacía: `.empty` del prototipo (icono grande apagado + texto).
  Widget _emptyState() {
    final theme = Theme.of(context);
    return Center(
      key: FilesView.emptyKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Opacity(
            opacity: 0.7,
            child: AppIcon(
              'folder',
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            _model.query.isEmpty
                ? 'Esta carpeta está vacía.'
                : 'Sin resultados para la búsqueda.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorState(String message) {
    final theme = Theme.of(context);
    return Center(
      key: FilesView.errorKey,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton(onPressed: _refresh, child: const Text('Reintentar')),
          ],
        ),
      ),
    );
  }

  /// `--muted-strong` según el brillo. `tokens.dart` no trae el helper (el
  /// chrome usa `onSurfaceVariant`, que es `muted` a secas) y el prototipo sí
  /// distingue los dos: la carpeta tiene que verse más fuerte que el archivo.
  static Color _mutedStrongOf(Brightness brightness) =>
      brightness == Brightness.dark
      ? AppColors.darkMutedStrong
      : AppColors.lightMutedStrong;
}

/// Hoja de acciones de una fila. Sólo sabe mostrar y devolver: resolver las
/// acciones es de la vista, que tiene el `context` y el callback del chat.
class _FileActionsSheet extends StatelessWidget {
  const _FileActionsSheet({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.xs,
              AppSpacing.sm,
              AppSpacing.xs,
            ),
            child: Row(
              children: <Widget>[
                Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
                AppIconButton(
                  icon: 'x',
                  tooltip: 'Cerrar',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          _SheetAction(
            name: FileAction.open.name,
            icon: 'external-link',
            label: 'Abrir',
            // Todavía no hay visor de archivos: se muestra, no se puede apretar.
            onPressed: null,
          ),
          _SheetAction(
            name: FileAction.copyPath.name,
            icon: 'copy',
            label: 'Copiar ruta',
            onPressed: () => Navigator.of(context).pop(FileAction.copyPath),
          ),
          _SheetAction(
            name: FileAction.diff.name,
            icon: 'git-branch',
            label: 'Ver diff',
            onPressed: null,
          ),
          _SheetAction(
            name: FileAction.addToChat.name,
            icon: 'plus',
            label: 'Añadir al chat',
            onPressed: () => Navigator.of(context).pop(FileAction.addToChat),
          ),
        ],
      ),
    );
  }
}

/// Las dos acciones del overflow. No usan [FileAction] porque el resultado no es
/// una acción de archivo sino un destino de navegación.
enum _OverflowAction { refresh, root }

class _OverflowSheet extends StatelessWidget {
  const _OverflowSheet({required this.canGoToRoot});

  final bool canGoToRoot;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SheetAction(
          name: _OverflowAction.refresh.name,
          icon: 'refresh',
          label: 'Actualizar',
          onPressed: () => Navigator.of(context).pop(_OverflowAction.refresh),
        ),
        _SheetAction(
          name: _OverflowAction.root.name,
          icon: 'folder',
          label: 'Ir a la raíz',
          onPressed: canGoToRoot
              ? () => Navigator.of(context).pop(_OverflowAction.root)
              : null,
        ),
      ],
    ),
  );
}

/// Fila de 48px de una hoja (`.arow`, `prototype/mobile.html:427`).
class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.name,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  /// [FileAction] o [_OverflowAction]. Va por nombre porque el enum del
  /// overflow es privado.
  final String name;

  final String icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onPressed != null;
    return InkWell(
      key: FilesView.sheetActionKey(name),
      onTap: onPressed,
      child: SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Row(
            children: <Widget>[
              AppIcon(
                icon,
                size: 20,
                color: enabled
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.md),
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: enabled
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
