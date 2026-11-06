import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/openclaw/backend_home.dart';
import 'package:dsh_app/openclaw/controller.dart';
import 'package:dsh_app/openclaw/home.dart';
import 'package:dsh_app/openclaw/host_catalog.dart';
import 'package:dsh_app/openclaw/remote_theme.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/host_switcher.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/remote/ssh_host_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../remote/support/fake_relay.dart';
import '../support/test_fonts.dart';
import 'host_catalog_test.dart' show MemoryStorage, MockGateway, NoSnapshots;

class LoadedController extends ClawController {
  LoadedController(String id, MemoryStorage storage)
    : super(profileId: id, storage: storage, client: MockGateway(), snapshots: NoSnapshots());
  @override
  Future<void> load() async {
    client.connected = true;
    changed();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GatewayHostCatalog catalog;
  final capture = GlobalKey();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final storage = MemoryStorage({
      GatewayHostCatalog.catalogKey: jsonEncode({
        'ids': ['one', 'two'],
        'selected': 'one',
      }),
      'claw.host.one.address': 'wss://one.example',
      'claw.host.one.token': 'one-secret',
      'claw.host.two.address': 'wss://two.example',
      'claw.host.two.token': 'two-secret',
    });
    catalog = GatewayHostCatalog(storage: storage, createController: (id) => LoadedController(id, storage));
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(402, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(catalog.load);
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: ProviderScope(
          overrides: [relayBackendProvider.overrideWithValue(FakeRelayBackend())],
          child: MaterialApp(
            theme: withTestFonts(buildRemoteDarkTheme()),
            debugShowCheckedModeBanner: false,
            locale: const Locale('zh', 'CN'),
            supportedLocales: AppLocale.supported,
            localizationsDelegates: L10n.localizationsDelegates,
            home: BackendHome(catalog: catalog, onLanguage: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'two live Gateways switch without replacing owner draft or history; deleting inactive host isolates secrets',
    (tester) async {
      await pump(tester);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      final one = tester.state<ClawHomeState>(find.byType(ClawHome));
      expect(one.c.profileId, 'one');
      one.input.text = 'draft-one';
      one.c.sessionKey = 'one-chat';
      final directory = ProviderScope.containerOf(tester.element(find.byType(ClawHome)))
          .read(gatewayHostEntryProvider)!;
      expect(directory.hosts.length, 2);
      directory.hosts.last.onPick();
      await tester.pumpAndSettle();
      final two = tester.state<ClawHomeState>(find.byType(ClawHome));
      expect(two.c.profileId, 'two');
      two.input.text = 'draft-two';
      two.c.sessionKey = 'two-chat';
      directory.hosts.first.onPick();
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(ClawHome)), same(one));
      expect(one.input.text, 'draft-one');
      expect(two.input.text, 'draft-two');
      expect(one.c.sessionKey, 'one-chat');
      expect(two.c.sessionKey, 'two-chat');
      one.manageHosts();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('add-gateway-host')), findsOneWidget);
      expect(find.byKey(const ValueKey('add-gateway-ssh-host')), findsOneWidget);
      expect(find.text('删除 OpenClaw 主机'), findsNothing);
      final row = find.byKey(const ValueKey('remote-gateway-host-two'));
      await tester.ensureVisible(row);
      await tester.drag(row, const Offset(-150, 0));
      await tester.pumpAndSettle();
      for (final element in find.byType(Scrollable).evaluate()) {
        final state = (element as StatefulElement).state as ScrollableState;
        if (state.position.axis == Axis.vertical) state.position.jumpTo(0);
      }
      await tester.pumpAndSettle();
      final boundary = capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../build/openclaw/multi-host-swipe-preview.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('two.example'), findsWidgets);
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      expect(catalog.controllers.keys, ['one']);
      expect(one.c.token, 'one-secret');
      expect(one.c.sessionKey, 'one-chat');
      expect(one.input.text, 'draft-one');
      expect(find.byKey(const ValueKey('remote-gateway-host-two')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('direct add opens empty Gateway form and cancellation preserves existing hosts', (tester) async {
    await pump(tester);
    tester.state<ClawHomeState>(find.byType(ClawHome)).manageHosts();
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('add-gateway-host'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('Gateway 地址（ws:// 或 wss://）'), findsOneWidget);
    expect(find.text('Gateway 令牌'), findsOneWidget);
    final dialog = find.byType(AlertDialog);
    expect(
      tester.widget<TextField>(find.descendant(of: dialog, matching: find.byType(TextField)).first).controller!.text,
      isEmpty,
    );
    Navigator.of(tester.element(dialog)).pop();
    await tester.pumpAndSettle();
    expect(catalog.controllers.keys, ['one', 'two']);
    expect(catalog.controllers.values.every((c) => c.connected), true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('add via SSH opens dedicated SSH form and cancelling creates no extra Gateway', (tester) async {
    await pump(tester);
    tester.state<ClawHomeState>(find.byType(ClawHome)).manageHosts();
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('add-gateway-ssh-host'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(SshHostFormPage), findsOneWidget);
    expect(tester.widget<SshHostFormPage>(find.byType(SshHostFormPage)).gatewayOnly, true);
    Navigator.of(tester.element(find.byType(SshHostFormPage))).pop();
    await tester.pumpAndSettle();
    expect(catalog.controllers.keys, ['one', 'two']);
    expect(find.byType(RemoteScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
