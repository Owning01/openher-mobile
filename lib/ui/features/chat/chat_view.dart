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
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'composer_suggestions.dart';
import 'package:image_picker/image_picker.dart';

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
import 'squares_spinner.dart';
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

  /// La ventana de contexto del modelo elegido, para el porcentaje.
  ///
  /// `null` si el catálogo no la tiene: el rótulo omite el `%` en vez de
  /// inventar una ventana. Buscar el modelo es una lectura de la caché del
  /// [CatalogRepository] (`findModel` la resuelve sin red cuando ya está
  /// cargado), así que no agrega un request por repintado.
  int? _contextWindow;
  String? _contextWindowFor;

  Future<void> _resolveContextWindow() async {
    final model = _vm.currentModel;
    final ref = model?.id;
    if (ref == null || ref.isEmpty) return;
    // La clave incluye el provider: dos providers pueden tener modelos con el
    // mismo `id` y ventanas distintas, y con sólo el `id` se cachearía la
    // ventana del provider anterior.
    final key = '${model!.providerID}/$ref';
    if (key == _contextWindowFor) return;
    _contextWindowFor = key;
    try {
      final info = await _catalog.findModel(
        providerId: model.providerID,
        modelId: ref,
      );
      if (!mounted || _contextWindowFor != key) return;
      setState(() => _contextWindow = info?.contextLimit);
    } catch (e) {
      // Sin ventana no hay porcentaje, y eso está bien: el número de tokens
      // sigue siendo cierto. Un fallo del catálogo no vale un error en
      // pantalla.
      _contextWindow = null;
    }
  }

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
    // El controller del input lo creo yo, asi que lo libero yo: el composer
    // solo lo `dispose()`a cuando es el suyo.
    _composerController.dispose();
    super.dispose();
  }

  void _onVm() {
    if (!mounted) return;
    // La ventana del modelo se resuelve una vez por modelo, no en cada tick del
    // poll: el catálogo ya está cacheado, así que no agrega un request, pero
    // `setState` en cada tick lo hace 30 veces por segundo, que es trabajo
    // tirado. El `unawaited` es a propósito: no se espera al catálogo para
    // pintar, y el número de tokens ya es cierto sin la ventana.
    unawaited(_resolveContextWindow());
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
    // `liveTitle` trae el titulo que el server le puso a la sesion con el
    // primer mensaje (`session.renamed`); sin el, el chat se quedaba
    // mostrando `ses_0acd172...` hasta un re-fetch completo.
    final title = (_vm.liveTitle ?? '').trim();
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
    // La fila de la grilla va al **pie**: es donde el usuario mira cuando
    // espera. No va detrás de `chat.header.progress` porque esa capa está
    // apagada por diseño (una de las cuatro del catálogo) y no se vería nunca.
    final thinking = _vm.working ? 1 : 0;
    final count = lead + messages.length + thinking;

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
          // La última fila es la grilla de "pensando". Va después de restar las
          // filas de encabezado, así que se compara contra el largo de la lista
          // de mensajes y no contra `index`.
          if (thinking == 1 && offset == messages.length) {
            return const _ThinkingRow();
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
              // El mensaje que el server no tomó queda en pantalla marcado, con
              // su reintento. Antes se borraba y el texto se perdía (409 al
              // mandar con el agente trabajando).
              onRetrySend: _vm.retrySend,
              // Sólo este assistant puede pintar puntos de escritura.
              isOpenAssistant: message.id == _vm.openAssistantId,
              // El menu del mensaje (Copiar, Deshacer). Sin esto no habia
              // forma de copiar un mensaje entero, y solo se podia copiar una
              // parte si se seleccionaba a mano: el `Text` del mensaje del
              // usuario ni siquiera era seleccionable.
              onMenu: _canMenu(message)
                  ? () => _openMessageMenu(message)
                  : null,
              // Los tres del mensaje en cola. Editar reutiliza el mismo canal
              // que el "deshacer": el texto vuelve al input por
              // `_prefillComposer`, y acá además desaparece la burbuja (lo
              // decide `takePendingText`).
              // El canal de imágenes: el agente manda rutas desnudas y el
              // server sirve los bytes en `GET /api/fs/read/<path>`, que exige
              // el header Basic. La config vive acá, en el shell, no en la
              // burbuja.
              //
              // **Con `location[directory]`, y ahí estaba el bug**: medido
              // 2026-10-06, un basename suelto contra la raíz del server da
              // `404 FileNotFoundError`, y el mismo basename con
              // `location[directory]` de su carpeta da `200 image/jpeg`. La
              // ruta absoluta entera da **500**, así que tampoco sirve mandarla
              // tal cual.
              //
              // De ahí la resolución: si el token trae carpeta, manda la suya;
              // si es un nombre suelto (`bautismoOlivia2021.jpeg`, que es lo que
              // manda el agente), se resuelve contra la carpeta de la sesión.
              imageUrl: (path) {
                final normal = path.replaceAll('\\', '/');
                final corte = normal.lastIndexOf('/');
                final nombre = corte < 0 ? normal : normal.substring(corte + 1);
                final carpeta = corte > 0
                    ? normal.substring(0, corte)
                    : _vm.directory;
                return _vm.api.config.fileUrl(nombre, directory: carpeta);
              },
              imageHeaders: _vm.api.config.binaryHeaders,
              onPendingEdit: _onPendingEdit,
              onPendingDiscard: _vm.discardPending,
              onPendingSend: _vm.confirmSend,
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
        // Con `window` para que aparezca el porcentaje: "102.9k contexto · 51%"
        // informa mucho más que el número solo, porque sin la ventana no se
        // sabe si 102k es mucho o poco.
        contextLabel: contextLabel(
          _vm.contextTokens,
          _vm.serverCost,
          window: _contextWindow,
        ),
        // Los adjuntos van con el prompt y se vacian recien cuando el envio
        // se admite: si falla, el usuario los conserva y reintenta sin
        // volver a elegirlos.
        //
        // **No** se vuelve a mezclar `_pending` adentro: el composer ya los
        // recibe en `attachments` y los devuelve en `files`. Agregarlos otra
        // vez mandaba cada foto **dos veces** (mismo uri, mismo nombre) — no se
        // notaba porque `attachments` nunca se paso y la tira no se veia.
        onSend: (text, files) => _enviar(text, files),
        onStop: _vm.abort,
        onPickModel: _openModelSheet,
        onPickAgent: _openAgentSheet,
        onAttach: _pickAttachment,
        // El composer **no recibia** los adjuntos: se elegian fotos y se
        // mandaban bien (por el merge de `onSend`) pero no se veian nunca, y
        // la `x` de cada thumb no hacia nada porque `onRemoveAttachment` era
        // `null` y el `?.call` se comia el toque en silencio.
        attachments: _pending,
        onRemoveAttachment: (a) => setState(
          // Por identidad, no por valor: dos tandas pueden traer el mismo
          // nombre de archivo y la `x` tiene que borrar solo el que se toco.
          () => _pending = [
            for (final f in _pending)
              if (!identical(f, a)) f,
          ],
        ),
        suggestions: _suggestions,
        suggestionsLoading: _suggestionsLoading,
        onTrigger: _onTrigger,
        onCommand: _runServerCommand,
        onLocalAction: _runLocalAction,
        // El canal por el que un "deshacer" devuelve al input lo que el
        // usuario habia escrito.
        controller: _composerController,
      ),
    );
  }

  /// Manda el mensaje con sus adjuntos.
  ///
  /// **Es async porque leer los adjuntos lo es.** Cada uno se convierte en un
  /// data URI leyendo el archivo del disco del teléfono: el server no puede
  /// leer esa ruta y contesta
  /// `400 InvalidRequestError: Unsupported attachment URI` (medido). Antes la
  /// conversión era sincrónica y mandaba la ruta pelada, que es el 400 que se
  /// veía al adjuntar una foto.
  Future<void> _enviar(String text, List<ComposerAttachment> files) async {
    final listos = <Map<String, String>>[];
    for (final f in files) {
      try {
        listos.add(await f.toPromptFile());
      } catch (e) {
        // Si no se puede leer, **no se manda a medias**: un adjunto que falta
        // cambia lo que el modelo ve, y el usuario no lo sabría.
        _vm.reportError('No se pudo leer ${f.name}: $e');
        return;
      }
    }
    if (!mounted) return;
    _vm.send(text, files: listos);
    if (_vm.error == null) setState(() => _pending = []);
  }

  // ──────────────────────────── menú de / y @ ────────────────────────────

  /// Lo que se está escribiendo bajo el cursor, y los ítems ya filtrados.
  ///
  /// Vive en la vista y no en el compositor porque el compositor no tiene
  /// cliente HTTP: el `GET /api/command`, el `GET /api/skill` y la búsqueda de
  /// archivos salen de acá. Lo que el compositor hace es detectar el
  /// disparador ([detectComposerTrigger]) y avisar.
  ComposerTrigger? _trigger;
  List<ComposerSuggestion> _suggestions = const [];
  bool _suggestionsLoading = false;

  /// Carga perezosa. Cada fuente se pide **una vez** por sesión de chat: el
  /// `GET /api/skill` pesa 438 KB y el `GET /api/agent` 87 KB, y tipear `@a` no
  /// puede provocar dos requests por tecla.
  ///
  /// Ojo con el nombre: `_agents` (abajo, en `_loadAgents`) es el
  /// [AgentCatalog] que usa la hoja de agente. Éste es otra cosa: los ítems del
  /// menú, ya tipados. Mezclarlos fue un error de nombre, no de diseño.
  List<ComposerSuggestion>? _commandItems;
  List<ComposerSuggestion>? _skillItems;
  List<ComposerSuggestion>? _agentItems;

  void _onTrigger(ComposerTrigger? t) {
    if (t == null) {
      if (_trigger != null)
        setState(() {
          _trigger = null;
          _suggestions = const [];
          _suggestionsLoading = false;
        });
      return;
    }
    // Cambió el disparador: se olvida el fallo anterior, porque el nuevo puede
    // ser un directorio que sí funciona.
    final cambioDeDisparador =
        _trigger?.kind != t.kind || _trigger?.start != t.start;
    if (cambioDeDisparador) _suggestionsFailed = false;
    setState(() {
      _trigger = t;
      _suggestions = filterSuggestions(_candidates(t), t.query);
    });
    if (_needsLoad(t)) _loadSources(t);
  }

  /// Los candidatos que casan con un disparador, sin filtrar todavía.
  ///
  /// `_fileItems` no lleva `?` porque arranca vacío y nunca es nulo: los tres
  /// que sí pueden no haber cargado todavía (comandos, agentes, skills) lo
  /// llevan, y por eso un menú recién abierto se pinta con lo que hay sin
  /// esperar a la red.
  ///
  /// Las acciones locales van **primero** y no se mezclan con la lista del
  /// server: son las tres que el usuario pidió y las que ya funcionaban desde
  /// el action sheet. Que el server no las anuncie en `GET /api/command` (medido:
  /// `compact`, `undo` y `redo` dan 404 por `POST .../command`) no significa que
  /// no existan: existen como endpoints, y ofrecerlas por nombre es justamente
  /// lo que el usuario pidió.
  List<ComposerSuggestion> _candidates(ComposerTrigger t) =>
      t.kind == ComposerTriggerKind.slash
      ? [..._localActions, ...?_commandItems]
      : [...?_agentItems, ...?_skillItems, ..._fileItems];

  /// Las tres acciones locales, con el id que el compositor enruta.
  ///
  /// El `insert` lleva la barra porque es lo que se ve en el campo; el
  /// compositor la saca para el `name` del POST (ver
  /// [ApiClient.runCommand] y [ChatComposer._dispatchSlash]).
  static const List<ComposerSuggestion> _localActions = [
    ComposerSuggestion(
      label: 'compact',
      insert: '/compact',
      kind: ComposerSuggestionKind.action,
      detail: 'Resume la conversación',
    ),
    ComposerSuggestion(
      label: 'undo',
      insert: '/undo',
      kind: ComposerSuggestionKind.action,
      detail: 'Deshacer el último mensaje',
    ),
    ComposerSuggestion(
      label: 'redo',
      insert: '/redo',
      kind: ComposerSuggestionKind.action,
      detail: 'Rehacer lo deshecho',
    ),
  ];

  /// ¿Falta alguna fuente para este disparador?
  ///
  /// Para `/` alcanza con la lista de comandos. Para `@` hacen falta los agentes
  /// siempre, las skills y los archivos recién con dos letras tipeadas: con una
  /// sola, la búsqueda de archivos trae el árbol entero del proyecto.
  ///
  /// [_suggestionsFailed] es lo que corta la insistencia: si una fuente falló
  /// (un `directory` roto da 500, medido), no se reintenta en cada tecla del
  /// mismo disparador. Volver a intentar es cambiar de disparador.
  bool _needsLoad(ComposerTrigger t) {
    if (_suggestionsFailed) return false;
    if (t.kind == ComposerTriggerKind.slash) return _commandItems == null;
    if (t.query.trim().length < kMentionMinQuery) return _agentItems == null;
    return _skillItems == null || _fileQuery != t.query.trim();
  }

  /// Ya se avisó que una fuente no carga. Se limpia al cambiar de disparador.
  bool _suggestionsFailed = false;

  static const int kMentionMinQuery = 2;

  /// La búsqueda de archivos, 150 ms después de la última tecla.
  ///
  /// El debounce es del cliente web medido, no una invención: sin él, `@a`
  /// dispara un `GET /api/fs/find` por tecla. Cada request lleva su [_fileToken]
  /// y se descarta si al llegar ya no es el último, sin lo cual una búsqueda
  /// lenta que llega tarde pisa el resultado de la nueva y el menú muestra
  /// archivos que no se tipearon.
  Timer? _fileDebounce;
  int _fileToken = 0;
  String? _fileQuery;
  List<ComposerSuggestion> _fileItems = const [];

  Future<void> _loadSources(ComposerTrigger t) async {
    setState(() => _suggestionsLoading = true);
    final api = _vm.api;
    final dir = _vm.directory;
    final token = ++_fileToken;
    try {
      if (t.kind == ComposerTriggerKind.slash) {
        if (_commandItems == null) {
          final raw = await api.listCommands(directory: dir);
          _commandItems = [
            for (final c in raw)
              if ((c['name'] as String? ?? '').isNotEmpty)
                ComposerSuggestion(
                  label: c['name']! as String,
                  kind: ComposerSuggestionKind.command,
                  detail: c['description'] as String? ?? '',
                  // El `name` viaja sin barra: el lookup del server es exacto.
                  runCommand: c['name']! as String,
                ),
          ];
        }
      } else {
        if (_agentItems == null) _agentItems = await _agentSuggestions(dir);
        final q = t.query.trim();
        if (q.length >= kMentionMinQuery) {
          if (_skillItems == null) {
            final raw = await api.listSkills(directory: dir);
            _skillItems = [
              for (final s in raw)
                if ((s['name'] as String? ?? '').isNotEmpty)
                  ComposerSuggestion(
                    label: s['name']! as String,
                    kind: ComposerSuggestionKind.skill,
                    detail: s['description'] as String? ?? '',
                    insert: '@${s['name']}',
                  ),
            ];
          }
          _fileDebounce?.cancel();
          final completer = Completer<void>();
          _fileDebounce = Timer(const Duration(milliseconds: 150), () {
            unawaited(
              api
                  .findFiles(query: q, directory: dir, limit: 12)
                  .then((page) {
                    // Descarte por token: una búsqueda vieja que llega tarde no
                    // puede pisar el resultado de la actual.
                    if (token != _fileToken) return;
                    _fileQuery = q;
                    _fileItems = [
                      for (final f in page.data)
                        if (f is Map<String, dynamic>)
                          ComposerSuggestion(
                            label: f['path'] as String? ?? '',
                            kind: ComposerSuggestionKind.file,
                            detail: f['type'] as String? ?? 'archivo',
                            insert: '@${f['path']}',
                          ),
                    ];
                    completer.complete();
                  })
                  .catchError((Object e) {
                    if (token == _fileToken) {
                      _fileQuery = q;
                      _fileItems = const [];
                    }
                    completer.complete();
                  }),
            );
          });
          unawaited(completer.future);
        }
      }
    } catch (e) {
      // El menú no es un servicio crítico, pero un fallo **sí** se dice: en
      // silencio el usuario tipea `@` y no entiende por qué no aparece nada.
      //
      // Medido: un `directory` que no existe da **500** (no una lista vacía), y
      // el menú se pide al tipear, así que sin este guardia el mismo error
      // saldría en pantalla en cada tecla. Por eso el aviso es de una vez: se
      // marca [_suggestionsFailed] y no se vuelve a pedir hasta que el
      // disparador cambie.
      if (!_suggestionsFailed) {
        _suggestionsFailed = true;
        _vm.reportError('No se pudieron cargar las sugerencias: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _suggestionsLoading = false;
          final t2 = _trigger;
          if (t2 != null) {
            _suggestions = filterSuggestions(_candidates(t2), t2.query);
          }
        });
      }
    }
  }

  /// Los agentes del server como ítems de menú. Los ocultos se filtran: un
  /// agente `hidden` es interno y no tiene que aparecer en el `@`.
  Future<List<ComposerSuggestion>> _agentSuggestions(String? dir) async {
    final raw = await _vm.api.listAgents(directory: dir);
    return [
      for (final a in raw)
        if ((a['id'] as String? ?? '').isNotEmpty && a['hidden'] != true)
          ComposerSuggestion(
            label: a['name'] as String? ?? a['id']! as String,
            kind: ComposerSuggestionKind.agent,
            detail: a['description'] as String? ?? '',
            insert: '@${a['name'] ?? a['id']}',
          ),
    ];
  }

  /// `POST /api/session/{id}/command` - un comando de barra del server.
  ///
  /// El `name` va **sin barra** (el lookup del server es exacto) y los
  /// argumentos en `text`, que es lo que exige el schema: `name` y `text`
  /// requeridos, `additionalProperties: false`.
  Future<void> _runServerCommand(String name, String args) async {
    try {
      await _vm.api.runCommand(
        _vm.sessionId,
        name: name,
        text: args,
        directory: _vm.directory,
      );
      await _vm.refresh();
    } catch (e) {
      _vm.reportError('No se pudo correr /$name: $e');
    }
  }

  /// Una acción local escrita con barra. Cada una tiene su endpoint y su
  /// semántica, y por eso **no** van por [_runServerCommand]: `POST
  /// /session/{id}/command` con estos nombres da 404 (medido).
  Future<void> _runLocalAction(String id, String args) async {
    switch (id) {
      case 'compact':
        try {
          await _vm.api.compactSession(_vm.sessionId, directory: _vm.directory);
          await _vm.refresh();
        } catch (e) {
          _vm.reportError('No se pudo compactar: $e');
        }
      case 'undo':
        await _revert();
      case 'redo':
        try {
          await _vm.api.commitRevert(_vm.sessionId, directory: _vm.directory);
          await _vm.refresh();
        } catch (e) {
          _vm.reportError('No se pudo rehacer: $e');
        }
    }
  }

  /// El Deshacer: `revert/stage` + `revert/commit`. No es un undo de un paso
  /// (medido: no existe tal endpoint), son dos etapas, y el commit va después
  /// del stage a propósito.
  Future<void> _revert() => _revertTo(_lastUserMessageId());

  /// Deshace **hasta** [messageId] y, si [restore] viene, devuelve ese texto al
  /// composer.
  ///
  /// El `restore` es la mitad del encargo de este método. Sin él, deshacer un
  /// mensaje tiraba el texto con el mensaje: el server lo saca del historial y
  /// el usuario se quedaba sin poder leer lo que habia escrito ni reenviarlo.
  /// Con él, el mensaje desaparece del chat y sus palabras vuelven al input,
  /// listas para corregirse y volver a mandarse — que es lo que se espera de
  /// un "deshacer" en cualquier parte.
  Future<void> _revertTo(String? messageId, {String? restore}) async {
    try {
      if (messageId == null) {
        _vm.reportError('No hay ningun mensaje al que volver.');
        return;
      }
      await _vm.api.stageRevert(
        _vm.sessionId,
        messageId: messageId,
        directory: _vm.directory,
      );
      await _vm.api.commitRevert(_vm.sessionId, directory: _vm.directory);
      await _vm.refresh();
      if (restore == null || restore.trim().isEmpty) return;
      _prefillComposer(restore);
    } catch (e) {
      _vm.reportError('No se pudo deshacer: $e');
    }
  }

  /// Pone texto en el input, con el cursor al final.
  ///
  /// **No** pide el foco a proposito: en un telefono eso abre el teclado encima
  /// del chat justo cuando el usuario quiere mirar lo que quedo. El texto esta
  /// a la vista, se toca el input si lo quiere editar, y el teclado no tapa nada.
  void _prefillComposer(String text) {
    if (!mounted) return;
    _composerController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  // ──────────────────────────── hojas ────────────────────────────

  /// Qué mensajes merecen menu.
  ///
  /// Los del usuario: **Copiar** y **Deshacer**. Los del assistant: **Copiar**,
  /// y nada mas — no se puede "deshacer" media respuesta sin tirar tambien todo
  /// lo que el usuario dijo despues, y ademas el `revert/stage` exige que el
  /// ancla sea un prompt (medido: sin `messageID` devuelve 400).
  ///
  /// Las pills (system, compactacion, agente) quedan afuera: copiar "Contexto
  /// compactado" no sirve de nada.
  bool _canMenu(SessionMessage m) => switch (m) {
    UserMessage() => m.text.trim().isNotEmpty,
    AssistantMessage() => m.textContent.trim().isNotEmpty,
    _ => false,
  };

  /// El menu de un mensaje: copiar todo, y deshacer si es del usuario.
  /// Editar un mensaje en cola: el texto vuelve al input y la burbuja desaparece.
  ///
  /// No queda rastro del pendiente. Es lo que dice `takePendingText`: si el
  /// usuario no lo manda de nuevo, no vuelve a aparecer en ninguna parte. Un
  /// "borrar y volver a aparecer después" sería un segundo mensaje pendiente sin
  /// que nadie lo pidiera.
  void _onPendingEdit(String localId) {
    final text = _vm.takePendingText(localId);
    if (text == null) return;
    _prefillComposer(text);
  }

  Future<void> _openMessageMenu(SessionMessage message) async {
    final isUser = message is UserMessage;
    final text = isUser
        ? message.text
        : (message as AssistantMessage).textContent;
    if (text.trim().isEmpty) return;

    final pick = await showModalBottomSheet<_MessageAction>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _MessageSheet(
        isUser: isUser,
        onClose: () => Navigator.of(sheetContext).pop(),
        onPick: (a) => Navigator.of(sheetContext).pop(a),
      ),
    );
    if (pick == null || !mounted) return;

    switch (pick) {
      case _MessageAction.copy:
        await _copyText(text);
      case _MessageAction.undo:
        await _revertTo(message.id, restore: text);
    }
  }

  /// Copia al portapapeles y **avisa**: sin el aviso no hay forma de saber si
  /// funciono, y un copiado silencioso que fallo se lee como que la app no
  /// hace nada.
  Future<void> _copyText(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('Mensaje copiado')));
    } catch (e) {
      _vm.reportError('No se pudo copiar: $e');
    }
  }

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
            // "Tokens de entrada" era el acumulado de la sesión, y por eso no
            // se podía llamar "contexto": son dos cosas distintas y la app las
            // mostraba con el mismo número. Acá cada una con su nombre.
            _Stat(label: 'Contexto actual', value: '${_vm.contextTokens} tok'),
            _Stat(
              label: 'Contexto',
              value: contextLabel(
                _vm.contextTokens,
                _vm.serverCost,
                window: _contextWindow,
              ),
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

  /// Elige **varias** imagenes y las deja como adjuntos pendientes.
  ///
  /// El boton existia desde el primer dia pero `onAttach` **no lo pasaba
  /// nadie**, igual que el microfono: el clip se apretaba y no pasaba nada.
  /// El prompt las acepta (`files: [{uri, name, mime}]` en la raiz del
  /// body, medido).
  ///
  /// Usa `pickMultiImage` y no `pickImage`: la primera devuelve un unico
  /// `XFile`, y el selector de Android colgado de ahi **no deja marcar mas de
  /// una foto** — habia que apretar el Clip N veces para N fotos. La segunda
  /// abre el selector en modo multiple y devuelve la lista entera de una.
  Future<void> _pickAttachment() async {
    try {
      final picked = await ImagePicker().pickMultiImage();
      if (picked.isEmpty) return;
      final nuevos = <ComposerAttachment>[];
      var rechazadas = 0;
      for (final f in picked) {
        final mime = _mimeOf(f.path);
        if (mime == null) {
          rechazadas++;
          continue;
        }
        nuevos.add(ComposerAttachment(name: f.name, mime: mime, uri: f.path));
      }
      if (nuevos.isEmpty) {
        _vm.reportError(
          rechazadas == 1
              ? 'Ese archivo no es una imagen.'
              : 'Ninguno de esos $rechazadas archivos es una imagen.',
        );
        return;
      }
      if (!mounted) return;
      // Se **agregan** a lo que ya estaba, no lo reemplazan: marcar tres fotos
      // son tres adjuntos, que es lo que uno espera cuando las elige juntas.
      setState(() => _pending = [..._pending, ...nuevos]);
      // **Un** aviso, no uno por archivo: con 6 fotos y 3 no admitidas no
      // queres tres snackbars apilados tapando el composer.
      if (rechazadas > 0) {
        _vm.reportError(
          '$rechazadas de ${picked.length} no se adjuntaron: no son imágenes.',
        );
      }
    } catch (e) {
      _vm.reportError('No se pudo adjuntar la imagen: $e');
    }
  }

  /// El mime por extension: la galeria de Android devuelve jpg, png, webp,
  /// gif o heic. Cualquier otra extension se rechaza con un mensaje claro en
  /// vez de mandarle al server un mime inventado.
  static String? _mimeOf(String path) {
    final lower = path.toLowerCase();
    for (final e in <String, String>{
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.png': 'image/png',
      '.webp': 'image/webp',
      '.gif': 'image/gif',
      '.heic': 'image/heic',
    }.entries) {
      if (lower.endsWith(e.key)) return e.value;
    }
    return null;
  }

  /// Los adjuntos aun no enviados. Los elige el usuario con el clip y se van
  /// con el proximo prompt.
  List<ComposerAttachment> _pending = [];

  /// El input del composer, para poder devolverle texto.
  ///
  /// Vive en el shell y no adentro del composer porque el que sabe **qué**
  /// texto volver es el shell: lo saca del mensaje que acaba de deshacer. Un
  /// "deshacer" es el unico camino en el app que escribe en el input sin que
  /// el usuario haya tocado el teclado.
  final TextEditingController _composerController = TextEditingController();

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
///
/// ## Por qué vive en un archivo de widgets
///
/// Porque es formato de UI, no cálculo: la aritmética va en
/// [TokenUsage.context] y el getter del viewmodel. Acá sólo se decide qué
/// redondeo y qué separador, que es exactamente lo que cambia cuando cambia el
/// prototipo. Por eso se puede probar sin montar un solo widget, y por eso el
/// test mide las dos cosas por separado: si el número está mal, el bug está en
/// [TokenUsage.context]; si el rótulo está mal, está acá.
///
/// [tokens] es el **contexto actual** ([ChatViewModel.contextTokens]), no el
/// acumulado de la sesión. Antes se pasaba `session.tokens` y el número era el
/// total gastado en toda la vida de la sesión, con la etiqueta de "contexto":
/// medido, marcaba 151× de más.
///
/// Cuando se conoce la ventana del modelo ([window]) se agrega el porcentaje,
/// que es el número que uno realmente quiere: de 200k, saber que vas por 51%
/// dice mucho más que "102.9k".
String contextLabel(int tokens, double cost, {int? window}) {
  final String count;
  if (tokens >= 1000) {
    final k = tokens / 1000;
    count = '${k.toStringAsFixed(k >= 100 ? 0 : 1)}k';
  } else {
    count = '$tokens';
  }
  final pct = (window != null && window > 0)
      ? ' · ${(tokens * 100 / window).round()}%'
      : '';
  return '$count contexto$pct · \$${cost.toStringAsFixed(2)}';
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

/// Lo que se puede hacer con un mensaje desde su menu.
enum _MessageAction { copy, undo }

extension on _MessageAction {
  String get label => switch (this) {
    _MessageAction.copy => 'Copiar mensaje',
    _MessageAction.undo => 'Deshacer y editar',
  };

  String get icon => switch (this) {
    _MessageAction.copy => 'copy',
    _MessageAction.undo => 'arrow-left',
  };
}

/// El menu de un mensaje.
///
/// "Deshacer y editar" y no "Deshacer": el nombre dice lo que pasa. El mensaje
/// vuelve al composer para que se pueda corregir, que es la mitad del
/// encargo — un deshacer que borra el texto sin devolverlo deja al usuario sin
/// ni el mensaje ni lo que habia escrito.
///
/// `isUser` decide si aparece el Deshacer: deshacer media respuesta del
/// assistant no tiene a que volver a, y el `revert/stage` exige que el ancla
/// sea un prompt.
class _MessageSheet extends StatelessWidget {
  const _MessageSheet({
    required this.isUser,
    required this.onClose,
    required this.onPick,
  });

  final bool isUser;
  final VoidCallback onClose;
  final ValueChanged<_MessageAction> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final actions = <_MessageAction>[
      _MessageAction.copy,
      if (isUser) _MessageAction.undo,
    ];
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
                    'Mensaje',
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
          for (final action in actions)
            Material(
              key: ValueKey('message-action-${action.name}'),
              color: Colors.transparent,
              child: InkWell(
                onTap: () => onPick(action),
                child: SizedBox(
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                    ),
                    child: Row(
                      children: [
                        AppIcon(action.icon, size: 20, color: scheme.onSurface),
                        const SizedBox(width: AppSpacing.md),
                        Text(
                          action.label,
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
        ],
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

/// La fila de "el agente está pensando": la grilla de 8 cuadrados.
///
/// Va al pie de la lista y **no** detrás de una capa. La línea de progreso de
/// 2 px vivía en `chat.header.progress`, que es una de las cuatro capas
/// apagadas del catálogo, y por eso no se veía: un spinner que no aparece no
/// es un spinner.
class _ThinkingRow extends StatelessWidget {
  const _ThinkingRow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs, bottom: AppSpacing.md),
      child: Row(
        children: <Widget>[
          const SquaresSpinner(),
          const SizedBox(width: AppSpacing.md),
          Text(
            'Pensando',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
