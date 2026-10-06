/// El composer (`chat.composer.*`): adjuntos, campo de escritura y la barra de
/// modelo/agente/contexto.
///
/// El botón de la derecha tiene **tres** estados y no dos, que es el detalle que
/// más se pierde en un port:
///
/// | estado | fondo | glifo | tooltip |
/// |---|---|---|---|
/// | hay texto | `primary` | `send` | Enviar |
/// | vacío | `surface-hover` | `send` (apagado) | Enviar |
/// | `working` | `danger` | `stop` | Detener |
///
/// El tercero es el que cumple §7.4: el botón Detener no se esconde hasta que
/// llega la evidencia real de fin de turno.
///
/// Lo que **no** se construye (apagado en la spec aprobada, ver
/// `assets/spec/layers.json`): el chip TSL (`chat.composer.tsl`) y el contador
/// de caracteres (`chat.composer.counter`). Los `LayerGate` están puestos igual:
/// si mañana se prenden, aparecen; y el test verifica que apagados no se pintan
/// aunque el viewmodel tenga los datos.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../core/app_icon.dart';
import '../../core/layer_gate.dart';
import '../../core/tokens.dart';
import 'composer_suggestions.dart';

/// Un adjunto pendiente de enviar (`PromptFileAttachment`).
class ComposerAttachment {
  const ComposerAttachment({required this.name, required this.uri, this.mime});

  final String name;
  final String uri;
  final String? mime;

  /// `{'uri': …, 'name': …, 'mime': …}`, que es lo que espera
  /// `POST /api/session/{id}/prompt`.
  ///
  /// **El `uri` va como data URI, no como ruta de archivo.** Medido 2026-10-06
  /// contra el server real: mandar la ruta del teléfono —o `file://`, o
  /// `content://`, o una URL— devuelve
  /// `400 InvalidRequestError: Unsupported attachment URI`, y `file://` da
  /// `Invalid file URI`. Con `data:<mime>;base64,<bytes>` de una imagen real
  /// devuelve **200**. El server no puede leer el disco del teléfono, así que
  /// el contenido tiene que viajar en el cuerpo.
  ///
  /// Tira si el archivo no se puede leer: el que llama decide qué decir. Un
  /// adjunto que no se pudo leer y se manda igual se convierte en un 400 que no
  /// explica nada.
  Future<Map<String, String>> toPromptFile() async {
    final bytes = await File(uri).readAsBytes();
    final tipo = mime ?? 'application/octet-stream';
    return {
      'uri': 'data:$tipo;base64,${base64Encode(bytes)}',
      'name': name,
      'mime': tipo,
    };
  }
}

