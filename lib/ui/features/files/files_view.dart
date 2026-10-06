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
import 'package:url_launcher/url_launcher.dart';

import '../../../core/network/server_config.dart';
import '../../../data/repositories/file_repository.dart';
import '../../../domain/models/file_type.dart';
import '../../core/app_icon.dart';
import '../../core/layer_gate.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import 'file_preview.dart';
import 'files_viewmodel.dart';

/// Qué se pidió desde la hoja de acciones de una fila.
enum FileAction { open, openInBrowser, copyPath, diff, addToChat }

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
  /// El botón de cambiar de disco. Solo se ve **fuera** de la raíz.
  static const String layerDrives = 'files.appbar.drives';
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
  static const Key drivesKey = Key('files-drives');
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
  /// Abre una URL en la app que el sistema elija para ese esquema.
  ///
  /// `LaunchMode.externalApplication` es lo que manda la URL **afuera** de la
  /// app: sin eso el launcher puede resolverla adentro y el usuario no ve que
  /// salio. Devuelve `false` en vez de tirar: el toast tiene que poder decir
  /// "no se pudo" sin que la app se caiga.
  static Future<bool> _openExternally(Uri url) async {
    try {
      return await launchUrl(url, mode: LaunchMode.externalApplication);
    } on Object {
      return false;
    }
  }

  Future<void> _openSheet(FileNode node) async {
    if (!LayerCatalog.instance.isOn(FilesView.layerSheet)) return;
    final action = await showModalBottomSheet<FileAction>(
      context: context,
      builder: (sheet) => _FileActionsSheet(
        title: _labelOf(node),
        type: FileType.of(node.name),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case FileAction.addToChat:
        widget.onAddToChat(node.path);
        break;
      case FileAction.openInBrowser:
        // Se abre en el navegador del sistema, no en un WebView embebido: asi
        // el CSS y el JS son de verdad y el usuario ve la URL de la que viene.
        // La password viaja en el query porque el server no emite cookie, asi
        // que la app no la copia a ningun lado (ver `browserFileUrl`).
        final url = widget.config.browserFileUrl(node.path);
        final opened = await _openExternally(url);
        if (!mounted) return;
        _toast(
          opened ? 'Abierto en el navegador' : 'No se pudo abrir el navegador',
        );
        break;
      case FileAction.copyPath:
        await Clipboard.setData(ClipboardData(text: node.path));
        if (!mounted) return;
        _toast('Ruta copiada');
        break;
      case FileAction.open:
        // El boton existia desde el primer dia y no hacia nada: mismo patron
        // que el pill de agente y el microfono, un control dibujado sin
        // destino. Ahora abre el visor, que decide por el tipo de archivo.
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => FilePreview(
              config: widget.config,
              path: node.path,
              name: node.name,
            ),
          ),
        );
        break;
      case FileAction.diff:
        // El diff necesita un repo git en el directorio. Sin destino todavia,
        // y se dice en vez de fingir que funciona.
        _toast('Diff: todavia no disponible');
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
            // **Cambiar de disco.** Es lo que faltaba para que el navegador se
            // parezca a Explorer: sin esto la raíz era la carpeta del `location`
            // del server y no había forma de nombrar otro disco.
            //
            // Solo se ve **fuera** de la raíz: dentro de un disco el botón de
            // arriba ya cumple ese papel, y dos caminos para lo mismo es ruido.
            if (!_model.isRoot)
              LayerGate(
                FilesView.layerDrives,
                child: AppIconButton(
                  icon: 'hard-drive',
                  tooltip: 'Cambiar de disco',
                  onPressed: _goToDrives,
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
    // La raíz **no es una carpeta**: es "Este equipo", con los discos de la PC.
    // Ahí no hay nada que listar hasta que se pregunte, y pedir los 26 discos al
    // abrir la pantalla era lo que la dejaba congelada un timeout entero.
    if (_model.isRoot) return _drivesBody();
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

  /// "Este equipo": los discos de la PC.
  ///
  /// Se pide **recién cuando se muestra**, no al construir la pantalla: probar 26
  /// letras al abrir Archivos era un timeout de 3 s con la pantalla en blanco.
  /// Y se pide **una sola vez** por sesión de pantalla — el usuario no cambia de
  /// disco en caliente, y si lo hace, el botón de discos lo vuelve a pedir.
  Widget _drivesBody() {
    if (_model.roots == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_model.loadRoots());
      });
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    final roots = _model.roots!;
    if (roots.isEmpty) {
      return _emptyState(
        // Decirlo: "no hay discos" sin haber preguntado sería mentir, y "no se
        // pudo" sin saber por qué tampoco ayuda.
        message: 'No se encontraron discos. Si la PC tiene alguno, revisá que el '
            'server lo vea desde su ubicación.',
      );
    }
    return RefreshIndicator(
      onRefresh: () => _model.loadRoots(),
      child: ListView.separated(
        key: FilesView.drivesKey,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: roots.length,
        separatorBuilder: (context, index) =>
            Divider(height: 1, color: Theme.of(context).dividerColor),
        itemBuilder: (context, index) {
          final drive = roots[index];
          return ListTile(
            key: Key('files-drive-$drive'),
            leading: AppIcon('hard-drive', size: 20),
            title: Text(drive, style: Theme.of(context).textTheme.bodyMedium),
            subtitle: Text(
              'Disco local',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            onTap: () => unawaited(_model.openDrive(drive)),
          );
        },
      ),
    );
  }

  /// Abre la hoja de discos.
  ///
  /// Es el otro camino a "Este equipo", además del botón del app bar: desde la
  /// raíz de un disco, "subir" ya vuelve acá, pero el botón es el que se ve.
  /// Vuelve a "Este equipo" (la lista de discos).
  ///
  /// Antes abría una hoja con los discos: redundante, porque la vista de
  /// discos **es** "Este equipo". Y con la hoja encima, el usuario cree que
  /// está cambiando de disco cuando en realidad sigue viendo la carpeta de
  /// antes, que es justo la confusión que se quiso evitar.
  Future<void> _goToDrives() async {
    await _model.loadRoots();
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
  /// [message] cuando el vacío **no** es "no hay nada": no hay discos,
  /// o una carpeta que no se pudo leer. Decirlo distinto es lo que
  /// separa un estado vacío de un error disfrazado.
  Widget _emptyState({String? message}) {
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
          if (message != null)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: 0,
              ),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ),
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
  const _FileActionsSheet({required this.title, required this.type});

  final String title;

  /// El tipo del archivo: decide si aparece la accion de navegador.
  final FileType type;

  /// Un navegador puede mostrar esto con su propio motor: HTML, SVG, imagen,
  /// PDF y texto. Video y audio tambien se abririan, pero el reproductor de la
  /// app es mejor que el del navegador, asi que no se ofrecen: no es que no se
  /// pueda, es que no es lo mejor.
  bool get _browserCanShow => switch (type.kind) {
    FileKind.html ||
    FileKind.svg ||
    FileKind.image ||
    FileKind.pdf ||
    FileKind.markdown ||
    FileKind.text ||
    FileKind.code => true,
    FileKind.video || FileKind.audio || FileKind.binary => false,
  };

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
            onPressed: () => Navigator.of(context).pop(FileAction.open),
          ),
          if (_browserCanShow)
            _SheetAction(
              name: FileAction.openInBrowser.name,
              icon: 'external-link',
              label: 'Abrir en el navegador',
              onPressed: () =>
                  Navigator.of(context).pop(FileAction.openInBrowser),
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

            // "Ver diff" todavia no hace nada, pero **si** devuelve la accion:
            // el `switch` de arriba muestra el aviso. Con `onPressed: null` la
            // fila ni siquiera era clickable y el aviso no existia (medido en
            // el handset: `clickable="false"` en el arbol de accesibilidad, con
            // la accion ya implementada en el `switch`).
            onPressed: () => Navigator.of(context).pop(FileAction.diff),
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
