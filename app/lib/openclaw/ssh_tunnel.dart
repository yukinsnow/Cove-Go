import 'dart:async';

import '../remote/ssh/local_forward.dart';
import '../remote/ssh/ssh_transport.dart';

/// Forwards an already-running Gateway, never starts a DSH engine.
class GatewaySshTunnel {
  SshTransport? _transport;
  LocalForwarder? _forward;
  int _revision = 0;

  Future<String> open(
    String address,
    SshConnectParams params,
    HostKeyCheck check, {
    SshTransportFactory factory = DartSshTransport.connect,
  }) async {
    await close();
    final revision = _revision;
    final target = Uri.parse(address);
    // TLS certificates belong to the remote hostname, not the phone's loopback.
    // SSH already encrypts the connection to a loopback-only ws Gateway.
    if (target.scheme != 'ws' || target.host.isEmpty) {
      throw const FormatException('SSH Gateway address must use ws://host:port');
    }
    final transport = await factory(params, check);
    if (revision != _revision) {
      transport.close();
      throw StateError('SSH connection cancelled');
    }
    _transport = transport;
    try {
      var timedOut = false;
      final pending = transport.openTunnel(target.host, target.hasPort ? target.port : 80);
      unawaited(
        pending.then((channel) {
          if (timedOut) channel.destroy();
        }, onError: (Object _) {}),
      );
      final probe = await pending.timeout(
        const Duration(seconds: 12),
        onTimeout: () {
          timedOut = true;
          throw TimeoutException('Gateway SSH tunnel');
        },
      );
      probe.destroy();
      final forward = await LocalForwarder.bind(
        () => transport.openTunnel(target.host, target.hasPort ? target.port : 80).timeout(const Duration(seconds: 12)),
      );
      if (revision != _revision) {
        await forward.close();
        throw StateError('SSH connection cancelled');
      }
      _forward = forward;
      return target.replace(host: '127.0.0.1', port: forward.port).toString();
    } catch (_) {
      if (revision == _revision) await close();
      rethrow;
    }
  }

  Future<void> close() async {
    _revision++;
    final forward = _forward;
    _forward = null;
    _transport?.close();
    _transport = null;
    await forward?.close();
  }
}
