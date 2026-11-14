import 'package:dsh_app/openclaw/feature_data.dart';
import 'package:dsh_app/openclaw/session_details.dart';
import 'package:dsh_app/ui/session/session_detail_page.dart' show GlassSegments;
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'send_test.dart' show SlowGateway, UiController, home;

void main() {
  test('trajectory joins delayed results to the original turn, without inventing diffs', () {
    final turns = gatewayDetailTurns([
      {'role': 'user', 'content': 'first'},
      {
        'role': 'assistant',
        'content': [
          {
            'type': 'toolCall',
            'id': 'a',
            'name': 'read',
            'arguments': {'path': 'a.txt'},
          },
        ],
      },
      {'role': 'user', 'content': 'second'},
      {
        'role': 'toolResult',
        'toolCallId': 'a',
        'details': {'durationMs': 12},
      },
    ]);
    expect(turns, hasLength(2));
    final step = turns.first.steps.last;
    expect(step.hasResult, true);
    expect(step.durationMs, 12);
    expect(step.diff, isNull);
    expect(step.path, 'a.txt');
    expect(turns.last.steps, hasLength(1));
  });

  testWidgets('five detail sections render on a phone and retire with the session', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = UiController(SlowGateway())..sessionKey = 'a';
    c.messages = [
      {'role': 'user', 'content': 'Hello'},
      {'role': 'assistant', 'content': 'World'},
    ];
    await tester.pumpWidget(home(c, buildDarkTheme()));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(Scaffold).first)).push(
      MaterialPageRoute<void>(
        builder: (_) => GatewaySessionDetailsPage(scope: GatewayFeatureScope(c, session: 'a')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(GlassSegments), findsOneWidget);
    for (final label in ['改动', '文件', '进度', '上下文', '轨迹']) {
      final target = find.descendant(of: find.byType(GlassSegments), matching: find.text(label));
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    c.sessionKey = 'b';
    c.changed();
    await tester.pumpAndSettle();
    expect(find.byType(GlassSegments), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
