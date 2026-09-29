import 'package:flutter_test/flutter_test.dart';
import 'package:openher_mobile/core/network/api_client.dart';
import 'package:openher_mobile/core/network/server_config.dart';
import 'package:openher_mobile/data/connectivity/network_monitor.dart';
import 'package:openher_mobile/data/connectivity/tailscale_monitor.dart';
import 'package:openher_mobile/domain/models/errors.dart';

/// El aviso de Tailscale.
///
/// Lo que importa no es que el detector exista, sino que **no avise cuando no
/// debe**: un aviso mentiroso ("conectate a Tailscale") cuando el problema es
/// el server entrena al usuario a ignorar la banda.
///
/// El fake va acá y no en `test/support/` porque es el unico que lo usa, y una
/// carpeta con un archivo no es una carpeta.
class FakeApi extends ApiClient {
  FakeApi({required super.config, this.up = false});

  /// `true` = el server responde.
  bool up;

  @override
  Future<Map<String, dynamic>> probeServer() async {
    if (up) return <String, dynamic>{'directory': r'C:\x'};
    throw const NetworkError();
  }
}

void main() {
  const tailnet = ServerConfig(
    host: '100.101.102.103',
    port: 4098,
    username: 'opencode',
    password: 'p',
  );
  const lan = ServerConfig(
    host: '192.168.1.50',
    port: 4098,
    username: 'opencode',
    password: 'p',
  );

  TailscaleMonitor build(ServerConfig config, NetworkMonitor net, FakeApi api) =>
      TailscaleMonitor(config: config, network: net, api: api);

  group('reconoce un host de Tailscale', () {
    test('el bloque CGNAT 100.64.0.0/10', () {
      expect(TailscaleMonitor.looksLikeTailscale('100.64.0.1'), isTrue);
      expect(TailscaleMonitor.looksLikeTailscale('100.127.255.254'), isTrue);
      expect(TailscaleMonitor.looksLikeTailscale('100.101.102.103'), isTrue);
      // Bordes del bloque: uno afuera y uno adentro.
      expect(TailscaleMonitor.looksLikeTailscale('100.63.255.255'), isFalse);
      expect(TailscaleMonitor.looksLikeTailscale('100.128.0.0'), isFalse);
    });

    test('el dominio de MagicDNS', () {
      expect(TailscaleMonitor.looksLikeTailscale('mi-tail.ts.net'), isTrue);
      expect(TailscaleMonitor.looksLikeTailscale('SERVER.TS.NET'), isTrue);
    });

    test('el ULA de Tailscale', () {
      expect(
        TailscaleMonitor.looksLikeTailscale('fd7a:115c:a1e0::1'),
        isTrue,
      );
    });

    test('una IP de casa no es Tailscale', () {
      expect(TailscaleMonitor.looksLikeTailscale('192.168.1.50'), isFalse);
      expect(TailscaleMonitor.looksLikeTailscale('127.0.0.1'), isFalse);
      expect(TailscaleMonitor.looksLikeTailscale('10.0.0.4'), isFalse);
      expect(TailscaleMonitor.looksLikeTailscale('opencode.local'), isFalse);
      expect(TailscaleMonitor.looksLikeTailscale(''), isFalse);
    });

    test('un octeto invalido no lo hace Tailscale por casualidad', () {
      expect(TailscaleMonitor.looksLikeTailscale('100.64.0'), isFalse);
      expect(TailscaleMonitor.looksLikeTailscale('100.64.0.999'), isFalse);
      expect(TailscaleMonitor.looksLikeTailscale('100.64.0.abc'), isFalse);
    });
  });

  group('cuando avisa y cuando no', () {
    test('sin VPN y sin server: avisa y culpa a Tailscale', () async {
      final m = build(tailnet, NetworkMonitor(), FakeApi(config: tailnet));
      addTearDown(m.dispose);

      await m.recheck();

      expect(m.reachability, Reachability.unreachable);
      expect(m.notice, 'Sin Tailscale no se llega al server');
      expect(m.blamesTailscale, isTrue);
    });

    test('con VPN y sin server: NO avisa, porque el problema es otro', () async {
      final net = NetworkMonitor()..debugSetVpnUp(true);
      final m = build(tailnet, net, FakeApi(config: tailnet));
      addTearDown(m.dispose);

      await m.recheck();

      expect(m.reachability, Reachability.unreachable);
      expect(
        m.notice,
        isNull,
        reason: 'con VPN prendida el server caido no es cosa de Tailscale',
      );
    });

    test('sin VPN pero con server vivo: NO avisa', () async {
      final m = build(
        tailnet,
        NetworkMonitor(),
        FakeApi(config: tailnet, up: true),
      );
      addTearDown(m.dispose);

      await m.recheck();

      expect(m.reachability, Reachability.reachable);
      expect(m.notice, isNull);
    });

    test('todavia no se probó: no avisa de algo que no se sabe', () {
      final m = build(tailnet, NetworkMonitor(), FakeApi(config: tailnet));
      addTearDown(m.dispose);

      expect(m.reachability, Reachability.unknown);
      expect(m.notice, isNull);
    });

    test('un host que no es Tailscale avisa sin culparlo', () async {
      final m = build(lan, NetworkMonitor(), FakeApi(config: lan));
      addTearDown(m.dispose);

      await m.recheck();

      expect(m.notice, 'No se puede llegar al server');
      expect(m.blamesTailscale, isFalse);
    });

    test('prender Tailscale saca el aviso', () async {
      final net = NetworkMonitor();
      final m = build(tailnet, net, FakeApi(config: tailnet));
      addTearDown(m.dispose);

      await m.recheck();
      expect(m.notice, isNotNull);

      net.debugSetVpnUp(true);
      await m.recheck();

      expect(m.notice, isNull);
    });

    test('el server vuelve y el aviso se va', () async {
      final api = FakeApi(config: tailnet);
      final m = build(tailnet, NetworkMonitor(), api);
      addTearDown(m.dispose);

      await m.recheck();
      expect(m.notice, isNotNull);

      api.up = true;
      await m.recheck();

      expect(m.reachability, Reachability.reachable);
      expect(m.notice, isNull);
    });
  });

  group('el VPN se trackea aparte del tipo de red', () {
    test('con Tailscale y Wi-Fi, kind queda wifi y vpnUp en true', () {
      // Es el caso real: Tailscale levanta un VPN sobre el Wi-Fi. Si `vpnUp` se
      // derivara de `kind`, aca se perderia y la banda apareceria con Tailscale
      // prendido.
      final net = NetworkMonitor();
      net.debugSetKind(NetworkKind.wifi);
      net.debugSetVpnUp(true);
      addTearDown(net.dispose);

      expect(net.kind, NetworkKind.wifi);
      expect(net.vpnUp, isTrue);
    });
  });
}
