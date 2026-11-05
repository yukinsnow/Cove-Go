import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:openclaw_client/openclaw_client.dart';

import '../state/offline_snapshot.dart';

class ClawController extends ChangeNotifier {
  ClawController({GatewayClient? client, OfflineSnapshotStore? snapshots})
    : client = client ?? GatewayClient(),
      snapshots = snapshots ?? OfflineSnapshotStore();
  final OfflineSnapshotStore snapshots;
  final _histories = <String, List<Map<String, dynamic>>>{};
  String get _cacheScope => OfflineSnapshotStore.digest(['gateway', address, token]);

  Future<void> _save() {
    final histories = Map<String, List<Map<String, dynamic>>>.of(_histories);
    Map<String, dynamic> snapshot() => {'sessions': sessions, 'selected': sessionKey, 'histories': histories};
    // Prefer recent conversations when the aggregate exceeds the disk budget.
    while (utf8.encode(jsonEncode(snapshot())).length > OfflineSnapshotStore.maxBytes && histories.isNotEmpty) {
      final oldest = histories.keys.firstWhere((key) => key != sessionKey, orElse: () => histories.keys.first);
      final rows = histories[oldest]!;
      if (histories.length == 1 && rows.length > 1) {
        histories[oldest] = rows.sublist(rows.length ~/ 2);
      } else {
        histories.remove(oldest);
      }
    }
    return snapshots.write(_cacheScope, snapshot());
  }

