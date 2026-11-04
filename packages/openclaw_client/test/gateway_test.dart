import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:openclaw_client/openclaw_client.dart';
import 'package:test/test.dart';

void main() {
  test('device identity survives secure-storage seed roundtrip', () async {
    final first = await DeviceIdentity.create();
    final second = await DeviceIdentity.create(await first.exportSeed());
    expect(first.id, second.id);
    final proof = await first.sign(
      'challenge',
      1234,
      'test-token',
      GatewayClient.scopes,
    );
    final payload = [
      'v3',
      first.id,
      'openclaw-ios',
      'ui',
      'operator',
      GatewayClient.scopes.join(','),
      '1234',
      'test-token',
      'challenge',
      'ios',
      '',
    ].join('|');
    expect(
      await Ed25519().verify(
        utf8.encode(payload),
        signature: Signature(
          base64Url.decode(base64Url.normalize(proof['signature'] as String)),
          publicKey: first.publicKey,
        ),
      ),
      isTrue,
    );
    expect(
      await Ed25519().verify(
        utf8.encode('$payload-changed'),
        signature: Signature(
          base64Url.decode(base64Url.normalize(proof['signature'] as String)),
          publicKey: first.publicKey,
        ),
      ),
      isFalse,
    );
  });
  test(
    'challenge auth, RPC correlation, server errors, live events, close',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      WebSocket? peer;
      final served = server.listen((req) async {
        peer = await WebSocketTransformer.upgrade(req);
        peer!.add(
          jsonEncode({
            'type': 'event',
            'event': 'connect.challenge',
            'payload': {'nonce': 'nonce', 'ts': 42},
          }),
        );
        peer!.listen((raw) {
          final frame = jsonDecode(raw as String) as Map;
          if (frame['method'] == 'connect') {
            expect(frame['params']['device']['signedAt'], 42);
            expect(frame['params']['minProtocol'], 4);
            peer!.add(
              jsonEncode({
                'type': 'res',
                'id': frame['id'],
                'ok': true,
                'payload': {
                  'type': 'hello-ok',
                  'protocol': 4,
                  'auth': {'scopes': GatewayClient.scopes},
                },
              }),
            );
          } else if (frame['method'] == 'deny') {
            peer!.add(
              jsonEncode({
                'type': 'res',
                'id': frame['id'],
                'ok': false,
                'error': {'code': 'FORBIDDEN', 'message': 'No access'},
              }),
            );
          } else if (frame['method'] == 'hang') {
            unawaited(peer!.close());
          } else {
            peer!.add(
              jsonEncode({
                'type': 'res',
                'id': frame['id'],
                'ok': true,
                'payload': frame['params'],
              }),
            );
            peer!.add(
              jsonEncode({
                'type': 'event',
                'event': 'chat',
                'payload': {'state': 'delta'},
              }),
            );
          }
        });
      });
      final client = GatewayClient();
      try {
        await client.connect(
          'ws://127.0.0.1:${server.port}',
          'test-token',
          await DeviceIdentity.create(),
        );
        expect(client.connected, isTrue);
        final event = client.events.firstWhere((e) => e['event'] == 'chat');
        expect(await client.request('echo', {'text': 'hello'}), {
          'text': 'hello',
        });
        expect((await event)['payload']['state'], 'delta');
        await expectLater(
          client.request('deny'),
          throwsA(
            isA<GatewayException>().having((e) => e.code, 'code', 'FORBIDDEN'),
          ),
        );
        await expectLater(client.request('hang'), throwsStateError);
        expect(client.connected, isFalse);
      } finally {
        await client.dispose();
        await peer?.close();
        await served.cancel();
        await server.close(force: true);
      }
    },
  );
  test(
    'rejects remote plaintext and credential URLs before opening a socket',
    () async {
      final client = GatewayClient(), identity = await DeviceIdentity.create();
      for (final address in [
        'ws://example.com',
        'wss://user:password@example.com',
        'wss://example.com?token=secret',
      ]) {
        await expectLater(
          client.connect(address, '', identity),
          throwsArgumentError,
        );
      }
      await client.dispose();
    },
  );
  test('extracts only visible text, not reasoning or tool payloads', () {
    expect(
      messageText({
        'content': [
          {'type': 'thinking', 'thinking': 'private'},
          {'type': 'text', 'text': 'visible'},
          {'type': 'toolCall', 'name': 'exec'},
        ],
      }),
      'visible',
    );
  });
}
