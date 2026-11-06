import 'dart:async';
import 'dart:io';
import 'dart:ui' as drawing;

import 'package:flutter/rendering.dart';

import 'package:dsh_app/openclaw/controller.dart';
import 'package:dsh_app/state/offline_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/openclaw/home.dart';
import 'package:dsh_app/openclaw/tool_activity.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:openclaw_client/openclaw_client.dart';

import '../support/test_fonts.dart';

class MemorySnapshots extends OfflineSnapshotStore {
  @override
  Future<void> write(String scope, Map<String, dynamic> snapshot) async {}
}

class SlowGateway extends GatewayClient {
  Completer<dynamic> admission = Completer<dynamic>();
  Completer<dynamic>? creation;
  bool reject = false;
  final ids = <String>[];
  List<Map<String, dynamic>> rows = [];
  @override
  bool get connected => true;
  @override
  Future<dynamic> request(String method, [Map<String, dynamic> params = const {}]) async {
    if (method == 'chat.send') {
      ids.add(params['idempotencyKey'] as String);
      await admission.future;
      if (reject) throw StateError('not admitted');
      return <String, dynamic>{};
    }
    if (method == 'chat.history') return {'messages': rows};
    if (method == 'sessions.create') return creation?.future ?? {'sessionKey': 'new'};
    if (method == 'sessions.list') return {'sessions': <dynamic>[]};
    return <String, dynamic>{};
  }
}

class UiController extends ClawController {
  UiController(SlowGateway gateway) : super(client: gateway, snapshots: MemorySnapshots());
  @override
  Future<void> load() async {}
}

Widget home(ClawController controller, ThemeData theme) => ProviderScope(
  child: MaterialApp(
    theme: withTestFonts(theme),
    locale: const Locale('zh', 'CN'),
    localizationsDelegates: const [
      L10n.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocale.supported,
    home: ClawHome(controller: controller, onLanguage: () {}),
  ),
);

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
}

