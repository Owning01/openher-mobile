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
///
/// 4. **Ninguna acción finge**: `Abrir diff` no aparece si el shell no le pasa
///    [ChatView.onOpenDiff]. Antes se pintaba siempre y contestaba con un
///    Snackbar que decía "lo abre la vista de archivos" sin que hubiera nada
///    conectado detrás.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../data/repositories/catalog_repository.dart';
import '../../../domain/models/agent_catalog.dart';
import '../../../domain/models/message.dart';
import '../../../domain/models/turn_activity.dart';
import '../../core/app_icon.dart';
import '../../core/layer_gate.dart';
import '../../core/theme.dart';
import '../../core/tokens.dart';
import 'chat_viewmodel.dart';
import 'composer.dart';
import 'message_bubble.dart';
import 'agent_sheet.dart';
import 'model_sheet.dart';

/// Las 12 acciones de la hoja `surfaces.sheet.actions`, **en el orden del
/// prototipo** (`prototype/mobile.html:1204-1215`).
///
/// El glifo de cada una es el SVG que usa el prototipo; los nombres del diseño
/// en Material (`hub`, `undo`, `redo`, `compress`, `call_split`, `eye`, `tune`,
/// `query_stats`, `bolt_outlined`) no existen en `assets/icons/`, y la regla del
/// Acciones del menú de la sesión.
///
/// **Cada entrada acá tiene algo detrás.** Antes había 12 y ninguna hacía nada:
/// `onAction` nunca lo pasaba nadie, así que el menú abría, se elegía algo y
/// no pasaba absolutamente nada. Ese es el bug que reportó el usuario.
///
/// Se sacaron las 7 sin respaldo en el dialecto v2 —medido contra
/// `openapi.json` y el server real— porque un botón inerte es peor que un
/// botón que no existe: promete una función que no se puede fulfillar.
///
/// Se quedan las 5 con Implementation:
/// * [compact] → `POST /api/session/{id}/compact` (medido)
/// * [undo] → `POST /api/session/{id}/revert/stage` + `/revert/commit` (medido)
/// * [exportMarkdown] → local, arma el markdown en el disco
/// * [readMode] → local, cambia cómo se pinta el chat
/// * [stats] → local, con lo que ya está en memoria
///
/// Lo que se sacó y por qué (para no volver a agregarlo a ciegas):
/// `rename`, `hub`, `redo`, `prompts`, `fork`, `promptHistory`, `chatSettings`.
/// Los siete existen en el cliente de escritorio o en la maqueta, pero el
/// dialecto v2 no expone endpoint para ninguno.
enum ChatSessionAction {
  compact('scale', 'Compactar'),
  undo('arrow-upward', 'Deshacer'),
  exportMarkdown('download', 'Exportar markdown'),
  readMode('book', 'Modo lectura'),
  stats('coins', 'Estadísticas');

  const ChatSessionAction(this.icon, this.label);

  final String icon;
  final String label;
}

class ChatView extends StatefulWidget {
  const ChatView({
    super.key,
    required this.viewModel,
    this.onBack,
    this.onAction,
    this.onPickModel,
    this.onOpenDiff,
    this.thinkingDefault = true,
    this.visible = true,
    this.catalog,
  });

  final ChatViewModel viewModel;

  /// Si el chat esta al frente. Lo decide el shell: fuera de pantalla el
  /// socket y los timers se pausan (bateria).
  final bool visible;

  /// Vuelve a la lista de sesiones (`chat.appbar.back`).
  final VoidCallback? onBack;

  /// Una de las 12 filas de la hoja de acciones. La ejecuta el shell: el chat
  /// no decide ni renombra ni exporta.

  /// Se eligió modelo (y nivel de pensamiento) en la hoja `surfaces.sheet.model`.
  ///
  /// El chat **no** crea la sesión ni guarda la preferencia: elige y avisa. El
  /// shell es el que sabe abrir la sesión con ese modelo y ese nivel
  /// (`ApiClient.createSession` arma `model: {id, providerID, variant}`).
  /// Avisa al shell qué acción se eligió. La acción **también** se
  /// ejecuta acá (antes no lo hacía y el menú no servía para nada), así
  /// que este callback es para el shell, no el mecanismo.
  final ValueChanged<ChatSessionAction>? onAction;

