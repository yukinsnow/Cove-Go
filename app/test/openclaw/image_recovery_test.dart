import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/openclaw/images.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openclaw_client/openclaw_client.dart';

import 'send_test.dart' show SlowGateway;

class GrantGateway extends SlowGateway {
  Map<String, dynamic>? downloaded;
  String url = '';
  @override
  Future<dynamic> request(String method, [Map<String, dynamic> params = const {}]) async {
    if (method == 'artifacts.download') {
      downloaded = params;
      return {'url': url};
    }
    return super.request(method, params);
  }
}

void main() {
  test('history reads canonical media facts and display content without duplicating a URL', () {
    final rows = gatewayImages({
      'content': const [],
      'openclawDisplayContent': [
        {'type': 'image', 'url': 'media://inbound/a.png'},
      ],
      '__openclaw': {
        'media': [
          {'kind': 'image', 'path': 'media://inbound/a.png', 'fileName': 'a.png'},
          {'contentType': 'image/jpeg', 'url': 'media://inbound/b.jpg'},
          {'path': 'media://inbound/c.webp'},
          {'kind': 'audio', 'path': 'media://inbound/voice.wav'},
        ],
      },
    });
    expect(rows, hasLength(3));
    expect(rows.map(gatewayImageReference), [
      'media://inbound/a.png',
      'media://inbound/b.jpg',
      'media://inbound/c.webp',
    ]);
  });

  test('unresolved stripped blocks do not hide local display bytes', () {
    expect(
      gatewayImages({
        'content': [
          {'type': 'image', 'omitted': true},
        ],
        '_localImages': [
          {'type': 'image', 'data': SlowGateway.png},
        ],
      }).single['data'],
      SlowGateway.png,
    );
  });

  test('canonical inbound media uses Gateway base path, session and bearer', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    Uri? seen;
    String? auth;
    server.listen((request) async {
      seen = request.uri;
      auth = request.headers.value(HttpHeaders.authorizationHeader);
      request.response.add(base64Decode(SlowGateway.png));
      await request.response.close();
    });
    final client = GatewayClient();
    addTearDown(client.dispose);
    final image = await loadGatewayImage(
      {'url': 'media://inbound/a.png'},
      client,
      'agent:main:example',
      address: 'ws://127.0.0.1:${server.port}/gateway/',
      token: 'test-only',
    );
    expect(image, isA<MemoryImage>());
    expect(seen!.path, '/gateway/__openclaw__/assistant-media');
    expect(seen!.queryParameters, {'source': 'media://inbound/a.png', 'sessionKey': 'agent:main:example'});
    expect(auth, 'Bearer test-only');
  });

  test('managed history URL requests fresh artifact grant including query parameters', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    String? ticket;
    server.listen((request) async {
      ticket = request.uri.queryParameters['mediaTicket'];
      request.response.add(base64Decode(SlowGateway.png));
      await request.response.close();
    });
    const id = '12345678-1234-4123-8123-123456789abc';
    final client = GrantGateway()..url = '/api/chat/media/outgoing/a/$id/full?mediaTicket=fresh';
    addTearDown(client.dispose);
    final image = await loadGatewayImage(
      {'url': '/api/chat/media/outgoing/a/$id/full'},
      client,
      'a',
      address: 'ws://127.0.0.1:${server.port}',
      token: 'test-only',
    );
    expect(image, isA<MemoryImage>());
    expect(client.downloaded, {'sessionKey': 'a', 'artifactId': 'artifact_managed_image_$id'});
    expect(ticket, 'fresh');
  });

  test('external images never receive Gateway token and redirects are not followed', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <String>[];
    server.listen((request) async {
      requests.add(request.uri.path);
      request.response.statusCode = 302;
      request.response.headers.set(HttpHeaders.locationHeader, '/redirect-target');
      await request.response.close();
    });
    final client = GatewayClient();
    addTearDown(client.dispose);
    final external = await loadGatewayImage(
      {'url': 'https://images.example/photo.png'},
      client,
      'a',
      address: 'ws://127.0.0.1:${server.port}',
      token: 'never-leak',
    );
    expect(external, isA<NetworkImage>());
    expect((external as NetworkImage).headers, isNull);
    expect(
      await loadGatewayImage(
        {'url': '/redirect'},
        client,
        'a',
        address: 'ws://127.0.0.1:${server.port}',
        token: 'never-leak',
      ),
      isNull,
    );
    expect(requests, ['/redirect']);
  });

  test('private paths and missing inbound origin do not become public URLs', () async {
    final client = GatewayClient();
    addTearDown(client.dispose);
    expect(await loadGatewayImage({'url': '/home/user/private.png'}, client, 'a'), isNull);
    expect(await loadGatewayImage({'url': 'media://inbound/a.png'}, client, 'a'), isNull);
    expect(await loadGatewayImage({'url': 'file:///tmp/a.png'}, client, 'a'), isNull);
  });
}
