/// La caja de actividad del **turno**, agrupada: un prompt del usuario genera
/// varios mensajes del assistant (uno por tramo de herramientas) y sin agrupar
/// cada uno pintaba su propia caja, así que el chat se llenaba de líneas
/// sueltas. Acá se junta el razonamiento + las tools de todo el turno en una
/// sola caja, que se monta en el primer mensaje del turno, debajo del prompt
/// del usuario: `[user] [caja] [mensajes del turno…]`.
///
/// Es el mismo algoritmo del cliente React
/// (`web/src/utils/turnActivity.ts` en opencode-remote-android), que es de
/// donde salió el agrupado. Las dos diferencias son deliberadas:
///
/// * acá no hay `visibleIDs`: el chat de Android pinta todos los mensajes de
///   la lista, así que "visible" es siempre `true`.
/// * no hay `summaryDiffs` ni `intermediateTexts`: el dialecto v2 de este
///   cliente no trae diffs en el mensaje y los textos intermedios se muestran
///   en su burbuja.
///
/// ## Cómo lo usa la UI
///
/// `chat_view` calcula el agrupado **una vez por build** (es O(n) sobre los
/// mensajes) y le pasa a cada [MessageBubble] lo que le toca:
///
/// ```dart
/// final turns = buildTurnActivities(messages);
/// // …dentro del itemBuilder:
/// MessageBubble(
///   message: message,
///   working: _vm.working,
///   turnActivity: turns[message.id],
///   absorbedActivity: turns.isAbsorbed(message.id),
/// );
/// ```
///
/// Sin eso, cada burbuja cae en su actividad propia: es el comportamiento
/// viejo (una caja por mensaje de assistant) y por eso existe esta función.
library;

import 'message.dart';

/// Lo que un turno hizo: su razonamiento, sus tools, y si sigue vivo.
///
/// Es un valor, no un widget: el agrupado es una función pura del dominio y la
/// caja de la UI sólo lo pinta. `lib/domain/models/` no depende de Flutter.
final class TurnActivity {
  const TurnActivity({
    required this.thinkingParts,
    required this.toolParts,
    required this.working,
    this.time,
  });

  /// El razonamiento del turno, en orden de aparición. Puede traer textos
  /// vacíos: el provider a veces los manda cifrados (`message.dart` lo dice).
  final List<AssistantReasoning> thinkingParts;

  /// Las tools del turno, en orden de aparición.
  final List<AssistantTool> toolParts;

  /// El turno sigue en curso: su último mensaje de assistant no cerró.
  final bool working;

  /// `time` del **último** assistant del turno. Sólo se usa para el resumen
  /// `N herramientas · X.Xs`: sin `completed` no hay duración que mentir.
  final MessageTime? time;

  /// Un turno sin tools ni razonamiento no tiene nada que mostrar: si fuerza
  /// una entrada, la caja sale vacía (una fila que sólo dice "Worked").
  bool get isEmpty => thinkingParts.isEmpty && toolParts.isEmpty;
}

/// El resultado del agrupado: qué mensaje posee la caja de su turno y qué
/// mensajes la cedieron.
///
/// La caja vive en **un** mensaje, así que la UI necesita las dos mitades: el
/// dueño pinta la caja y los absorbidos no. Sin el segundo conjunto, un mensaje
/// que no es dueño caería en el comportamiento viejo y volvería a pintar la
/// suya — que es exactamente el bug que vino a matar.
final class TurnActivities {
  const TurnActivities({required this.boxes, required this.absorbedIds});

  /// Caja de cada turno, por id del mensaje **dueño**.
  final Map<String, TurnActivity> boxes;

  /// Ids de los mensajes que cedieron su caja al dueño de su turno. Sólo
  /// assistant: los demás tipos (píldoras de sistema, resultados de shell) no
  /// pintan caja y no tienen nada que absorber.
  final Set<String> absorbedIds;

  /// La caja que le toca a `messageId`, o `null`.
  TurnActivity? operator [](String messageId) => boxes[messageId];

  /// ¿La caja de este mensaje quedó en otro mensaje del mismo turno?
  bool isAbsorbed(String messageId) => absorbedIds.contains(messageId);

  bool get isEmpty => boxes.isEmpty;
}

/// Agrupa los mensajes en turnos y devuelve una caja por turno.
///
/// Un mensaje del **usuario** cierra el turno anterior; los assistant y los
/// resultados de shell se acumulan en el turno que está corriendo. Al cerrar
/// un turno se juntan el razonamiento y las tools de **todos** sus mensajes, y
/// la caja se le asigna al **primer assistant del turno** (el que sigue al
/// prompt), saltándose los resultados de shell: la caja no debe vivir adentro
/// de una píldora de comando.
///
/// Los turnos sin tools ni razonamiento no producen entrada, así que sus
/// mensajes se pintan normales y no queda una caja vacía.
TurnActivities buildTurnActivities(List<SessionMessage> messages) {
  final boxes = <String, TurnActivity>{};
  final absorbed = <String>{};
  var turn = <SessionMessage>[];

  void flush() {
    final current = turn;
    turn = <SessionMessage>[];
    if (current.isEmpty) return;

    final thinking = <AssistantReasoning>[];
    final tools = <AssistantTool>[];
    final assistants = <AssistantMessage>[];
    for (final message in current) {
      if (message case final AssistantMessage assistant) {
        assistants.add(assistant);
        thinking.addAll(assistant.reasoningItems);
        tools.addAll(assistant.toolItems);
      }
    }
    // Sin assistant el turno no tiene dueño posible (sólo resultados de
    // shell), y sin dueño no hay dónde montar la caja.
    if (assistants.isEmpty) return;

    // El dueño es el PRIMER assistant del turno, no el que tiene tools: la
    // caja tiene que quedar estable arriba, en la burbuja que sigue al prompt,
    // y no saltar de burbuja en burbuja mientras el turno crece.
    final owner = assistants.first.id;
    // El cierre lo decide el último assistant del turno. Los resultados de
    // shell no traen `time.completed` ni `finish`: si contaran, dejarían la
    // caja "Trabajando" para siempre.
    final last = assistants.last;
    final activity = TurnActivity(
      thinkingParts: thinking,
      toolParts: tools,
      working: !last.isComplete,
      time: last.time,
    );
    // Sin nada que mostrar el turno no produce entrada: el mensaje se pinta
    // normal y no queda una caja vacía.
    if (activity.isEmpty) return;
    boxes[owner] = activity;
    for (final assistant in assistants) {
      if (assistant.id != owner) absorbed.add(assistant.id);
    }
  }

  for (final message in messages) {
    if (message is UserMessage) {
      flush();
      continue;
    }
    // Los assistant y los resultados de shell entran al turno que corre. Los
    // avisos (sistema, compactación, cambios de agente/modelo) no: no son
    // trabajo del modelo ni abren ni cierran un turno.
    if (message is AssistantMessage || message is ShellMessage) {
      turn.add(message);
    }
  }
  flush();

  return TurnActivities(boxes: boxes, absorbedIds: absorbed);
}
