import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/openclaw/feature_data.dart';
import 'package:dsh_app/openclaw/usage.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openclaw_client/openclaw_client.dart';

import 'send_test.dart' show SlowGateway, UiController;

class UsageGateway extends SlowGateway {
  final calls = <(String, Map<String, dynamic>)>[];
  bool pluginError = false;
  Completer<dynamic>? delayed;
  @override
  Future<dynamic> request(String method, [Map<String, dynamic> params = const {}]) async {
    calls.add((method, params));
    if (delayed != null) return delayed!.future;
    if (method == 'plugins.sessionAction') {
      if (pluginError) throw GatewayException('FORBIDDEN', 'credential-must-not-render');
      return {
        'ok': true,
        'result': {
          'ok': true,
          'updatedMs': 1794300000000,
          'providers': [
            {
              'id': 'relay',
              'label': 'Relay fixture',
              'status': 'ok',
              'currency': 'USD',
              'balance': 12.3,
              'todayTokens': 234,
            },
            {
              'id': 'deepseek',
              'label': 'DeepSeek fixture',
              'status': 'ok',
              'mode': 'available',
              'balance': 8,
              'currency': 'CNY',
            },
            {
              'id': 'broken',
              'label': 'Broken fixture',
              'status': 'error',
              'error': 'credential-must-not-render',
              'balance': 0,
            },
          ],
          'subscriptions': [
            {
              'label': 'ChatGPT quota fixture',
              'status': 'ok',
              'plan': 'pro',
              'allowed': true,
              'windows': [
                {'label': '5h fixture', 'usedPercent': 40, 'resetAt': 1794300000000},
              ],
            },
          ],
        },
      };
    }
    return {
      'startDate': '2026-11-01',
      'endDate': '2026-11-07',
      'totals': {
        'totalTokens': 100,
        'input': 60,
        'output': 40,
        'cacheRead': 10,
        'totalCost': 0.01,
        'missingCostEntries': 1,
      },
      'cacheStatus': {'status': 'partial'},
      'aggregates': {
        'byModel': List.generate(
          10,
          (i) => {
            'provider': 'relay',
            'model': 'model-$i',
            'totals': {'totalTokens': i + 1, 'totalCost': 0.001},
          },
        ),
      },
    };
  }
}

void main() {
  test('missing numbers and incomplete reports are not fabricated as zero', () {
    expect(usageNumber(null), isNot('0'));
    expect(usageNumber(double.nan), isNot('0'));
    expect(usageNumber(0), '0');
    expect(
      usagePartial({
        'cacheStatus': {'pendingFiles': 1},
      }),
      true,
    );
    expect(
      usagePartial({
        'cacheStatus': {'staleFiles': 1},
      }),
      true,
    );
    expect(
      usagePartial({
        'cacheStatus': {'status': 'complete'},
      }),
      false,
    );
  });
  for (final pluginError in [false, true]) {
    testWidgets('native usage renders all models independently of plugin=$pluginError', (tester) async {
      final client = UsageGateway()..pluginError = pluginError;
      final c = UiController(client);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocale.supported,
          localizationsDelegates: L10n.localizationsDelegates,
          home: GatewayUsagePage(scope: GatewayFeatureScope(c)),
        ),
      );
      await tester.pumpAndSettle();
      expect(client.calls.first.$1, 'plugins.sessionAction');
      expect(client.calls.first.$2, {'pluginId': 'api-usage', 'actionId': 'summary', 'payload': {}});
      expect(client.calls.last.$2, {'agentScope': 'all', 'range': '7d', 'mode': 'utc', 'limit': 1});
      expect(find.textContaining('credential-must-not-render'), findsNothing);
      await tester.tap(find.text('近 30 天'));
      await tester.pumpAndSettle();
      expect(client.calls.last.$2['range'], '30d');
      final beforeRefresh = client.calls.length;
      await tester.tap(find.byKey(const ValueKey('usage-refresh')));
      await tester.pumpAndSettle();
      expect(client.calls.length, beforeRefresh + 2);
      if (!pluginError) {
        expect(find.text('Relay fixture'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('ChatGPT quota fixture'), 400);
        expect(find.textContaining('2026-'), findsWidgets);
        expect(find.textContaining('58900'), findsNothing);
      }
      await tester.scrollUntilVisible(find.text('relay / model-9'), 500);
      expect(find.text('relay / model-9'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Gateway 各模型统计'), -500);
      expect(find.textContaining('2026-11-01'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  }
  testWidgets('retired host hides delayed result and never migrates to new connection', (tester) async {
    final client = UsageGateway()..delayed = Completer<dynamic>();
    final c = UiController(client);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: AppLocale.supported,
        home: GatewayUsagePage(scope: GatewayFeatureScope(c)),
      ),
    );
    await tester.pump();
    c.disposed = true;
    c.changed();
    client.delayed!.complete({
      'ok': true,
      'result': {
        'ok': true,
        'providers': [
          {'label': 'late-secret-host'},
        ],
      },
    });
    await tester.pumpAndSettle();
    expect(find.text('late-secret-host'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
