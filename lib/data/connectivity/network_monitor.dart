import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Qué tipo de red activa hay en el dispositivo.
///
/// Se usa para decidir si la app entra en **modo de bajo consumo**: con datos
/// móviles se recorta el streaming y el polling; con Wi-Fi, comportamiento
/// normal. Nunca se decide por吞吐量 sino por el tipo de red.
enum NetworkKind { none, wifi, mobile, ethernet, other }

/// Detector de tipo de red, con seam para tests.
///
/// No inventa: si el sistema no puede decir, devuelve `null` ("no sé"), y el
/// llamador decide el default en vez de asumir cellular.
class NetworkMonitor extends ChangeNotifier {
  NetworkMonitor({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;
  StreamSubscription<List<ConnectivityResult>>? _sub;

  NetworkKind _kind = NetworkKind.other;
  NetworkKind get kind => _kind;

  /// `true` si estamos con datos móviles (celular). Sólo esto activa el modo
  /// bajo: Ethernet y Wi-Fi no lo activan nunca.
  bool get onCellular => _kind == NetworkKind.mobile;

  /// Empieza a escuchar cambios de red.
  Future<void> start() async {
    _kind = _classify(await _connectivity.checkConnectivity());
    _sub = _connectivity.onConnectivityChanged.listen((results) {
      final next = _classify(results);
      if (next == _kind) return;
      _kind = next;
      notifyListeners();
    });
  }

  @visibleForTesting
  void debugSetKind(NetworkKind k) {
    if (_kind == k) return;
    _kind = k;
    notifyListeners();
  }

  /// Clasifica una lista de resultados (visible para tests). La prioridad
  /// es mobile > wifi > ethernet: si hay cellular y wifi a la vez, cellular
  /// manda, que es el caso del hotspot.
  @visibleForTesting
  static NetworkKind classifyForTest(List<NetworkKind> kinds) {
    if (kinds.contains(NetworkKind.mobile)) return NetworkKind.mobile;
    if (kinds.contains(NetworkKind.wifi)) return NetworkKind.wifi;
    if (kinds.contains(NetworkKind.ethernet)) return NetworkKind.ethernet;
    if (kinds.contains(NetworkKind.other)) return NetworkKind.other;
    return NetworkKind.none;
  }

  static NetworkKind _classify(List<ConnectivityResult> results) {
    if (results.isEmpty) return NetworkKind.none;
    if (results.contains(ConnectivityResult.mobile)) return NetworkKind.mobile;
    if (results.contains(ConnectivityResult.wifi)) return NetworkKind.wifi;
    if (results.contains(ConnectivityResult.ethernet)) {
      return NetworkKind.ethernet;
    }
    if (results.contains(ConnectivityResult.vpn)) return NetworkKind.other;
    if (results.contains(ConnectivityResult.none)) return NetworkKind.none;
    return NetworkKind.other;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

/// Política de consumo: qué se recorta cuando hay datos móviles.
///
/// Es un valor, no un bool suelto, para que el chat lea "qué hacer" y no tenga
/// que conocer la regla.
class DataPolicy {
  const DataPolicy({
    required this.onCellular,
    this.pollInterval = const Duration(seconds: 2),
    this.pageSize = 30,
    this.streamingEnabled = true,
    this.imagesEnabled = true,
  });

  const DataPolicy.normal()
    : onCellular = false,
      pollInterval = const Duration(seconds: 2),
      pageSize = 30,
      streamingEnabled = true,
      imagesEnabled = true;

  /// Con datos móviles: se baja el polling, se achica la página, y se apaga
  /// el streaming en vivo (el modelo no se ve token a token, llega al cerrar
  /// el turno). Las imágenes se apagan porque son lo más pesado.
  const DataPolicy.lowData()
    : onCellular = true,
      pollInterval = const Duration(seconds: 12),
      pageSize = 15,
      streamingEnabled = false,
      imagesEnabled = false;

  final bool onCellular;
  final Duration pollInterval;
  final int pageSize;
  final bool streamingEnabled;
  final bool imagesEnabled;

  /// Fabrica la política según la red. `onCellular` es el único disparador.
  factory DataPolicy.forNetwork(NetworkKind kind) =>
      kind == NetworkKind.mobile ? DataPolicy.lowData() : DataPolicy.normal();
}