void main() {
  late SlowGateway gateway;
  late ClawController c;
  setUp(() {
    gateway = SlowGateway();
    c = ClawController(client: gateway, snapshots: MemorySnapshots())..sessionKey = 'a';
  });
  tearDown(() => c.dispose());

  for (final dark in [false, true]) {
    testWidgets('Gateway markdown has readable table and inline code ($dark)', (tester) async {
      final ui = UiController(gateway)..sessionKey = 'a';
      ui.messages = [
        {'role': 'assistant', 'content': '| 加速区域 | 是否备案 |\n| --- | --- |\n| 全球 | 不需要 |\n\n你的 `response.cn` 可以接入。'},
      ];
      final theme = dark ? buildDarkTheme() : buildLightTheme();
      final capture = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(key: capture, child: home(ui, theme)));
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownBody), findsOneWidget);
      final rendered = tester.widget<GptMarkdownTheme>(find.byType(GptMarkdownTheme)).gptThemeData;
      final header = rendered.styleSheet.table!.headerBackground!;
      expect(contrast(theme.colorScheme.onSurface, header), greaterThanOrEqualTo(4.5));
      final code = rendered.inlineCode;
      expect(contrast(code.color!, code.backgroundColor!), greaterThanOrEqualTo(4.5));
      expect(tester.takeException(), isNull);
      final boundary = capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final renderedImage = await boundary.toImage();
        final bytes = await renderedImage.toByteData(format: drawing.ImageByteFormat.png);
        final file = File('../build/openclaw/readability-${dark ? 'dark' : 'light'}.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        renderedImage.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('slow send clears input and renders bubble; failure restores draft', (tester) async {
    final ui = UiController(gateway)..sessionKey = 'a';
    await tester.pumpWidget(home(ui, buildDarkTheme()));
    await tester.pumpAndSettle();
    final state = tester.state<ClawHomeState>(find.byType(ClawHome));
    state.input.text = '立即显示';
    late Future<void> sending;
    await tester.runAsync(() async {
      sending = state.send();
    });
    await tester.pump();
    expect(state.input.text, isEmpty);
    expect(find.byType(UserBubble), findsOneWidget);
    expect(tester.widget<UserBubble>(find.byType(UserBubble)).text, '立即显示');
    await tester.runAsync(() async {
      gateway.reject = true;
      gateway.admission.complete({});
      await sending;
    });
    await tester.pump();
    expect(state.input.text, '立即显示');
    expect(ui.visibleMessages, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('first message appears while new session is still being created', (tester) async {
    final ui = UiController(gateway);
    await tester.pumpWidget(home(ui, buildDarkTheme()));
    await tester.pumpAndSettle();
    final state = tester.state<ClawHomeState>(find.byType(ClawHome));
    state.input.text = '新对话第一条';
    late Future<void> sending;
    await tester.runAsync(() async {
      gateway.creation = Completer<dynamic>();
      sending = state.send();
    });
    await tester.pump();
    expect(ui.sessionKey, isEmpty);
    expect(find.byType(UserBubble), findsOneWidget);
    await tester.runAsync(() async {
      gateway.creation!.complete({'sessionKey': 'new'});
      gateway.admission.complete({});
      await sending;
    });
    await tester.pump();
    expect(find.byType(UserBubble), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('consecutive tool results occupy one compact row and details stay accessible', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final ui = UiController(gateway)..sessionKey = 'a';
    ui.messages = [
      {'role': 'user', 'content': '检查项目'},
      for (var i = 0; i < 12; i++) ...[
        {
          'role': 'assistant',
          'content': [
            {'type': 'toolCall', 'name': 'exec'},
          ],
        },
        {'role': i.isEven ? 'toolResult' : 'tool', 'toolName': i.isEven ? 'bash' : 'exec', 'content': 'output-$i'},
      ],
      {'role': 'assistant', 'content': '检查完成'},
      {'role': 'toolResult', 'toolName': 'read', 'content': 'next-output'},
    ];
    final capture = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: capture, child: home(ui, buildDarkTheme())));
    await tester.pumpAndSettle();
    final summaries = find.byType(GatewayToolActivity);
    expect(summaries, findsNWidgets(2));
    expect(tester.widgetList<GatewayToolActivity>(summaries).map((w) => w.entries.length), unorderedEquals([12, 1]));
    final batch = find.byWidgetPredicate((w) => w is GatewayToolActivity && w.entries.length == 12);
    expect(tester.getSize(batch).height, lessThanOrEqualTo(52));
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.byType(UserBubble), findsOneWidget);
    expect(tester.takeException(), isNull);
    final boundary = capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: drawing.ImageByteFormat.png);
      await File('../build/openclaw/compact-tools-dark.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.tap(find.descendant(of: batch, matching: find.byType(TextButton)));
    await tester.pumpAndSettle();
    expect(find.text('output-0'), findsNothing);
    await tester.tap(find.byType(ExpansionTile).first);
    await tester.pumpAndSettle();
    expect(find.text('output-0'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('live tools also use the compact summary and long names do not overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final ui = UiController(gateway)..sessionKey = 'a';
    ui.tools['live'] = {'name': 'a-very-long-tool-name-that-must-not-stretch-the-chat-row', 'phase': 'running'};
    await tester.pumpWidget(home(ui, buildLightTheme()));
    await tester.pumpAndSettle();
    expect(find.byType(GatewayToolActivity), findsOneWidget);
    expect(tester.getSize(find.byType(GatewayToolActivity)).height, lessThanOrEqualTo(52));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('echo is synchronous and survives admission and stale history until actual echo', () async {
    final sending = c.send('hello');
    expect(c.visibleMessages.map(messageText), ['hello']);
    expect(c.sending, isTrue);
    await c.history();
    expect(c.visibleMessages.map(messageText), ['hello']);
    gateway.admission.complete({});
    await sending;
    await c.history();
    expect(c.visibleMessages.map(messageText), ['hello']);
    gateway.rows = [
      {'role': 'user', 'content': 'hello'},
    ];
    await c.history();
    expect(c.visibleMessages.map(messageText), ['hello']);
  });

  test('old identical text does not consume echo; subsequent identical sends deduplicate', () async {
    gateway.rows = [
      {'role': 'user', 'content': 'hello'},
    ];
    await c.history();
    final sending = c.send('hello');
    await c.history();
    expect(c.visibleMessages.length, 2);
    gateway.admission.complete({});
    await sending;
    gateway.rows = [
      ...gateway.rows,
      {'role': 'user', 'content': 'hello'},
    ];
    await c.history();
    expect(c.visibleMessages.length, 2);
  });

  test('failure removes echo and retry preserves request identity', () async {
    final sending = c.send('hello');
    final failure = expectLater(sending, throwsStateError);
    gateway.reject = true;
    gateway.admission.complete({});
    await failure;
    expect(c.visibleMessages, isEmpty);
    gateway.reject = false;
    gateway.admission = Completer<dynamic>();
    final retry = c.send('hello');
    expect(c.visibleMessages.length, 1);
    gateway.admission.complete({});
    await retry;
    expect(gateway.ids.toSet().length, 1);
  });

  test('echo belongs to originating session across selection changes', () async {
    final sending = c.send('hello');
    await c.select('b');
    expect(c.visibleMessages, isEmpty);
    gateway.admission.complete({});
    await sending;
    await c.select('a');
    expect(c.visibleMessages.map(messageText), ['hello']);
  });

  test('new session shows echo even while session creation is in flight', () async {
    c.sessionKey = '';
    final sending = c.send('first');
    expect(c.visibleMessages.map(messageText), ['first']);
    gateway.admission.complete({});
    await sending;
    expect(c.sessionKey, 'new');
    expect(c.visibleMessages.map(messageText), ['first']);
  });
}
