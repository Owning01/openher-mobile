import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Spinner rectangular de **8 cuadrados**.
///
/// Aparece en el chat mientras el agente está pensando, en lugar del punto
/// pulsante que había: en una pantalla de teléfono un punto del tamaño de una
/// coma se pierde entre el texto, y esta grilla se lee de un vistazo.
///
/// ## Por qué 8 cuadrados y no un `CircularProgressIndicator`
///
/// Un spinner circular de Android no compite con nada: es una animación
/// genérica. La grilla tiene forma de bloque de "pensando", se mantiene quieta
/// en su estructura (lo que se mueve es la luz, no la forma) y funciona igual
/// en claro y en oscuro sin cambiar de widget.
///
/// ## La animación
///
/// No gira: una grilla que rota marea. Lo que hace es una **onda de luz** que
/// recorre los 8 cuadrados en diagonal, como el "breathing" de los operadores.
/// La onda va en bucle infinito pero con un salto: cuando pasa del último al
/// primero el brillo cae a cero, así que el reinicio no se lee como un glitch.
class SquaresSpinner extends StatefulWidget {
  const SquaresSpinner({
    super.key,
    this.size = 8,
    this.gap = 3,
    this.color,
    this.squares = 8,
  });

  /// Lado de cada cuadrado en px.
  final double size;

  /// Separación entre cuadrados.
  final double gap;

  final Color? color;

  /// Cuántos cuadrados tiene la grilla. 8 = 4x2, que es lo que se pidió.
  final int squares;

  @override
  State<SquaresSpinner> createState() => _SquaresSpinnerState();
}

/// El período de un ciclo del spinner de cuadrados.
///
/// **1400 ms, y no se toca al alargar la luz del título** (que está en 2800,
/// ver `SessionsView.titleSweepPeriod`). Un spinner lento se lee como una app
/// colgada, y el spinner está justamente para decir lo contrario. La
/// sincronización que importa es la del lenguaje visual —una luz que trabaja—,
/// no que los tres indicadores duren lo mismo.
const Duration kSquaresSpinnerPeriod = Duration(milliseconds: 1400);

class _SquaresSpinnerState extends State<SquaresSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    // Un ciclo completo dura lo que la onda tarda en cruzar la grilla más un
    // descanso, para que el reinicio sea un fundido y no un corte.
    duration: kSquaresSpinnerPeriod,
  );

  @override
  void initState() {
    super.initState();
    _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = widget.color ?? scheme.onSurfaceVariant;
    final accent = scheme.primary;
    // La grilla en reposo es un **tinte del fondo**, no un gris translúcido.
    // Con alfa 0.22 sobre el color de superficie el contraste medido entre el
    // frente y la grilla era de 96 contra 70 de luminancia: la grilla pesaba más
    // de lo que debía y el color de acento no popsaba. Mezclando el fondo con
    // el gris la grilla se marca en los dos temas y el frente manda.
    final reposo = Color.lerp(scheme.surface, base, 0.34)!;
    final columns = math.max(1, (widget.squares / 2).round());
    final rows = (widget.squares / columns).ceil();

    return Semantics(
      label: 'Pensando',
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            // `Column` de `Row`s, no un `Row` de `Row`s: en un `Row` las filas
            // se separan con un `SizedBox` **horizontal** y la grilla quedaba
            // en una tira de 8 en línea en vez de 4x2.
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (var r = 0; r < rows; r++) ...<Widget>[
                  if (r > 0) SizedBox(height: widget.gap),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (var c = 0; c < columns; c++) ...<Widget>[
                        if (c > 0) SizedBox(width: widget.gap),
                        _square(reposo, accent, r * columns + c),
                      ],
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  /// Un cuadrado de la grilla, con el brillo que le toca.
  ///
  /// No es una onda sino un **cometa**: un frente de color de acento que salta
  /// de cuadrado en cuadrado y deja una estela apagada detrás. La primera
  /// versión usaba una onda con `d = head - index`, y con eso todo cuadrado
  /// *por delante* del frente salía en brillo pleno: la grilla se veía entera
  /// encendida y no se leía ningún movimiento (medido en los goldens).
  ///
  /// La cabeza **salta** de cuadrado, no se desliza entre dos. La distancia es
  /// **módulo `squares`**, no un `clamp`: con el módulo el final del ciclo y el
  /// principio dan la misma imagen, así que el salto del último cuadrado al
  /// primero no se ve, y además siempre hay exactamente un cuadrado al frente.
  /// Sin el módulo había cuadros donde los ocho quedaban apagados y en tema
  /// oscuro el spinner se desaparecía (también medido, en los goldens).
  Widget _square(Color reposo, Color accent, int index) {
    const wave = 2.6; // estela, en cantidad de cuadrados

    // La cabeza **salta** de cuadrado, no se desliza entre dos: se redondea al
    // entero más cercano. Con el frente continuo el cuadrado más brillo se
    // quedaba en ~0.72 en las fases intermedias (medido) y el spinner perdía el
    // pulso. Redondeado, siempre hay uno enplo y la lectura es de marquesina.
    final cabeza = (_c.value * widget.squares).round() % widget.squares;
    // 0 = el frente está acá; 1 = le falta uno; 7 = le falta toda la vuelta.
    final d = (cabeza - index + widget.squares) % widget.squares;
    final on = d == 0 ? 1.0 : (1.0 - d / wave).clamp(0.0, 1.0);

    final color = Color.lerp(reposo, accent, on)!;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(1.5),
        ),
      ),
    );
  }
}
