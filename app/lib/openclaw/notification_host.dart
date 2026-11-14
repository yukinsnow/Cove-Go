import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../notify/chat_alerts.dart';
import '../state/connection_state.dart';
import '../state/hosts_state.dart';
import 'controller.dart';
import 'host_catalog.dart';
import 'notifications.dart';

/// One owner above both navigators. Never depends on whichever chat is visible.
class CoveNotificationHost extends ConsumerStatefulWidget {
  const CoveNotificationHost({super.key, required this.catalog, required this.onTap, required this.child});
  final GatewayHostCatalog catalog;
  final Future<void> Function(CoveNotificationTarget) onTap;
  final Widget child;
  @override
  ConsumerState<CoveNotificationHost> createState() => _CoveNotificationHostState();
}

class _CoveNotificationHostState extends ConsumerState<CoveNotificationHost> {
  final _gateways = <ClawController, StreamSubscription<Map<String, dynamic>>>{};
  HostConnection? _dsh;
  HostAlertTracker? _tracker;
  Object _dshEpoch = Object();
  late final CoveNotificationBridge _bridge;
  ProviderSubscription<AsyncValue<HostConnection?>>? _connection;
  ProviderSubscription<bool>? _preferences;
  ProviderSubscription<HostRef>? _host;

  @override
  void initState() {
    super.initState();
    _bridge = ref.read(coveNotificationBridgeProvider);
    widget.catalog.addListener(_syncGateways);
    _syncGateways();
    _preferences = ref.listenManual(coveNotificationsEnabledProvider, (_, _) => _wireDsh());
    _host = ref.listenManual(activeHostProvider, (_, _) => _wireDsh());
    _wireDsh();
    unawaited(
      _bridge.listen((target) {
        if (mounted) unawaited(widget.onTap(target));
      }),
    );
  }

  void _syncGateways() {
    final owners = widget.catalog.controllers;
    for (final old in _gateways.keys.toList()) {
      if (!owners.containsValue(old)) unawaited(_gateways.remove(old)!.cancel());
    }
    for (final entry in owners.entries) {
      final c = entry.value;
      if (_gateways.containsKey(c)) continue;
      final tracker = GatewayNoticeTracker();
      _gateways[c] = c.client.events.listen((frame) {
        final notice = tracker.consume(frame);
        final address = c.address, token = c.token, epoch = c.workspaceEpoch;
        if (notice != null) {
          unawaited(
            _post(
              notice,
              CoveNotificationTarget(backend: 'openclaw', host: entry.key, session: notice.session),
              current: () =>
                  identical(widget.catalog.controllers[entry.key], c) &&
                  !c.disposed &&
                  c.connected &&
                  c.workspaceEpoch == epoch &&
                  c.address == address &&
                  c.token == token,
            ),
          );
        }
      }, onError: (Object _) {});
    }
  }

  void _wireDsh() {
    final enabled = ref.read(coveNotificationsEnabledProvider);
    if (!enabled || ref.read(activeHostProvider).isLocal) {
      _connection?.close();
      _connection = null;
      _syncDsh(null);
      return;
    }
    _connection ??= ref.listenManual(
      activeConnectionProvider,
      (_, next) => _syncDsh(next.value),
      fireImmediately: true,
    );
  }

  void _syncDsh(HostConnection? connection) {
    if (identical(_dsh?.client, connection?.client)) return;
    _dsh = connection;
    final epoch = _dshEpoch = Object();
    unawaited(_tracker?.dispose());
    _tracker = null;
    if (connection == null || connection.isLocal || connection.hostId == null) return;
    final host = connection.kind == HostKind.ssh ? HostRef.ssh(connection.hostId!) : HostRef.relay(connection.hostId!);
    _tracker = HostAlertTracker(
      host: host,
      source: DshAlertSource(connection.client),
      onAlert: (alert) {
        unawaited(
          _post(
            CoveNotice(
              id: alert.key,
              session: alert.sessionId,
              failed: alert.kind == AlertKind.failed || alert.kind == AlertKind.stopped,
              attention: alert.kind.attention,
            ),
            CoveNotificationTarget(backend: 'dsh', host: host.encode(), session: alert.sessionId),
            current: () => identical(_dshEpoch, epoch) && identical(_dsh?.client, connection.client),
          ),
        );
      },
      onWithdraw: (_, _, _) {},
      onSessionGone: (_, _) {},
    )..start();
  }

  Future<void> _post(CoveNotice notice, CoveNotificationTarget target, {required bool Function() current}) async {
    if (!mounted || !current() || !ref.read(coveNotificationsEnabledProvider)) return;
    // Settings can be disabled while permission checks are in flight.
    final status = await _bridge.status();
    if (!mounted || !current() || !ref.read(coveNotificationsEnabledProvider) || status['enabled'] != true) return;
    await _bridge.show(
      id: jsonEncode([target.backend, target.host, notice.id]),
      title: 'Cove-Go',
      body: notice.body,
      target: target,
      stillCurrent: () => mounted && current() && ref.read(coveNotificationsEnabledProvider),
    );
  }

  @override
  void dispose() {
    widget.catalog.removeListener(_syncGateways);
    for (final sub in _gateways.values) {
      unawaited(sub.cancel());
    }
    unawaited(_tracker?.dispose());
    _connection?.close();
    _preferences?.close();
    _host?.close();
    _bridge.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
