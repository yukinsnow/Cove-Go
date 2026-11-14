import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:openclaw_client/openclaw_client.dart' show messageText;

import '../l10n/l10n.dart';
import '../ui/common/page_hero.dart' show HeroStat;
import '../ui/session/session_detail_page.dart' show GlassSegments;
import '../ui/theme/theme.dart';
import '../ui/shell/page_frame.dart';
import 'feature_data.dart';
import 'image_blocks.dart';

Map _map(Object? value) => value is Map ? value : const {};
String? _string(Object? value) => value is String && value.trim().isNotEmpty ? value : null;
num? _number(Object? value) => value is num && value.isFinite && value >= 0 ? value : null;

/// A history projection, not a reconstructed execution trace. Timestamps are
/// recorded timestamps, never a basis for inferred model/tool durations.
class GatewayDetailStep {
  GatewayDetailStep({required this.kind, required this.message, this.call});
  final String kind;
  Map message;
  final Map? call;
  bool get tool => kind == 'tool';
  String? get toolName => _string(call?['name']) ?? _string(message['toolName']) ?? _string(message['name']);
  bool get hasResult => tool && ['tool', 'toolResult'].contains(message['role']);
  String? get text => tool ? null : _string(messageText(message));
  Object? get timestamp => message['timestamp'];
  num? get durationMs => _number(message['durationMs']) ?? _number(_map(message['details'])['durationMs']);
  Map get usage => _map(message['usage']);
  String? get path {
    var arguments = call?['arguments'] ?? call?['input'];
    if (arguments is String && arguments.length < 65536) {
      try {
        arguments = jsonDecode(arguments);
      } on FormatException {
        arguments = null;
      }
    }
    final args = _map(arguments), details = _map(message['details']);
    return _string(args['path']) ?? _string(args['file_path']) ?? _string(details['path']);
  }

  /// Only an explicit tool-result diff qualifies. Tool arguments, prose about
  /// edits and a successful write are not proof of an actual diff.
  String? get diff => hasResult && message['isError'] != true
      ? _string(_map(message['details'])['diff']) ?? _string(_map(message['structuredContent'])['diff'])
      : null;
}

class GatewayDetailTurn {
  GatewayDetailTurn({required this.hasPrompt});
  final bool hasPrompt;
  final List<GatewayDetailStep> steps = [];
}

List<GatewayDetailTurn> gatewayDetailTurns(List<Map<String, dynamic>> messages) {
  final turns = <GatewayDetailTurn>[];
  // Results can arrive after a later user message; retain their original owner.
  final calls = <String, GatewayDetailStep>{};
  for (final message in messages) {
    final role = message['role'];
    if (role == 'user' || turns.isEmpty) turns.add(GatewayDetailTurn(hasPrompt: role == 'user'));
    final turn = turns.last;
    if (role == 'toolResult' || role == 'tool') {
      final id = _string(message['toolCallId']) ?? _string(message['tool_use_id']);
      final step = id == null ? null : calls.remove(id);
      if (step != null) {
        step.message = message;
      } else {
        turn.steps.add(GatewayDetailStep(kind: 'tool', message: message));
      }
      continue;
    }
    if (_string(messageText(message)) != null ||
        gatewayFiles(message).isNotEmpty ||
        gatewayImages(message).isNotEmpty) {
      turn.steps.add(
        GatewayDetailStep(
          kind: role == 'user'
              ? 'user'
              : role == 'assistant'
              ? 'assistant'
              : 'other',
          message: message,
        ),
      );
    }
    final content = message['content'];
    if (content is! List) continue;
    for (final block in content.whereType<Map>()) {
      if (!['toolCall', 'tool_use', 'tool-call'].contains(block['type'])) continue;
      final step = GatewayDetailStep(kind: 'tool', message: message, call: block);
      turn.steps.add(step);
      final id = _string(block['id']) ?? _string(block['toolCallId']);
      if (id != null) calls[id] = step;
    }
  }
  return turns.where((turn) => turn.steps.isNotEmpty).toList();
}

