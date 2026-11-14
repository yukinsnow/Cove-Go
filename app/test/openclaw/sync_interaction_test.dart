import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'send_test.dart' show SlowGateway, UiController;

class SyncGateway extends SlowGateway {
  final pending = <String, Completer<dynamic>>{};
  bool failSubscription = false;
  @override
  Future<dynamic> request(String method, [Map<String, dynamic> params = const {}]) async {
    if (method == 'sessions.messages.subscribe' && failSubscription) throw StateError('subscribe failed');
    if (method == 'chat.history') return (pending[params['sessionKey']] = Completer<dynamic>()).future;
    return super.request(method, params);
  }
}

void main() {
  test('failed subscription can be retried, history completes sync', () async {
    final g = SyncGateway()..failSubscription = true;
    final c = UiController(g);
    addTearDown(c.dispose);
    await expectLater(c.select('a'), throwsStateError);
    expect(c.syncFailed, true);
    expect(c.syncing, false);
    g.failSubscription = false;
    final retry = c.resync();
    await Future<void>.delayed(Duration.zero);
    expect(c.syncing, true);
    g.pending['a']!.complete({
      'messages': [
        {'role': 'assistant', 'content': 'fresh'},
      ],
    });
    await retry;
    expect(c.syncing, false);
    expect(c.syncFailed, false);
    expect(c.messages.single['content'], 'fresh');
  });

  test('manual retry supersedes a stalled initial sync without stale completion', () async {
    final g = SyncGateway();
    final c = UiController(g);
    addTearDown(c.dispose);
    final first = c.select('a');
    await Future<void>.delayed(Duration.zero);
    final old = g.pending['a']!;
    final retry = c.resync();
    await Future<void>.delayed(Duration.zero);
    expect(c.resyncing, true);
    old.complete({
      'messages': [
        {'role': 'assistant', 'content': 'stale'},
      ],
    });
    await first;
    expect(c.syncing, true);
    expect(c.messages, isEmpty);
    g.pending['a']!.complete({
      'messages': [
        {'role': 'assistant', 'content': 'fresh'},
      ],
    });
    await retry;
    expect(c.resyncing, false);
    expect(c.syncing, false);
    expect(c.messages.single['content'], 'fresh');
  });

  test('a retired sync failure cannot set the new conversation error', () async {
    final g = SyncGateway();
    final c = UiController(g);
    addTearDown(c.dispose);
    final first = c.guard(() => c.select('a'));
    await Future<void>.delayed(Duration.zero);
    final second = c.select('b');
    await Future<void>.delayed(Duration.zero);
    g.pending['a']!.completeError(StateError('old failure'));
    await first;
    expect(c.error, isEmpty);
    expect(c.syncFailed, false);
    expect(c.syncing, true);
    g.pending['b']!.complete({'messages': []});
    await second;
  });

  test('late old history cannot clear new selection syncing or replace history', () async {
    final g = SyncGateway();
    final c = UiController(g);
    addTearDown(c.dispose);
    final first = c.select('a');
    await Future<void>.delayed(Duration.zero);
    final second = c.select('b');
    await Future<void>.delayed(Duration.zero);
    g.pending['a']!.complete({
      'messages': [
        {'role': 'assistant', 'content': 'old'},
      ],
    });
    await first;
    expect(c.syncing, true);
    expect(c.messages, isEmpty);
    g.pending['b']!.complete({
      'messages': [
        {'role': 'assistant', 'content': 'current'},
      ],
    });
    await second;
    expect(c.syncing, false);
    expect(c.messages.single['content'], 'current');
  });
}
