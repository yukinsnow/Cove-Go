import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'controller.dart';

/// Only profile IDs and the selected ID enter the catalog. Credentials and
/// device identities stay in separate keychain entries for each controller.
class GatewayHostCatalog extends ChangeNotifier {
  GatewayHostCatalog({FlutterSecureStorage? storage, this.createController})
    : storage = storage ?? const FlutterSecureStorage();
  static const catalogKey = 'claw.host.catalog.v1';
  final FlutterSecureStorage storage;
  final ClawController Function(String id)? createController;
  final controllers = <String, ClawController>{};
  String selected = 'legacy';
  bool loaded = false, _disposed = false;
  Future<void> _writes = Future.value();

  bool _queued = false;
  void changed() {
    if (_disposed) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      if (_queued) return;
      _queued = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _queued = false;
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  ClawController _controller(String id) {
    final c = createController?.call(id) ?? ClawController(profileId: id, storage: storage);
    c.onConfigured = save;
    c.addListener(changed);
    controllers[id] = c;
    return c;
  }

  Future<void> load() async {
    if (loaded) return;
    final raw = await storage.read(key: catalogKey);
    if (_disposed) return;
    if (raw == null) {
      // Copy before committing the catalog; interrupted migration is safe to
      // repeat, and original credentials are not removed until fully saved.
      final address = await storage.read(key: 'claw.address');
      final token = await storage.read(key: 'claw.token');
      if (address?.isNotEmpty == true) {
        for (final field in ['address', 'token', 'sshId', 'identity']) {
          final value = await storage.read(key: 'claw.$field');
          if (value != null) await storage.write(key: 'claw.host.legacy.$field', value: value);
        }
        final c = controllers['legacy'] ?? _controller('legacy');
        c.address = address!;
        c.token = token ?? '';
        c.sshId = await storage.read(key: 'claw.sshId');
      }
    } else {
      final data = jsonDecode(raw) as Map;
      for (final id in (data['ids'] as List).cast<String>()) {
        if (controllers.containsKey(id)) continue;
        final c = _controller(id);
        c.address = await storage.read(key: 'claw.host.$id.address') ?? '';
        c.token = await storage.read(key: 'claw.host.$id.token') ?? '';
        c.sshId = await storage.read(key: 'claw.host.$id.sshId');
      }
      selected = data['selected'] as String? ?? 'legacy';
    }
    if (_disposed) return;
    if (controllers.isEmpty) _controller('legacy');
    if (!controllers.containsKey(selected)) selected = controllers.keys.first;
    await save();
    for (final field in ['address', 'token', 'sshId', 'identity']) {
      await storage.delete(key: 'claw.$field');
    }
    loaded = true;
    changed();
  }

  Future<void> save() {
    final payload = jsonEncode({
      'ids': [
        for (final id in controllers.keys)
          if (id == selected || controllers[id]!.address.isNotEmpty) id,
      ],
      'selected': selected,
    });
    final op = _writes.catchError((Object _) {}).then((_) => storage.write(key: catalogKey, value: payload));
    _writes = op;
    return op;
  }

  Future<void> pick(String id) async {
    if (!controllers.containsKey(id)) return;
    selected = id;
    changed();
    await save();
  }

  ClawController add() {
    var id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    while (controllers.containsKey(id)) {
      id += 'x';
    }
    final c = _controller(id);
    changed();
    return c;
  }

  Future<void> remove(String id) async {
    final c = controllers[id];
    if (c == null) return;
    await c.removeHost();
    c.removeListener(changed);
    controllers.remove(id);
    c.dispose();
    if (controllers.isEmpty) _controller('legacy');
    if (!controllers.containsKey(selected)) selected = controllers.keys.first;
    try {
      await save();
    } finally {
      changed();
    }
  }

  Future<void> discardEmpty(String id) async {
    if (controllers[id]?.address.isNotEmpty == true || id == selected) return;
    final c = controllers.remove(id);
    c?.removeListener(changed);
    c?.dispose();
    await save();
    changed();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final c in controllers.values) {
      c.removeListener(changed);
      c.dispose();
    }
    super.dispose();
  }
}
