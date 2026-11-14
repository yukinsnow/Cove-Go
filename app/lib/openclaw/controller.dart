import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:openclaw_client/openclaw_client.dart';

import '../state/offline_snapshot.dart';
import 'image_blocks.dart';

/// Safe diagnostic: never includes an address, keychain value or server text.
class HostRemovalException implements Exception {
  HostRemovalException(this.stage, Object cause)
    : code = cause is PlatformException && cause.details is int ? '${cause.details}' : 'failed';
  final String stage, code;
  @override
  String toString() => '$stage/$code';
}

class ClawController extends ChangeNotifier {
  ClawController({
    GatewayClient? client,
    OfflineSnapshotStore? snapshots,
    this.profileId,
    FlutterSecureStorage? storage,
  }) : client = client ?? GatewayClient(),
       snapshots = snapshots ?? OfflineSnapshotStore(),
       storage = storage ?? const FlutterSecureStorage();
  final String? profileId;
  String _key(String name) => profileId == null ? 'claw.$name' : 'claw.host.$profileId.$name';
  Future<void> Function()? onConfigured;
  final OfflineSnapshotStore snapshots;
  String? sshId;
  String? _sessionSshId;
  String? transportAddress;
  Future<String> Function(String, String?)? resolveAddress;
  Future<void> Function()? closeTransport;
  final _histories = <String, List<Map<String, dynamic>>>{};
  String get _cacheScope => OfflineSnapshotStore.digest([
    'gateway',
    address,
    token,
    ?sshId,
    if (profileId != null && profileId != 'legacy') profileId!,
  ]);

