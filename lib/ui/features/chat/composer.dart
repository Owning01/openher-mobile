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

import 'package:flutter/material.dart';

import '../../core/app_icon.dart';
import '../../core/layer_gate.dart';
import '../../core/tokens.dart';

/// Un adjunto pendiente de enviar (`PromptFileAttachment`).
class ComposerAttachment {
  const ComposerAttachment({required this.name, required this.uri, this.mime});

  final String name;
  final String uri;
  final String? mime;

  /// `{'uri': …, 'name': …, 'mime': …}`, que es lo que espera
  /// `POST /api/session/{id}/prompt`.
  Map<String, String> toPromptFile() => {
    'uri': uri,
    'name': name,
    'mime': ?mime,
  };
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

  /// Tope del campo. `20000` es el del prototipo; el server corta el prompt con
  /// 413 antes, así que es sólo una guarda visual.
  static const int charLimit = 20000;

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

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _canSend =>
      widget.canSend &&
      (_controller.text.trim().isNotEmpty || widget.attachments.isNotEmpty);

  void _submit() {
    if (widget.working) {
      widget.onStop?.call();
      return;
    }
    if (!_canSend) return;
    final text = _controller.text.trim();
    widget.onSend?.call(text, widget.attachments);
    _controller.clear();
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
            itemBuilder: (context, i) => _thumb(widget.attachments[i]),
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
                tooltip: 'Adjuntar (Ctrl+V pega imágenes)',
                onPressed: widget.onAttach,
                size: 20,
                tapSize: 32,
                color: scheme.onSurfaceVariant,
              ),
            ),
            Expanded(
              child: TextField(
                key: ChatComposer.inputKey,
                controller: _controller,
                focusNode: _focus,
                minLines: 1,
                maxLines: ChatComposer.maxLines,
                onChanged: (_) => setState(() {}),
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
            LayerGate(
              'chat.composer.mic',
              child: AppIconButton(
                key: ChatComposer.micKey,
                icon: 'mic',
                tooltip: 'Dictar por voz (es-ES)',
                onPressed: widget.onDictate,
                size: 20,
                tapSize: 32,
                color: scheme.onSurfaceVariant,
              ),
            ),
            _sendButton(scheme, hasText),
          ],
        ),
      ),
    );
  }

  /// `chat.composer.send`: 32 px, círculo. filled `primary` cuando hay algo que
  /// mandar, apagado cuando no, y `danger` + `stop` mientras el turno corre.
  Widget _sendButton(ColorScheme scheme, bool hasText) {
    final danger = AppColors.diffDelOf(Theme.of(context).brightness);
    final background = widget.working
        ? danger
        : (_canSend ? scheme.primary : scheme.surfaceContainerHighest);
    final foreground = widget.working
        ? const Color(0xFFFFFFFF)
        : (_canSend ? scheme.onPrimary : scheme.onSurfaceVariant);
    return Semantics(
      button: true,
      label: widget.working ? 'Detener' : 'Enviar',
      child: Tooltip(
        message: widget.working ? 'Detener' : 'Enviar',
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
                  widget.working ? 'stop' : 'send',
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
  Widget _modelBar(ColorScheme scheme) {
    return LayerGate(
      'chat.composer.modelbar',
      child: SizedBox(
        height: 26,
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
                onTap: widget.onPickModel,
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
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pill de 24 px con glifo 12 (`chat.composer.model` / `.agent`).
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(icon, size: 12, color: scheme.onSurfaceVariant),
              const SizedBox(width: 5),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
    child: const Text(
      'TSL',
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
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
