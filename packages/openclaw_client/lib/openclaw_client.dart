/// OpenClaw Gateway protocol v4. No DSH bridge or shared-secret proxy required.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

String wireId() => List.generate(
  20,
  (_) => Random.secure().nextInt(256),
).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

class DeviceIdentity {
  DeviceIdentity(this.keyPair, this.publicKey);
  final SimpleKeyPair keyPair;
  final SimplePublicKey publicKey;
  String get id => sha256.convert(publicKey.bytes).toString();
  static Future<DeviceIdentity> create([String? seed]) async {
    final pair = seed == null
        ? await Ed25519().newKeyPair()
        : await Ed25519().newKeyPairFromSeed(base64Decode(seed));
    return DeviceIdentity(pair, await pair.extractPublicKey());
  }

  Future<String> exportSeed() async =>
      base64Encode(await keyPair.extractPrivateKeyBytes());
  Future<Map<String, dynamic>> sign(
    String nonce,
    int ts,
    String token,
    List<String> scopes,
  ) async {
    final payload = [
      'v3',
      id,
      'openclaw-ios',
      'ui',
      'operator',
      scopes.join(','),
      '$ts',
      token,
      nonce,
      'ios',
      '',
    ].join('|');
    final signature = await Ed25519().sign(
      utf8.encode(payload),
      keyPair: keyPair,
    );
    return {
      'id': id,
      'publicKey': _b64(publicKey.bytes),
      'signature': _b64(signature.bytes),
      'signedAt': ts,
      'nonce': nonce,
    };
  }
}

class GatewayException implements Exception {
  GatewayException(this.code, this.message, [this.details]);
  final String code, message;
  final dynamic details;
  @override
  String toString() => '$code: $message';
}

class GatewayClient {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <String, Completer<dynamic>>{};
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  bool connected = false;
  Stream<Map<String, dynamic>> get events => _events.stream;
  Map<String, dynamic> hello = {};
  static const scopes = [
    'operator.read',
    'operator.write',
    'operator.approvals',
    'operator.questions',
  ];

  Future<Map<String, dynamic>> connect(
    String address,
    String token,
    DeviceIdentity identity,
  ) async {
    await disconnect();
    final uri = Uri.parse(address.trim());
    if (!['wss', 'ws'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ArgumentError(
        'Use a wss:// Gateway URL without credentials or query parameters',
      );
    }
    if (uri.scheme == 'ws' &&
        !['localhost', '127.0.0.1', '::1'].contains(uri.host)) {
      throw ArgumentError('Remote Gateway connections require wss://');
    }
    final challenge = Completer<Map<String, dynamic>>();
    _socket = await WebSocket.connect(
      uri.toString(),
    ).timeout(const Duration(seconds: 15));
    _subscription = _socket!.listen(
      (raw) {
        try {
          final frame = Map<String, dynamic>.from(
            jsonDecode(raw as String) as Map,
          );
          if (frame['type'] == 'res') {
            final waiter = _pending.remove(frame['id']);
            if (waiter == null) return;
            if (frame['ok'] == true) {
              waiter.complete(frame['payload']);
            } else {
              final e = frame['error'] as Map? ?? {};
              waiter.completeError(
                GatewayException(
                  '${e['code'] ?? 'RPC_ERROR'}',
                  '${e['message'] ?? 'Request failed'}',
                  e['details'],
                ),
              );
            }
          } else if (frame['type'] == 'event') {
            if (frame['event'] == 'connect.challenge' &&
                !challenge.isCompleted) {
              challenge.complete(
                Map<String, dynamic>.from(frame['payload'] as Map),
              );
            } else {
              _events.add(frame);
            }
          }
        } catch (_) {
          _fail(const FormatException('Invalid Gateway frame'));
        }
      },
      onError: (Object e) {
        if (!challenge.isCompleted) challenge.completeError(e);
        _fail(e);
      },
      onDone: () {
        if (!challenge.isCompleted)
          challenge.completeError(StateError('Disconnected before challenge'));
        _fail(StateError('Gateway disconnected'));
      },
    );
    try {
      final c = await challenge.future.timeout(const Duration(seconds: 30));
      if (c['nonce'] is! String || c['ts'] is! int || (c['ts'] as int) < 0) {
        throw const FormatException('Invalid Gateway challenge');
      }
      hello = Map<String, dynamic>.from(
        await request('connect', {
              'minProtocol': 4,
              'maxProtocol': 4,
              'client': {
                'id': 'openclaw-ios',
                'version': '0.1.0',
                'platform': 'ios',
                'mode': 'ui',
                'displayName': 'Cove-Go',
              },
              'role': 'operator',
              'scopes': scopes,
              'caps': ['tool-events', 'chat-only-assistant-text'],
              'auth': {'token': token},
              'device': await identity.sign(
                c['nonce'] as String,
                c['ts'] as int,
                token,
                scopes,
              ),
              'locale': 'zh-CN',
              'userAgent': 'Cove-Go/0.1.0',
            })
            as Map,
      );
      connected = true;
      return hello;
    } catch (_) {
      await disconnect();
      rethrow;
    }
  }

  Future<dynamic> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    final socket = _socket;
    if (socket == null) throw StateError('Gateway not connected');
    final id = wireId();
    final waiter = Completer<dynamic>();
    _pending[id] = waiter;
    try {
      final frame = jsonEncode({
        'type': 'req',
        'id': id,
        'method': method,
        'params': params,
      });
      final maxPayload =
          (hello['policy'] as Map?)?['maxPayload'] as int? ?? 26214400;
      if (utf8.encode(frame).length > maxPayload)
        throw StateError('Request exceeds Gateway frame limit');
      socket.add(frame);
      return await waiter.future.timeout(const Duration(seconds: 35));
    } finally {
      _pending.remove(id);
    }
  }

  void _fail(Object error) {
    connected = false;
    for (final waiter in _pending.values) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _pending.clear();
    if (!_events.isClosed)
      _events.add({'type': 'event', 'event': 'connection.closed'});
  }

  Future<void> disconnect() async {
    connected = false;
    await _subscription?.cancel();
    _subscription = null;
    final socket = _socket;
    _socket = null;
    await socket?.close();
    _fail(StateError('Connection closed'));
  }

  Future<void> dispose() async {
    await disconnect();
    await _events.close();
  }
}

String messageText(dynamic message) {
  if (message is! Map) return '';
  final content = message['content'];
  if (content is String) return content;
  if (content is List)
    return content
        .whereType<Map>()
        .where((b) => b['type'] == 'text')
        .map((b) => b['text'] ?? '')
        .join('\n');
  return message['text'] as String? ?? '';
}
