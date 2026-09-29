import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/network/api_client.dart';
import '../../core/network/server_config.dart';
import 'network_monitor.dart';

/// Qué se sabe del server en este momento.
enum Reachability {
  /// Todavía no se probó. La UI no dice nada: no se avisa de algo que no se sabe.
  unknown,

  /// El server respondió.
  reachable,

  /// No hubo respuesta: sin Tailscale, server apagado, o host mal configurado.
  unreachable,
}

/// Detecta "no estás conectado a Tailscale" y sabe si el host es de Tailscale.
///
/// ## De dónde sale la señal
///
/// En Android **Tailscale se registra como VPN**, así que el sistema ya lo dice:
/// `connectivity_plus` devuelve `ConnectivityResult.vpn` mientras está arriba
/// (medido en un Xiaomi con Android 16: con Tailscale prendido hay un
/// `NetworkAgent` de VPN en `dumpsys connectivity`, y el ícono VPN del system
/// status bar). No hace falta ni ping ni adivinar.
///
/// ## Cuándo avisar
///
/// Sólo cuando se sabe que el server **no** responde **y** no hay VPN: ese es
/// el caso "no llegás a Tailscale". Si hay VPN y el server no responde, el
/// problema es otro (el server está caído) y el aviso de Tailscale sería
/// mentiroso, así que no se muestra.
class TailscaleMonitor extends ChangeNotifier {
  TailscaleMonitor({
    required this.config,
    required this.network,
    ApiClient? api,
    this.onCellular = false,
  }) : _api = api ?? ApiClient(config: config);

  final ServerConfig config;
  final NetworkMonitor network;
  final ApiClient _api;

  /// Con datos móviles el reintento se estira:Dead el server, cada probe es
  /// datos que el usuario no pidió gastar.
  bool onCellular;

  Reachability _reach = Reachability.unknown;
  Reachability get reachability => _reach;

  /// El sistema reporta una VPN activa. En Android eso **es** Tailscale (o
  /// cualquier otra VPN, que para este caso es lo mismo: sin VPN no hay
  /// tailnet).
  bool get vpnUp => network.vpnUp;

  /// El aviso que hay que mostrar, o `null` si no hay nada que avisar.
  ///
  /// Es la regla completa en un solo lugar, para que la UI no la reimplemente.
  String? get notice {
    if (_reach != Reachability.unreachable || vpnUp) return null;
    return looksLikeTailscale(config.host)
        ? 'Sin Tailscale no se llega al server'
        : 'No se puede llegar al server';
  }

  /// ¿El aviso **nombra** a Tailscale? Si el host no parece de Tailscale, el
  /// botón se ofrece igual (el usuario lo pidió y le sirve), pero el texto no
  /// culpa a Tailscale de un problema que puede ser otro.
  bool get blamesTailscale => looksLikeTailscale(config.host);

  Timer? _timer;
  bool _probing = false;

  /// Cada cuánto reintenta mientras el server no responde. Corto para que
  /// prender Tailscale se note al toque; largo con datos móviles.
  Duration get _retryEvery =>
      onCellular ? const Duration(seconds: 30) : const Duration(seconds: 10);

  Future<void> start() async {
    network.addListener(_onNetwork);
    unawaited(recheck());
  }

  void _onNetwork() {
    // Cambió la red: el alcance anterior ya no dice nada. Un probe de verdad,
    // no un salto a `unknown` queeria solo.
    unawaited(recheck());
  }

  /// Probea el server y reacomoda el timer.
  ///
  /// Se puede llamar las veces que haga falta: si hay un probe en vuelo, el
  /// nuevo se ignora, para no apilar requests cuando Tailscale se prende y
  /// apaga rápido.
  Future<void> recheck() async {
    if (_probing) return;
    _probing = true;
    final next = await _probe();
    _probing = false;
    if (next != _reach) {
      _reach = next;
      notifyListeners();
    }
    _retime();
  }

  Future<Reachability> _probe() async {
    try {
      // `probeServer` es `GET /api/location` con deadline corto: el mismo
      // chequeo que hace la pantalla de conectar, sin inventar otro endpoint.
      await _api.probeServer();
      return Reachability.reachable;
    } on Object {
      return Reachability.unreachable;
    }
  }

  /// El timer sólo corre mientras el server **no** responde: cuando todo anda,
  /// esta clase no genera ni un request.
  void _retime() {
    _timer?.cancel();
    _timer = null;
    if (_reach != Reachability.unreachable) return;
    _timer = Timer.periodic(_retryEvery, (_) => recheck());
  }

  @override
  void dispose() {
    _timer?.cancel();
    network.removeListener(_onNetwork);
    super.dispose();
  }

  // ------------------------------------------------------------- host tests

  /// ¿El host parece uno de Tailscale?
  ///
  /// Tres señales, todas medibles sin la app:
  /// - **IPv4 en `100.64.0.0/10`**: el bloque CGNAT que Tailscale usa para sus
  ///   direcciones de nodo.
  /// - **IPv6 que empieza con `fd7a:115c:a1e0`**: el ULA que Tailscale reparte.
  /// - **nombre que termina en `.ts.net`**: el dominio de MagicDNS.
  static bool looksLikeTailscale(String host) {
    final h = host.trim().toLowerCase();
    if (h.isEmpty) return false;
    if (h.endsWith('.ts.net')) return true;
    if (_inCgnat(h)) return true;
    return _isTailscaleUla(h);
  }

  /// `100.64.0.0/10` ⇒ el segundo octeto entre 64 y 127. Se parsean los cuatro
  /// octetos a mano: es un chequeo de prefijo, no una operación de red.
  static bool _inCgnat(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final octets = <int>[];
    for (final p in parts) {
      final v = int.tryParse(p);
      if (v == null || v < 0 || v > 255) return false;
      octets.add(v);
    }
    return octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127;
  }

  static bool _isTailscaleUla(String host) =>
      host.startsWith('fd7a:115c:a1e0:') || host == 'fd7a:115c:a1e0::/48';
}
