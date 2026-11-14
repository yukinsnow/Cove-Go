import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../ui/shell/page_frame.dart';
import 'feature_data.dart';

Map usageMap(Object? value) => value is Map ? value : const {};
List<Map> usageRows(Object? value) => value is List ? value.whereType<Map>().toList() : const [];
String usageNumber(Object? value) => value is num && value.isFinite
    ? (value == value.roundToDouble() ? value.toInt().toString() : value.toStringAsFixed(4))
    : appL10n.ocUsageUnknown;
bool usagePartial(Map result) {
  final cache = usageMap(result['cacheStatus']);
  return result['partial'] != null ||
      ['partial', 'computing', 'stale'].contains(cache['status']) ||
      ['pendingFiles', 'staleFiles'].any((key) => cache[key] is num && cache[key] > 0) ||
      usageRows(result['sessions'])
          .any((row) => row['computing'] == true || usageMap(row['usage'])['refreshing'] == true);
}

/// Independent results: a missing optional plugin cannot hide Gateway accounting.
class UsageResult {
  const UsageResult(this.data, this.failed);
  final Map? data;
  final bool failed;
}

class GatewayUsagePage extends StatefulWidget {
  const GatewayUsagePage({super.key, required this.scope});
  final GatewayFeatureScope scope;
  @override
  State<GatewayUsagePage> createState() => _GatewayUsagePageState();
}

class _GatewayUsagePageState extends State<GatewayUsagePage> {
  String range = '7d';
  late Future<UsageResult> wallets, accounting;
  @override
  void initState() {
    super.initState();
    widget.scope.controller.addListener(changed);
    reload();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.scope.controller.removeListener(changed);
    super.dispose();
  }

  Future<UsageResult> read(String method, Map<String, dynamic> params, {bool plugin = false}) async {
    try {
      var raw = await widget.scope.read(method, params);
      if (raw is! Map) return const UsageResult(null, true);
      if (plugin) {
        if (raw['ok'] != true || raw['result'] is! Map) return const UsageResult(null, true);
        raw = raw['result'];
        if (raw['ok'] != true) return const UsageResult(null, true);
      } else if (raw['aggregates'] is! Map || raw['totals'] is! Map) {
        return const UsageResult(null, true);
      }
      return UsageResult(raw as Map, false);
    } catch (_) {
      // Never render provider error bodies, URLs, account identifiers or tokens.
      return const UsageResult(null, true);
    }
  }

  void reload() {
    wallets = read('plugins.sessionAction', {
      'pluginId': 'api-usage',
      'actionId': 'summary',
      'payload': <String, dynamic>{},
    }, plugin: true);
    // Aggregate totals cover the accessible population, not the limited session
    // rows. Avoid projection:overview, which intentionally omits full byModel.
    accounting = read('sessions.usage', {'agentScope': 'all', 'range': range, 'mode': 'utc', 'limit': 1});
  }