/// A bounded privacy projection, not a raw protocol/config viewer. Arbitrary
/// tool output and arguments are deliberately absent. Known connection secrets
/// and common credential assignments are also removed from displayed excerpts.
String gatewayDetailText(String text, {String token = ''}) {
  var result = token.isEmpty ? text : text.replaceAll(token, '[redacted]');
  result = result.replaceAll(RegExp(r'\b(?:sk|ghp|github_pat)-?[A-Za-z0-9_\-]{16,}\b'), '[redacted]');
  result = result.replaceAll(RegExp(r'Bearer\s+[^\s"\x27]+', caseSensitive: false), 'Bearer [redacted]');
  result = result.replaceAllMapped(
    RegExp(
      r'''((?:api[_-]?key|access[_-]?token|auth[_-]?token|password|secret|cookie|authorization)["']?\s*[:=]\s*)[^\n]+''',
      caseSensitive: false,
    ),
    (match) => '${match[1]}[redacted]',
  );
  result = result.replaceAll(
    RegExp(r'-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-]*PRIVATE KEY-----|$)'),
    '[redacted]',
  );
  return result;
}

bool _sensitivePath(String? path) =>
    path != null &&
    RegExp(
      r'(^|[/\\])(?:\.env(?:\.[^/\\]*)?|auth-profiles\.json|credentials(?:\.[^/\\]*)?|id_(?:rsa|ed25519)|openclaw\.json|config\.json)$',
      caseSensitive: false,
    ).hasMatch(path);

class GatewaySessionDetailsPage extends StatefulWidget {
  const GatewaySessionDetailsPage({super.key, required this.scope});
  final GatewayFeatureScope scope;
  @override
  State<GatewaySessionDetailsPage> createState() => _GatewaySessionDetailsPageState();
}

class _GatewaySessionDetailsPageState extends State<GatewaySessionDetailsPage> with SingleTickerProviderStateMixin {
  late final TabController tabs = TabController(length: 5, vsync: this)..addListener(changed);
  int get tab => tabs.index;
  Map? description, progress;
  bool describing = false, loadingProgress = false;
  int generation = 0;
  bool get owned => widget.scope.session?.isNotEmpty == true && widget.scope.current;
  @override
  void initState() {
    super.initState();
    widget.scope.controller.addListener(changed);
    reload();
  }

