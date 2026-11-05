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
  testWidgets('disconnected client, connect form and language switch', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpenClawApp()));
    await tester.pumpAndSettle();
    expect(find.text('OpenClaw Go'), findsOneWidget);
    expect(find.text('未连接'), findsWidgets);
    expect(find.text('把 OpenClaw 装进口袋'), findsOneWidget);
    await tester.tap(find.text('连接 OpenClaw'));
    await tester.pumpAndSettle();
    expect(find.text('Gateway 地址（wss://）'), findsOneWidget);
    expect(find.text('Gateway 令牌'), findsOneWidget);
    expect(tester.widgetList<TextField>(find.byType(TextField)).any((w) => w.obscureText), isTrue);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(AppIcons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
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
    final original = tester.state(find.byType(ClawHome));
    await tester.tap(find.byIcon(AppIcons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('identity-host-switcher')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('gateway-host-row')), findsOneWidget);
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
    await tester.tap(find.byKey(const ValueKey('gateway-host-row')));
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
    await tester.tap(find.text('连接电脑或服务器'));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('remote-gateway-host')), findsOneWidget);
    expect(find.text('OpenClaw Gateway'), findsOneWidget);
    await tester.tap(find.byTooltip('连接与设置'));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteScreen), findsNothing);
    expect(find.text('Gateway 地址（wss://）'), findsOneWidget);
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
      {'key': 'one', 'displayName': 'Alpha'},
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
    await tester.tap(find.text('运行中'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('Beta'), findsOneWidget);
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
    expect(find.text('连接与设置'), findsOneWidget);
    expect(find.text('English / 中文'), findsOneWidget);
    expect(find.text('开源许可'), findsOneWidget);
    await tester.tap(find.text('连接与设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Gateway 地址（wss://）'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  });
  testWidgets('DSH composer and messages retain keyboard dismissal on a phone', (tester) async {
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
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
