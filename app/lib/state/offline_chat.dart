import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'offline_snapshot.dart';
import 'hosts_state.dart';
import 'offline_identity.dart';

/// Persist only rendered conversation text, never approvals, commands, pending
/// submissions or engine state. A cached row cannot authorize an operation.
Map<String, dynamic> offlineChat(List<ChatItem> items, String? title) => {
  'title': title,
  'items': [
    for (final item in items.skip((items.length - 150).clamp(0, items.length)))
      if (item is UserChatItem)
        {'role': 'user', 'seq': item.seq, 'time': item.time.millisecondsSinceEpoch, 'text': item.text}
      else if (item is AssistantChatItem && !item.streaming)
        {
          'role': 'assistant',
          'id': item.id,
          'seq': item.seq,
          'time': item.time?.millisecondsSinceEpoch,
          'text': item.text,
          'reasoning': item.reasoning,
        },
  ],
};

List<ChatItem> restoreOfflineChat(Map<String, dynamic>? snapshot) {
  try {
    return [
      for (final item in snapshot?['items'] as List? ?? [])
        if (item['role'] == 'user')
          UserChatItem(
            seq: item['seq'] as int,
            time: DateTime.fromMillisecondsSinceEpoch(item['time'] as int),
            text: item['text'] as String,
            images: const [],
            files: const [],
          )
        else if (item['role'] == 'assistant')
          AssistantChatItem(
            id: item['id'] as String,
            seq: item['seq'] as int?,
            time: item['time'] == null ? null : DateTime.fromMillisecondsSinceEpoch(item['time'] as int),
            text: item['text'] as String,
            reasoning: item['reasoning'] as String? ?? '',
          ),
    ];
  } on Object {
    return const [];
  }
}

// Defer identity resolution outside widget construction: account/mux identity
// providers can otherwise synchronously invalidate a sibling header widget.
final offlineChatSnapshotProvider = FutureProvider.autoDispose
    .family<({String? scope, Map<String, dynamic>? snapshot}), String>((ref, sessionId) async {
      await Future<void>.value();
      if (!ref.mounted) return (scope: null, snapshot: null);
      if (ref.watch(activeHostProvider).isLocal) return (scope: null, snapshot: null);
      final identity = await ref.watch(offlineReadIdentityProvider.future);
      if (!ref.mounted) return (scope: null, snapshot: null);
      if (identity == null) return (scope: null, snapshot: null);
      final scope = 'dsh-chat:${identity.digest}:$sessionId';
      final snapshot = await ref.watch(offlineSnapshotStoreProvider).read(scope);
      return (scope: scope, snapshot: snapshot);
    });