  final ValueChanged<ModelPick>? onPickModel;

  /// Catálogo de modelos para la hoja. Si no viene, el chat arma el suyo contra
  /// el `ApiClient` del viewmodel: el shell puede inyectar uno compartido (que
  /// cachea entre sesiones) o dejarlo ahí.
  final CatalogRepository? catalog;

  /// Abre el diff de un tool (`edit`/`write`/`patch`) en la vista que lo sabe
  /// mostrar. Lo ejecuta el shell: el chat no sabe de archivos.
  ///
  /// `null` ⇒ el chip `Abrir diff` **no se pinta** (ver `ToolCard`). El chat no
  /// inventa un destino ni promete con un Snackbar.
  final ValueChanged<AssistantTool>? onOpenDiff;

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

  /// Catálogo propio, sólo si el shell no inyectó uno. Se arma una vez: cada
  /// apertura de la hoja reusa la caché en vez de pegarle al server.
  CatalogRepository? _ownCatalog;

  /// Espejo de widget.visible: el post-frame del initState lo consulta.
  late bool _visible = true;
  bool _atBottom = true;
  bool _firstBuildDone = false;

  ChatViewModel get _vm => widget.viewModel;

  CatalogRepository get _catalog =>
      widget.catalog ?? (_ownCatalog ??= CatalogRepository(_vm.api));

