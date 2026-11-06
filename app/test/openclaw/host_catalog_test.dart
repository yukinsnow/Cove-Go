import 'dart:convert';

import 'package:dsh_app/openclaw/controller.dart';
import 'package:dsh_app/openclaw/host_catalog.dart';
import 'package:dsh_app/state/offline_snapshot.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openclaw_client/openclaw_client.dart';

class MemoryStorage extends FlutterSecureStorage {
  MemoryStorage([Map<String, String>? initial]) : values = {...?initial};
  final Map<String, String> values;
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }
}

class FailingCatalogStorage extends MemoryStorage {
  FailingCatalogStorage(super.initial);
  bool fail = true;
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (fail && key == GatewayHostCatalog.catalogKey) throw StateError('keychain unavailable');
    await super.write(key: key, value: value);
  }
}

class MockGateway extends GatewayClient {
  bool reject = false;
  String? credential, identityId;
  @override
  Future<Map<String, dynamic>> connect(String address, String token, DeviceIdentity identity) async {
    credential = token;
    identityId = identity.id;
    if (reject) throw StateError('offline');
    connected = true;
    return {};
  }

  @override
  Future<void> disconnect() async {
    connected = false;
  }

  @override
  Future<dynamic> request(String method, [Map<String, dynamic> params = const {}]) async => switch (method) {
    'sessions.list' => {'sessions': <dynamic>[]},
    'models.list' => {'models': <dynamic>[]},
    _ => <String, dynamic>{},
  };
}

class NoSnapshots extends OfflineSnapshotStore {
  @override
  Future<Map<String, dynamic>?> read(String scope) async => null;
  @override
  Future<void> write(String scope, Map<String, dynamic> snapshot) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('migrates legacy credential SSH and paired identity once into secure catalog', () async {
    final storage = MemoryStorage({
      'claw.address': 'wss://one.example',
      'claw.token': 'one-secret',
      'claw.sshId': 'ssh-one',
      'claw.identity': 'paired-seed',
    });
    final catalog = GatewayHostCatalog(storage: storage);
    await catalog.load();
    expect(catalog.controllers.keys, ['legacy']);
    expect(catalog.controllers['legacy']!.address, 'wss://one.example');
    expect(catalog.controllers['legacy']!.sshId, 'ssh-one');
    expect(storage.values['claw.host.legacy.identity'], 'paired-seed');
    expect(storage.values.containsKey('claw.token'), false);
    expect(storage.values[GatewayHostCatalog.catalogKey], isNot(contains('one-secret')));
    catalog.dispose();
    final restored = GatewayHostCatalog(storage: storage);
    await restored.load();
    expect(restored.controllers.keys, ['legacy']);
    expect(restored.controllers['legacy']!.token, 'one-secret');
    restored.dispose();
  });

  test('interrupted migration keeps legacy credentials and can finish on retry', () async {
    final storage = FailingCatalogStorage({
      'claw.address': 'wss://old.example',
      'claw.token': 'old-secret',
      'claw.identity': 'paired-seed',
    });
    final first = GatewayHostCatalog(storage: storage);
    await expectLater(first.load(), throwsStateError);
    expect(storage.values['claw.token'], 'old-secret');
    expect(storage.values['claw.identity'], 'paired-seed');
    first.dispose();
    storage.fail = false;
    final retry = GatewayHostCatalog(storage: storage);
    await retry.load();
    expect(retry.controllers['legacy']!.token, 'old-secret');
    expect(storage.values['claw.host.legacy.identity'], 'paired-seed');
    expect(storage.values.containsKey('claw.token'), false);
    retry.dispose();
  });

  test('parallel controllers keep both links identities and state; removing one leaves the other intact', () async {
    final storage = MemoryStorage();
    final clients = <String, MockGateway>{};
    final catalog = GatewayHostCatalog(
      storage: storage,
      createController: (id) => ClawController(
        profileId: id,
        storage: storage,
        client: clients[id] = MockGateway(),
        snapshots: NoSnapshots(),
      ),
    );
    await catalog.load();
    final first = catalog.controllers['legacy']!, second = catalog.add();
    await Future.wait([
      first.connect('wss://one.example', 'first-secret'),
      second.connect('wss://two.example', 'second-secret'),
    ]);
    expect(first.connected && second.connected, true);
    expect(clients[first.profileId]!.identityId, isNot(clients[second.profileId]!.identityId));
    first.sessionKey = 'first-session';
    second.sessionKey = 'second-session';
    first.messages = [
      {'role': 'assistant', 'content': 'first-only'},
    ];
    second.messages = [
      {'role': 'assistant', 'content': 'second-only'},
    ];
    await catalog.pick(second.profileId!);
    await catalog.pick(first.profileId!);
    expect(first.connected && second.connected, true);
    expect(first.sessionKey, 'first-session');
    expect(second.messages.single['content'], 'second-only');
    await catalog.remove(first.profileId!);
    expect(second.connected, true);
    expect(second.sessionKey, 'second-session');
    expect(storage.values['claw.host.${second.profileId}.token'], 'second-secret');
    expect(storage.values.containsKey('claw.host.legacy.token'), false);
    expect(storage.values.containsKey('claw.host.legacy.identity'), false);
    final saved = jsonDecode(storage.values[GatewayHostCatalog.catalogKey]!) as Map;
    expect(saved['ids'], [second.profileId]);
    catalog.dispose();
    final restored = GatewayHostCatalog(storage: storage);
    await restored.load();
    expect(restored.selected, second.profileId);
    expect(restored.controllers.keys, [second.profileId]);
    expect(restored.controllers[second.profileId]!.token, 'second-secret');
    restored.dispose();
  });

  test('offline configuration remains saved and can be removed; cancelled add is not persisted', () async {
    final storage = MemoryStorage();
    final catalog = GatewayHostCatalog(
      storage: storage,
      createController: (id) => ClawController(
        profileId: id,
        storage: storage,
        client: MockGateway()..reject = true,
        snapshots: NoSnapshots(),
      ),
    );
    await catalog.load();
    final cancelled = catalog.add();
    await catalog.discardEmpty(cancelled.profileId!);
    expect(catalog.controllers.containsKey(cancelled.profileId), false);
    final offline = catalog.add();
    await offline.connect('wss://offline.example', 'offline-secret');
    expect(offline.connected, false);
    expect(offline.error, contains('offline'));
    expect(storage.values[GatewayHostCatalog.catalogKey], contains(offline.profileId!));
    expect(storage.values['claw.host.${offline.profileId}.token'], 'offline-secret');
    await catalog.remove(offline.profileId!);
    expect(storage.values.containsKey('claw.host.${offline.profileId}.token'), false);
    catalog.dispose();
  });
}
