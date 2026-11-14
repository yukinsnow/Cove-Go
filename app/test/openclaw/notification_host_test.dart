import 'dart:async';

import 'package:dsh_app/openclaw/controller.dart';
import 'package:dsh_app/openclaw/host_catalog.dart';
import 'package:dsh_app/openclaw/notification_host.dart';
import 'package:dsh_app/openclaw/notifications.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'host_catalog_test.dart' show MemoryStorage, MockGateway, NoSnapshots;

class NoticeGateway extends MockGateway {
  final frames = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Map<String, dynamic>> get events => frames.stream;
  @override
  Future<void> dispose() async {
    await frames.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cove/notifications');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final retire in ['none', 'preference', 'disconnect', 'host', 'reconnect', 'denied']) {
    testWidgets('live lifecycle reaches native bridge; retirement=$retire', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final storage = MemoryStorage();
      final catalog = GatewayHostCatalog(storage: storage);
      final client = NoticeGateway()..connected = true;
      final controller = ClawController(profileId: 'one', storage: storage, client: client, snapshots: NoSnapshots())
        ..address = 'wss://one.example'
        ..token = 'test-only'
        ..sessionKey = 'different-visible-chat';
      catalog.controllers['one'] = controller;
      final container = ProviderContainer();
      await container.read(coveNotificationsEnabledProvider.notifier).setEnabled(true);
      final permission = Completer<Map<String, dynamic>>();
      final posts = <Map>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'status') return permission.future;
        if (call.method == 'show') posts.add(call.arguments as Map);
        return null;
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: CoveNotificationHost(catalog: catalog, onTap: (_) async {}, child: const SizedBox()),
        ),
      );
      final frame = <String, dynamic>{
        'event': 'sessions.changed',
        'payload': {
          'sessionKey': 'finished-chat',
          'phase': 'end',
          'runId': 'internal',
          'clientRunId': 'client',
          'session': {'key': 'finished-chat', 'status': 'done', 'lastRunId': 'client'},
        },
      };
      client.frames.add(frame);
      await tester.pump();
      if (retire == 'preference') await container.read(coveNotificationsEnabledProvider.notifier).setEnabled(false);
      if (retire == 'disconnect') client.connected = false;
      if (retire == 'host') catalog.controllers.remove('one');
      if (retire == 'reconnect') await controller.connect(controller.address, controller.token);
      permission.complete({'native': true, 'enabled': retire != 'denied'});
      await tester.pumpAndSettle();
      expect(posts.length, retire == 'none' ? 1 : 0);
      if (retire == 'none') {
        expect(posts.single['target'], {'backend': 'openclaw', 'host': 'one', 'session': 'finished-chat'});
        expect(posts.single['body'], isNot(contains('test-only')));
        client.frames.add(frame);
        client.frames.add({
          'event': 'chat',
          'payload': {'state': 'final', 'runId': 'client', 'sessionKey': 'finished-chat'},
        });
        await tester.pumpAndSettle();
        expect(posts.length, 1);
      }
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      if (retire == 'host') controller.dispose();
      catalog.dispose();
    });
  }
}
