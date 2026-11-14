import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';

class CoveNotificationTarget {
  const CoveNotificationTarget({required this.backend, required this.host, required this.session});
  final String backend, host, session;
  Map<String, String> toMap() => {'backend': backend, 'host': host, 'session': session};
  static CoveNotificationTarget? parse(Object? raw) {
    if (raw is! Map) return null;
    final backend = raw['backend'], host = raw['host'], session = raw['session'];
    if (!['openclaw', 'dsh'].contains(backend) ||
        host is! String ||
        host.isEmpty ||
        host.length > 2048 ||
        session is! String ||
        session.length > 500) {
      return null;
    }
    return CoveNotificationTarget(backend: backend as String, host: host, session: session);
  }
}

class CoveNotificationBridge {
  CoveNotificationBridge({MethodChannel? channel}) : channel = channel ?? const MethodChannel('cove/notifications');
  final MethodChannel channel;
  Future<Map> status({bool request = false}) async {
    try {
      return await channel.invokeMapMethod<String, dynamic>(request ? 'request' : 'status') ?? {};
    } on MissingPluginException {
      return {'native': false, 'enabled': false};
    } on PlatformException {
      return {'native': true, 'enabled': false};
    }
  }

  Future<void> listen(void Function(CoveNotificationTarget) onTap) async {
    channel.setMethodCallHandler((call) async {
      final target = CoveNotificationTarget.parse(call.arguments);
      if (call.method == 'tap' && target != null) onTap(target);
    });
    try {
      final target = CoveNotificationTarget.parse(await channel.invokeMethod<Object?>('listen'));
      if (target != null) onTap(target);
    } on MissingPluginException {
      /* Non-iOS/test host. */
    } on PlatformException {
      /* Native bridge unavailable. */
    }
  }

  void stop() => channel.setMethodCallHandler(null);
  Future<bool> show({
    required String id,
    required String title,
    required String body,
    required CoveNotificationTarget target,
    bool Function()? stillCurrent,
  }) async {
    try {
      if ((await status())['enabled'] != true || stillCurrent?.call() == false) return false;
      await channel.invokeMethod<void>('show', {
        'id': id,
        'title': title,
        'body': body,
        'thread': jsonEncode([target.backend, target.host, target.session]),
        'target': target.toMap(),
      });
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> cancelAll() async {
    try {
      await channel.invokeMethod<void>('cancelAll');
    } on MissingPluginException {
      /* No native implementation. */
    } on PlatformException {
      /* Native implementation unavailable. */
    }
  }

  Future<void> settings() async {
    try {
      await channel.invokeMethod<bool>('settings');
    } on MissingPluginException {
      /* No native implementation. */
    } on PlatformException {
      /* Native implementation unavailable. */
    }
  }
}

final coveNotificationBridgeProvider = Provider<CoveNotificationBridge>((ref) => CoveNotificationBridge());

class CoveNotificationPrefs extends Notifier<bool> {
  bool _edited = false;
  @override
  bool build() {
    unawaited(_load());
    return false; // Opt-in: never ask or disclose content at startup.
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (ref.mounted && !_edited) state = prefs.getBool('cove.notifications.enabled') ?? false;
  }

  Future<void> setEnabled(bool value) async {
    _edited = true;
    state = value;
    await (await SharedPreferences.getInstance()).setBool('cove.notifications.enabled', value);
    if (!value && ref.mounted) await ref.read(coveNotificationBridgeProvider).cancelAll();
  }
}

final coveNotificationsEnabledProvider = NotifierProvider<CoveNotificationPrefs, bool>(CoveNotificationPrefs.new);

/// No message bodies, host addresses, secrets or private titles go on the lock screen.
class CoveNotice {
  const CoveNotice({required this.id, required this.session, required this.failed, this.attention = false});
  final String id, session;
  final bool failed, attention;
  String get body => attention
      ? appL10n.ocNotificationAttention
      : failed
      ? appL10n.ocNotificationFailed
      : appL10n.ocNotificationDone;
}

/// Consumes live chat terminals and persisted session lifecycle terminals.
/// Roster subscribers receive sessions.changed even when a different chat is
/// selected. Historical rows and metadata-only updates must never notify.
class GatewayNoticeTracker {
  final _seen = <String>{};
  bool _remember(String id) {
    if (!_seen.add(id)) return false;
    if (_seen.length > 1024) _seen.remove(_seen.first);
    return true;
  }

  CoveNotice? consume(Map<String, dynamic> frame) {
    if (frame['payload'] is! Map) return null;
    final payload = frame['payload'] as Map;
    if (frame['event'] == 'heartbeat') {
      if (payload['status'] != 'sent' || payload['silent'] == true || payload['ts'] is! num) return null;
      final id = 'heartbeat:${payload['ts']}';
      if (!_remember(id)) return null;
      return CoveNotice(id: id, session: '', failed: false, attention: true);
    }
    Object? state;
    Object? run, session;
    if (frame['event'] == 'chat') {
      if (payload['yielded'] == true) return null;
      state = payload['state'];
      run = payload['runId'];
      session = payload['sessionKey'];
    } else if (frame['event'] == 'sessions.changed') {
      // Require an explicit live lifecycle envelope, not a sessions.list row or
      // a later rename/model change carrying the last run's terminal status.
      final phase = payload['phase'];
      if (phase != 'end' && phase != 'error') return null;
      final row = payload['session'] is Map ? payload['session'] as Map : const {};
      final status = payload['status'] ?? row['status'];
      state = status == 'done'
          ? 'final'
          : ['failed', 'timeout'].contains(status)
          ? 'error'
          : null;
      run = payload['clientRunId'] ?? payload['runId'];
      session = payload['sessionKey'];
      // A yielded/superseded run may carry the previous stored status. Only
      // accept the exact run that produced this persisted terminal projection.
      if ((payload['lastRunId'] ?? row['lastRunId']) != run) return null;
    }
    if (!['final', 'error'].contains(state) || run is! String || run.isEmpty || session is! String || session.isEmpty) {
      return null;
    }
    final id = jsonEncode([session, run]);
    if (!_remember(id)) return null;
    return CoveNotice(id: id, session: session, failed: state == 'error');
  }
}
