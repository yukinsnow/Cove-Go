import 'dart:io';
import 'dart:async';

import 'package:cryptography/cryptography.dart';
import 'package:dsh_app/openclaw/controller.dart';
import 'package:dsh_app/state/offline_chat.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dsh_app/state/offline_snapshot.dart';
import 'package:dsh_app/state/offline_identity.dart';

import '../remote/support/fake_relay.dart';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openclaw_client/openclaw_client.dart';

class _DisconnectedGateway extends GatewayClient {
  int attempts = 0;
  @override
  Future<Map<String, dynamic>> connect(String address, String token, DeviceIdentity identity) async {
    attempts++;
    throw StateError('offline');
  }
}

class _DelayedSnapshots extends OfflineSnapshotStore {
  final reading = Completer<void>();
  final result = Completer<Map<String, dynamic>?>();
  @override
  Future<Map<String, dynamic>?> read(String scope) {
    if (!reading.isCompleted) reading.complete();
    return result.future;
  }
}

class _Host extends ActiveHostController {
  @override
  HostRef build() => const HostRef.relay('a');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late SecretKey key;
  OfflineSnapshotStore store() => OfflineSnapshotStore(directory: () async => root, key: () async => key);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('offline-snapshot-test');
    key = await AesGcm.with256bits().newSecretKey();
  });
  tearDown(() async => root.delete(recursive: true));

  test('encrypted snapshots survive a fresh store, isolate scope and hide content on disk', () async {
    await store().write('host-a', {'text': 'private conversation'});
    expect(await store().read('host-a'), {'text': 'private conversation'});
    expect(await store().read('host-b'), isNull);
    final file = (await root.list().toList()).single as File;
    expect(await file.readAsString(), isNot(contains('private conversation')));
    expect(file.path, isNot(contains('host-a')));
    key = await AesGcm.with256bits().newSecretKey();
    expect(await store().read('host-a'), isNull);
  });

  test('corrupt and oversized caches are ignored without blocking startup', () async {
    final cache = store();
    await cache.write('a', {'text': 'ok'});
    final file = (await root.list().toList()).single as File;
    await file.writeAsString('broken');
    expect(await store().read('a'), isNull);
    await cache.write('large', {'text': 'x' * OfflineSnapshotStore.maxBytes});
    expect(await store().read('large'), isNull);
  });

  test('serialized writes keep newest snapshot and bound disk growth', () async {
    final cache = store();
    await Future.wait([
      for (var i = 0; i < 27; i++) cache.write('scope-$i', {'n': i}),
    ]);
    expect((await root.list().toList()).length, 24);
    await Future.wait([
      cache.write('latest', {'n': 1}),
      cache.write('latest', {'n': 2}),
    ]);
    expect(await store().read('latest'), {'n': 2});
  });

  test('chat eviction preserves the local identity needed for offline startup', () async {
    final cache = store();
    await cache.write('dsh-identity:binding', {'digest': 'fixture'});
    await Future.wait([
      for (var i = 0; i < 27; i++) cache.write('chat-$i', {'n': i}),
    ]);
    expect(await store().read('dsh-identity:binding'), {'digest': 'fixture'});
    expect((await root.list().toList()).length, 25);
  });

  test('Gateway cold start restores messages before failed background connection; offline switching works', () async {
    final scope = OfflineSnapshotStore.digest(['gateway', 'wss://example.invalid', 'test-secret']);
    await store().write(scope, {
      'sessions': [
        {'key': 'a'},
        {'key': 'b'},
      ],
      'selected': 'a',
      'histories': {
        'a': [
          {'role': 'user', 'content': 'first'},
        ],
        'b': [
          {'role': 'assistant', 'content': 'second'},
        ],
      },
    });
    final secrets = <String, String>{'claw.address': 'wss://example.invalid', 'claw.token': 'test-secret'};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = Map.from(call.arguments as Map);
        if (call.method == 'read') return secrets[args['key']];
        if (call.method == 'write') secrets[args['key'] as String] = args['value'] as String;
        return null;
      },
    );
    final client = _DisconnectedGateway();
    final c = ClawController(client: client, snapshots: store());
    await c.load();
    expect(c.sessionKey, 'a');
    expect(c.messages.single['content'], 'first');
    expect(c.readingCache, isTrue);
    for (var i = 0; i < 20 && c.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(client.attempts, 1);
    expect(c.connected, isFalse);
    await c.select('b');
    expect(c.messages.single['content'], 'second');
    final revision = c.selectionRevision;
    await c.select('b');
    expect(c.selectionRevision, greaterThan(revision));
    c.dispose();
  });

  test('late startup cache cannot reconnect over an explicit connection choice', () async {
    final secrets = <String, String>{'claw.address': 'wss://example.invalid', 'claw.token': 'test-secret'};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final args = Map.from(call.arguments as Map);
        if (call.method == 'read') return secrets[args['key']];
        if (call.method == 'write') secrets[args['key'] as String] = args['value'] as String;
        return null;
      },
    );
    final snapshots = _DelayedSnapshots();
    final client = _DisconnectedGateway();
    final c = ClawController(client: client, snapshots: snapshots);
    final loading = c.load();
    await snapshots.reading.future;
    await c.connect('wss://example.invalid', 'test-secret');
    snapshots.result.complete({'sessions': [], 'selected': 'old', 'histories': {}});
    await loading;
    expect(client.attempts, 1);
    expect(c.sessionKey, isEmpty);
    c.dispose();
  });

  test('Remote display identity restores from local account without a host connection', () async {
    SharedPreferences.setMockInitialValues({});
    final identity = ReadListIdentity.of(['trusted-host']);
    final backend = FakeRelayBackend(
      user: const RelayUser(id: 'account-a', displayName: 'fixture'),
    );
    ProviderContainer container(ReadListIdentity? live) => ProviderContainer(
      overrides: [
        activeHostProvider.overrideWith(_Host.new),
        readListIdentityProvider.overrideWithValue(live),
        relayBackendProvider.overrideWithValue(backend),
        offlineSnapshotStoreProvider.overrideWithValue(store()),
      ],
    );
    final online = container(identity);
    expect(await online.read(offlineReadIdentityProvider.future), identity);
    online.dispose();
    backend.listError = StateError('Remote host listing unavailable');
    final offline = container(null);
    expect(await offline.read(offlineReadIdentityProvider.future), identity);
    offline.dispose();
    backend.user = const RelayUser(id: 'account-b', displayName: 'other account');
    final other = container(null);
    expect(await other.read(offlineReadIdentityProvider.future), isNull);
    other.dispose();
  });

  test('DSH cold disconnected controller displays cached history read-only', () async {
    SharedPreferences.setMockInitialValues({});
    const identity = ReadListIdentity('offline-fixture');
    await store().write(
      'dsh-chat:${identity.digest}:s',
      offlineChat([const AssistantChatItem(id: 'a1', seq: 1, text: 'saved answer', reasoning: '')], 'saved title'),
    );
    final container = ProviderContainer(
      overrides: [
        activeHostProvider.overrideWith(_Host.new),
        activeConnectionProvider.overrideWith((ref) => const AsyncData(null)),
        readListIdentityProvider.overrideWithValue(identity),
        offlineSnapshotStoreProvider.overrideWithValue(store()),
      ],
    );
    final subscription = container.listen(chatProvider('s'), (_, _) {});
    await container.read(offlineChatSnapshotProvider('s').future);
    await Future<void>.delayed(Duration.zero);
    final state = container.read(chatProvider('s'));
    expect((state.items.single as AssistantChatItem).text, 'saved answer');
    expect(state.title, 'saved title');
    expect(state.loading, isFalse);
    expect(state.controlReady, isFalse);
    expect(state.approvals, isEmpty);
    subscription.close();
    container.dispose();
  });

  test('DSH cache restores only durable text, not running drafts or control authority', () {
    final snapshot = offlineChat([
      UserChatItem(seq: 1, time: DateTime(2026), text: 'hello', images: const [], files: const []),
      const AssistantChatItem(id: 'a2', seq: 2, text: 'answer', reasoning: 'thought'),
      const AssistantChatItem(id: 'draft', text: 'unfinished', reasoning: '', streaming: true),
    ], 'title');
    final restored = restoreOfflineChat(snapshot);
    expect(restored.length, 2);
    expect((restored.last as AssistantChatItem).text, 'answer');
    expect((restored.last as AssistantChatItem).streaming, isFalse);
    expect(restoreOfflineChat({'items': 'corrupt'}), isEmpty);
  });
}
