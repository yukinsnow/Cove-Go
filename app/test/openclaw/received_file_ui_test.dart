import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'package:dsh_app/openclaw/attachments.dart';
import 'package:dsh_app/openclaw/feature_data.dart';
import 'package:dsh_app/openclaw/received_file.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'send_test.dart' show SlowGateway, UiController, home;

class PendingDownloadGateway extends SlowGateway {
  final download = Completer<dynamic>();
  @override
  Future<dynamic> request(String method, [Map<String, dynamic> params = const {}]) {
    if (method == 'artifacts.download') {
      downloads++;
      return download.future;
    }
    return super.request(method, params);
  }
}

void main() {
  testWidgets('real delivery-mirror ZIP appears in assistant bubble and opens native download page', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final temp = (await tester.runAsync(() => Directory.systemTemp.createTemp('cove-widget-')))!;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => temp.path);
    addTearDown(() async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await temp.delete(recursive: true);
    });
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = PendingDownloadGateway();
    final c = UiController(gateway)..sessionKey = 'fixture';
    c.messages = [
      {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Package delivered'},
          {
            'type': 'attachment',
            'attachment': {
              'artifactId': 'artifact_managed_media_e0e85255-5999-429c-82e9-d1a2d8e6c42a',
              'url': '/api/chat/media/outgoing/fixture/e0e85255-5999-429c-82e9-d1a2d8e6c42a/full',
              'kind': 'document',
              'label': 'Cove-Go-0.1.22-build23-unsigned.zip',
              'mimeType': 'application/zip',
              'sizeBytes': 28258724,
            },
          },
        ],
      },
    ];
    await tester.pumpWidget(home(c, buildLightTheme()));
    await tester.pumpAndSettle();
    expect(find.byType(GatewayFileTile), findsOneWidget);
    expect(find.text('Cove-Go-0.1.22-build23-unsigned.zip'), findsOneWidget);
    await tester.tap(find.byType(GatewayFileTile));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(gateway.downloads, 1);
    expect(find.byType(GatewayReceivedFilePage), findsOneWidget);
    expect(find.byKey(const ValueKey('received-file-download')), findsOneWidget);
    expect(find.byKey(const ValueKey('received-file-save')), findsNothing);
    expect(tester.takeException(), isNull);
    gateway.download.completeError(StateError('fixture download failed'));
    await tester.pumpAndSettle();
    expect(gateway.downloads, 1);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('iOS downloaded file uses native preview and Documents save; sharing remains available', (tester) async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(402, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temp = (await tester.runAsync(() => Directory.systemTemp.createTemp('cove-ios-widget-')))!;
    final calls = <MethodCall>[];
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const files = MethodChannel('dsh/files');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, (_) async => temp.path);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(files, (call) async {
      calls.add(call);
      return call.method == 'saveToDownloads' ? 'Cove-Go/report.pdf' : null;
    });
    addTearDown(() async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(files, null);
      await temp.delete(recursive: true);
    });
    final gateway = SlowGateway();
    final c = UiController(gateway)..sessionKey = 'fixture';
    c.messages = [
      {
        'role': 'assistant',
        'content': [
          {
            'type': 'attachment',
            'attachment': {
              'artifactId': 'fixture-file',
              'kind': 'document',
              'label': 'report.pdf',
              'mimeType': 'application/pdf',
            },
          },
        ],
      },
    ];
    await tester.pumpWidget(home(c, buildLightTheme()));
    await tester.pumpAndSettle();
    unawaited(
      Navigator.of(tester.element(find.byType(GatewayFileTile))).push<void>(
        MaterialPageRoute(
          builder: (_) => GatewayReceivedFilePage(
            scope: GatewayFeatureScope(c, session: 'fixture'),
            file: const {'artifactId': 'fixture-file', 'label': 'report.pdf', 'mimeType': 'application/pdf'},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dynamic page = tester.state(find.byType(GatewayReceivedFilePage));
    await tester.runAsync(() async {
      final pending = page.download() as Future<void>;
      await pending;
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('received-file-save')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('received-file-preview')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('received-file-native-save')));
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method), ['open', 'saveToDownloads']);
    expect(calls.last.arguments['name'], 'report.pdf');
    expect(calls.last.arguments['mime'], 'application/pdf');
    expect(await tester.runAsync(() => File(calls.last.arguments['path'] as String).exists()), isTrue);
    expect(find.text('Cove-Go/report.pdf'), findsOneWidget);
    // Retiring the host/session removes file actions and the saved destination.
    c.sessionKey = 'other';
    c.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('received-file-preview')), findsNothing);
    expect(find.text('Cove-Go/report.pdf'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
