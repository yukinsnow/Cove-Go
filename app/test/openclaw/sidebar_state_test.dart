import 'dart:async';

import 'package:dsh_app/openclaw/controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openclaw_client/openclaw_client.dart';

import 'host_catalog_test.dart' show MemoryStorage, NoSnapshots;

class SidebarGateway extends GatewayClient {
  final frames = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  Object? catalogError;
  Completer<dynamic>? listResponse;
  List<Map<String, dynamic>> rows = [
    {'key': 'other', 'category': 'Work', 'hasActiveRun': false},
  ];
  @override
  Stream<Map<String, dynamic>> get events => frames.stream;
  @override
  Future<Map<String, dynamic>> connect(String address, String token, DeviceIdentity identity) async {
    connected = true;
    return {};
  }

  @override
  Future<void> disconnect() async => connected = false;
  @override
  Future<dynamic> request(String method, [Map<String, dynamic> params = const {}]) async {
    if (method == 'sessions.list') {
      return listResponse?.future ?? {'sessions': rows.map(Map<String, dynamic>.of).toList()};
    }
    if (method == 'sessions.groups.list') {
      if (catalogError != null) throw catalogError!;
      return {
        'groups': [
          {'name': 'Work', 'position': 0},
          {'name': 'Research', 'position': 1},
        ],
        'sectionOrder': ['category:Research', 'category:Work'],
      };
    }
    return <String, dynamic>{};
  }

  void emit(Map<String, dynamic> payload) => frames.add({'event': 'sessions.changed', 'payload': payload});
  @override
  Future<void> dispose() async {
    await frames.close();
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SidebarGateway gateway;
  late ClawController c;
  setUp(() {
    gateway = SidebarGateway();
    c = ClawController(client: gateway, storage: MemoryStorage(), snapshots: NoSnapshots());
  });
  tearDown(() => c.dispose());

  test('catalog order and background incremental activity use Gateway facts', () async {
    await c.connect('wss://fixture.example', 'fixture');
    expect(c.error, isEmpty);
    expect(c.sessionGroups, ['Research', 'Work']);
    expect(c.isSessionRunning(c.sessions.single), false);
    gateway.emit({'sessionKey': 'other', 'hasActiveRun': true, 'status': 'running'});
    expect(c.isSessionRunning(c.sessions.single), true);
    gateway.emit({'sessionKey': 'other', 'category': 'Research', 'displayName': 'Renamed'});
    expect(c.sessions.single['category'], 'Research');
    expect(c.isSessionRunning(c.sessions.single), true);
    gateway.emit({'sessionKey': 'other', 'hasActiveRun': false, 'status': 'done'});
    expect(c.isSessionRunning(c.sessions.single), false);
    gateway.emit({'sessionKey': 'other', 'hasActiveSubagentRun': true});
    expect(c.isSessionRunning(c.sessions.single), true);
    gateway.emit({'sessionKey': 'other', 'hasActiveSubagentRun': false});
    expect(c.isSessionRunning(c.sessions.single), false);
    expect(c.isSessionRunning({'status': 'running', 'hasActiveRun': false}), false);
    expect(c.isSessionRunning({'status': 'running'}), true);
    expect(c.isSessionRunning({'status': 'queued'}), true);
    expect(c.isSessionRunning({'status': 'failed'}), false);
  });

  test('old Gateway without group RPC keeps row categories and connects', () async {
    gateway.catalogError = GatewayException('INVALID_REQUEST', 'unknown method');
    await c.connect('wss://fixture.example', 'fixture');
    expect(c.error, isEmpty);
    expect(c.connected, true);
    expect(c.sessionGroups, isEmpty);
    expect(c.sessions.single['category'], 'Work');
  });

  test('group RPC permission errors are not hidden as compatibility fallback', () async {
    gateway.catalogError = GatewayException('FORBIDDEN', 'fixture denied');
    await c.connect('wss://fixture.example', 'fixture');
    expect(c.error, contains('FORBIDDEN'));
  });

  test('late list response cannot undo live running state', () async {
    await c.connect('wss://fixture.example', 'fixture');
    final delayed = Completer<dynamic>();
    gateway.listResponse = delayed;
    final refresh = c.refreshSessions();
    gateway.emit({'sessionKey': 'other', 'hasActiveRun': true});
    gateway.rows.single['hasActiveRun'] = true;
    gateway.listResponse = null;
    delayed.complete({
      'sessions': [
        {'key': 'other', 'hasActiveRun': false},
      ],
    });
    await refresh;
    expect(c.isSessionRunning(c.sessions.single), true);
  });

  test('late response after host removal cannot restore sessions or groups', () async {
    await c.connect('wss://fixture.example', 'fixture');
    final delayed = Completer<dynamic>();
    gateway.listResponse = delayed;
    final refresh = c.refreshSessions();
    await c.removeHost();
    delayed.complete({
      'sessions': [
        {'key': 'stale', 'hasActiveRun': true},
      ],
    });
    await refresh;
    expect(c.sessions, isEmpty);
    expect(c.sessionGroups, isEmpty);
  });
}
