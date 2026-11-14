import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/openclaw/feature_data.dart';
import 'package:dsh_app/openclaw/feature_artifact.dart';
import 'package:dsh_app/openclaw/features.dart';
import 'package:dsh_app/openclaw/feature_export.dart';
import 'package:dsh_app/openclaw/home.dart';
import 'package:dsh_app/ui/common/tile_grid.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openclaw_client/openclaw_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';
import 'send_test.dart' show SlowGateway, UiController, home;

class FeatureGateway extends SlowGateway {
  final calls = <(String, Map<String, dynamic>)>[];
  Completer<dynamic>? delayed;
  Object? error;
  bool urlArtifact = false;
  @override
  Future<dynamic> request(String method, [Map<String, dynamic> params = const {}]) async {
    calls.add((method, params));
    if (error != null) throw error!;
    if (delayed != null) return delayed!.future;
    switch (method) {
      case 'sessions.describe':
        return {
          'session': {
            'key': params['key'],
            'displayName': 'Fixture chat',
            'model': 'test/model',
            'token': 'must-not-render',
          },
        };
      case 'artifacts.list':
        return {
          'artifacts': [
            {
              'id': 'out',
              'title': 'result.pdf',
              'mimeType': 'application/pdf',
              'type': 'file',
              'download': {'mode': 'bytes'},
            },
          ],
        };
      case 'artifacts.download':
        return urlArtifact
            ? {'url': 'https://untrusted.example/file'}
            : {'encoding': 'base64', 'data': base64Encode(utf8.encode('artifact text'))};
      case 'sessions.files.list':
        return {
          'files': [
            {'path': 'notes.md', 'name': 'notes.md', 'kind': 'read', 'missing': false},
          ],
        };
      case 'sessions.files.get':
        return {
          'file': {
            'path': 'notes.md',
            'name': 'notes.md',
            'content': 'hello file preview',
            'previewKind': 'text',
            'contentEncoding': 'utf8',
          },
        };
      case 'progressCard.get':
        return {
          'card': {
            'markdown': 'Fixture progress',
            'steps': [
              {'step': 'Build', 'status': 'completed'},
            ],
          },
        };
      case 'skills.status':
        return {
          'skills': [
            {'name': 'weather', 'description': 'Weather lookup', 'eligible': true},
          ],
        };
      case 'plugins.list':
        return {
          'plugins': [
            {'id': 'fixture-plugin', 'name': 'Fixture plugin', 'enabled': true},
          ],
        };
      case 'agents.list':
        return {
          'agents': [
            {'id': 'main', 'name': 'Fixture agent'},
          ],
        };
      case 'cron.list':
        return {
          'jobs': [
            {'id': 'job', 'name': 'Daily check', 'enabled': true},
          ],
        };
      default:
        return super.request(method, params);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FeatureGateway gateway;
  late UiController c;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    gateway = FeatureGateway();
    c = UiController(gateway)..sessionKey = 'a';
    c.sessions = [
      {'key': 'a', 'displayName': 'Fixture chat'},
    ];
  });

  Future<void> openHub(WidgetTester tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(home(c, buildLightTheme()));
    await tester.pumpAndSettle();
    tester.state<ClawHomeState>(find.byType(ClawHome)).openSettings(features: true);
    await tester.pumpAndSettle();
  }