  Future<void> _restore() async {
    final scope = _cacheScope, selection = _selection, connection = _connectionRevision;
    final cached = await snapshots.read(scope);
    if (disposed ||
        scope != _cacheScope ||
        cached == null ||
        selection != _selection ||
        connection != _connectionRevision) {
      return;
    }
    try {
      sessions = (cached['sessions'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      _histories.clear();
      for (final entry in (cached['histories'] as Map).entries) {
        _histories[entry.key as String] = (entry.value as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      }
      sessionKey = cached['selected'] as String? ?? '';
      messages = _histories[sessionKey] ?? [];
      readingCache = messages.isNotEmpty;
    } on Object {
      sessions = [];
      messages = [];
      sessionKey = '';
      _histories.clear();
    }
    changed();
  }

  void _rememberHistory() {
    readingCache = false;
    _histories.remove(sessionKey);
    _histories[sessionKey] = messages;
    while (_histories.length > 20) {
      _histories.remove(_histories.keys.first);
    }
    unawaited(_save());
  }

  final GatewayClient client;
  final storage = const FlutterSecureStorage();
  StreamSubscription<Map<String, dynamic>>? _events;
  String address = '', token = '', error = '', sessionKey = '';
  bool busy = false, sending = false, disposed = false, readingCache = false;
  List<Map<String, dynamic>> sessions = [], messages = [], models = [];
  final Map<String, Map<String, dynamic>> tools = {};
  final Map<String, String> live = {};
  int _selection = 0, _historyRequest = 0, _connectionRevision = 0;
  String? _submissionFingerprint, _submissionId;

  /// Changes even when reopening the same conversation; viewports must reset.
  int get selectionRevision => _selection;
  bool get connected => client.connected;
  void changed() {
    if (!disposed) notifyListeners();
  }

  Future<void> load() async {
    final revision = _connectionRevision;
    final savedAddress = await storage.read(key: 'claw.address') ?? '';
    final savedToken = await storage.read(key: 'claw.token') ?? '';
    if (disposed || revision != _connectionRevision) return;
    address = savedAddress;
    token = savedToken;
    await _restore();
    changed();
    if (address.isNotEmpty && token.isNotEmpty && !disposed && revision == _connectionRevision && !connected && !busy) {
      unawaited(connect(address, token));
    }
  }

  Future<void> guard(Future<void> Function() operation) async {
    error = '';
    changed();
    try {
      await operation();
    } catch (e) {
      // Never display a server string containing the configured credential.
      error = token.isEmpty ? '$e' : '$e'.replaceAll(token, '[redacted]');
    }
    changed();
  }

  Future<void> connect(String url, String secret) async {
    if (busy || disposed) return;
    ++_connectionRevision;
    await guard(() async {
      busy = true;
      changed();
      try {
        await _events?.cancel();
        _events = client.events.listen(_onEvent);
        final identity = await DeviceIdentity.create(await storage.read(key: 'claw.identity'));
        await storage.write(key: 'claw.identity', value: await identity.exportSeed());
        final changedHost = address != url.trim() || token != secret.trim();
        address = url.trim();
        token = secret.trim();
        if (changedHost) {
          ++_selection;
          sessionKey = '';
          sessions = [];
          messages = [];
          _histories.clear();
          live.clear();
          tools.clear();
          models = [];
          _submissionFingerprint = null;
          _submissionId = null;
          readingCache = false;
          await _restore();
          changed();
        }
        await client.connect(address, token, identity);
        await storage.write(key: 'claw.address', value: address);
        await storage.write(key: 'claw.token', value: token);
        await client.request('sessions.subscribe');
        await refreshSessions();
        if (sessionKey.isNotEmpty) await select(sessionKey);
        final catalog = await client.request('models.list') as Map;
        models = (catalog['models'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } finally {
        busy = false;
        changed();
      }
    });
  }

  Future<void> refreshSessions() async {
    final result =
        await client.request('sessions.list', {'limit': 100, 'includeGlobal': false, 'includeUnknown': false}) as Map;
    sessions = (result['sessions'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    unawaited(_save());
    changed();
  }

  Future<void> select(String key) async {
    final previous = sessionKey;
    sessionKey = key;
    final selection = ++_selection;
    messages = _histories[key] ?? [];
    readingCache = messages.isNotEmpty;
    live.clear();
    tools.clear();
    changed();
    unawaited(_save());
    if (!connected) return;
    if (previous.isNotEmpty) await client.request('sessions.messages.unsubscribe', {'key': previous});
    if (selection != _selection) return;
    await client.request('sessions.messages.subscribe', {'key': key});
    if (selection != _selection) return;
    final history = await client.request('chat.history', {'sessionKey': key, 'limit': 150}) as Map;
    if (selection != _selection) return;
    messages = (history['messages'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    _rememberHistory();
    changed();
  }

  Future<void> newSession() async {
    final result = await client.request('sessions.create', {'agentId': 'main', 'idempotencyKey': wireId()}) as Map;
    final key = result['sessionKey'] ?? result['key'] ?? (result['session'] as Map?)?['key'];
    if (key is! String) throw StateError('Gateway did not return a session key');
    await refreshSessions();
    await select(key);
  }

  Future<void> history() async {
    final key = sessionKey, selection = _selection;
    final request = ++_historyRequest;
    if (key.isEmpty || !connected) return;
    final result = await client.request('chat.history', {'sessionKey': key, 'limit': 150}) as Map;
    if (selection != _selection || request != _historyRequest) return;
    messages = (result['messages'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    _rememberHistory();
    changed();
  }

  Future<void> send(
    String text, {
    String queueMode = 'followup',
    List<Map<String, dynamic>> attachments = const [],
  }) async {
    if (sending) return;
    sending = true;
    changed();
    try {
      if (sessionKey.isEmpty) await newSession();
      final fingerprint = jsonEncode([sessionKey, text, queueMode, attachments]);
      if (_submissionFingerprint != fingerprint) {
        _submissionFingerprint = fingerprint;
        _submissionId = wireId();
      }
      await client.request('chat.send', {
        'sessionKey': sessionKey,
        'message': text,
        'idempotencyKey': _submissionId,
        'queueMode': queueMode,
        if (attachments.isNotEmpty) 'attachments': attachments,
      });
      _submissionFingerprint = null;
      _submissionId = null;
      // Admission succeeded. A history refresh failure must not invite a
      // second submission of the already accepted user input.
      unawaited(guard(history));
    } finally {
      sending = false;
      changed();
    }
  }

  Future<void> abort() async {
    await client.request('chat.abort', {'sessionKey': sessionKey});
    await history();
  }

  Future<void> model(String value) async {
    await client.request('sessions.patch', {'key': sessionKey, 'model': value});
    await refreshSessions();
  }

  void _onEvent(Map<String, dynamic> frame) {
    final event = frame['event'];
    if (event == 'connection.closed') {
      changed();
      return;
    }
    final p = frame['payload'];
    if (p is! Map || p['sessionKey'] != sessionKey) return;
    if (event == 'chat') {
      final run = '${p['runId']}';
      if (p['state'] == 'delta') {
        if (p['message'] != null) {
          live[run] = messageText(p['message']);
        } else {
          final delta = p['deltaText'] as String? ?? '';
          live[run] = p['replace'] == true ? delta : (live[run] ?? '') + delta;
        }
      }
      if (['final', 'aborted', 'error'].contains(p['state'])) {
        live.remove(run);
        if (p['state'] == 'error') error = '${p['errorMessage'] ?? 'Agent run failed'}';
        unawaited(guard(history));
      }
    } else if (event == 'agent' && p['stream'] == 'tool') {
      final data = Map<String, dynamic>.from(p['data'] as Map? ?? {});
      tools['${p['runId']}:${data['toolCallId'] ?? data['name']}'] = data;
    }
    changed();
  }

  String toolText(Map<String, dynamic> tool) => const JsonEncoder.withIndent('  ').convert(tool);
  @override
  void dispose() {
    disposed = true;
    unawaited(_events?.cancel());
    unawaited(client.dispose());
    super.dispose();
  }
}