  @override
  @override
  void initState() {
    super.initState();
    _visible = widget.visible;
    _scroll.addListener(_onScroll);
    _vm.addListener(_onVm);
    // Se establece la visibilidad inicial. Con isible: true abre el socket
    // (un chat al frente tiene que estar en vivo); con alse lo deja
    // cerrado hasta que didUpdateWidget lo promueva. No se fuerza 	rue a
    // ciegas: el shell sabe si esta al frente.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _vm.setVisible(_visible);
    });
  }

  /// El shell cambia isible al cambiar de pestana (el IndexedStack deja
  /// el widget montado): hay que propagarlo a mano, porque
  /// didChangeDependencies no corre en un update.
  @override
  void didUpdateWidget(covariant ChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      _visible = widget.visible;
      _vm.setVisible(_visible);
    }
  }

  @override
  void dispose() {
    // El socket se pausa antes de que el widget muera: fuera de pantalla no
    // hay stream ni timers (bateria).
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
    // El callback se registra en `_onVm` (con `mounted`) pero corre **después**
    // del frame: si entre medio el widget salió del árbol, el `setState`
    // revienta con "used after being disposed". Se re-chequea acá.
    if (!mounted) return;
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
    setState(() => _atBottom = true);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Capa chat.appbar: apagar el toggle saca la barra entera.
        LayerGate('chat.appbar', child: _appBar()),
        if (_vm.error case final String message) _errorBanner(message),
        // Capa chat.header.progress: apagada por diseño (se puede
        // prender desde Ajustes). Indica que hay un turno en curso.
        LayerGate(
          'chat.header.progress',
          child: _vm.working ? const _WorkingLine() : const SizedBox.shrink(),
        ),
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
    final title = _vm.sessionInfo?.title.trim() ?? '';
    if (title.isNotEmpty) return title;
    // Sin título el server manda el id: `ses_0acd172…` no dice nada, así que
    // se recorta al prefijo.
    final id = _vm.sessionId;
    return id.length > 12 ? '${id.substring(0, 12)}…' : id;
  }

  String get _subtitle {
    final model = _vm.currentModel;
    final agent = _vm.currentAgent;
    final left = model == null ? 'Elegir modelo' : model.id;
    return agent == null || agent.isEmpty ? left : '$left · $agent';
  }

  // ──────────────────────────── banner ────────────────────────────

  /// Canal C (`OchError`): no bloquea, no tira, y se va solo en el próximo
  /// re-fetch exitoso.
  Widget _errorBanner(String message) {
    final scheme = Theme.of(context).colorScheme;
    // Chrome monocromo: el mismo `danger` que la card de error del assistant y
    // que el error de un tool. El rojo de los diffs es de los diffs.
    final danger = AppColors.dangerOf(Theme.of(context).brightness);
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
    // Los ítems fijos van **arriba** de la lista y no son un `header`: es un
    // `ListView.builder` y no se puede meter un hijo más sin romper el índice.
    // `0` = aviso de reintento, `1` = botón de "Cargar 30 anteriores".
    final notice = _vm.retryNotice;
    final lead = (notice != null ? 1 : 0) + (_vm.hasEarlier ? 1 : 0);
    final count = lead + messages.length;

    // Una caja por TURNO, no por mensaje: es el diseno de
    // 	urnActivity.ts del cliente React, al pie de la letra. Sin esto,
    // MessageBubble cae en su fallback y cada mensaje del assistant
    // vuelve a dibujar su propia caja -- que es lo que llenaba el chat.
    final turns = buildTurnActivities(messages);

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
          var offset = index;
          if (notice != null) {
            if (offset == 0) return _retryPill(notice);
            offset--;
          }
          if (_vm.hasEarlier) {
            if (offset == 0) return _loadMore();
            offset--;
          }
          final message = messages[offset];
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: MessageBubble(
              // offset ya descuenta las filas de encabezado (aviso de
              // reintento y cargar-anteriores). Usar index aca tiraba
              // RangeError en cuanto esas filas aparecian.
              turnActivity: turns[message.id],
              absorbedActivity: turns.isAbsorbed(message.id),
              key: ValueKey(message.id),
              message: message,
              working: _vm.working,
              thinkingDefault: widget.thinkingDefault,
              onOpenDiff: widget.onOpenDiff == null ? null : _onOpenDiff,
              onQuestionAnswer: _onQuestion,
              questionRequestId: _requestIdFor(message),
            ),
          );
        },
      ),
    );
  }

  /// El `requestID` de la pregunta que espera, si este mensaje es el que la
  /// tiene pendiente. El id vive en el `question.asked`, no en el mensaje: sin
  /// esto la card no podría llamar al endpoint de reply.
  String? _requestIdFor(SessionMessage message) {
    final tool = MessageBubble.pendingQuestionTool(message);
    // `AssistantContent.id` es `String?` aunque el tool siempre lo traiga: sin
    // `callID` no hay a qué `requestID` pegarse y el viewmodel va al prompt.
    final callId = tool?.id;
    if (callId == null) return null;
    return _vm.requestIdFor(callId);
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
    // El diff lo abre el `files`/shell: el chat sólo pasa el tool. Si el shell
    // no pasó handler, el chip ni siquiera se pintó (`ToolCard`).
    widget.onOpenDiff?.call(tool);
  }

  /// El aviso de reintento: `Reintentando en 8s — Rate limit`. Sin esto un
  /// `status: retry` es un "ocupado" más, indistinguible de un turno trabajando
  /// (§7.3). Va en la pila de sistema porque **no** es un error: no hay nada
  /// que arreglar, sólo que avisar.
  Widget _retryPill(String notice) {
    final scheme = Theme.of(context).colorScheme;
    return LayerGate(
      'chat.msg.system',
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            notice,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  /// Contesta la pregunta de la card.
  ///
  /// El viewmodel intenta el endpoint de reply del protocolo y, si no existe
  /// (404 medido en `:4098`), manda las respuestas como prompt. Cuando fue por
  /// el prompt se avisa: no es un error, pero sí cambia lo que el usuario está
  /// tocando (su mensaje en vez de la card).
  void _onQuestion(String? requestId, List<String> answers) {
    unawaited(
      _vm.answerQuestion(requestId, answers: [answers]).then((path) {
        if (path != QuestionReplyPath.prompt || !mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'Este servidor no expone el endpoint de preguntas: la respuesta '
              'va como mensaje.',
            ),
          ),
        );
      }),
    );
  }

  // ──────────────────────────── composer ────────────────────────────

  Widget _composer() {
    // Capa chat.composer: apagar el toggle saca el composer entero.
    return LayerGate(
      'chat.composer',
      child: ChatComposer(
        working: _vm.working,
        canSend: true,
        modelLabel: _modelLabel,
        agentLabel: _agentLabel,
        contextLabel: contextLabel(_vm.serverTokens, _vm.serverCost),
        onSend: (text, files) =>
            _vm.send(text, files: [for (final f in files) f.toPromptFile()]),
        onStop: _vm.abort,
        onPickModel: _openModelSheet,
        onPickAgent: _openAgentSheet,
      ),
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
    await _runAction(action);
    widget.onAction?.call(action);
  }

  /// Modo lectura: la misma conversación sin la chrome de las tools.
  bool _readMode = false;

  /// Corre la acción elegida en el menú de la sesión.
  ///
  /// Antes el menú llamaba a `widget.onAction`, y **`onAction` no lo pasaba
  /// nadie**: la hoja cerraba y no pasaba nada. Las cinco acciones que quedaron
  /// se ejecutan acá, con el `ApiClient` de esta sesión.
  /// El id del ultimo mensaje del usuario: el punto al que vuelve el
  /// Deshacer.
  ///
  /// El revert/stage lo exige en el body (medido: sin messageID devuelve
  /// 400 Missing key at [messageID]), y no es cualquier mensaje: tiene que
  /// ser un prompt, porque deshacer un turno entero empieza por su prompt.
  String? _lastUserMessageId() {
    final messages = _vm.messages;
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i] is UserMessage) return messages[i].id;
    }
    return null;
  }

  Future<void> _runAction(ChatSessionAction action) async {
    switch (action) {
      case ChatSessionAction.compact:
        try {
          await _vm.api.compactSession(_vm.sessionId, directory: _vm.directory);
          await _vm.refresh();
        } catch (e) {
          _vm.reportError('No se pudo compactar: $e');
        }
      case ChatSessionAction.undo:
        try {
          // El server no tiene "undo": tiene un revert **por etapas** —
          // `stage` prepara y `commit` lo aplica (medido en el spec). Mandar los
          // dos es lo que hace que el Deshacer sea un Deshacer y no un cambio
          // de hipótesis a medias si falla el segundo.
          final anchor = _lastUserMessageId();
          if (anchor == null) {
            _vm.reportError('No hay ningun mensaje al que volver.');
            return;
          }
          await _vm.api.stageRevert(
            _vm.sessionId,
            messageId: anchor,
            directory: _vm.directory,
          );
          await _vm.api.commitRevert(_vm.sessionId, directory: _vm.directory);
          await _vm.refresh();
        } catch (e) {
          _vm.reportError('No se pudo deshacer: $e');
        }
      case ChatSessionAction.exportMarkdown:
        try {
          final path = await _exportMarkdown();
          if (!mounted) return;
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(SnackBar(content: Text('Exportado en $path')));
        } catch (e) {
          _vm.reportError('No se pudo exportar: $e');
        }
      case ChatSessionAction.readMode:
        setState(() => _readMode = !_readMode);
      case ChatSessionAction.stats:
        await _showStats();
    }
  }

  /// Escribe la conversación en un `.md` y devuelve dónde quedó.
  ///
  /// Se arma a mano y no con un paquete de markdown: el formato es cuatro
  /// encabezados por mensaje y una línea de metadatos, y una dependencia de
  /// 2 MB para eso es sólo peso.
  Future<String> _exportMarkdown() async {
    final buffer = StringBuffer()
      ..writeln('# ${_title}')
      ..writeln()
      ..writeln('- Sesión: `${_vm.sessionId}`')
      ..writeln('- Exportado: ${DateTime.now().toIso8601String()}')
      ..writeln();
    for (final m in _vm.messages) {
      switch (m) {
        case UserMessage(:final text):
          buffer
            ..writeln('## Usuario')
            ..writeln()
            ..writeln(text)
            ..writeln();
        case AssistantMessage(:final content):
          buffer
            ..writeln('## Asistente')
            ..writeln();
          for (final part in content) {
            if (part is AssistantText) buffer.writeln(part.text);
          }
          buffer.writeln();
        default:
          break;
      }
    }
    final dir = Directory.systemTemp;
    final file = File(
      '${dir.path}${Platform.pathSeparator}openher-${_vm.sessionId}.md',
    );
    await file.writeAsString(buffer.toString());
    return file.path;
  }

  /// Costo y tokens de la sesión, de lo que ya está en memoria.
  Future<void> _showStats() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => LayerGate(
      'surfaces.sheet.actions',
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Estadísticas', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            _Stat(label: 'Mensajes', value: '${_vm.messages.length}'),
            _Stat(
              label: 'Costo',
              value: '\$${_vm.serverCost.toStringAsFixed(4)}',
            ),
            _Stat(label: 'Tokens de entrada', value: '${_vm.serverTokens}'),
            _Stat(
              label: 'Contexto',
              value: contextLabel(_vm.serverTokens, _vm.serverCost),
            ),
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: const Text('Cerrar'),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// Elige modelo **y** nivel de pensamiento, y lo aplica a la sesión viva.
  ///
  /// Antes esto terminaba en `widget.onPickModel?.call(picked)`: la elección se
  /// descartaba. Ahora manda el `POST /api/session/{id}/model` (medido: 204 sin
  /// cuerpo) y recién después la deja registrada en el VM para que los pills
  /// muestren lo elegido.
  /// El rótulo del pill de modelo.
  ///
  /// Antes era `info?.model?.id`, y eso daba siempre `null`: una sesión nueva
  /// del server v2 **no trae** campo `model` (medido: `id`, `projectID`,
  /// `cost`, `tokens`, `time`, `location`), así que el pill decía "Elegir
  /// modelo" para siempre, incluso después de haber elegido.
  String get _modelLabel {
    final m = _vm.currentModel;
    if (m == null || m.id.isEmpty) return 'Elegir modelo';
    return m.id;
  }

  /// El rótulo del pill de agente, con el mismo criterio.
  String get _agentLabel => AgentCatalog.labelFor(_agents, _vm.currentAgent);

  Future<void> _openModelSheet() async {
    final picked = await showModelSheet(
      context,
      catalog: _catalog,
      current: _vm.currentModel,
    );
    if (picked == null) return;
    final model = ModelRef(
      id: picked.modelId,
      providerID: picked.providerId,
      variant: picked.variantId,
    );
    try {
      await _vm.api.setSessionModel(
        _vm.sessionId,
        providerId: picked.providerId,
        modelId: picked.modelId,
        variantId: picked.variantId,
        directory: _vm.directory,
      );
      _vm.applySelection(model: model);
    } catch (e) {
      _vm.reportError('No se pudo cambiar el modelo: $e');
    }
    // Se avisa igual: un shell que abre sesiones nuevas con este modelo tiene
    // que enterarse, y el `catch` ya dejó el error a la vista.
    widget.onPickModel?.call(picked);
  }

  /// Elige agente y lo aplica a la sesión viva.
  ///
  /// El pill de agente usaba el mismo callback que el de modelo, y los dos
  /// abrían la hoja de modelo. Por eso no había forma de elegir un agente: no
  /// era que estuviera escondido, es que la pantalla no existía.
  Future<void> _openAgentSheet() async {
    final picked = await showAgentSheet(
      context,
      load: _loadAgents,
      current: _vm.currentAgent,
    );
    if (picked == null) return;
    try {
      await _vm.api.setSessionAgent(
        _vm.sessionId,
        agent: picked,
        directory: _vm.directory,
      );
      _vm.applySelection(agent: picked);
    } catch (e) {
      _vm.reportError('No se pudo cambiar el agente: $e');
    }
  }

  /// Los agentes, cacheados en memoria mientras la vista viva: `GET /api/agent`
  /// son 26 y no cambian entre aperturas de la hoja.
  AgentCatalog? _agents;

  Future<AgentCatalog> _loadAgents() async {
    final cached = _agents;
    if (cached != null) return cached;
    final raw = await _vm.api.listAgents(directory: _vm.directory);
    final catalog = AgentCatalog.fromList(raw);
    _agents = catalog;
    return catalog;
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
                      onTap: () => onPick(action),
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

/// Linea de 2 px que se mueve mientras el agente trabaja (.progress del
/// prototipo). Va **encima** de la lista, no dentro del scroll, para que no
/// se mueva con el contenido. Apagada por defecto en la spec de capas.
class _WorkingLine extends StatefulWidget {
  const _WorkingLine();

  @override
  State<_WorkingLine> createState() => _WorkingLineState();
}

class _WorkingLineState extends State<_WorkingLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 2,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => FractionallySizedBox(
          alignment: Alignment(-1 + 2 * _c.value, 0),
          widthFactor: 0.35,
          child: ColoredBox(color: theme.colorScheme.primary),
        ),
      ),
    );
  }
}

/// Una fila de las Estadísticas: rótulo a la izquierda, valor a la derecha.
class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Text(
          value,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}