  Future<void> _save() {
    final histories = Map<String, List<Map<String, dynamic>>>.of(_histories);
    Map<String, dynamic> snapshot() => {
      'sessions': sessions,
      'groups': sessionGroups,
      'groupFilter': selectedGroup,
      'selected': sessionKey,
      'histories': histories,
    };
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
      sessionGroups = (cached['groups'] as List? ?? []).whereType<String>().toList();
      selectedGroup = cached['groupFilter'] as String?;
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
      sessionGroups = [];
      selectedGroup = null;
      groupCatalogSupported = false;
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
  final FlutterSecureStorage storage;
  StreamSubscription<Map<String, dynamic>>? _events;
  String address = '', token = '', error = '', sessionKey = '';
  bool busy = false, sending = false, disposed = false, readingCache = false;
  List<Map<String, dynamic>> sessions = [], messages = [], models = [];
  List<String> sessionGroups = [];
  String? selectedGroup;
  bool groupCatalogSupported = false;
  int get workspaceEpoch => _connectionRevision;
  List<Map<String, dynamic>> get scopedSessions =>
      selectedGroup == null ? sessions : sessions.where((s) => (s['category'] ?? '') == selectedGroup).toList();
  void selectGroup(String? name) {
    selectedGroup = name;
    changed();
    unawaited(_save());
  }

  void _checkWorkspaceEpoch(int epoch) {
    if (disposed || _removing || epoch != _connectionRevision || !connected) {
      throw StateError('Gateway changed during workspace operation');
    }
  }

  Future<List<Map<String, dynamic>>> groupDefaults() async {
    final epoch = workspaceEpoch;
    final result = await client.request('sessions.groups.defaults') as Map;
    _checkWorkspaceEpoch(epoch);
    return (result['defaults'] as List? ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> addGroup(String name) async {
    final epoch = workspaceEpoch;
    await refreshSessions(); // Merge the current catalog; never put an outdated local-only list.
    _checkWorkspaceEpoch(epoch);
    await client.request('sessions.groups.put', {
      'names': <String>{
        ...sessionGroups,
        ...sessions.map((s) => s['category']).whereType<String>().where((s) => s.isNotEmpty),
        name,
      }.toList(),
    });
    _checkWorkspaceEpoch(epoch);
    await refreshSessions();
    _checkWorkspaceEpoch(epoch);
    if (!sessionGroups.contains(name)) throw StateError('Gateway did not retain the group');
    selectGroup(name);
  }

  Future<void> renameGroup(String name, String to) async {
    final epoch = workspaceEpoch;
    await client.request('sessions.groups.rename', {'name': name, 'to': to});
    _checkWorkspaceEpoch(epoch);
    await refreshSessions();
    _checkWorkspaceEpoch(epoch);
    if (!sessionGroups.contains(to)) throw StateError('Gateway did not retain the group rename');
    if (selectedGroup == name) selectGroup(to);
  }

  Future<void> deleteGroup(String name) async {
    final epoch = workspaceEpoch;
    await client.request('sessions.groups.delete', {'name': name});
    _checkWorkspaceEpoch(epoch);
    await refreshSessions();
    _checkWorkspaceEpoch(epoch);
    if (sessionGroups.contains(name) || sessions.any((s) => s['category'] == name)) {
      throw StateError('Gateway did not remove the group');
    }
    if (selectedGroup == name) selectGroup(null);
  }

  Future<void> updateGroupDirectory(String name, String? cwd) async {
    final epoch = workspaceEpoch;
    await client.request('sessions.groups.update', {'name': name, 'cwd': cwd, 'worktree': false});
    _checkWorkspaceEpoch(epoch);
    final defaults = await groupDefaults();
    _checkWorkspaceEpoch(epoch);
    final actual = defaults.where((d) => d['name'] == name).firstOrNull;
    if ((actual?['cwd'] ?? '') != (cwd ?? '') || actual?['worktree'] == true) {
      throw StateError('Gateway did not retain the directory default');
    }
    changed();
  }

  Future<void> moveSessionGroup(String key, String? name) async {
    final epoch = workspaceEpoch;
    await client.request('sessions.patch', {'key': key, 'category': name});
    _checkWorkspaceEpoch(epoch);
    await refreshSessions();
    _checkWorkspaceEpoch(epoch);
    final row = sessions.where((s) => s['key'] == key).firstOrNull;
    if (row == null || (row['category'] ?? '') != (name ?? '')) throw StateError('Gateway did not retain membership');
  }

  int _sessionRefresh = 0, _sessionEvents = 0;

  /// Aggregate direct activity is authoritative; descendants may still be working.
  bool isSessionRunning(Map<String, dynamic> session) {
    if (session['hasActiveSubagentRun'] == true) return true;
    if (session['hasActiveRun'] is bool) return session['hasActiveRun'] == true;
    return session['status'] == 'running' || session['status'] == 'queued';
  }

  // Pending echoes are transient. Once matched, display-only image fallbacks
  // may be retained in the encrypted, host-scoped offline snapshot.
  final _outgoing = <_OutgoingPrompt>[];
  List<Map<String, dynamic>> get visibleMessages => [
    ...messages,
    for (final prompt in _outgoing)
      if (prompt.sessionKey == sessionKey) prompt.message,
  ];

  void _retainImages(Map<String, dynamic> row, Map previous) {
    final files = gatewayFiles(previous);
    if (files.isNotEmpty && gatewayFiles(row).isEmpty) row['_localFiles'] = files;
    final images = gatewayImages(previous);
    // Canonical references take precedence; only keep display-only local bytes
    // for older Gateways that replace the admitted image with plain text.
    if (images.isNotEmpty && !gatewayImages(row).any(gatewayImageUsable)) {
      row['_localImages'] = images;
    }
  }

  void _replaceHistory(List rows) {
    final previous = messages;
    messages = rows.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final used = <int>{};
    for (final row in messages) {
      final id = row['id'] ?? row['messageId'] ?? row['idempotencyKey'] ?? row['requestId'];
      var match = -1;
      for (var i = 0; i < previous.length; i++) {
        final old = previous[i];
        if (!used.contains(i) &&
            old['role'] == row['role'] &&
            (id != null
                ? [old['id'], old['messageId'], old['idempotencyKey'], old['requestId']].contains(id)
                : messageText(old) == messageText(row))) {
          match = i;
          break;
        }
      }
      if (match >= 0) {
        used.add(match);
        _retainImages(row, previous[match]);
      }
    }
    _reconcileOutgoing();
  }

  void _reconcileOutgoing() {
    _outgoing.removeWhere((prompt) {
      if (prompt.sessionKey != sessionKey) return false;
      final users = messages.where((m) => m['role'] == 'user').toList();
      final keyed = users.where((m) => m['idempotencyKey'] == prompt.id || m['requestId'] == prompt.id);
      final sameText = users.where((m) => messageText(m) == messageText(prompt.message)).toList();
      final row =
          keyed.firstOrNull ?? (sameText.length > prompt.previousMatches ? sameText[prompt.previousMatches] : null);
      if (row == null) return false;
      _retainImages(row, prompt.message);
      return true;
    });
  }

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
    final savedAddress = await storage.read(key: _key('address')) ?? '';
    final savedToken = await storage.read(key: _key('token')) ?? '';
    final savedSsh = await storage.read(key: _key('sshId'));
    if (disposed || revision != _connectionRevision) return;
    sshId = _sessionSshId = savedSsh;
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

  Completer<void>? _connecting;
  Future<void>? _removal;
  bool _removing = false;

  Future<void> connect(String url, String secret) async {
    if (busy || disposed || _removing) return;
    final done = Completer<void>();
    _connecting = done;
    final revision = ++_connectionRevision;
    bool current() => !disposed && !_removing && revision == _connectionRevision;
    try {
      await guard(() async {
        busy = true;
        changed();
        try {
          await _events?.cancel();
          _events = client.events.listen(_onEvent);
          final uri = Uri.tryParse(url.trim());
          if (uri == null ||
              !['ws', 'wss'].contains(uri.scheme) ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty ||
              uri.hasQuery ||
              uri.hasFragment ||
              (sshId == null && uri.scheme == 'ws' && !['localhost', '127.0.0.1', '::1'].contains(uri.host)) ||
              (sshId != null && uri.scheme != 'ws')) {
            throw const FormatException('Use a secure Gateway URL without credentials or query parameters');
          }
          if (!current()) return;
          final identity = await DeviceIdentity.create(await storage.read(key: _key('identity')));
          if (!current()) return;
          await storage.write(key: _key('identity'), value: await identity.exportSeed());
          if (!current()) return;
          final changedHost = address != url.trim() || token != secret.trim() || _sessionSshId != sshId;
          _sessionSshId = sshId;
          address = url.trim();
          token = secret.trim();
          if (changedHost) {
            ++_selection;
            syncing = syncFailed = false;
            sessionKey = '';
            sessions = [];
            sessionGroups = [];
            selectedGroup = null;
            groupCatalogSupported = false;
            messages = [];
            _histories.clear();
            _outgoing.clear();
            live.clear();
            tools.clear();
            models = [];
            _submissionFingerprint = null;
            _submissionId = null;
            readingCache = false;
            await _restore();
            changed();
          }
          if (!current()) return;
          await storage.write(key: _key('sshId'), value: sshId);
          await storage.write(key: _key('address'), value: address);
          await storage.write(key: _key('token'), value: token);
          if (!current()) return;
          await onConfigured?.call();
          if (!current()) return;
          await client.disconnect();
          if (!current()) return;
          transportAddress = null;
          transportAddress = await resolveAddress?.call(address, sshId) ?? address;
          if (!current()) {
            await closeTransport?.call();
            return;
          }
          await client.connect(transportAddress!, token, identity);
          if (!current()) return;
          await client.request('sessions.subscribe');
          if (!current()) return;
          await refreshSessions();
          if (!current()) return;
          if (sessionKey.isNotEmpty) await select(sessionKey);
          if (!current()) return;
          final catalog = await client.request('models.list') as Map;
          if (!current()) return;
          models = (catalog['models'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        } finally {
          busy = false;
          changed();
        }
      });
    } finally {
      if (identical(_connecting, done)) _connecting = null;
      done.complete();
    }
  }

  Future<void> removeHost() => _removal ??= _removeHost().whenComplete(() => _removal = null);

  Future<void> _removeHost() async {
    if (disposed) throw StateError('Controller disposed');
    _removing = true;
    ++_connectionRevision;
    busy = true;
    changed();
    var stage = 'disconnect';
    try {
      // Cancel transport work, then wait for any in-flight keychain writes.
      // Never let a late connect recreate credentials after their deletion.
      final connecting = _connecting;
      await client.disconnect();
      await closeTransport?.call();
      await connecting?.future;
      busy = true;
      stage = 'storage';
      for (final field in ['sshId', 'address', 'token', 'identity']) {
        final key = _key(field);
        // Direct profiles have no SSH item. Some Apple keychain queries for
        // an absent sync item can fail even though normal reads work.
        if (await storage.read(key: key) != null) await storage.delete(key: key);
      }
      stage = 'disconnect';
      sshId = null;
      transportAddress = null;
      await closeTransport?.call();
      await _events?.cancel();
      _events = null;
      await client.disconnect();
      ++_selection;
      syncing = syncFailed = false;
      address = token = error = sessionKey = '';
      sessions = [];
      sessionGroups = [];
      selectedGroup = null;
      groupCatalogSupported = false;
      messages = [];
      models = [];
      _histories.clear();
      _outgoing.clear();
      live.clear();
      tools.clear();
      _submissionFingerprint = _submissionId = null;
      readingCache = false;
    } catch (e) {
      throw HostRemovalException(stage, e);
    } finally {
      _removing = false;
      busy = false;
      changed();
    }
  }

  Future<void> refreshSessions() async {
    final connection = _connectionRevision, request = ++_sessionRefresh;
    final events = _sessionEvents;
    bool current() => !disposed && !_removing && connection == _connectionRevision && request == _sessionRefresh;
    final rows = <Map<String, dynamic>>[];
    var offset = 0;
    while (true) {
      final result = await client.request('sessions.list', {
        'limit': 100,
        if (offset > 0) 'offset': offset,
        'includeGlobal': false,
        'includeUnknown': false,
      }) as Map;
      if (!current()) return;
      if (events != _sessionEvents) return refreshSessions();
      final page = (result['sessions'] as List? ?? []).whereType<Map>();
      rows.addAll(page.map((e) => Map<String, dynamic>.from(e)));
      if (result['hasMore'] != true) break;
      final next = result['nextOffset'] as int? ?? offset + page.length;
      if (next <= offset) throw StateError('Invalid Gateway pagination');
      offset = next;
    }
    sessions = {for (final row in rows) row['key']: row}.values.toList();
    changed();
    try {
      final catalog = await client.request('sessions.groups.list') as Map;
      if (!current()) return;
      groupCatalogSupported = true;
      final names = <String>[
        for (final group in catalog['groups'] as List? ?? [])
          if (group is Map && group['name'] is String) group['name'] as String,
      ];
      final order = (catalog['sectionOrder'] as List? ?? []).whereType<String>();
      sessionGroups = <String>{
        for (final id in order)
          if (id.startsWith('category:') && names.contains(id.substring(9))) id.substring(9),
        ...names,
      }.toList();
    } on GatewayException catch (e) {
      // Older Gateways may not implement the optional catalog RPC. Row categories
      // still group correctly; authentication and transport errors remain visible.
      final unsupported =
          e.code == 'METHOD_NOT_FOUND' ||
          (e.code == 'INVALID_REQUEST' && e.message.toLowerCase().contains('unknown method'));
      if (!unsupported) rethrow;
      if (current()) {
        sessionGroups = [];
        groupCatalogSupported = false;
      }
    }
    if (!current()) return;
    unawaited(_save());
    changed();
  }

  bool syncing = false, syncFailed = false;
  int? _manualSyncSelection;
  bool get resyncing => _manualSyncSelection == _selection;

  Future<void> select(String key) async {
    final previous = sessionKey;
    sessionKey = key;
    final selection = ++_selection;
    messages = _histories[key] ?? [];
    _reconcileOutgoing();
    readingCache = messages.isNotEmpty;
    live.clear();
    tools.clear();
    changed();
    unawaited(_save());
    if (!connected) {
      syncing = false;
      changed();
      return;
    }
    syncing = true;
    syncFailed = false;
    changed();
    try {
      if (previous.isNotEmpty) await client.request('sessions.messages.unsubscribe', {'key': previous});
      if (selection != _selection) return;
      await client.request('sessions.messages.subscribe', {'key': key});
      if (selection != _selection) return;
      await history();
    } catch (_) {
      // A retired request must not put its error banner onto the new chat.
      if (selection != _selection) return;
      syncFailed = true;
      rethrow;
    } finally {
      if (selection == _selection) {
        syncing = false;
        changed();
      }
    }
  }

  /// Re-establish the subscription as well as history after a failed sync.
  Future<void> resync() async {
    if (resyncing || sessionKey.isEmpty) return;
    final operation = select(sessionKey);
    final selection = _selection;
    _manualSyncSelection = selection;
    changed();
    try {
      await operation;
    } finally {
      if (_manualSyncSelection == selection) _manualSyncSelection = null;
      changed();
    }
  }

  Future<void> newSession({String? outgoingId}) async {
    final epoch = workspaceEpoch;
    final category = selectedGroup;
    Map<String, dynamic>? defaults;
    if (category != null && category.isNotEmpty) {
      try {
        defaults = (await groupDefaults()).where((d) => d['name'] == category).firstOrNull;
      } on GatewayException catch (e) {
        if (e.code != 'METHOD_NOT_FOUND' &&
            !(e.code == 'INVALID_REQUEST' && e.message.toLowerCase().contains('unknown method'))) {
          rethrow;
        }
      }
      _checkWorkspaceEpoch(epoch);
    }
    final result = await client.request('sessions.create', {
      'agentId': 'main',
      'idempotencyKey': wireId(),
      if (category != null && category.isNotEmpty) 'category': category,
      if (defaults?['cwd'] is String) 'cwd': defaults!['cwd'],
      if (defaults?['worktree'] == true) 'worktree': true,
    }) as Map;
    _checkWorkspaceEpoch(epoch);
    final key = result['sessionKey'] ?? result['key'] ?? (result['session'] as Map?)?['key'];
    if (key is! String) throw StateError('Gateway did not return a session key');
    await refreshSessions();
    _checkWorkspaceEpoch(epoch);
    for (final prompt in _outgoing) {
      if (prompt.id == outgoingId) prompt.sessionKey = key;
    }
    await select(key);
  }

  Future<void> history() async {
    final key = sessionKey, selection = _selection;
    final request = ++_historyRequest;
    if (key.isEmpty || !connected) return;
    final result = await client.request('chat.history', {'sessionKey': key, 'limit': 150}) as Map;
    if (selection != _selection || request != _historyRequest) return;
    _replaceHistory(result['messages'] as List? ?? []);
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
    final connection = _connectionRevision;
    final key = sessionKey;
    final fingerprint = jsonEncode([key, text, queueMode, attachments]);
    if (_submissionFingerprint != fingerprint) {
      _submissionFingerprint = fingerprint;
      _submissionId = wireId();
    }
    final id = _submissionId!;
    final content = <Map<String, dynamic>>[
      if (text.isNotEmpty) {'type': 'text', 'text': text},
      for (final file in attachments)
        {
          'type': file['type'] ?? 'image',
          'fileName': file['fileName'],
          'mimeType': file['mimeType'],
          'sizeBytes': file['sizeBytes'],
          if (file['type'] == 'image' || file['type'] == null)
            'source': {'type': 'base64', 'media_type': file['mimeType'], 'data': file['content']},
        },
    ];
    final prompt = _OutgoingPrompt(
      sessionKey: key,
      id: id,
      message: {'role': 'user', 'content': content},
      previousMatches: visibleMessages.where((m) => m['role'] == 'user' && messageText(m) == text).length,
    );
    _outgoing.add(prompt);
    changed();
    try {
      if (key.isEmpty) {
        await newSession(outgoingId: id);
        prompt.sessionKey = sessionKey;
        _submissionFingerprint = jsonEncode([sessionKey, text, queueMode, attachments]);
        changed();
      }
      if (connection != _connectionRevision) throw StateError('Gateway changed during send');
      await client.request('chat.send', {
        'sessionKey': prompt.sessionKey,
        'message': text,
        'idempotencyKey': id,
        'queueMode': queueMode,
        if (attachments.isNotEmpty) 'attachments': attachments,
      });
      if (connection != _connectionRevision) return;
      _submissionFingerprint = null;
      _submissionId = null;
      // Keep the echo until history contains the actual user row. Admission
      // can precede transcript persistence, especially for queued messages.
      unawaited(guard(history));
    } catch (_) {
      _outgoing.remove(prompt);
      rethrow;
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
    if (p is! Map) return;
    if (event == 'sessions.changed' || event == 'sessions.updated') {
      ++_sessionEvents;
      final key = p['sessionKey'];
      final row = sessions.where((row) => row['key'] == key).firstOrNull;
      if (key is! String || row == null || p['reason'] == 'delete' || p['reason'] == 'groups') {
        unawaited(guard(refreshSessions));
      } else {
        final snapshot = p['session'];
        if (snapshot is Map) row.addAll(Map<String, dynamic>.from(snapshot));
        // Incremental omission means unchanged, including aggregate activity.
        for (final field in [
          'category',
          'displayName',
          'label',
          'updatedAt',
          'status',
          'hasActiveRun',
          'hasActiveSubagentRun',
        ]) {
          if (p.containsKey(field)) row[field] = p[field];
        }
        if (snapshot is! Map &&
            ![
              'category',
              'displayName',
              'label',
              'updatedAt',
              'status',
              'hasActiveRun',
              'hasActiveSubagentRun',
            ].any(p.containsKey)) {
          unawaited(guard(refreshSessions));
        }
        unawaited(_save());
        changed();
      }
      return;
    }
    if (p['sessionKey'] != sessionKey) return;
    if (event == 'session.message') {
      // Delivery mirrors (message tool attachments) can arrive before the run's
      // final chat event; fetch the persisted display projection immediately.
      unawaited(guard(history));
    } else if (event == 'chat') {
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
    unawaited(closeTransport?.call());
    super.dispose();
  }
}

class _OutgoingPrompt {
  _OutgoingPrompt({required this.sessionKey, required this.id, required this.message, required this.previousMatches});
  String sessionKey;
  final String id;
  final Map<String, dynamic> message;
  final int previousMatches;
}