  Future<void> tapCard(WidgetTester tester, String id) async {
    final finder = find.byKey(ValueKey('gateway-feature-$id'));
    await tester.scrollUntilVisible(finder, 250, scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('nine-dot entry opens DSH-style hub, not plain settings', (tester) async {
    await openHub(tester);
    expect(find.byType(GatewayFeaturesPage), findsOneWidget);
    expect(find.byType(TileGrid), findsWidgets);
    expect(find.byType(FeatureCard), findsWidgets);
    expect(find.text('当前打开的对话'), findsOneWidget);
    await tapCard(tester, 'details');
    expect(gateway.calls.first.$1, 'sessions.describe');
    expect(gateway.calls.first.$2, {'key': 'a'});
    expect(find.textContaining('test/model'), findsOneWidget);
    expect(find.textContaining('must-not-render'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final entry in [
    ('progress', 'progressCard.get', 'Fixture progress'),
    ('skills', 'skills.status', 'weather'),
    ('plugins', 'plugins.list', 'Fixture plugin'),
    ('agents', 'agents.list', 'Fixture agent'),
    ('cron', 'cron.list', 'Daily check'),
    ('artifacts', 'artifacts.list', 'result.pdf'),
  ]) {
    testWidgets('${entry.$1} card reads the real scoped Gateway method', (tester) async {
      await openHub(tester);
      await tapCard(tester, entry.$1);
      expect(gateway.calls.any((call) => call.$1 == entry.$2), true);
      expect(find.textContaining(entry.$3), findsOneWidget);
      if (['progress', 'skills', 'artifacts'].contains(entry.$1)) {
        expect(gateway.calls.firstWhere((call) => call.$1 == entry.$2).$2['sessionKey'], 'a');
      }
      if (entry.$1 == 'artifacts') {
        expect(gateway.calls.firstWhere((call) => call.$1 == 'artifacts.list').$2['messageRole'], 'assistant');
      }
      expect(gateway.calls.any((call) => call.$1.endsWith('.update') || call.$1.endsWith('.install')), false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('files card opens a native text preview and export requires explicit action', (tester) async {
    await openHub(tester);
    await tapCard(tester, 'files');
    await tester.tap(find.text('notes.md'));
    await tester.pumpAndSettle();
    expect(find.text('hello file preview'), findsOneWidget);
    expect(gateway.calls.firstWhere((call) => call.$1 == 'sessions.files.get').$2, {
      'sessionKey': 'a',
      'path': 'notes.md',
    });
    Navigator.of(tester.element(find.byType(GatewayFilePreview))).pop();
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(GatewayReadPage))).pop();
    await tester.pumpAndSettle();
    await tapCard(tester, 'export');
    expect(find.byType(GatewayExportPage), findsOneWidget);
    expect(find.textContaining('不是完整会话或 ZIP 备份'), findsOneWidget);
    expect(gateway.calls.any((call) => call.$1 == 'chat.history'), false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final urlOnly in [false, true]) {
    testWidgets('artifact loads bounded Gateway bytes without following returned URLs ($urlOnly)', (tester) async {
      gateway.urlArtifact = urlOnly;
      await openHub(tester);
      await tapCard(tester, 'artifacts');
      await tester.tap(find.text('result.pdf'));
      await tester.pumpAndSettle();
      expect(find.byType(GatewayArtifactPage), findsOneWidget);
      expect(gateway.calls.any((call) => call.$1 == 'artifacts.download'), false);
      await tester.tap(find.text('加载附件'));
      await tester.pumpAndSettle();
      expect(gateway.calls.firstWhere((call) => call.$1 == 'artifacts.download').$2, {
        'sessionKey': 'a',
        'artifactId': 'out',
        'messageRole': 'assistant',
      });
      if (urlOnly) {
        expect(find.textContaining('暂不支持原生预览'), findsOneWidget);
        expect(find.text('分享／保存到文件'), findsNothing);
      } else {
        expect(find.text('分享／保存到文件'), findsOneWidget);
      }
      c.sessionKey = 'b';
      c.changed();
      await tester.pumpAndSettle();
      expect(find.textContaining('当前对话已变化'), findsOneWidget);
      expect(find.text('分享／保存到文件'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('workspace and settings cards route to existing flows', (tester) async {
    await openHub(tester);
    await tapCard(tester, 'workspaces');
    expect(find.byKey(const ValueKey('gateway-group-all')), findsOneWidget);
    Navigator.of(tester.element(find.byKey(const ValueKey('gateway-group-all')))).pop();
    await tester.pumpAndSettle();
    final settings = find.byKey(const ValueKey('gateway-all-settings'));
    await tester.scrollUntilVisible(settings, 250, scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(find.text('外观'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('no session disables implemented cards; unimplemented cards are absent', (tester) async {
    c.sessionKey = '';
    await openHub(tester);
    FeatureCard card(String id) => tester.widget<FeatureCard>(find.byKey(ValueKey('gateway-feature-$id')));
    expect(card('details').enabled, false);
    expect(card('files').enabled, false);
    for (final id in ['terminal', 'jobs', 'permissions']) {
      expect(find.byKey(ValueKey('gateway-feature-$id')), findsNothing);
    }
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('gateway-feature-models')),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(card('models').enabled, false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Gateway capability roster hides unsupported cards and empty sections', (tester) async {
    gateway.hello = {
      'features': {
        'methods': ['sessions.describe', 'chat.history'],
      },
    };
    await openHub(tester);
    expect(find.byKey(const ValueKey('gateway-feature-details')), findsOneWidget);
    expect(find.byKey(const ValueKey('gateway-feature-export')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('gateway-all-settings')),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    for (final id in [
      'files',
      'artifacts',
      'skills',
      'progress',
      'cron',
      'plugins',
      'agents',
      'models',
      'terminal',
      'jobs',
      'permissions',
    ]) {
      expect(find.byKey(ValueKey('gateway-feature-$id')), findsNothing);
    }
    expect(find.text('自动化'), findsNothing);
    expect(find.text('引擎与扩展'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unsupported or denied reads show errors and retry instead of fake data', (tester) async {
    await openHub(tester);
    gateway.error = GatewayException('FORBIDDEN', 'fixture denied');
    await tapCard(tester, 'skills');
    expect(find.textContaining('FORBIDDEN'), findsOneWidget);
    expect(find.textContaining('未执行修改'), findsOneWidget);
    gateway.error = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('weather'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late read after conversation switch is hidden', (tester) async {
    await openHub(tester);
    gateway.delayed = Completer<dynamic>();
    final card = find.byKey(const ValueKey('gateway-feature-details'));
    await tester.ensureVisible(card);
    await tester.tap(card);
    await tester.pump();
    c.sessionKey = 'b';
    c.changed();
    gateway.delayed!.complete({
      'session': {'displayName': 'stale hidden'},
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('当前对话已变化'), findsOneWidget);
    expect(find.textContaining('stale hidden'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('advertised methods gate unsupported requests before sending', () async {
    gateway.hello = {
      'features': {
        'methods': ['chat.history'],
      },
    };
    final scope = GatewayFeatureScope(c, session: 'a');
    await expectLater(scope.read('skills.status', {'sessionKey': 'a'}), throwsStateError);
    expect(gateway.calls, isEmpty);
    c.dispose();
  });

  for (final dark in [false, true]) {
    testWidgets('hub renders at phone width with ${dark ? "dark" : "light"} theme', (tester) async {
      tester.view.physicalSize = const Size(402, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: withTestFonts(dark ? buildDarkTheme() : buildLightTheme()),
            locale: const Locale('zh', 'CN'),
            supportedLocales: AppLocale.supported,
            localizationsDelegates: L10n.localizationsDelegates,
            home: RepaintBoundary(
              key: capture,
              child: GatewayFeaturesPage(
                controller: c,
                onSettings: () {},
                onSearch: () {},
                onModels: () {},
                onHosts: () {},
                onWeb: () {},
                onExport: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final boundary = capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final path = File('../build/openclaw/features-${dark ? "dark" : "light"}.png');
        await path.parent.create(recursive: true);
        await path.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('gateway-all-settings')),
        350,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../build/openclaw/features-${dark ? "dark" : "light"}-bottom.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  }
}
