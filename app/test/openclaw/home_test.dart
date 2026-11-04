import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_app/main_openclaw.dart';
import 'package:dsh_app/openclaw/home.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';

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
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('把 OpenClaw 装进口袋'), findsOneWidget);
    await tester.tap(find.text('连接 OpenClaw'));
    await tester.pumpAndSettle();
    expect(find.text('Gateway 地址（wss://）'), findsOneWidget);
    expect(find.text('Gateway 令牌'), findsOneWidget);
    expect(tester.widgetList<TextField>(find.byType(TextField)).any((w) => w.obscureText), isTrue);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English / 中文'));
    await tester.pumpAndSettle();
    expect(find.text('Disconnected'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('both backends share a shell without replacing OpenClaw state', (tester) async {
    final backend = FakeRelayBackend();
    await tester.pumpWidget(
      ProviderScope(overrides: [relayBackendProvider.overrideWithValue(backend)], child: const OpenClawApp()),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RemoteScreen, skipOffstage: false), findsNothing);
    final original = tester.state(find.byType(ClawHome));
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DSH Remote'));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteScreen), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenClaw'));
    await tester.pumpAndSettle();
    expect(identical(tester.state(find.byType(ClawHome)), original), isTrue);
    expect(find.text('未连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
