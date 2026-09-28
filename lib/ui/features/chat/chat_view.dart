/// La pantalla de chat: app bar, lista de mensajes, botón de salto al final y
/// composer. Es el corazón de la app y el port exacto del prototipo
/// (`prototype/mobile.html:751-1037`).
///
/// Tres decisiones que no se ven y importan:
///
/// 1. **El salto al final sigue la cola, no el rebuild.** Si el usuario scrolleó
///    para arriba a leer algo, un delta no le mueve la pantalla; cuando vuelve
///    al final, el seguimiento se reanuda solo.
/// 2. **El botón Detener vive en el composer**, no en el app bar, y desaparece
///    con la evidencia real de fin de turno (`API_CONTRACT.md` §7.4), no por
///    reloj.
/// 3. **Lo que la spec tiene apagado no se construye**: el subtítulo modelo ·
///    agente del app bar (`chat.appbar.subtitle`) y la barra de progreso
///    (`chat.header.progress`) existen como `LayerGate` para que el toggle de
///    Ajustes los pueda prender, pero apagados no pintan nada.
library;

import 'package:flutter/material.dart';

import '../../../domain/models/message.dart';
import '../../../domain/models/session.dart';
import '../../core/app_icon.dart';
import '../../core/layer_gate.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import 'chat_viewmodel.dart';
import 'composer.dart';
import 'message_bubble.dart';

/// Las 12 acciones de la hoja `surfaces.sheet.actions`, **en el orden del
/// prototipo** (`prototype/mobile.html:1204-1215`).
///
/// El glifo de cada una es el SVG que usa el prototipo; los nombres del diseño
/// en Material (`hub`, `undo`, `redo`, `compress`, `call_split`, `eye`, `tune`,
/// `query_stats`, `bolt_outlined`) no existen en `assets/icons/`, y la regla del
/// repo es no agregar assets: se usa el equivalente real de la lista.
enum ChatSessionAction {
  rename('edit', 'Renombrar'),
  hub('layers', 'OpenCode Hub'),
  undo('arrow-upward', 'Deshacer'),
  redo('arrow-downward', 'Rehacer'),
  compact('scale', 'Compactar'),
  exportMarkdown('download', 'Exportar markdown'),
  prompts('sparkles', 'Prompts'),
  fork('git-branch', 'Fork de la sesión'),
  readMode('book', 'Modo lectura'),
  promptHistory('history', 'Historial de prompts'),
  chatSettings('settings', 'Ajustes del chat'),
  stats('coins', 'Estadísticas de la sesión');

  const ChatSessionAction(this.icon, this.label);

  final String icon;
  final String label;

  /// `Deshacer`/`Rehacer` no tienen historia de undo en el chat móvil: se
  /// muestran apagados, igual que en el prototipo.
  bool get enabled => this != undo && this != redo;
}

class ChatView extends StatefulWidget {
  const ChatView({
    super.key,
    required this.viewModel,
    this.onBack,
    this.onAction,
    this.onPickModel,
    this.thinkingDefault = true,
  });

  final ChatViewModel viewModel;

  /// Vuelve a la lista de sesiones (`chat.appbar.back`).
  final VoidCallback? onBack;

  /// Una de las 12 filas de la hoja de acciones. La ejecuta el shell: el chat
  /// no decide ni renombra ni exporta.
  final ValueChanged<ChatSessionAction>? onAction;

  /// Se pide modelo/agente distinto (la hoja `surfaces.sheet.model`).
  final ValueChanged<SessionInfo?>? onPickModel;

  /// Preferencia de Ajustes: el razonamiento arranca abierto.
  final bool thinkingDefault;

  /// La lista scrolleada (los tests).
  static const Key listKey = Key('chat-list');

  /// Botón "ir al último mensaje" (`chat.fab.jump`).
  static const Key jumpKey = Key('chat-jump-fab');

  /// Botón "más acciones" del app bar (`chat.appbar.overflow`).
  static const Key overflowKey = Key('chat-overflow');

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final ScrollController _scroll = ScrollController();
  bool _atBottom = true;
  bool _firstBuildDone = false;

