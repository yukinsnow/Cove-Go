import 'dart:async';
import 'dart:io';

import 'package:dsh_app/openclaw/image_blocks.dart';
import 'package:dsh_app/openclaw/feature_data.dart';
import 'package:dsh_app/openclaw/received_file.dart';
import 'package:flutter_test/flutter_test.dart';

import 'send_test.dart' show SlowGateway, UiController;

class ReceivedGateway extends SlowGateway {
  String url = '';
  Map<String, dynamic>? params;
  Completer<dynamic>? delayed;
  @override
  Future<dynamic> request(String method, [Map<String, dynamic> params = const {}]) async {
    if (method == 'artifacts.download') {
      this.params = params;
      return delayed == null ? {'url': url} : delayed!.future;
    }
    return super.request(method, params);
  }
}

void main() {
  const id = 'e0e85255-5999-429c-82e9-d1a2d8e6c42a';
  const attachment = {
    'artifactId': 'artifact_managed_media_$id',
    'url': '/api/chat/media/outgoing/session/$id/full',
    'kind': 'document',
    'label': 'Cove-Go-0.1.22-build23-unsigned.zip',
    'mimeType': 'application/zip',
    'sizeBytes': 4,
  };
  test('actual delivery mirror attachment schema is visible, deduplicated and actionable', () {
    final message = {
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': 'package'},
        {'type': 'attachment', 'attachment': attachment},
      ],
    };
    final files = gatewayFiles(message);
    expect(files.single['fileName'], attachment['label']);
    expect(files.single['artifactId'], attachment['artifactId']);
    expect(gatewayImages(message), isEmpty);
    expect(gatewayReceivedName(files.single), attachment['label']);
    expect(gatewayReceivedName({'fileName': '../../danger.zip'}), 'danger.zip');
    final withFacts = {
      ...message,
      '__openclaw': {
        'media': [
          {...attachment, 'kind': 'document', 'fileName': attachment['label']},
        ],
      },
    };
    expect(gatewayFiles(withFacts), hasLength(1));
    expect(
      gatewayImages({
        'content': [
          {
            'type': 'attachment',
            'attachment': {...attachment, 'mimeType': 'image/png'},
          },
        ],
      }),
      hasLength(1),
    );
  });
  test('only known fresh download paths on exact origin are eligible', () {
    const base = 'wss://gateway.example/base';
    expect(
      gatewayDownloadUri(base, '/api/chat/media/outgoing/a/$id/full?mediaTicket=fresh')!.path,
      '/base/api/chat/media/outgoing/a/$id/full',
    );
    for (final bad in [
      'https://evil.example/api/artifacts/download/a/b',
      '//evil.example/a',
      '/private/file',
      'file:///etc/passwd',
      'http://gateway.example/api/artifacts/download/a/b',
    ]) {
      expect(gatewayDownloadUri(base, bad), isNull);
    }
  });
  for (final mode in ['ok', 'redirect', 'oversize', 'truncated', 'retired', 'external']) {
    test('bounded disk download with bearer and no redirect: $mode', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final dir = await Directory.systemTemp.createTemp('cove-test-');
      addTearDown(() => dir.delete(recursive: true));
      var hits = 0;
      String? authorization;
      server.listen((request) async {
        hits++;
        authorization = request.headers.value('authorization');
        if (mode == 'redirect') {
          request.response.statusCode = 302;
          request.response.headers.set('location', '/private/redirect');
        } else {
          request.response.add(
            List.filled(
              mode == 'truncated'
                  ? 2
                  : mode == 'oversize'
                  ? 8
                  : 4,
              42,
            ),
          );
        }
        await request.response.close();
      });
      final client = ReceivedGateway()
        ..url = mode == 'external'
            ? 'https://evil.example/api/artifacts/download/a/b'
            : '/api/chat/media/outgoing/a/$id/full?mediaTicket=fresh';
      final c = UiController(client)
        ..address = 'ws://127.0.0.1:${server.port}'
        ..token = 'test-only'
        ..sessionKey = 'session';
      addTearDown(c.dispose);
      if (mode == 'retired') client.delayed = Completer<dynamic>();
      final downloading = downloadGatewayFile(
        GatewayFeatureScope(c, session: 'session'),
        gatewayFiles({
          'content': [
            {'type': 'attachment', 'attachment': attachment},
          ],
        }).single,
        dir,
        maxBytes: 4,
      );
      if (mode == 'retired') {
        c.sessionKey = 'different';
        client.delayed!.complete({'url': client.url});
      }
      if (mode == 'ok') {
        final file = await downloading;
        expect(await file.length(), 4);
        expect(file.path.endsWith('.zip'), true);
        expect(client.params, {
          'sessionKey': 'session',
          'artifactId': 'artifact_managed_media_$id',
          'transport': 'http',
        });
      } else {
        await expectLater(downloading, throwsStateError);
        expect(await dir.list().isEmpty, true);
      }
      expect(hits, ['retired', 'external'].contains(mode) ? 0 : 1);
      if (hits > 0) expect(authorization, 'Bearer test-only');
    });
  }
}
