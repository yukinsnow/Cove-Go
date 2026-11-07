import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_app/main_openclaw.dart';
import 'package:dsh_app/openclaw/home.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/host_switcher.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/web/mode_home.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:dsh_app/ui/shell/session_search_page.dart';

import '../remote/support/fake_relay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
  });
  testWidgets('Gateway composer centers single-line text and all controls', (tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ProviderScope(child: OpenClawApp()));
    await tester.pumpAndSettle();
    final composer = find.byType(Composer);
    final field = find.descendant(of: composer, matching: find.byType(TextField));
    final plus = find.descendant(of: composer, matching: find.byIcon(AppIcons.add));
    final queue = find.descendant(of: composer, matching: find.byIcon(AppIcons.queued));
    final send = find.descendant(of: composer, matching: find.byIcon(AppIcons.send));
    void checkCenters() {
      final center = tester.getCenter(composer).dy;
      for (final item in [field, plus, queue, send]) {
        expect(tester.getCenter(item).dy, closeTo(center, 0.5));
      }
      expect(tester.getSize(composer).height, closeTo(56, 0.5));
    }

    checkCenters();
    await tester.enterText(field, '测试输入');
    await tester.pumpAndSettle();
    checkCenters();
    await tester.enterText(field, '第一行\n第二行\n第三行');
    await tester.pumpAndSettle();
    expect(tester.getSize(composer).height, greaterThan(56));
    expect(tester.getCenter(plus).dy, closeTo(tester.getCenter(send).dy, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('disconnected client, connect form and language switch', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpenClawApp()));
    await tester.pumpAndSettle();
    expect(find.text('Cove-Go'), findsOneWidget);
    expect(find.text('未连接'), findsWidgets);
    expect(find.text('把 OpenClaw 装进口袋'), findsOneWidget);
    await tester.tap(find.text('连接 OpenClaw'));
    await tester.pumpAndSettle();
    expect(find.text('Gateway 地址（ws:// 或 wss://）'), findsOneWidget);
    expect(find.text('Gateway 令牌'), findsOneWidget);
    expect(find.text('直接连接'), findsOneWidget);
    expect(find.text('添加 SSH 连接'), findsOneWidget);
    expect(tester.widgetList<TextField>(find.byType(TextField)).any((w) => w.obscureText), isTrue);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(AppIcons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('English / 中文'), 250);
    await tester.tap(find.text('English / 中文'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(AppIcons.back));
    await tester.pumpAndSettle();
    expect(find.text('Disconnected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('one remote host picker replaces backend drawer and hides local execution', (tester) async {
    final backend = FakeRelayBackend();
    await tester.pumpWidget(
      ProviderScope(overrides: [relayBackendProvider.overrideWithValue(backend)], child: const OpenClawApp()),
    );
    await tester.pumpAndSettle();
    final original = tester.state<ClawHomeState>(find.byType(ClawHome));
    original.c.address = 'wss://gateway.example';
    await tester.tap(find.byIcon(AppIcons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('identity-host-switcher')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('gateway-host-row-legacy')), findsOneWidget);
    expect(find.text('本机'), findsNothing);
    expect(find.text('DSH Remote'), findsNothing);
    // Picking a different protocol preserves the Gateway conversation owner.
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(ClawHome)));
    container.read(activeHostProvider.notifier).select(const HostRef.relay('test-host', name: 'Yuki-PC'));
    container.read(gatewayHostEntryProvider)!.onRemotePick();
    await tester.pumpAndSettle();
    expect(find.byType(ModeHome), findsOneWidget);
    // No wrapper app bar/drawer around the native conversation shell.
    expect(find.byType(AppBar), findsNothing);
    showHostSheet(tester.element(find.byType(ModeHome)), onManage: () {});
    await tester.pumpAndSettle();
    expect(find.text('本机'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('gateway-host-row-legacy')));
    await tester.pumpAndSettle();
    expect(identical(tester.state(find.byType(ClawHome)), original), isTrue);
    expect(find.text('未连接'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets('remote management configures Gateway from its list row', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [relayBackendProvider.overrideWithValue(FakeRelayBackend())],
        child: const OpenClawApp(),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state<ClawHomeState>(find.byType(ClawHome));
    state.switchHost();
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理远程主机'));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('remote-gateway-host-legacy')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('add-gateway-host')));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteScreen), findsOneWidget);
    expect(find.text('Gateway 地址（ws:// 或 wss://）'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('host picker has one manage entry and Gateway deletion stays in its section', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [relayBackendProvider.overrideWithValue(FakeRelayBackend())],
        child: const OpenClawApp(),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state<ClawHomeState>(find.byType(ClawHome));
    state.c.address = 'wss://gateway.example';
    state.c.token = 'test-token';
    state.c.sessions = [
      {'key': 'old'},
    ];
    state.c.changed();
    state.switchHost();
    await tester.pumpAndSettle();
    expect(find.text('连接与设置'), findsNothing);
    expect(find.text('管理远程主机'), findsOneWidget);
    await tester.tap(find.text('管理远程主机'));
    await tester.pumpAndSettle();
    expect(find.text('删除 OpenClaw 主机'), findsNothing);
    await tester.longPress(find.byKey(const ValueKey('remote-gateway-host-legacy')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(state.c.address, isNotEmpty);
    expect(find.text('删除 OpenClaw 主机'), findsNothing);
    await tester.longPress(find.byKey(const ValueKey('remote-gateway-host-legacy')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(find.byType(RemoteScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('add-gateway-host')), findsOneWidget);
    expect(state.c.address, isEmpty);
    expect(state.c.token, isEmpty);
    expect(state.c.sessions, isEmpty);
    expect(find.byKey(const ValueKey('remote-gateway-host-legacy')), findsNothing);
    await tester.tap(find.text('添加 OpenClaw 主机'));
    await tester.pumpAndSettle();
    expect(find.text('Gateway 地址（ws:// 或 wss://）'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('Gateway drawer reuses DSH header search and pinned footer controls', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ProviderScope(child: OpenClawApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final dynamic state = tester.state(find.byType(ClawHome));
    state.c.sessions = <Map<String, dynamic>>[
      {'key': 'one', 'displayName': 'Alpha', 'category': 'Projects'},
      {'key': 'two', 'displayName': 'Beta', 'hasActiveRun': true},
    ];
    state.c.changed();
    await tester.tap(find.byIcon(AppIcons.menu));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(NewChatButton), findsOneWidget);
    expect(find.byType(WebModeKey), findsOneWidget);
    expect(find.byType(SessionSearchBar), findsOneWidget);
    expect(find.byType(IdentityBar), findsOneWidget);
    expect(find.text('English / 中文'), findsNothing);
    expect(tester.getTopLeft(find.byType(IdentityBar)).dy, greaterThan(650));
    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('未分组'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('运行中'), findsNothing);
    expect(find.textContaining('未读'), findsNothing);
    expect(find.byKey(const ValueKey('unread')), findsNothing);
    await tester.tap(find.byType(SessionSearchBar));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(find.byType(TextField), 'Alpha');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Alpha'), findsWidgets);
    expect(find.text('Beta'), findsNothing);
    await tester.tap(find.byIcon(AppIcons.back));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byIcon(AppIcons.menu));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byTooltip('设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('连接与设置'), findsNothing);
    expect(find.text('管理远程主机'), findsOneWidget);
    expect(find.text('English / 中文'), findsOneWidget);
    expect(find.text('开源许可'), findsOneWidget);
    await tester.tap(find.text('管理远程主机'));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteScreen), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-gateway-host')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Gateway 地址（ws:// 或 wss://）'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  });
  testWidgets('keyboard dismissal clears native IME and preserves editing', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(const ProviderScope(child: OpenClawApp()));
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(ClawHome));
    state.c.sessionKey = 'test-session';
    state.c.sessions = <Map<String, dynamic>>[
      {'key': 'test-session', 'displayName': 'Test chat'},
    ];
    state.c.messages = <Map<String, dynamic>>[
      {'role': 'user', 'content': 'Hello'},
      {'role': 'assistant', 'content': 'A **reply**'},
    ];
    state.c.changed();
    await tester.pumpAndSettle();
    expect(find.byType(Composer), findsOneWidget);
    expect(find.byType(UserBubble), findsOneWidget);
    expect(find.text('Test chat'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(Composer), matching: find.byType(TextField)));
    await tester.pumpAndSettle();
    expect(state.composerFocus.hasFocus, isTrue);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('收起键盘'));
    await tester.pumpAndSettle();
    expect(state.composerFocus.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    // Simulate a native IME still visible after Flutter has already lost focus.
    await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    expect(tester.testTextInput.isVisible, isTrue);
    tester.testTextInput.log.clear();
    await tester.tap(find.byTooltip('收起键盘'));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.log.any((call) => call.method == 'TextInput.hide'), isTrue);
    expect(tester.testTextInput.isVisible, isFalse);
    // Dismissal must leave the field editable and preserve its draft.
    final field = find.descendant(of: find.byType(Composer), matching: find.byType(TextField));
    await tester.tap(field);
    await tester.pumpAndSettle();
    expect(state.composerFocus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.enterText(field, '保留草稿');
    await tester.tap(find.byTooltip('收起键盘'));
    await tester.pumpAndSettle();
    expect(state.input.text, '保留草稿');
    expect(tester.testTextInput.isVisible, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS, TargetPlatform.android}));
}