  ChatViewModel get _vm => widget.viewModel;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _vm.addListener(_onVm);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _vm.setVisible(true);
    });
  }

  @override
  void dispose() {
    // El socket se pausa antes de que el widget muera: fuera de pantalla no
    // hay stream ni timers (batería).
    _vm.setVisible(false);
    _vm.removeListener(_onVm);
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onVm() {
    if (!mounted) return;
    setState(() {});
    // Antes del primer frame siempre se ancla al final (una lista que abre a la
    // mitad se siente rota); después, sólo si el usuario ya estaba abajo.
    final follow = _atBottom || !_firstBuildDone;
    _firstBuildDone = true;
    if (follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // 24 px de tolerancia: es el alto del propio FAB, no un Magic Number
    // para que el borde "pique" un frame antes.
    const tolerance = 24.0;
    final atBottom =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - tolerance;
    if (atBottom == _atBottom) return;
    setState(() => _atBottom = atBottom);
  }

  void _jumpToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
    setState(() => _atBottom = true);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _appBar(),
        if (_vm.error case final String message) _errorBanner(message),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: _messages()),
              // `.fabdock`: el FAB flota sobre el borde inferior del scroll,
              // 10 px por encima de la línea del composer.
              if (!_atBottom)
                Positioned(
                  right: AppSpacing.md,
                  bottom: 10,
                  child: LayerGate(
                    'chat.fab.jump',
                    child: AppIconButton(
                      key: ChatView.jumpKey,
                      icon: 'arrow-downward',
                      tooltip: 'Ir al último mensaje',
                      onPressed: _jumpToBottom,
                      size: 16,
                      tapSize: 28,
                    ),
                  ),
                ),
            ],
          ),
        ),
        _composer(),
      ],
    );
  }

  // ───────────────────────────── app bar ─────────────────────────────

  Widget _appBar() {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(bottom: BorderSide(color: scheme.outline)),
      ),
      // 56 px: `AppTheme.appBarHeight` y `min-height:56px` del CSS.
      child: SizedBox(
        height: AppTheme.appBarHeight,
        child: Row(
          children: [
            LayerGate(
              'chat.appbar.back',
              child: AppIconButton(
                icon: 'arrow-left',
                tooltip: 'Volver a sesiones',
                onPressed: widget.onBack,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ),
            Expanded(
              child: LayerGate(
                'chat.appbar.title',
                child: Text(
                  _title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleLarge,
                ),
              ),
            ),
            // Apagado en la spec: el subtítulo modelo · agente. El widget está
            // para que el toggle de Ajustes lo pueda prender sin tocar el
            // app bar.
            LayerGate(
              'chat.appbar.subtitle',
              child: TextButton(
                onPressed: _openModelSheet,
                child: Text(
                  _subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelSmall,
                ),
              ),
            ),
            LayerGate(
              'chat.appbar.overflow',
              child: AppIconButton(
                key: ChatView.overflowKey,
                icon: 'more-horizontal',
                tooltip: 'Más acciones',
                onPressed: _openActions,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _title {
    final info = _vm.sessionInfo;
    final title = info?.title.trim() ?? '';
    if (title.isNotEmpty) return title;
    // Sin título el server manda el id: `ses_0acd172…` no dice nada, así que
    // se recorta al prefijo.
    final id = _vm.sessionId;
    return id.length > 12 ? '${id.substring(0, 12)}…' : id;
  }

  String get _subtitle {
    final model = _vm.sessionInfo?.model;
    final agent = _vm.sessionInfo?.agent;
    final left = model == null ? 'Elegir modelo' : model.id;
    return agent == null || agent.isEmpty ? left : '$left · $agent';
  }

  // ──────────────────────────── banner ────────────────────────────

  /// Canal C (`OchError`): no bloquea, no tira, y se va solo en el próximo
  /// re-fetch exitoso.
  Widget _errorBanner(String message) {
    final scheme = Theme.of(context).colorScheme;
    final danger = AppColors.diffDelOf(Theme.of(context).brightness);
    return Material(
      color: scheme.surfaceContainer,
      child: InkWell(
        onTap: _vm.clearError,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.sm,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              AppIcon('alert-triangle', size: 16, color: danger),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: scheme.onSurface),
                ),
              ),
              AppIconButton(
                icon: 'x',
                tooltip: 'Cerrar aviso',
                onPressed: _vm.clearError,
                size: 14,
                tapSize: 32,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ──────────────────────────── mensajes ────────────────────────────

  Widget _messages() {
    final messages = _vm.messages;
    // El botón de "anteriores" es el ítem 0, no un `header`: la lista es un
    // `ListView.builder` y no se puede meter un hijo más sin romper el índice.
    final withLoadMore = _vm.hasEarlier ? 1 : 0;
    final count = withLoadMore + messages.length;

    return LayerGate(
      'chat.scroll',
      child: ListView.builder(
        key: ChatView.listKey,
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.xl,
        ),
        itemCount: count == 0 ? 1 : count,
        itemBuilder: (context, index) {
          if (count == 0) return _emptyState();
          if (withLoadMore == 1 && index == 0) return _loadMore();
          final message = messages[index - withLoadMore];
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: MessageBubble(
              key: ValueKey(message.id),
              message: message,
              working: _vm.working,
              thinkingDefault: widget.thinkingDefault,
              onOpenDiff: _onOpenDiff,
              onQuestionAnswer: _onQuestion,
            ),
          );
        },
      ),
    );
  }

  Widget _emptyState() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xxxl),
      child: Column(
        children: [
          AppIcon('message-square', size: 48, color: scheme.onSurfaceVariant),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Sin mensajes todavía',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            _vm.loading
                ? 'Cargando la sesión...'
                : 'Mandá el primer mensaje para empezar el turno.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _loadMore() {
    final scheme = Theme.of(context).colorScheme;
    return LayerGate(
      'chat.msg.loadmore',
      child: Center(
        child: TextButton.icon(
          onPressed: _vm.loadingEarlier ? null : _vm.loadEarlier,
          icon: AppIcon('history', size: 16, color: scheme.onSurfaceVariant),
          label: Text(
            _vm.loadingEarlier ? 'Cargando...' : 'Cargar 30 anteriores',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  void _onOpenDiff(AssistantTool tool) {
    // El diff lo abre el `files`/shell: el chat sólo pasa el tool.
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('Diff de ${tool.name}: lo abre la vista de archivos'),
      ),
    );
  }

  void _onQuestion(List<String> answers) {
    if (answers.isEmpty) {
      _vm.send('Ahora no.');
      return;
    }
    _vm.send(answers.join('\n'));
  }

  // ──────────────────────────── composer ────────────────────────────

  Widget _composer() {
    final info = _vm.sessionInfo;
    return ChatComposer(
      working: _vm.working,
      canSend: true,
      modelLabel: info?.model?.id,
      agentLabel: info?.agent,
      contextLabel: contextLabel(_vm.serverTokens, _vm.serverCost),
      onSend: (text, files) =>
          _vm.send(text, files: [for (final f in files) f.toPromptFile()]),
      onStop: _vm.abort,
      onPickModel: _openModelSheet,
    );
  }

  // ──────────────────────────── hojas ────────────────────────────

  Future<void> _openActions() async {
    final action = await showModalBottomSheet<ChatSessionAction>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => LayerGate(
        'surfaces.sheet.actions',
        child: _ActionSheet(
          title: _title,
          onClose: () => Navigator.of(sheetContext).pop(),
          onPick: (a) => Navigator.of(sheetContext).pop(a),
        ),
      ),
    );
    if (action == null) return;
    final handler = widget.onAction;
    if (handler != null) handler(action);
  }

  Future<void> _openModelSheet() async {
    final info = _vm.sessionInfo;
    final picked = await showModalBottomSheet<SessionInfo?>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => LayerGate(
        'surfaces.sheet.model',
        child: _ModelSheet(
          info: info,
          onClose: () => Navigator.of(sheetContext).pop(),
        ),
      ),
    );
    if (picked != null) widget.onPickModel?.call(picked);
  }
}

/// `14.2k contexto · $0.38`, el formato del prototipo. Una decimal hasta las
/// 100k: `14.2k` informa, `14k` esconde el margen; de 100k en adelante el
/// decimal ya es ruido.
String contextLabel(int tokens, double cost) {
  final String count;
  if (tokens >= 1000) {
    final k = tokens / 1000;
    count = '${k.toStringAsFixed(k >= 100 ? 0 : 1)}k';
  } else {
    count = '$tokens';
  }
  return '$count contexto · \$${cost.toStringAsFixed(2)}';
}

/// La hoja de las 12 acciones (`surfaces.sheet.actions`). `.arow`: 48 px, glifo
/// 20, 13 px, apagada si no hay nada que deshacer/rehacer.
class _ActionSheet extends StatelessWidget {
  const _ActionSheet({
    required this.title,
    required this.onClose,
    required this.onPick,
  });

  final String title;
  final VoidCallback onClose;
  final ValueChanged<ChatSessionAction> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.sm,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                AppIconButton(
                  icon: 'x',
                  tooltip: 'Cerrar',
                  onPressed: onClose,
                  size: 20,
                ),
              ],
            ),
          ),
          // 12 filas de 48 px no entran en una hoja de 9/16 de la pantalla en
          // un teléfono chico: la cabeza queda fija y las filas scrollean, como
          // el `.sheet-body` del prototipo.
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final action in ChatSessionAction.values)
                    _ActionRow(
                      action: action,
                      onTap: action.enabled ? () => onPick(action) : null,
                      scheme: scheme,
                    ),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.action,
    required this.onTap,
    required this.scheme,
  });

  final ChatSessionAction action;
  final VoidCallback? onTap;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = enabled ? scheme.onSurface : scheme.onSurfaceVariant;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              children: [
                AppIcon(action.icon, size: 20, color: color),
                const SizedBox(width: AppSpacing.md),
                Text(
                  action.label,
                  style: TextStyle(fontSize: 13, color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// La hoja de modelo y agente (`surfaces.sheet.model`).
///
/// **Es un andamiaje**: la app todavía no tiene catálogo de modelos ni de
/// agentes (no hay endpoint en el contrato medido), así que muestra lo que la
/// sesión ya usa y delega el cambio al shell con [ChatView.onPickModel]. Cuando
/// exista el catálogo, esta hoja pasa a listarlo; el andamiaje (buscador,
/// secciones `surfaces.model.agent` / `surfaces.model.item`, check) ya está.
class _ModelSheet extends StatefulWidget {
  const _ModelSheet({required this.info, required this.onClose});

  final SessionInfo? info;
  final VoidCallback onClose;

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  final TextEditingController _query = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final model = widget.info?.model;
    final agent = widget.info?.agent;
    final modelMatches =
        model == null || _filter.isEmpty || model.id.contains(_filter);
    final agentMatches =
        agent == null || _filter.isEmpty || agent.contains(_filter);
    // Con filtro y sin resultados, o sin modelo/agente que listar: se avisa.
    final filtered = _filter.isNotEmpty;
    final nothingToShow =
        (agent == null || !agentMatches) && (model == null || !modelMatches);
    final emptySession = agent == null && model == null;

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.sm,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Modelo y agente',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                AppIconButton(
                  icon: 'x',
                  tooltip: 'Cerrar',
                  onPressed: widget.onClose,
                  size: 20,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: TextField(
              controller: _query,
              onChanged: (v) => setState(() => _filter = v.trim()),
              decoration: InputDecoration(
                hintText: 'Buscar modelo o agente…',
                prefixIcon: AppIcon(
                  'search',
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          // Cuando el catálogo crezca, la lista scrollea; la cabeza y el
          // buscador quedan fijos.
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (agentMatches && agent != null) ...[
                    const _SectionHead('AGENTE'),
                    LayerGate(
                      'surfaces.model.agent',
                      child: _ModelRow(
                        name: agent,
                        detail: _agentDetail(agent),
                        selected: true,
                        onTap: widget.onClose,
                      ),
                    ),
                  ],
                  if (modelMatches && model != null) ...[
                    const _SectionHead('MODELO'),
                    LayerGate(
                      'surfaces.model.item',
                      child: _ModelRow(
                        name: model.id,
                        detail: model.providerID,
                        selected: true,
                        onTap: widget.onClose,
                      ),
                    ),
                  ],
                  if (filtered && nothingToShow)
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Text(
                        'Sin resultados para "$_filter".',
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (emptySession)
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Text(
                        'Esta sesión todavía no tiene modelo ni agente.',
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Los tres agentes que el prototipo documenta. Es texto de ayuda, no lógica:
  /// la lista real de agentes la trae el shell cuando exista el endpoint.
  static String _agentDetail(String agent) => switch (agent) {
    'plan' => 'solo lectura, propone un plan',
    'explore' => 'búsqueda amplia en el repo',
    _ => 'escribe código, ejecuta comandos',
  };
}

class _SectionHead extends StatelessWidget {
  const _SectionHead(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.md,
      AppSpacing.md,
      AppSpacing.md,
      AppSpacing.xs,
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.name,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurface,
                        ),
                      ),
                      Text(
                        detail,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected) AppIcon('check', size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