class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.working,
    required this.canSend,
    this.modelLabel,
    this.agentLabel,
    this.contextLabel = '',
    this.attachments = const <ComposerAttachment>[],
    this.onSend,
    this.onStop,
    this.onAttach,
    this.onDictate,
    this.onRemoveAttachment,
    this.onPickModel,
    this.onPickAgent,
    this.suggestions = const <ComposerSuggestion>[],
    this.suggestionsLoading = false,
    this.controller,
    this.onCommand,
    this.onLocalAction,
    this.onTrigger,
  });

  /// Hay un turno en curso: el botón derecho pasa a Detener.
  final bool working;

  /// Hay algo que mandar (texto o adjuntos). El composer lo calcula solo desde
  /// el texto, pero el shell puede pisarlo (p.ej. mientras sube un adjunto).
  final bool canSend;

  /// `null` ⇒ todavía no se eligió modelo: el pill dice "Elegir modelo".
  final String? modelLabel;

  final String? agentLabel;

  /// `14.2k contexto · $0.38`, listo para pintar.
  final String contextLabel;

  final List<ComposerAttachment> attachments;

  /// Se dispara al mandar. `null` deja el botón inerte (view de sólo lectura).
  final void Function(String text, List<ComposerAttachment> files)? onSend;

  final VoidCallback? onStop;
  final VoidCallback? onAttach;
  final VoidCallback? onDictate;
  final ValueChanged<ComposerAttachment>? onRemoveAttachment;
  final VoidCallback? onPickModel;

  /// Abrir la hoja de agente. Antes no existia: el pill de agente
  /// usaba onPickModel y terminaba en la hoja de modelo, asi que no
  /// habia forma de elegir un agente.
  final VoidCallback? onPickAgent;

  /// Los ítems del menú de `/` y `@`, ya filtrados por lo escrito.
  ///
  /// Los carga el shell, no el compositor: el compositor no tiene cliente HTTP
  /// y no debe. Lo único que hace es detectar el disparador
  /// ([detectComposerTrigger]), filtrar lo que llega y pintar la lista.
  final List<ComposerSuggestion> suggestions;

  /// El menú se está armando (buscando archivos en el server). Se pinta una
  /// línea de "buscando" para que el menú no aparezca y desaparezca.
  final bool suggestionsLoading;

  /// El controller del input, si el shell quiere escribir en él.
  ///
  /// Es lo que hace posible un **deshacer** que devuelve al composer lo que el
  /// usuario había escrito: el shell lo revierte en el server y empuja el texto
  /// de vuelta por acá. Sin este parámetro el texto se perdía con el mensaje.
  ///
  /// `null` (lo normal) deja que el composer use el suyo. Si viene de afuera,
  /// el shell es quien lo `dispose()`a.
  final TextEditingController? controller;

  /// Se eligió un **comando del server**: `POST /api/session/{id}/command`
  /// con [name] **sin barra** y [args] como texto.
  final void Function(String name, String args)? onCommand;

  /// Se eligió una **acción local** (`compact`, deshacer, rehacer). No viaja al
  /// server como comando: cada una tiene su endpoint y su semántica.
  final void Function(String id, String args)? onLocalAction;

  /// Avisa que cambió el disparador bajo el cursor (o que se cerró el menú).
  ///
  /// Es la ida del menú: el compositor detecta **qué** se está escribiendo y
  /// la vista carga **qué** hay para ofrecer. La separación es a propósito: el
  /// compositor no tiene cliente HTTP, y meterlo lo convertiría en un widget
  /// que además de pintar pide 438 KB de skills.
  final ValueChanged<ComposerTrigger?>? onTrigger;

  /// Tope del campo. `20000` es el del prototipo; el server corta el prompt con
  /// 413 antes, así que es sólo una guarda visual.
  static const int charLimit = 20000;

  /// El dictado es es-ES porque la app es en español; el layer
  /// chat.composer.mic se dibuja con el texto Dictar por voz (es-ES).
  /// Si el dispositivo no tiene ese modelo instalado, initialize falla y
  /// el boton lo dice en vez de quedarse mudo.
  static const String kDictationLocale = 'es_ES';

  /// 5 líneas es el máximo del `textarea` del prototipo (`max-height:98px` con
  /// `line-height:19.5px`).
  static const int maxLines = 5;

  static const Key inputKey = Key('composer-input');
  static const Key sendKey = Key('composer-send');
  static const Key modelPillKey = Key('composer-model-pill');
  static const Key agentPillKey = Key('composer-agent-pill');
  static const Key attachKey = Key('composer-attach');
  static const Key micKey = Key('composer-mic');
  static const Key attachmentsKey = Key('composer-attachments');
  static const Key suggestionsKey = Key('composer-suggestions');
  static const Key suggestionItemKey = Key('composer-suggestion-item');
  static const Key suggestionEmptyKey = Key('composer-suggestion-empty');

  /// El thumb del adjunto [i]. Por indice, no por `ValueKey(archivo)`: dos
  /// tandas pueden traer el mismo nombre y el test necesita poder afirmar "hay
  /// 6" y "el septimo no existe", que es justo lo que se rompió cuando el
  /// Clip solo dejaba elegir una foto.
  static Key attachmentThumbKey(int i) => Key('composer-attachment-$i');

  /// Los tres nombres de acción local, sin barra. Ver [kLocalActions] para por
  /// qué existen aunque el server no los anuncie.
  static const String kSlashCompact = 'compact';
  static const String kSlashUndo = 'undo';
  static const String kSlashRedo = 'redo';

  /// Las tres acciones que el server **no** anuncia pero que existen como
  /// endpoint, y que el usuario pidió poder escribir con barra.
  ///
  /// Medido: `GET /api/command` devuelve `init`, `review` y `debate`, y
  /// `POST /api/session/{id}/command` con `compact` / `undo` / `redo` responde
  /// **404**. No son comandos: son `POST /compact` y
  /// `POST /revert/stage` + `/revert/commit`, que la app ya tenía en el action
  /// sheet. Aparecen en el menú como [ComposerSuggestionKind.action] y por eso
  /// viajan con `runCommand: null`.
  static const List<String> kLocalActions = [
    kSlashCompact,
    kSlashUndo,
    kSlashRedo,
  ];

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  final TextEditingController _own = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// El controller con el que se pinta el input.
  ///
  /// Si el shell pasó uno ([ChatComposer.controller]), ése manda: es el canal
  /// por el que un **deshacer** devuelve al input lo que el usuario había
  /// escrito. Antes no existía, y deshacar un mensaje lo borraba del server y
  /// con él el texto, sin dejar de dónde recuperarlo.
  ///
  /// Cuando es externo **no** se.dispose() acá: el dueño es quien lo creó. Un
  /// `dispose` doble sobre el mismo controller revienta el `ChangeNotifier` con
  /// el listener del `TextField` todavía colgado.
  TextEditingController get _controller => widget.controller ?? _own;

  /// El motor de dictado. Se crea acá y no como campo final para poder
  /// inyectarlo en un test sin el plugin nativo.
  final SpeechToText _speech = SpeechToText();
  bool _speechReady = false;
  bool _dictating = false;

  @override
  void dispose() {
    if (widget.controller == null) _own.dispose();
    _focus.dispose();
    // Dejar el microfono abierto al salir de la pantalla del chat
    // deja el servicio de dictado escuchando en el vacio.
    _speech.stop();
    super.dispose();
  }

  /// El dictado por voz vive acá y no en la vista porque el que tiene que
  /// escribir el texto reconocido es el `TextEditingController` del composer.
  /// Si la vista lo manejara, el textohoveríalostres campos o habría que
  /// inventar un canal de "escribí esto en el input".
  ///
  /// El botón queda **inerte con motivo visible** si el server de dictado no
  /// está disponible (Android 11+ sin `<queries>`, sin modelo de idioma, sin
  /// permiso): un icono que no hace nada es peor que uno que dice por qué.
  Future<void> _toggleDictation() async {
    if (_dictating) {
      await _speech.stop();
      return;
    }
    if (!_speechReady) {
      _speechReady = await _speech.initialize(
        onError: (e) =>
            _reportDictation('No se pudo iniciar el dictado: ${e.errorMsg}'),
        onStatus: (s) {
          // `notListening` con resultado vacío es el fin normal del dictado por
          // voz en Android; sin esto se queda pensando que sigue escuchando.
          if (s == 'done' || s == 'notListening') _endDictation();
        },
      );
      if (!_speechReady) {
        _reportDictation(
          'Este dispositivo no tiene dictado por voz disponible.',
        );
        return;
      }
    }
    await _speech.listen(
      localeId: ChatComposer.kDictationLocale,
      onResult: (r) {
        setState(() {
          _controller.text = r.recognizedWords;
          _controller.selection = TextSelection.collapsed(
            offset: _controller.text.length,
          );
        });
        if (r.finalResult) _endDictation();
      },
    );
    if (mounted) setState(() => _dictating = true);
  }

  void _endDictation() {
    if (!_dictating) return;
    setState(() => _dictating = false);
  }

  void _reportDictation(String message) {
    _endDictation();
    if (mounted)
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(message)));
  }

  bool get _canSend =>
      widget.canSend &&
      (_controller.text.trim().isNotEmpty || widget.attachments.isNotEmpty);

  /// El disparador bajo el cursor, o `null` si el menú está cerrado.
  ///
  /// Se recalcula en cada cambio del texto, no en cada tecla: el `onChanged`
  /// de un `TextField` es la única señal fiable de dónde quedó el cursor, y
  /// leer `_controller.selection` desde un `Listener` de teclado llega antes de
  /// que el texto esté actualizado, con la posición vieja.
  ComposerTrigger? _trigger;

  /// Los ítems ya filtrados, con el primero como seleccionado.
  int _highlight = 0;

  /// El menú se abre para `/` y para `@`, pero **no se reabre** cuando el
  /// comando ya está elegido y hay argumentos en camino. Sin esto, elegir
  /// `/compact` reabriera el menú y el Enter quedaba atrapado en un ciclo
  /// completar → reabrir → completar: había que apretarlo dos o tres veces.
  ///
  /// La regla se apoya en [parseSlashCommand] y no en contar espacios a mano,
  /// para que el test pueda verificarla sin montar el árbol de widgets.
  bool get _menuOpen {
    final t = _trigger;
    if (t == null) return false;
    if (t.kind == ComposerTriggerKind.slash) {
      // "/compact" se completa; "/compact foco" ya está elegido y se cierra.
      final text = _controller.text;
      if (text.startsWith('/') && text.contains(' ')) return false;
    }
    // Con algo que mostrar, el menú está. Sin nada, sólo se abre si hay una
    // consulta o si está cargando: un "Sin coincidencias" de la barra recién
    // tipeada, antes de que llegue la lista, sería un parpadeo que miente.
    if (widget.suggestions.isNotEmpty) return true;
    if (widget.suggestionsLoading) return true;
    return t.query.trim().isNotEmpty;
  }

  /// Reemplaza el disparador por lo elegido y deja el cursor atrás.
  void _accept(ComposerSuggestion s) {
    final t = _trigger;
    if (t == null) return;
    final text = _controller.text;
    final before = text.substring(0, t.start);
    final after = text.substring(t.end);
    final ins = '${s.insertion} ';
    final next = '$before$ins$after';
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: before.length + ins.length),
    );
    setState(() {
      _trigger = null;
      _highlight = 0;
    });
  }

  /// Manda el texto. Si es un comando de barra completo, lo **corre** en vez de
  /// mandarlo como prompt: `/review` no es un mensaje que el modelo lee, es una
  /// orden para el server (medido: `POST /api/session/{id}/command` devuelve
  /// 204 y el trabajo corre como un turno).
  ///
  /// Con el turno en curso y **algo escrito**, manda igual y deja que el shell lo
  /// ponga en cola (`ChatViewModel.send` → `pendingSend`), en vez de eliminar
  /// el mensaje. Es lo único que hace alcanzable ese camino: si el botón fuera
  /// siempre Detener, el usuario no podría dejar escrito el mensaje siguiente
  /// y el modelo lo vería solo cuando terminara el turno.
  ///
  /// Con el input vacío sigue siendo Detener, que es su atajo de un toque.
  void _submit() {
    if (widget.working && !_canSend) {
      widget.onStop?.call();
      return;
    }
    if (!_canSend) return;
    final text = _controller.text.trim();
    if (widget.attachments.isNotEmpty) {
      widget.onSend?.call(text, widget.attachments);
      _controller.clear();
      return;
    }

    final command = parseSlashCommand(text);
    if (command != null) {
      final taken = _dispatchSlash(command.name, command.args);
      // Si nadie lo recibe (shell de sólo lectura), cae al prompt normal en
      // vez de perder el texto: un comando que se traga solo es peor.
      if (taken) {
        _controller.clear();
        return;
      }
    }

    widget.onSend?.call(text, widget.attachments);
    _controller.clear();
  }

  /// Enruta un comando a su destino. Devuelve `true` si alguien lo recibió.
  ///
  /// Dos callbacks y no uno con un prefijo mágico: la diferencia entre "esto lo
  /// corre el server" y "esto lo corre la app" es exactamente la que se rompió
  /// al mandar `/compact` por el endpoint de comandos (404, medido).
  bool _dispatchSlash(String name, String args) {
    if (_isLocalAction(name)) {
      if (widget.onLocalAction == null) return false;
      widget.onLocalAction!(name, args);
      return true;
    }
    if (widget.onCommand == null) return false;
    widget.onCommand!(name, args);
    return true;
  }

  /// Si el nombre es una de las tres acciones locales.
  ///
  /// Va por [kLocalActions] y no por una cadena suelta porque el menú y el
  /// despacho tienen que estar de acuerdo: si el menú ofrece `/compact` y el
  /// despacho no lo reconoce, el comando se mandaría como prompt al modelo.
  /// La lista vive en la clase para que no haya dos fuentes de verdad.
  static bool _isLocalAction(String name) =>
      ChatComposer.kLocalActions.contains(name);

  /// Reabre el menú cuando el cursor vuelve sobre un disparador vivo: sin esto,
  /// mover el cursor a la izquierda de un `/review` a medio escribir lo dejaba
  /// cerrado sin forma de completarlo.
  void _onTextChanged() {
    final caret = _controller.selection.baseOffset;
    final next = caret < 0
        ? null
        : detectComposerTrigger(_controller.text, caret);
    final same =
        next?.kind == _trigger?.kind &&
        next?.start == _trigger?.start &&
        next?.query == _trigger?.query;
    if (same) {
      setState(() {});
      return;
    }
    setState(() {
      _trigger = next;
      _highlight = 0;
    });
    // Se avisa **siempre**, y no sólo cuando cambia: la vista carga en async y
    // necesita re-preguntar aunque el disparador sea el mismo. Sin esto, abrir
    /// `/`, cerrarlo con la flecha y volver a abrirlo no recarga nada.
    widget.onTrigger?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasText =
        _controller.text.trim().isNotEmpty || widget.attachments.isNotEmpty;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outline)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.sm,
            AppSpacing.sm,
            AppSpacing.sm,
            AppSpacing.xs,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.attachments.isNotEmpty) _attachmentStrip(),
              if (_menuOpen) _suggestionList(),
              _inputRow(scheme, hasText),
              const SizedBox(height: AppSpacing.sm),
              _modelBar(scheme),
            ],
          ),
        ),
      ),
    );
  }

  /// `chat.composer.attachments`: thumbs de 44 px con la `x` de quitar.
  Widget _attachmentStrip() {
    return LayerGate(
      'chat.composer.attachments',
      child: Padding(
        key: ChatComposer.attachmentsKey,
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: widget.attachments.length,
            separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
            itemBuilder: (context, i) => KeyedSubtree(
              key: ChatComposer.attachmentThumbKey(i),
              child: _thumb(widget.attachments[i]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _thumb(ComposerAttachment attachment) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: AppRadius.mdAll,
            border: Border.all(color: scheme.outline),
          ),
          child: Center(
            child: AppIcon(
              attachment.mime?.startsWith('image/') ?? false ? 'image' : 'file',
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Positioned(
          top: -5,
          right: -5,
          child: Material(
            color: scheme.surfaceContainer,
            clipBehavior: Clip.antiAlias,
            shape: CircleBorder(side: BorderSide(color: scheme.outlineVariant)),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => widget.onRemoveAttachment?.call(attachment),
              child: const SizedBox(
                width: 16,
                height: 16,
                child: Center(child: AppIcon('x', size: 12)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// `chat.composer.input`: contenedor `surface-strong`, radio 16, mínimo 44 px.
  Widget _inputRow(ColorScheme scheme, bool hasText) {
    return LayerGate(
      'chat.composer.input',
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.fromLTRB(4, 6, 6, 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.outline),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            LayerGate(
              'chat.composer.attach',
              child: AppIconButton(
                key: ChatComposer.attachKey,
                icon: 'paperclip',
                tooltip: 'Adjuntar fotos (Ctrl+V pega imágenes)',
                onPressed: widget.onAttach,
                size: 20,
                tapSize: 32,
              ),
            ),
            Expanded(
              child: CallbackShortcuts(
                bindings: <ShortcutActivator, VoidCallback>{
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () {
                    if (_menuOpen) _move(1);
                  },
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () {
                    if (_menuOpen) _move(-1);
                  },
                },
                child: TextField(
                  key: ChatComposer.inputKey,
                  controller: _controller,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: ChatComposer.maxLines,
                  onChanged: (_) => _onTextChanged(),
                  onSubmitted: (_) => _submit(),
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  style: const TextStyle(fontSize: 13, height: 1.5),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                      vertical: 6,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    hintText: 'Escribe un mensaje...',
                  ),
                ),
              ),
            ),
            LayerGate(
              'chat.composer.mic',
              child: AppIconButton(
                key: ChatComposer.micKey,
                icon: 'mic',
                tooltip: 'Dictar por voz (es-ES)',
                onPressed: _toggleDictation,
                color: _dictating
                    ? Theme.of(context).colorScheme.primary
                    : _mutedStrong(context),
                size: 20,
                tapSize: 32,
              ),
            ),
            _sendButton(scheme, hasText),
          ],
        ),
      ),
    );
  }

  /// El menú de `/` y `@`, arriba del campo.
  ///
  /// Sin `LayerGate` propio a propósito: `assets/spec/layers.json` tiene 94 keys
  /// y agregar una sería inventar contrato. Va dentro de `chat.composer`, que es
  /// la superficie de la que forma parte — y que está encendida.
  ///
  /// Altura máxima de 4 filas (~148 px): con más, el menú tapaba el chat, que
  /// es justo lo que se está escribiendo.
  Widget _suggestionList() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final items = widget.suggestions;
    final at = _trigger?.kind == ComposerTriggerKind.at;

    return Container(
      key: ChatComposer.suggestionsKey,
      constraints: const BoxConstraints(maxHeight: 148),
      margin: const EdgeInsets.only(bottom: AppSpacing.xs),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: Text(
                  widget.suggestionsLoading
                      ? 'Buscando…'
                      : at
                      ? 'Sin coincidencias'
                      : 'Sin coincidencias',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          : ListView.builder(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              itemCount: items.length,
              itemBuilder: (context, i) {
                final s = items[i];
                final sel = i == _highlight;
                return InkWell(
                  key: i == 0
                      ? ChatComposer.suggestionItemKey
                      : ValueKey('composer-suggestion-$i'),
                  onTap: () => _accept(s),
                  child: Container(
                    color: sel ? _hover(context) : null,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        AppIcon(
                          _iconFor(s.kind),
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                s.insertion,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (s.detail.isNotEmpty)
                                Text(
                                  s.detail,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  /// El glifo de cada tipo. Todos existen en `assets/icons`: se agrega un SVG
  /// nuevo sólo si de verdad no hay ninguno que sirva, y para cinco tipos hay.
  static String _iconFor(ComposerSuggestionKind kind) => switch (kind) {
    ComposerSuggestionKind.command => 'sparkles',
    ComposerSuggestionKind.action => 'history',
    ComposerSuggestionKind.agent => 'user',
    ComposerSuggestionKind.skill => 'sparkles',
    ComposerSuggestionKind.file => 'file',
    ComposerSuggestionKind.mcp => 'layers',
  };

  /// `--surface-hover`, leído de los tokens según el brillo.
  ///
  /// Vive en `_AppPalette`, que es privado de `theme.dart`, así que se lee de
  /// `AppColors` como hace [_mutedStrong] en este mismo archivo. Meter un
  /// `ThemeExtension` por un solo color sería más ceremonia que el color.
  static Color _hover(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? AppColors.darkSurfaceHover
      : AppColors.lightSurfaceHover;

  /// Mueve el resaltado del menú, dando la vuelta en los extremos.
  ///
  /// Un ítem de más de uno elige: 8 filas y una pantalla, la lista no se
  /// desplaza sola porque `ListView.builder` con `shrinkWrap` no sabe el alto
  /// del highlight.
  void _move(int delta) {
    final n = widget.suggestions.length;
    if (n == 0) return;
    setState(() => _highlight = (_highlight + delta) % n);
  }

  /// `chat.composer.send`: 32 px, círculo. filled `primary` cuando hay algo que
  /// mandar, apagado cuando no, y `danger` + `stop` mientras el turno corre
  /// **con el input vacío**.
  Widget _sendButton(ColorScheme scheme, bool hasText) {
    // Mientras el turno corre el botón es de dos cosas según haya texto:
    // vacío = **Detener**, con algo escrito = **encolar**. Antes era siempre
    // Detener, y entonces el camino del mensaje en cola era inalcanzable desde
    // la UI: `ChatViewModel.send` sabe encolar (`pendingSend`) pero nada lo
    // llamaba, porque el composer no dejaba mandar con el turno vivo.
    //
    // Detener sigue estando a un toque: con el input vacío el botón es el
    // de.stop.
    final encola = widget.working && _canSend;
    final detiene = widget.working && !encola;
    // `--danger` del prototipo: el botón de Detener es el único elemento de
    // color de la pantalla, así que tiene que ser el rojo de la maqueta y no
    // el gris del chrome.
    final danger = AppColors.diffDelOf(Theme.of(context).brightness);
    final background = detiene
        ? danger
        : (_canSend ? scheme.primary : scheme.surfaceContainerHighest);
    final foreground = detiene
        // `.sendbtn.stop{color:#fff}`, también en oscuro.
        ? AppColors.lightOnPrimary
        : (_canSend ? scheme.onPrimary : scheme.onSurfaceVariant);
    final etiqueta = encola
        ? 'Enviar en cola'
        : (detiene ? 'Detener' : 'Enviar');
    return Semantics(
      button: true,
      label: etiqueta,
      child: Tooltip(
        message: etiqueta,
        child: Material(
          key: ChatComposer.sendKey,
          color: background,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _submit,
            child: SizedBox(
              width: 32,
              height: 32,
              child: Center(
                child: AppIcon(
                  // El icono sigue al estado, no al turno: `stop` solo cuando
                  // el botón efectivamente detiene.
                  detiene ? 'stop' : 'send',
                  size: 16,
                  color: foreground,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// `chat.composer.modelbar`: pill de modelo, pill de agente, y el contexto a
  /// la derecha. El chip TSL y el contador de caracteres cuelgan acá, apagados.
  ///
  /// `.modelbar` (:364) mete 4 px de padding lateral: la barra se sangra 4 px
  /// respecto de la caja de texto, y no se veía porque acá no había padding.
  Widget _modelBar(ColorScheme scheme) {
    return LayerGate(
      'chat.composer.modelbar',
      child: SizedBox(
        height: 26,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Row(
            children: [
              LayerGate(
                'chat.composer.model',
                child: _Pill(
                  pillKey: ChatComposer.modelPillKey,
                  icon: 'cpu',
                  label: widget.modelLabel ?? 'Elegir modelo',
                  onTap: widget.onPickModel,
                ),
              ),
              const SizedBox(width: 6),
              LayerGate(
                'chat.composer.agent',
                child: _Pill(
                  pillKey: ChatComposer.agentPillKey,
                  icon: 'user',
                  label: widget.agentLabel ?? 'Elegir agente',
                  onTap: widget.onPickAgent,
                ),
              ),
              // Apagado en la spec aprobada: existe el widget para que el toggle
              // de Ajustes lo pueda prender sin tocar el composer.
              const LayerGate('chat.composer.tsl', child: _TslChip()),
              const Spacer(),
              LayerGate(
                'chat.composer.counter',
                child: _Counter(text: _controller.text),
              ),
              LayerGate(
                'chat.composer.ctx',
                child: Text(
                  widget.contextLabel,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `--muted-strong` del prototipo: un gris más oscuro que `--muted`, que es lo
/// que usan `.cbtn`, `.mpill` y los rótulos en mayúsculas.
Color _mutedStrong(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? AppColors.darkMutedStrong
    : AppColors.lightMutedStrong;

/// Pill de 24 px con glifo 12 (`chat.composer.model` / `.agent`).
///
/// `.mpill` (:365-370): 24 px de alto, 132 px como máximo, `--surface-strong`,
/// borde `--border`, 11 px en `--muted-strong`. La altura fija es lo que
/// faltaba: sin ella el pill medía lo que midiera su texto y la barra de modelo
/// no alineaba con la fila de arriba.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.pillKey,
    required this.icon,
    required this.label,
    this.onTap,
  });

  final Key pillKey;
  final String icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mutedStrong = _mutedStrong(context);
    return Material(
      color: scheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outline),
      ),
      child: InkWell(
        key: pillKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 24,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(icon, size: 12, color: mutedStrong),
                const SizedBox(width: 5),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 132),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: mutedStrong),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `chat.composer.tsl`. Apagado por diseño; se construye igual para que la
/// capa exista como un solo lugar.
class _TslChip extends StatelessWidget {
  const _TslChip();

  @override
  Widget build(BuildContext context) => Container(
    height: 24,
    alignment: Alignment.center,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    margin: const EdgeInsets.only(left: 6),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Theme.of(context).colorScheme.outline),
      color: Theme.of(context).colorScheme.surfaceContainer,
    ),
    // `.tsl` (:372): 11 px w700 en `--muted`. Sin color explícito heredaba el
    // `--text` del tema y el chip apagado se leía como texto normal.
    child: Text(
      'TSL',
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: _mutedStrong(context),
      ),
    ),
  );
}

/// `chat.composer.counter`. Apagado por diseño (idéntico criterio que el TSL).
class _Counter extends StatelessWidget {
  const _Counter({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    '${text.characters}/${ChatComposer.charLimit}',
    style: TextStyle(
      fontSize: 11,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}
