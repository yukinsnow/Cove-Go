import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:openclaw_client/openclaw_client.dart';

class ClawController extends ChangeNotifier {
  ClawController({GatewayClient? client}) : client = client ?? GatewayClient();
  final GatewayClient client;
  final storage = const FlutterSecureStorage();
  StreamSubscription<Map<String, dynamic>>? _events;
  String address = '', token = '', error = '', sessionKey = '';
  bool busy = false, sending = false, disposed = false;
  List<Map<String, dynamic>> sessions = [], messages = [], models = [];
  final Map<String, Map<String, dynamic>> tools = {};
  final Map<String, String> live = {};
  int _selection = 0, _historyRequest = 0;
  String? _submissionFingerprint, _submissionId;

  /// Changes even when reopening the same conversation; viewports must reset.
  int get selectionRevision => _selection;
  bool get connected => client.connected;
  void changed() {
    if (!disposed) notifyListeners();
  }

  Future<void> load() async {
    address = await storage.read(key: 'claw.address') ?? '';
    token = await storage.read(key: 'claw.token') ?? '';
    changed();
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

  Future<void> connect(String url, String secret) => guard(() async {
    busy = true;
    changed();
    try {
      await _events?.cancel();
      _events = client.events.listen(_onEvent);
      final identity = await DeviceIdentity.create(await storage.read(key: 'claw.identity'));
      await storage.write(key: 'claw.identity', value: await identity.exportSeed());
      address = url.trim();
      token = secret.trim();
      await client.connect(address, token, identity);
      await storage.write(key: 'claw.address', value: address);
      await storage.write(key: 'claw.token', value: token);
      await client.request('sessions.subscribe');
      await refreshSessions();
      final catalog = await client.request('models.list') as Map;
      models = (catalog['models'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (sessionKey.isNotEmpty) await select(sessionKey);
    } finally {
      busy = false;
      changed();
    }
  });
  Future<void> refreshSessions() async {
    final result =
        await client.request('sessions.list', {'limit': 100, 'includeGlobal': false, 'includeUnknown': false}) as Map;
    sessions = (result['sessions'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    changed();
  }

  Future<void> select(String key) async {
    final previous = sessionKey;
    sessionKey = key;
    final selection = ++_selection;
    messages = [];
    live.clear();
    tools.clear();
    changed();
    if (previous.isNotEmpty) await client.request('sessions.messages.unsubscribe', {'key': previous});
    await client.request('sessions.messages.subscribe', {'key': key});
    final history = await client.request('chat.history', {'sessionKey': key, 'limit': 150}) as Map;
    if (selection != _selection) return;
    messages = (history['messages'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
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
    if (key.isEmpty) return;
    final result = await client.request('chat.history', {'sessionKey': key, 'limit': 150}) as Map;
    if (selection != _selection || request != _historyRequest) return;
    messages = (result['messages'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
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
