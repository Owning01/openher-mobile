import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/data/connectivity/network_monitor.dart';

/// El modo de bajo consumo se activa **sólo** con datos móviles. Estos tests
/// fijan esa regla: no es un ajuste que haya que acordar a mano, es el tipo de
/// red el que lo dispara.
void main() {
  group('clasificación de red', () {
    test('sólo mobile activa el modo bajo', () {
      expect(DataPolicy.forNetwork(NetworkKind.mobile).onCellular, isTrue);
      expect(DataPolicy.forNetwork(NetworkKind.wifi).onCellular, isFalse);
      expect(DataPolicy.forNetwork(NetworkKind.ethernet).onCellular, isFalse);
      expect(DataPolicy.forNetwork(NetworkKind.other).onCellular, isFalse);
      expect(DataPolicy.forNetwork(NetworkKind.none).onCellular, isFalse);
    });

    test('con varias redes a la vez, manda la prioritaria', () {
      expect(
        NetworkMonitor.classifyForTest(const [
          NetworkKind.wifi,
          NetworkKind.mobile,
        ]),
        NetworkKind.mobile,
        reason: 'hotspot: cellular gana',
      );
      expect(
        NetworkMonitor.classifyForTest(const [
          NetworkKind.ethernet,
          NetworkKind.wifi,
        ]),
        NetworkKind.wifi,
      );
      expect(NetworkMonitor.classifyForTest(const []), NetworkKind.none);
    });
  });

  group('política de bajo consumo', () {
    test('con datos móviles: sin streaming, poll lento, página chica', () {
      const p = DataPolicy.lowData();
      expect(p.streamingEnabled, isFalse);
      expect(p.imagesEnabled, isFalse);
      expect(p.pageSize, lessThan(DataPolicy.normal().pageSize));
      expect(p.pollInterval, greaterThan(DataPolicy.normal().pollInterval));
    });

    test('normal: streaming, imágenes, poll corto', () {
      const p = DataPolicy.normal();
      expect(p.streamingEnabled, isTrue);
      expect(p.imagesEnabled, isTrue);
      expect(p.pageSize, 30);
      expect(p.pollInterval, const Duration(seconds: 2));
    });
  });

  test('onCellular es exactamente mobile', () {
    // El caso que se cuelga: un hotspot marcado como medido no debe activar el
    // modo, y un ethernet con datos tampoco.
    final m = NetworkMonitor();
    m.debugSetKind(NetworkKind.ethernet);
    expect(m.onCellular, isFalse);
    m.debugSetKind(NetworkKind.mobile);
    expect(m.onCellular, isTrue);
    m.debugSetKind(NetworkKind.wifi);
    expect(m.onCellular, isFalse);
  });
}
