import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as drawing;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dsh_app/ui/chat/composer.dart';

import 'package:dsh_app/openclaw/controller.dart';
import 'package:dsh_app/state/offline_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/openclaw/home.dart';
import 'package:dsh_app/openclaw/images.dart';
import 'package:dsh_app/openclaw/attachments.dart';
import 'package:dsh_app/ui/chat/artifact_preview.dart' show ImageViewerPage;
import 'package:dsh_app/openclaw/tool_activity.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:openclaw_client/openclaw_client.dart';

import '../support/test_fonts.dart';

class MemorySnapshots extends OfflineSnapshotStore {
  final snapshots = <String, Map<String, dynamic>>{};
  @override
  Future<void> write(String scope, Map<String, dynamic> snapshot) async {
    snapshots[scope] = Map<String, dynamic>.from(jsonDecode(jsonEncode(snapshot)) as Map);
  }

  @override
  Future<Map<String, dynamic>?> read(String scope) async => snapshots[scope];
}

class SlowGateway extends GatewayClient {
  Completer<dynamic> admission = Completer<dynamic>();
  Completer<dynamic>? creation;
  bool reject = false;
  int downloads = 0;
  static const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=';
  final ids = <String>[];
  Map<String, dynamic>? sent;
  List<Map<String, dynamic>> rows = [];
  @override
  bool get connected => true;
  @override
  Future<dynamic> request(String method, [Map<String, dynamic> params = const {}]) async {
    if (method == 'artifacts.download') {
      downloads++;
      return {'encoding': 'base64', 'data': png};
    }
    if (method == 'chat.send') {
      sent = params;
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

Widget home(
  ClawController controller,
  ThemeData theme, {
  Future<List<XFile>> Function(int)? picker,
  Future<List<XFile>> Function(int)? filePicker,
}) => ProviderScope(
  overrides: [
    if (picker != null) gatewayImagePickerProvider.overrideWithValue(picker),
    if (filePicker != null) gatewayFilePickerProvider.overrideWithValue(filePicker),
  ],
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

  testWidgets('image-only history and mixed messages render and open a zoom viewer', (tester) async {
    final ui = UiController(gateway)..sessionKey = 'a';
    ui.messages = [
      {
        'role': 'user',
        'content': [
          {'type': 'image', 'artifactId': 'history-image', 'omitted': true},
        ],
      },
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '带图消息'},
          {
            'type': 'image',
            'source': {'type': 'base64', 'data': SlowGateway.png},
          },
        ],
      },
    ];
    await tester.pumpWidget(home(ui, buildLightTheme()));
    await tester.pumpAndSettle();
    expect(find.byType(UserBubble), findsNWidgets(2));
    expect(find.byType(GatewayImage), findsNWidgets(2));
    expect(find.byType(Image), findsNWidgets(2));
    expect(gateway.downloads, 1);
    await tester.tap(find.byType(GatewayImage).first);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerPage), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('draft thumbnail previews, sends immediately and survives history echo', (tester) async {
    final ui = UiController(gateway)..sessionKey = 'a';
    await tester.pumpWidget(home(ui, buildLightTheme()));
    await tester.pumpAndSettle();
    final state = tester.state<ClawHomeState>(find.byType(ClawHome));
    state.attachments.add({
      'type': 'image',
      'mimeType': 'image/png',
      'fileName': 'photo.png',
      'content': SlowGateway.png,
    });
    ui.changed();
    await tester.pumpAndSettle();
    expect(find.byType(GatewayImage), findsOneWidget);
    await tester.tap(find.byType(GatewayImage));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    Navigator.of(tester.element(find.byType(ImageViewerPage))).pop();
    await tester.pumpAndSettle();
    expect(state.attachments, hasLength(1));
    late Future<void> sending;
    await tester.runAsync(() async {
      sending = state.send();
    });
    // Admission is deliberately pending, so the send button keeps animating.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.attachments, isEmpty);
    expect(find.byType(UserBubble), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    gateway.rows = [
      {
        'role': 'user',
        'content': [
          {'type': 'image', 'artifactId': 'echo-image', 'omitted': true},
        ],
      },
    ];
    await tester.runAsync(() async {
      gateway.admission.complete({});
      await sending;
      await ui.history();
    });
    await tester.pumpAndSettle();
    expect(find.byType(UserBubble), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('zoomable selection requires confirmation and draft remove preserves text', (tester) async {
    final ui = UiController(gateway)..sessionKey = 'a';
    await tester.pumpWidget(home(ui, buildLightTheme()));
    await tester.pumpAndSettle();
    final state = tester.state<ClawHomeState>(find.byType(ClawHome));
    Future<bool?> preview() => Navigator.of(state.context).push<bool>(
      MaterialPageRoute(
        builder: (_) => GatewayImageSelection(image: MemoryImage(base64Decode(SlowGateway.png)), name: 'photo.png'),
      ),
    );
    final cancelled = preview();
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    Navigator.of(tester.element(find.byType(GatewayImageSelection))).pop();
    expect(await cancelled, isNull);
    final confirmed = preview();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(await confirmed, isTrue);
    state.input.text = '保留文字';
    state.attachments.add({'type': 'image', 'mimeType': 'image/png', 'content': SlowGateway.png});
    ui.changed();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('移除'));
    await tester.pumpAndSettle();
    expect(state.attachments, isEmpty);
    expect(state.input.text, '保留文字');
    expect(find.byType(GatewayImage), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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

  testWidgets('attachment entry hides the keyboard before opening native picker', (tester) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.textInput, (call) async {
      calls.add(call.method);
      return null;
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/image_picker'),
      (call) async {
        expectSync(calls, contains('TextInput.hide'));
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.textInput, null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/image_picker'),
        null,
      );
    });
    final ui = UiController(gateway)..sessionKey = 'a';
    await tester.pumpWidget(
      home(
        ui,
        buildLightTheme(),
        picker: (_) async {
          expectSync(calls, contains('TextInput.hide'));
          return [];
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    final state = tester.state<ClawHomeState>(find.byType(ClawHome));
    expect(state.composerFocus.hasFocus, isTrue);
    calls.clear();
    final picking = state.attach();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('gateway-pick-media')));
    await tester.pumpAndSettle();
    await picking;
    expectSync(calls, contains('TextInput.hide'));
    expect(state.composerFocus.hasFocus, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('media option accepts one photo without asking single or multiple', (tester) async {
    final ui = UiController(gateway)..sessionKey = 'a';
    var calls = 0;
    await tester.pumpWidget(
      home(
        ui,
        buildLightTheme(),
        picker: (_) async {
          calls++;
          return [XFile.fromData(base64Decode(SlowGateway.png), path: 'one.png', mimeType: 'image/png')];
        },
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state<ClawHomeState>(find.byType(ClawHome));
    final picking = state.attach();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('gateway-pick-media')));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(GatewayImageSelection), findsOneWidget);
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    await picking;
    expect(state.attachments, hasLength(1));
    expect(state.attachments.single['fileName'], 'one.png');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final confirm in [true, false]) {
    testWidgets('multiple images are previewed and attached atomically ($confirm)', (tester) async {
      final ui = UiController(gateway)..sessionKey = 'a';
      var calls = 0;
      await tester.pumpWidget(
        home(
          ui,
          buildLightTheme(),
          picker: (limit) async {
            calls++;
            expectSync(limit, 9);
            return [
              for (final name in ['one.png', 'two.png'])
                XFile.fromData(base64Decode(SlowGateway.png), name: name, path: name, mimeType: 'image/png'),
            ];
          },
        ),
      );
      await tester.pumpAndSettle();
      final state = tester.state<ClawHomeState>(find.byType(ClawHome));
      state.input.text = 'keep draft';
      final picking = state.attach();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('gateway-pick-media')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('gateway-pick-multiple')), findsNothing);
      await state.attach(); // Duplicate taps must not open another picker.
      expect(calls, 1);
      expect(find.byType(GatewayImagesSelection), findsOneWidget, reason: ui.error);
      expect(state.attachments, isEmpty);
      expect(find.text('添加所选图片（2）'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('gateway-image-preview-0')));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      Navigator.of(tester.element(find.byType(ImageViewerPage))).pop();
      await tester.pumpAndSettle();
      if (confirm) {
        await tester.tap(find.text('添加所选图片（2）'));
      } else {
        Navigator.of(tester.element(find.byType(GatewayImagesSelection))).pop();
      }
      await tester.pumpAndSettle();
      await picking;
      expect(state.attachments.map((a) => a['fileName']), confirm ? ['one.png', 'two.png'] : isEmpty);
      expect(state.input.text, 'keep draft');
      expect(state.pickingImages, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final change in ['cancel', 'session', 'oversize', 'limit', 'preview-session']) {
    testWidgets('multi-selection discards cancelled stale or invalid batches ($change)', (tester) async {
      final ui = UiController(gateway)..sessionKey = 'a';
      final result = Completer<List<XFile>>();
      if (change == 'oversize') {
        gateway.hello = {
          'policy': {
            'attachments': {'maxImageBytes': 1},
          },
        };
      }
      await tester.pumpWidget(home(ui, buildLightTheme(), picker: (_) => result.future));
      await tester.pumpAndSettle();
      final state = tester.state<ClawHomeState>(find.byType(ClawHome));
      final picking = state.attach();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('gateway-pick-media')));
      await tester.pumpAndSettle();
      if (change == 'session') ui.sessionKey = 'another';
      result.complete(
        change == 'cancel'
            ? []
            : [
                for (var i = 0; i < (change == 'limit' ? 10 : 2); i++)
                  XFile.fromData(base64Decode(SlowGateway.png), name: '$i.png', path: '$i.png', mimeType: 'image/png'),
              ],
      );
      await tester.pumpAndSettle();
      if (change == 'preview-session') {
        expect(find.byType(GatewayImagesSelection), findsOneWidget, reason: ui.error);
        ui.sessionKey = 'another';
        await tester.tap(find.text('添加所选图片（2）'));
        await tester.pumpAndSettle();
      }
      await picking;
      expect(state.attachments, isEmpty);
      expect(state.pickingImages, isFalse);
      if (change == 'oversize' || change == 'limit') expect(ui.error, isNotEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('upload menu cancels without calling either native picker', (tester) async {
    final ui = UiController(gateway)..sessionKey = 'a';
    var calls = 0;
    Future<List<XFile>> picker(int _) async {
      calls++;
      return [];
    }

    await tester.pumpWidget(home(ui, buildLightTheme(), picker: picker, filePicker: picker));
    await tester.pumpAndSettle();
    final state = tester.state<ClawHomeState>(find.byType(ClawHome));
    final pending = state.attach();
    await tester.pumpAndSettle();
    expect(find.text('图片／视频'), findsOneWidget);
    expect(find.byKey(const ValueKey('gateway-pick-files')), findsOneWidget);
    Navigator.of(tester.element(find.byKey(const ValueKey('gateway-pick-files')))).pop();
    await tester.pumpAndSettle();
    await pending;
    expect(calls, 0);
    expect(state.attachments, isEmpty);
    expect(state.pickingImages, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final outcome in ['confirm', 'cancel', 'session', 'host', 'oversize', 'empty', 'total']) {
    testWidgets('file picker validates and confirms document plus video ($outcome)', (tester) async {
      final ui = UiController(gateway)..sessionKey = 'a';
      if (outcome == 'oversize') {
        gateway.hello = {
          'policy': {
            'attachments': {'maxBytes': 1},
          },
        };
      }
      if (outcome == 'total') {
        gateway.hello = {
          'policy': {'maxPayload': 65540},
        };
      }
      final result = Completer<List<XFile>>();
      await tester.pumpWidget(home(ui, buildLightTheme(), filePicker: (_) => result.future));
      await tester.pumpAndSettle();
      final state = tester.state<ClawHomeState>(find.byType(ClawHome));
      final picking = state.attach();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('gateway-pick-files')));
      await tester.pumpAndSettle();
      if (outcome == 'session') ui.sessionKey = 'b';
      if (outcome == 'host') ui.address = 'wss://other.example';
      result.complete([
        XFile.fromData(
          Uint8List.fromList(outcome == 'empty' ? [] : utf8.encode('%PDF-1.4')),
          path: 'report.pdf',
          name: 'report.pdf',
        ),
        XFile.fromData(
          Uint8List.fromList([0, 0, 0, 24, 102, 116, 121, 112, 105, 115, 111, 109]),
          path: 'clip.mp4',
          name: 'clip.mp4',
        ),
      ]);
      await tester.pumpAndSettle();
      if (outcome == 'confirm' || outcome == 'cancel') {
        expect(find.byType(GatewayAttachmentSelection), findsOneWidget, reason: ui.error);
        expect(find.text('report.pdf'), findsOneWidget);
        expect(find.text('clip.mp4'), findsOneWidget);
        if (outcome == 'confirm') {
          await tester.tap(find.text('添加所选附件（2）'));
        } else {
          Navigator.of(tester.element(find.byType(GatewayAttachmentSelection))).pop();
        }
        await tester.pumpAndSettle();
      }
      await picking;
      expect(state.attachments.length, outcome == 'confirm' ? 2 : 0);
      if (outcome == 'confirm') {
        expect(state.attachments.first['mimeType'], 'application/pdf');
        expect(state.attachments.last['mimeType'], 'video/mp4');
        late Future<void> sending;
        await tester.runAsync(() async {
          sending = state.send();
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(gateway.sent?['attachments'], hasLength(2));
        expect(gatewayFiles(ui.visibleMessages.single), hasLength(2));
        expect(gatewayImages(ui.visibleMessages.single), isEmpty);
        await tester.runAsync(() async {
          gateway.admission.complete();
          await sending;
        });
      }
      if (['oversize', 'empty', 'total'].contains(outcome)) expect(ui.error, isNotEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('failed file send restores attachment metadata and content for retry', (tester) async {
    final ui = UiController(gateway)..sessionKey = 'a';
    await tester.pumpWidget(home(ui, buildLightTheme()));
    await tester.pumpAndSettle();
    final state = tester.state<ClawHomeState>(find.byType(ClawHome));
    final file = {
      'type': 'file',
      'fileName': 'report.pdf',
      'mimeType': 'application/pdf',
      'content': base64Encode(utf8.encode('%PDF-1.4')),
      'sizeBytes': 8,
    };
    state.attachments.add(file);
    state.input.text = 'check this';
    gateway.reject = true;
    gateway.admission.complete();
    await tester.runAsync(() async {
      await state.send();
    });
    await tester.pumpAndSettle();
    expect(state.input.text, 'check this');
    expect(state.attachments.single, file);
    expect(ui.error, isNotEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('gallery media accepts a video without rendering it as an image', (tester) async {
    final ui = UiController(gateway)..sessionKey = 'a';
    await tester.pumpWidget(
      home(
        ui,
        buildLightTheme(),
        picker: (_) async => [
          XFile.fromData(
            Uint8List.fromList([0, 0, 0, 24, 102, 116, 121, 112, 105, 115, 111, 109]),
            path: 'clip.mp4',
            name: 'clip.mp4',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state<ClawHomeState>(find.byType(ClawHome));
    final picking = state.attach();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('gateway-pick-media')));
    await tester.pumpAndSettle();
    expect(find.byType(GatewayAttachmentSelection), findsOneWidget);
    await tester.tap(find.text('添加所选附件（1）'));
    await tester.pumpAndSettle();
    await picking;
    expect(state.attachments.single['type'], 'file');
    expect(state.attachments.single['mimeType'], 'video/mp4');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('OpenClaw composer follows persisted Return-to-send preference', (tester) async {
    SharedPreferences.setMockInitialValues({'return_key_sends': true});
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => call.method == 'readAll' ? <String, String>{} : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        null,
      ),
    );
    final ui = UiController(gateway)..sessionKey = 'a';
    await tester.pumpWidget(home(ui, buildLightTheme()));
    await tester.pumpAndSettle();
    final scope = ProviderScope.containerOf(tester.element(find.byType(ClawHome)));
    await tester.runAsync(() async {
      for (var i = 0; i < 50 && !scope.read(settingsProvider).loaded; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pumpAndSettle();
    expect(scope.read(settingsProvider).returnKeySends, isTrue);
    expect(tester.widget<Composer>(find.byType(Composer)).returnKeySends, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('plain-text history preserves admitted image through refresh and session re-entry', () async {
    final sending = c.send(
      'look',
      attachments: [
        {'type': 'image', 'mimeType': 'image/png', 'content': SlowGateway.png},
      ],
    );
    gateway.rows = [
      {'role': 'user', 'id': 'message-1', 'content': 'look'},
    ];
    gateway.admission.complete({});
    await sending;
    await c.history();
    expect(c.visibleMessages, hasLength(1));
    expect(gatewayImages(c.visibleMessages.single), hasLength(1));
    await c.history();
    expect(gatewayImages(c.visibleMessages.single), hasLength(1));
    gateway.rows = [];
    await c.select('b');
    expect(c.visibleMessages, isEmpty);
    gateway.rows = [
      {'role': 'user', 'id': 'message-1', 'content': 'look'},
    ];
    await c.select('a');
    expect(gatewayImages(c.visibleMessages.single), hasLength(1));
    // A canonical image replaces fallback bytes, rather than rendering twice.
    gateway.rows = [
      {
        'role': 'user',
        'id': 'message-1',
        'content': 'look',
        '__openclaw': {
          'media': [
            {'kind': 'image', 'path': 'media://inbound/a.png'},
          ],
        },
      },
    ];
    await c.history();
    expect(gatewayImages(c.visibleMessages.single).single['url'], 'media://inbound/a.png');
    expect(c.visibleMessages.single['_localImages'], isNull);
  });

  test('image fallback survives a fresh controller restoring its host-scoped snapshot', () async {
    final cache = MemorySnapshots();
    final writer = ClawController(client: gateway, snapshots: cache)..sessionKey = 'a';
    final sending = writer.send(
      'saved',
      attachments: [
        {'mimeType': 'image/png', 'content': SlowGateway.png},
      ],
    );
    gateway.rows = [
      {'id': 'saved-image', 'role': 'user', 'content': 'saved'},
    ];
    gateway.admission.complete({});
    await sending;
    await writer.history();
    final fresh = ClawController(snapshots: cache);
    addTearDown(fresh.dispose);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => null,
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        null,
      ),
    );
    await fresh.load();
    expect(fresh.sessionKey, 'a');
    expect(gatewayImages(fresh.visibleMessages.single), hasLength(1));
    expect(gatewayImages(fresh.visibleMessages.single).single['source']['data'], SlowGateway.png);
    writer.dispose();
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