  @override
  void didUpdateWidget(GatewaySessionDetailsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) {
      oldWidget.scope.controller.removeListener(changed);
      widget.scope.controller.addListener(changed);
      reload();
    }
  }

  void changed() {
    if (mounted) setState(() {});
  }

  void reload() {
    final request = ++generation;
    description = progress = null;
    if (!owned) return;
    describing = loadingProgress = true;
    load('sessions.describe', {'key': widget.scope.session}, request, false);
    load('progressCard.get', {'sessionKey': widget.scope.session}, request, true);
  }

  Future<void> load(String method, Map<String, dynamic> params, int request, bool isProgress) async {
    Map? result;
    try {
      final response = _map(await widget.scope.read(method, params));
      final value = response[isProgress ? 'card' : 'session'];
      if (value is Map) result = value;
    } catch (_) {
      // Protocol errors may include arbitrary server/config/credential content.
      // Missing permission, unsupported method and failure stay unavailable.
    }
    if (!mounted || !owned || request != generation) return;
    setState(() {
      if (isProgress) {
        progress = result;
        loadingProgress = false;
      } else {
        description = result;
        describing = false;
      }
    });
  }

  @override
  void dispose() {
    generation++;
    tabs.dispose();
    widget.scope.controller.removeListener(changed);
    super.dispose();
  }

  String safe(String text) => gatewayDetailText(text, token: widget.scope.controller.token);
  Widget note(String text) => Padding(padding: const EdgeInsets.all(20), child: Text(text));
  Widget field(String label, Object? value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: SelectableText(
      '$label: ${value is String || value is num || value is bool ? safe('$value') : context.l10n.ocDetailsUnavailable}',
    ),
  );
  Widget card(String title, List<Widget> children) => Card(
    margin: const EdgeInsets.fromLTRB(16, 6, 16, 10),
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

  String? time(Object? value) {
    DateTime? parsed;
    if (value is num && value.isFinite && value > 0 && value < 8640000000000000) {
      // Gateway history timestamps are epoch milliseconds, not durations.
      parsed = DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
    } else if (value is String) {
      parsed = DateTime.tryParse(value);
    }
    return parsed?.toLocal().toString();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    if (!owned) return AppPage.list(title: l.catalogChatDetails, children: [note(l.ocFeatureScopeChanged)]);
    final c = widget.scope.controller;
    final turns = gatewayDetailTurns(c.messages);
    final session = c.sessions.where((row) => row['key'] == widget.scope.session).firstOrNull;
    final labels = [
      l.ocDetailsTrajectory,
      l.ocDetailsChanges,
      l.ocDetailsFiles,
      l.ocDetailsProgress,
      l.ocDetailsContext,
    ];
    return AppPage.list(
      title: l.catalogChatDetails,
      subtitle: Text(
        safe('${description?['displayName'] ?? session?['displayName'] ?? session?['label'] ?? widget.scope.session}'),
      ),
      actions: [
        IconButton(
          key: const ValueKey('oc-details-refresh'),
          tooltip: l.ocRefresh,
          icon: const Icon(Icons.refresh_rounded),
          onPressed: () => setState(reload),
        ),
      ],
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Row(
            children: [
              for (final metric in [
                ('${turns.where((turn) => turn.hasPrompt).length}', l.ocDetailsTurns),
                ('${turns.fold<int>(0, (count, turn) => count + turn.steps.length)}', l.ocDetailsSteps),
                (
                  turns
                      .expand((turn) => turn.steps)
                      .where((step) => step.diff != null && step.path != null)
                      .map((step) => step.path)
                      .toSet()
                      .length
                      .toString(),
                  l.ocDetailsChangedFiles,
                ),
              ])
                Expanded(
                  child: HeroStat(value: metric.$1, label: metric.$2),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: GlassSegments(controller: tabs, labels: labels),
        ),
        if (tab == 0) ...trajectory(turns),
        if (tab == 1) ...changes(turns),
        if (tab == 2) ...files(turns),
        if (tab == 3) ...progressView(),
        if (tab == 4) ...contextView({...?session, ...?description}),
      ],
    );
  }

  List<Widget> trajectory(List<GatewayDetailTurn> turns) {
    final l = context.l10n;
    return [
      note(widget.scope.controller.readingCache ? l.ocDetailsCachedHistory : l.ocDetailsHistoryNote),
      if (turns.isEmpty) note(l.ocDetailsHistoryEmpty),
      for (var index = turns.length - 1; index >= 0; index--)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: GlassSurface(
            tier: GlassTier.chrome,
            child: Material(
              color: Colors.transparent,
              child: ExpansionTile(
                key: ValueKey('oc-details-turn-$index'),
                initiallyExpanded: index == turns.length - 1,
                title: Text(turns[index].hasPrompt ? l.ocDetailsTurn(index + 1) : l.ocDetailsEarlierHistory),
                subtitle: Text(
                  l.ocDetailsStepCount(turns[index].steps.length, turns[index].steps.where((step) => step.tool).length),
                ),
                children: [
                  for (var i = 0; i < turns[index].steps.length; i++) stepView(turns[index].steps[i], index, i),
                ],
              ),
            ),
          ),
        ),
    ];
  }

  Widget stepView(GatewayDetailStep step, int turn, int index) {
    final l = context.l10n;
    final label = step.tool
        ? safe(step.toolName ?? l.ocTools)
        : switch (step.kind) {
            'user' => l.ocDetailsUser,
            'assistant' => l.ocDetailsAssistant,
            _ => l.ocDetailsMessage,
          };
    final recorded = time(step.timestamp);
    final status = !step.tool
        ? null
        : !step.hasResult
        ? l.ocDetailsResultMissing
        : step.message['isError'] == true
        ? l.ocDetailsToolError
        : l.ocDetailsResultRecorded;
    return ExpansionTile(
      key: ValueKey('oc-details-step-$turn-$index'),
      leading: Icon(
        step.tool
            ? Icons.build_outlined
            : step.kind == 'user'
            ? Icons.person_outline_rounded
            : Icons.chat_bubble_outline_rounded,
        size: 20,
      ),
      title: Text(label),
      subtitle: Text([?status, ?recorded].join(' · ')),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (step.text != null) SelectableText(safe(step.text!)),
        if (step.tool) Text(l.ocDetailsToolPrivacy),
        if (step.path != null && !_sensitivePath(step.path)) field(l.ocDetailsPath, step.path),
        field(l.ocDetailsDuration, step.durationMs == null ? null : '${step.durationMs} ms'),
        for (final entry in [
          (l.ocDetailsInputTokens, 'input'),
          (l.ocDetailsOutputTokens, 'output'),
          (l.ocDetailsCacheRead, 'cacheRead'),
          (l.ocDetailsCacheWrite, 'cacheWrite'),
          (l.ocDetailsTotalTokens, 'totalTokens'),
        ])
          if (_number(step.usage[entry.$2]) != null) field(entry.$1, step.usage[entry.$2]),
        if (![
          'input',
          'output',
          'cacheRead',
          'cacheWrite',
          'totalTokens',
        ].any((key) => _number(step.usage[key]) != null))
          field(l.ocDetailsTotalTokens, null),
      ],
    );
  }

  List<Widget> changes(List<GatewayDetailTurn> turns) {
    final l = context.l10n;
    final steps = turns.expand((turn) => turn.steps).where((step) => step.diff != null).toList();
    return [
      note(l.ocDetailsChangesNote),
      if (steps.isEmpty) note(l.ocDetailsChangesUnavailable),
      for (var i = 0; i < steps.length; i++)
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: ExpansionTile(
            title: Text(
              safe(
                _sensitivePath(steps[i].path)
                    ? l.ocDetailsSensitiveFile
                    : steps[i].path ?? steps[i].toolName ?? l.ocTools,
              ),
            ),
            subtitle: Text(l.ocDetailsRecordedDiff),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: _sensitivePath(steps[i].path)
                    ? Text(l.ocDetailsSensitiveFile)
                    : SelectableText(
                        safe(steps[i].diff!),
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
              ),
            ],
          ),
        ),
    ];
  }

  List<Widget> files(List<GatewayDetailTurn> turns) {
    final l = context.l10n;
    final evidence = <String, (String, Map)>{};
    for (final turn in turns) {
      for (final step in turn.steps) {
        // Calls reference files; they do not prove that files exist or changed.
        if (step.path case final path?) evidence.putIfAbsent(path, () => (l.ocDetailsToolReference, {'path': path}));
        for (final attachment in [...gatewayFiles(step.message), ...gatewayImages(step.message)]) {
          final path =
              _string(attachment['fileName']) ??
              _string(attachment['name']) ??
              _string(attachment['path']) ??
              _string(attachment['artifactId']);
          if (path != null) evidence[path] = (l.ocDetailsAttachment, attachment);
        }
      }
    }
    return [
      note(l.ocDetailsFilesNote),
      if (evidence.isEmpty) note(l.ocDetailsFilesUnavailable),
      for (final entry in evidence.entries)
        card(safe(_sensitivePath(entry.key) ? l.ocDetailsSensitiveFile : entry.key), [
          Text(entry.value.$1),
          if (_number(entry.value.$2['sizeBytes']) != null) field(l.ocDetailsBytes, entry.value.$2['sizeBytes']),
          if (_string(entry.value.$2['mimeType']) != null) field(l.ocDetailsMimeType, entry.value.$2['mimeType']),
        ]),
    ];
  }

  List<Widget> progressView() {
    final l = context.l10n;
    if (loadingProgress) {
      return [
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    final data = progress;
    if (data == null) return [note(l.ocDetailsProgressUnavailable)];
    final markdown = _string(data['markdown']);
    final steps = data['steps'];
    return [
      note(l.ocDetailsProgressNote),
      if (markdown != null) card(l.ocDetailsProgress, [SelectableText(safe(markdown))]),
      if (steps is List)
        for (final step in steps.whereType<Map>())
          card(safe(_string(step['step']) ?? _string(step['title']) ?? l.ocDetailsProgress), [
            field(l.ocDetailsStatus, _string(step['status'])),
          ]),
      if (time(data['updatedAt']) case final updated?) note('${l.ocDetailsUpdated}: $updated'),
      if (markdown == null && (steps is! List || steps.isEmpty)) note(l.ocDetailsProgressUnavailable),
    ];
  }

  List<Widget> contextView(Map session) {
    final l = context.l10n;
    return [
      note(l.ocDetailsContextNote),
      if (describing) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
      card(l.ocDetailsSession, [
        field(l.ocDetailsSessionKey, widget.scope.session),
        for (final entry in [
          (l.ocDetailsSessionId, 'sessionId'),
          (l.ocDetailsStatus, 'status'),
          (l.ocDetailsModel, 'model'),
          (l.ocDetailsProvider, 'modelProvider'),
          (l.ocDetailsGroup, 'category'),
          (l.ocDetailsWorkspace, 'workspaceDir'),
          (l.ocDetailsPermission, 'permissionMode'),
        ])
          field(entry.$1, _string(session[entry.$2])),
        field(l.ocDetailsTotalTokens, _number(session['totalTokens'])),
        field(l.ocDetailsContextLimit, _number(session['contextTokens'])),
        field(l.ocDetailsUpdated, time(session['updatedAt'])),
      ]),
      note(l.ocDetailsContextUnavailable),
    ];
  }
}
