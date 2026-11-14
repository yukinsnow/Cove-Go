import 'dart:async';

import 'package:dsh_app/openclaw/notifications.dart';
import 'package:dsh_app/openclaw/notification_settings.dart';
import 'package:dsh_app/openclaw/remote_theme.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cove/notifications');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Map<String, dynamic> event(String state, {String run = 'run', String session = 'chat'}) => {
    'event': 'chat',
    'payload': <String, dynamic>{'state': state, 'runId': run, 'sessionKey': session},
  };
  for (final allowed in [true, false]) {
    testWidgets('notification settings explicitly requests permission and respects denial ($allowed)', (tester) async {
      var requests = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'request') requests++;
        return {'native': true, 'enabled': allowed};
      });
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: buildRemoteLightTheme(),
            locale: const Locale('zh', 'CN'),
            supportedLocales: AppLocale.supported,
            localizationsDelegates: L10n.localizationsDelegates,
            home: const Scaffold(body: SingleChildScrollView(child: CoveNotificationSettings())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, 0);
      final tile = tester.widget<SettingsSwitchTile>(find.byKey(const ValueKey('cove-notifications-enabled')));
      expect(tile.value, false);
      await tester.runAsync(() async {
        tile.onChanged!(true);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(tester.element(find.byType(CoveNotificationSettings)));
      expect(requests, 1);
      expect(container.read(coveNotificationsEnabledProvider), allowed);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  test('only terminal events notify; dedup is isolated by session and owner', () {
    final tracker = GatewayNoticeTracker();
    expect(tracker.consume(event('delta')), isNull);
    expect(tracker.consume(event('aborted')), isNull);
    final done = tracker.consume(event('final'))!;
    expect(done.failed, false);
    expect(done.session, 'chat');
    expect(tracker.consume(event('final')), isNull);
    expect(tracker.consume(event('error')), isNull);
    expect(tracker.consume(event('final', session: 'other')), isNotNull);
    expect(GatewayNoticeTracker().consume(event('final')), isNotNull);
    expect(tracker.consume(event('error', run: 'failed'))!.failed, true);
    expect(tracker.consume(event('final', run: '')), isNull);
    expect(tracker.consume({'event': 'chat', 'payload': 'invalid'}), isNull);
  });
  Map<String, dynamic> lifecycle(String status, {String phase = 'end', String run = 'run'}) => {
    'event': 'sessions.changed',
    'payload': {
      'sessionKey': 'chat',
      'phase': phase,
      'runId': 'internal-$run',
      'clientRunId': run,
      'session': {'key': 'chat', 'status': status, 'lastRunId': run},
    },
  };
  test('live roster terminals notify even without a selected-chat final', () {
    final tracker = GatewayNoticeTracker();
    expect(tracker.consume(lifecycle('done'))!.failed, false);
    expect(tracker.consume(event('final')), isNull);
    expect(tracker.consume(lifecycle('failed', phase: 'error', run: 'bad'))!.failed, true);
    expect(tracker.consume(lifecycle('timeout', run: 'slow'))!.failed, true);
    expect(tracker.consume(lifecycle('killed', run: 'stop')), isNull);
    expect(tracker.consume(lifecycle('interrupted', run: 'restart')), isNull);
    final reverse = GatewayNoticeTracker();
    expect(reverse.consume(event('final')), isNotNull);
    expect(reverse.consume(lifecycle('done')), isNull);
  });
  test('metadata, snapshots, yielded and stale run projections cannot notify', () {
    final tracker = GatewayNoticeTracker();
    expect(tracker.consume(lifecycle('done', phase: 'start')), isNull);
    expect(tracker.consume(lifecycle('done', phase: 'model')), isNull);
    final metadata = lifecycle('done');
    (metadata['payload'] as Map).remove('phase');
    expect(tracker.consume(metadata), isNull);
    expect(tracker.consume({'event': 'sessions.list', 'payload': lifecycle('done')['payload']}), isNull);
    final stale = lifecycle('done');
    ((stale['payload'] as Map)['session'] as Map)['lastRunId'] = 'previous-run';
    expect(tracker.consume(stale), isNull);
    final yielded = event('final');
    (yielded['payload'] as Map)['yielded'] = true;
    expect(tracker.consume(yielded), isNull);
    final malformed = event('final');
    (malformed['payload'] as Map)['state'] = 123;
    expect(tracker.consume(malformed), isNull);
    expect(tracker.consume(lifecycle('done')), isNotNull);
  });
  test('proactive sent heartbeat alerts only, without claiming a session', () {
    final tracker = GatewayNoticeTracker();
    Map<String, dynamic> heartbeat(String state, {bool silent = false}) => {
      'event': 'heartbeat',
      'payload': {'status': state, 'ts': 1234, 'silent': silent},
    };
    expect(tracker.consume(heartbeat('ok-token')), isNull);
    expect(tracker.consume(heartbeat('skipped')), isNull);
    expect(tracker.consume(heartbeat('sent', silent: true)), isNull);
    final notice = tracker.consume(heartbeat('sent'))!;
    expect(notice.attention, true);
    expect(notice.session, isEmpty);
    expect(tracker.consume(heartbeat('sent')), isNull);
  });
  test('tap parser rejects malformed and unrecognized backend targets', () {
    expect(CoveNotificationTarget.parse({'backend': 'shell', 'host': 'a', 'session': 'b'}), isNull);
    expect(CoveNotificationTarget.parse({'backend': 'openclaw', 'host': '', 'session': 'b'}), isNull);
    const target = CoveNotificationTarget(backend: 'openclaw', host: 'profile', session: 'chat');
    expect(CoveNotificationTarget.parse(target.toMap())!.session, 'chat');
  });
  test('bridge checks permission without prompting and never posts when denied', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return {'native': true, 'enabled': false};
    });
    final bridge = CoveNotificationBridge();
    expect(
      await bridge.show(
        id: 'a',
        title: 'Cove-Go',
        body: 'generic',
        target: const CoveNotificationTarget(backend: 'openclaw', host: 'a', session: 's'),
      ),
      false,
    );
    expect(calls, ['status']);
  });
  test('late permission result cannot post after preference/host retires', () async {
    final permission = Completer<Map>();
    var shows = 0, current = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'status') return permission.future;
      if (call.method == 'show') shows++;
      return null;
    });
    final bridge = CoveNotificationBridge();
    final posting = bridge.show(
      id: 'a',
      title: 'Cove-Go',
      body: 'generic',
      target: const CoveNotificationTarget(backend: 'openclaw', host: 'a', session: 's'),
      stillCurrent: () => current,
    );
    current = false;
    permission.complete({'native': true, 'enabled': true});
    expect(await posting, false);
    expect(shows, 0);
  });
  test('enabled bridge posts generic content and exact opaque navigation target', () async {
    Map? posted;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'status') return {'native': true, 'enabled': true};
      if (call.method == 'show') posted = call.arguments as Map;
      return null;
    });
    final bridge = CoveNotificationBridge();
    final notice = CoveNotice(id: 'run', session: 's', failed: false);
    expect(
      await bridge.show(
        id: notice.id,
        title: 'Cove-Go',
        body: notice.body,
        target: const CoveNotificationTarget(backend: 'openclaw', host: 'opaque-profile', session: 's'),
      ),
      true,
    );
    expect(posted!['title'], 'Cove-Go');
    expect(posted!['body'], isNot(contains('token')));
    expect((posted!['target'] as Map)['host'], 'opaque-profile');
  });
  test('permission is explicit and cold launch tap is delivered once', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'listen') return {'backend': 'openclaw', 'host': 'a', 'session': 's'};
      return {'native': true, 'enabled': true};
    });
    final bridge = CoveNotificationBridge();
    final taps = <CoveNotificationTarget>[];
    await bridge.listen(taps.add);
    expect(taps.single.session, 's');
    expect(calls, ['listen']);
    await bridge.status(request: true);
    expect(calls.last, 'request');
    bridge.stop();
  });
  test('preferences default off and disabling clears posted notifications', () async {
    var cancels = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'cancelAll') cancels++;
      return null;
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(coveNotificationsEnabledProvider), false);
    final prefs = container.read(coveNotificationsEnabledProvider.notifier);
    await prefs.setEnabled(true);
    expect(container.read(coveNotificationsEnabledProvider), true);
    await prefs.setEnabled(false);
    expect(container.read(coveNotificationsEnabledProvider), false);
    expect(cancels, 1);
  });
}
