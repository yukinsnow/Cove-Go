import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/openclaw/controller.dart';
import 'package:dsh_app/openclaw/home.dart';
import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_filter_bar.dart';
import 'package:dsh_app/ui/shell/session_search_page.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('real Gateway handshake keeps DSH chrome after connect, select and reconnect', (tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
    final controller = ClawController();
    HttpServer? server;
    final peers = <WebSocket>[];
    final sessions = [
      {
        'key': 'alpha',
        'displayName': '连接后的对话',
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'model': 'test/example',
        'category': 'Work',
      },
      {
        'key': 'beta',
        'displayName': '运行中的对话',
        'updatedAt': DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch,
        'hasActiveRun': true,
        'category': 'Research',
      },
    ];
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server!.listen((request) async {
        final peer = await WebSocketTransformer.upgrade(request);
        peers.add(peer);
        peer.add(
          jsonEncode({
            'type': 'event',
            'event': 'connect.challenge',
            'payload': {'nonce': 'fixture', 'ts': 42},
          }),
        );
        peer.listen((raw) {
          final frame = jsonDecode(raw as String) as Map;
          final payload = switch (frame['method']) {
            'connect' => {'type': 'hello-ok', 'protocol': 4},
            'sessions.list' => {'sessions': sessions},
            'sessions.groups.list' => {
              'groups': [
                {'name': 'Work', 'position': 0},
                {'name': 'Research', 'position': 1},
                {'name': 'Empty', 'position': 2},
              ],
              'sectionOrder': ['category:Research', 'category:Work'],
            },
            'models.list' => {'models': <dynamic>[]},
            'chat.history' => {
              'messages': [
                for (var i = 0; i < 80; i++) {'role': 'user', 'content': 'History message $i'},
              ],
            },
            _ => <String, dynamic>{},
          };
          peer.add(jsonEncode({'type': 'res', 'id': frame['id'], 'ok': true, 'payload': payload}));
        });
      });
    });
    final capture = GlobalKey();
    AppLocale.use(const Locale('zh', 'CN'));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildLightTheme(),
          locale: const Locale('zh', 'CN'),
          localizationsDelegates: const [
            L10n.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocale.supported,
          home: RepaintBoundary(
            key: capture,
            child: ClawHome(controller: controller, onLanguage: () {}),
          ),
        ),
      ),
    );
    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
    }

    await settle();
    final state = tester.state<ClawHomeState>(find.byType(ClawHome));
    Future<void> checkDrawer() async {
      state.scaffoldKey.currentState!.openDrawer();
      await settle();
      expect(find.byType(DrawerBrandHeader), findsOneWidget);
      expect(find.byType(NewChatButton), findsOneWidget);
      expect(find.byType(SessionSearchBar), findsOneWidget);
      expect(find.byType(SessionFilterRow), findsNothing);
      expect(find.byType(IdentityBar), findsOneWidget);
      expect(find.byType(SessionDrawerSurface), findsOneWidget);
      expect(tester.getSize(find.byType(SessionDrawerSurface)).width, 320);
      expect(tester.getTopLeft(find.byType(IdentityBar)).dy, greaterThan(750));
      expect(find.text('English / 中文'), findsNothing);
      expect(find.text('开源许可'), findsNothing);
      expect(find.descendant(of: find.byType(SessionDrawerSurface), matching: find.byType(TextField)), findsNothing);
      expect(tester.takeException(), isNull);
    }

    await checkDrawer();
    state.closeSidebar();
    await settle();
    for (var attempt = 0; attempt < 2; attempt++) {
      await tester.runAsync(() => controller.connect('ws://127.0.0.1:${server!.port}', 'fixture-token'));
      expect(controller.connected, isTrue);
      expect(controller.error, isEmpty);
      await tester.runAsync(() => controller.select('alpha'));
      await settle();
      expect(state.scroll.position.pixels, closeTo(0, 0.5));
      expect(state.scroll.position.maxScrollExtent, greaterThan(500));
      expect(find.text('History message 79').hitTestable(), findsOneWidget);
      state.scroll.jumpTo(500);
      await settle();
      controller.changed();
      await settle();
      expect(state.scroll.position.pixels, closeTo(500, 0.5), reason: 'reading older messages must not force a jump');
      for (final key in ['beta', 'alpha', 'alpha']) {
        await tester.runAsync(() => controller.select(key));
        await settle();
        expect(state.scroll.position.pixels, closeTo(0, 0.5), reason: 'entering $key always starts at newest');
        expect(find.text('History message 79').hitTestable(), findsOneWidget);
      }
      expect(find.byType(ChatHeader), findsOneWidget);
      expect(tester.widget<ChatHeader>(find.byType(ChatHeader)).useDshState, isFalse);
      await checkDrawer();
      expect(find.text('今天'), findsNothing);
      expect(find.text('昨天'), findsNothing);
      expect(find.textContaining('未读'), findsNothing);
      expect(find.byKey(const ValueKey('unread')), findsNothing);
      expect(find.text('Research'), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Empty'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Work')).dy,
        lessThan(tester.getTopLeft(find.text('Research')).dy),
        reason: 'newest member wins over Gateway catalog order',
      );
      expect(tester.getTopLeft(find.text('Research')).dy, lessThan(tester.getTopLeft(find.text('Empty')).dy));
      expect(
        find.descendant(of: find.byType(SessionTile), matching: find.byType(CircularProgressIndicator)),
        findsOneWidget,
      );
      // A background session changes state without opening it or reloading history.
      Future<void> emit(Map<String, dynamic> payload) async {
        await tester.runAsync(() async {
          peers.last.add(jsonEncode({'type': 'event', 'event': 'sessions.changed', 'payload': payload}));
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await settle();
      }

      await emit({
        'sessionKey': 'beta',
        'updatedAt': DateTime.now().add(const Duration(minutes: 1)).millisecondsSinceEpoch,
      });
      expect(
        tester.getTopLeft(find.text('Research')).dy,
        lessThan(tester.getTopLeft(find.text('Work')).dy),
        reason: 'background updates reorder groups immediately',
      );
      await emit({'sessionKey': 'beta', 'hasActiveRun': false, 'status': 'done'});
      expect(
        find.descendant(of: find.byType(SessionTile), matching: find.byType(CircularProgressIndicator)),
        findsNothing,
      );
      await emit({
        'sessionKey': 'beta',
        'session': {'hasActiveRun': true, 'status': 'running'},
      });
      expect(
        find.descendant(of: find.byType(SessionTile), matching: find.byType(CircularProgressIndicator)),
        findsOneWidget,
      );
      await emit({'sessionKey': 'beta', 'category': 'Work', 'displayName': 'Renamed task'});
      expect(
        controller.isSessionRunning(controller.sessions.last),
        isTrue,
        reason: 'omitted activity must not clear the running flag',
      );
      expect(find.text('Renamed task'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Renamed task')).dy,
        lessThan(tester.getTopLeft(find.descendant(of: find.byType(SessionTile), matching: find.text('连接后的对话'))).dy),
        reason: 'members also sort newest first',
      );
      await emit({'sessionKey': 'beta', 'category': null});
      expect(
        tester.getTopLeft(find.text('未分组')).dy,
        lessThan(tester.getTopLeft(find.text('Work')).dy),
        reason: 'ungrouped participates in the same activity order',
      );
      await emit({'sessionKey': 'beta', 'hasActiveRun': false, 'status': 'failed'});
      expect(
        find.descendant(of: find.byType(SessionTile), matching: find.byType(CircularProgressIndicator)),
        findsNothing,
      );
      if (attempt == 1) {
        await emit({'sessionKey': 'beta', 'hasActiveRun': true, 'status': 'running'});
        final boundary = capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('../build/openclaw/connected-drawer-preview.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      state.closeSidebar();
      await settle();
    }
    await tester.runAsync(controller.removeHost);
    expect(controller.address, isEmpty);
    expect(controller.token, isEmpty);
    expect(controller.connected, false);
    await settle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle();
    await tester.runAsync(() async {
      for (final peer in peers) {
        await peer.close();
      }
      await server!.close(force: true);
    });
  });
}
