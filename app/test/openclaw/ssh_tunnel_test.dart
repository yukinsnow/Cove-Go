import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_app/openclaw/ssh_tunnel.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
import 'package:dsh_app/remote/ssh/ssh_host_config.dart';

import '../remote/support/fake_ssh.dart';

void main() {
  const config = SshHostConfig(id: 'gateway-ssh', name: 'Gateway SSH', host: 'server', user: 'me', gatewayOnly: true);
  final params = SshConnectParams.of(config, const SshSecrets(password: 'test'));
  test('legacy SSH remains DSH; Gateway ownership survives edits and reload', () {
    final json = config.toJson();
    expect(SshHostConfig.fromJson(json), config);
    expect(config.copyWith(name: 'renamed').gatewayOnly, isTrue);
    json.remove('gatewayOnly');
    expect(SshHostConfig.fromJson(json)!.gatewayOnly, isFalse);
  });
  test('Gateway SSH forwards its target without executing DSH commands', () async {
    final server = FakeSshServer();
    server.remote.pid = 42;
    server.remote.port = 18789;
    final tunnel = GatewaySshTunnel();
    final url = Uri.parse(
      await tunnel.open('ws://127.0.0.1:18789/gateway', params, (_) => true, factory: server.connect),
    );
    expect(url.host, '127.0.0.1');
    expect(url.port, isNot(18789));
    expect(url.path, '/gateway');
    expect(server.last.scripts, isEmpty);
    expect(server.last.tunnels, [('127.0.0.1', 18789)]);
    await tunnel.close();
    expect(server.last.isClosed, isTrue);
  });
  test('refused destination closes SSH and rejected host keys never forward', () async {
    final server = FakeSshServer();
    final tunnel = GatewaySshTunnel();
    await expectLater(
      tunnel.open('ws://127.0.0.1:18789', params, (_) => true, factory: server.connect),
      throwsA(isA<TunnelRefused>()),
    );
    expect(server.last.isClosed, isTrue);
    await expectLater(
      tunnel.open('ws://127.0.0.1:18789', params, (_) => false, factory: server.connect),
      throwsA(anything),
    );
    expect(server.transports, hasLength(1));
    await tunnel.close();
  });
}
