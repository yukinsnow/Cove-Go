import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'hosts_state.dart';
import 'offline_snapshot.dart';
import 'read_list_identity.dart';

/// Resolve display provenance from local credentials/configuration, without
/// waiting for Remote's online host listing. This never grants live authority.
final offlineReadIdentityProvider = FutureProvider.autoDispose<ReadListIdentity?>((ref) async {
  await Future<void>.value();
  if (!ref.mounted) return null;
  final selected = ref.watch(activeHostProvider);
  if (selected.isLocal) return null;
  final live = ref.watch(readListIdentityProvider);
  final store = ref.watch(offlineSnapshotStoreProvider);
  String? binding;
  if (selected.kind == HostKind.relay) {
    final backend = ref.watch(relayBackendProvider);
    final server = ref.watch(relayServerProvider) ?? defaultRelayServer;
    // currentUser restores local secure credentials; listHosts is network I/O.
    final user = await backend.currentUser();
    if (!ref.mounted) return null;
    if (user != null) {
      binding = OfflineSnapshotStore.digest(['relay', server, user.id, user.provider, selected.id]);
    }
  } else {
    final hosts = ref.watch(hostsProvider);
    final host = hosts.sshById(selected.id);
    if (hosts.loaded && host?.hostKeyFingerprint != null) {
      binding = OfflineSnapshotStore.digest([
        'ssh',
        host!.id,
        host.connectionKey,
        host.workingDirectory,
        host.hostKeyType,
        host.hostKeyFingerprint,
      ]);
    }
  }
  if (binding == null) return live;
  final scope = 'dsh-identity:$binding';
  if (live != null) {
    await store.write(scope, {'digest': live.digest});
    return live;
  }
  final saved = await store.read(scope);
  final digest = saved?['digest'];
  return digest is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ? ReadListIdentity(digest) : null;
});