  Widget note(String text) => Padding(padding: const EdgeInsets.all(16), child: Text(text));
  Widget section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 4),
    child: Text(title, style: Theme.of(context).textTheme.titleLarge),
  );
  Widget metric(String label, Object? value, {String suffix = ''}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Text('$label: ${usageNumber(value)}${value is num ? suffix : ''}'),
  );
  Widget card(String title, List<Widget> children) => Card(
    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    ),
  );
  Widget result(Future<UsageResult> future, bool plugin) => FutureBuilder<UsageResult>(
    future: future,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Padding(
          padding: EdgeInsets.all(20),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      final value = snapshot.data;
      if (value == null || value.failed || value.data == null) {
        return note(plugin ? context.l10n.ocUsagePluginMissing : context.l10n.ocUsageFailed);
      }
      return plugin ? walletView(value.data!) : modelView(value.data!);
    },
  );
  Widget walletView(Map data) {
    final l = context.l10n;
    final providers = usageRows(data['providers']), subscriptions = usageRows(data['subscriptions']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (data['updatedMs'] is num)
          note(
            '${l.ocUsageUpdated}: ${DateTime.fromMillisecondsSinceEpoch((data['updatedMs'] as num).toInt()).toLocal()}',
          ),
        for (final p in providers)
          card('${p['label'] ?? p['id'] ?? ''}', [
            if (p['status'] != 'ok')
              Text(l.ocUsageFailed)
            else ...[
              if (p['valid'] == false) Text(l.ocUsageBlocked),
              metric('${l.ocUsageBalance} (${p['currency'] ?? l.ocUsageUnknown})', p['balance']),
              if (p['planName'] is String && (p['planName'] as String).isNotEmpty) Text('${p['planName']}'),
              if (p['mode'] == 'available' || p['mode'] == 'unavailable')
                Text(l.ocUsageNoDetail)
              else ...[
                metric('${l.ocUsageToday} · ${l.ocUsageRequests}', p['todayRequests']),
                metric('${l.ocUsageToday} · Tokens', p['todayTokens']),
                metric('${l.ocUsageToday} · ${p['currency'] ?? ''}', p['todayCost']),
                metric('${l.ocUsageTotal} · ${l.ocUsageRequests}', p['totalRequests']),
                metric('${l.ocUsageTotal} · Tokens', p['totalTokens']),
                metric('${l.ocUsageTotal} · ${p['currency'] ?? ''}', p['totalCost']),
              ],
            ],
          ]),
        for (final s in subscriptions)
          card('${s['label'] ?? s['provider'] ?? ''}', [
            Text(l.ocUsageSubscription),
            if (s['status'] != 'ok')
              Text(l.ocUsageFailed)
            else ...[
              if (s['plan'] is String) Text('${s['plan']}'),
              if (s['allowed'] == false) Text(l.ocUsageBlocked),
              for (final w in usageRows(s['windows'])) ...[
                metric('${w['label'] ?? ''} · ${l.ocUsageUsed}', w['usedPercent'], suffix: '%'),
                if (w['usedPercent'] is num && (w['usedPercent'] as num).isFinite)
                  LinearProgressIndicator(value: ((w['usedPercent'] as num) / 100).clamp(0.0, 1.0).toDouble()),
                Text(
                  '${l.ocUsageReset}: ${w['resetAt'] is num && w['resetAt'] > 0 ? DateTime.fromMillisecondsSinceEpoch((w['resetAt'] as num).toInt()).toLocal() : l.ocUsageUnknown}',
                ),
              ],
              for (final m in usageRows(s['models']))
                Text('${m['model'] ?? ''}: ${m['available'] == true ? '✓' : '—'}'),
            ],
          ]),
        if (providers.isEmpty && subscriptions.isEmpty) note(l.ocFeatureEmpty),
      ],
    );
  }

  List<Widget> totals(Map totals) {
    final l = context.l10n;
    final unavailable = usageMap(totals['usageReport'])['state'] == 'unavailable';
    return [
      if (unavailable) Text(l.ocUsagePartial),
      metric('Tokens', unavailable ? null : totals['totalTokens']),
      metric(l.ocUsageInput, unavailable ? null : totals['input']),
      metric(l.ocUsageOutput, unavailable ? null : totals['output']),
      metric(l.ocUsageCache, unavailable ? null : totals['cacheRead']),
      metric(l.ocUsageCost, unavailable ? null : totals['totalCost']),
      if (totals['missingCostEntries'] is num && totals['missingCostEntries'] > 0) Text(l.ocUsageMissingCost),
    ];
  }

  Widget modelView(Map data) {
    final l = context.l10n, rows = usageRows(usageMap(data['aggregates'])['byModel']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        note('${l.ocUsagePeriod}: ${data['startDate'] ?? '—'} → ${data['endDate'] ?? '—'}'),
        if (usagePartial(data)) note(l.ocUsagePartial),
        card(l.ocUsageTotal, totals(usageMap(data['totals']))),
        for (final row in rows)
          card(
            '${row['provider'] ?? l.ocUsageUnknown} / ${row['model'] ?? l.ocUsageUnknown}',
            totals(usageMap(row['totals'])),
          ),
        if (rows.isEmpty) note(l.ocUsageEmpty),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AppPage.list(
      title: l.ocUsageTitle,
      children: [
        note(l.ocUsageScope),
        if (!widget.scope.current)
          note(l.ocFeatureScopeChanged)
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              children: [
                for (final item in [('7d', l.ocUsage7d), ('30d', l.ocUsage30d), ('90d', l.ocUsage90d)])
                  ChoiceChip(
                    label: Text(item.$2),
                    selected: range == item.$1,
                    onSelected: (selected) {
                      if (selected && range != item.$1) {
                        setState(() {
                          range = item.$1;
                          accounting = read('sessions.usage', {
                            'agentScope': 'all',
                            'range': range,
                            'mode': 'utc',
                            'limit': 1,
                          });
                        });
                      }
                    },
                  ),
                TextButton.icon(
                  key: const ValueKey('usage-refresh'),
                  icon: const Icon(Icons.refresh),
                  label: Text(l.ocUsageRefresh),
                  onPressed: () => setState(reload),
                ),
              ],
            ),
          ),
          section(l.ocUsageWallets),
          result(wallets, true),
          section(l.ocUsageModels),
          result(accounting, false),
        ],
      ],
    );
  }
}
