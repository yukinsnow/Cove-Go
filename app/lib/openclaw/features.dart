import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../ui/common/app_sheet.dart' show groupTitleStyle;
import '../ui/common/feature_tile.dart';
import '../ui/common/list_page_row.dart';
import '../ui/common/overview_card.dart';
import '../ui/common/tile_grid.dart';
import '../ui/shell/page_frame.dart';
import '../ui/theme/app_icons.dart';
import 'controller.dart';
import 'feature_data.dart';
import 'feature_artifact.dart';
import 'notification_settings.dart';
import 'workspaces.dart';
import 'usage.dart';

/// OpenClaw-only hub: it must never read the DSH connection/providers.
class GatewayFeaturesPage extends StatelessWidget {
  const GatewayFeaturesPage({
    super.key,
    required this.controller,
    required this.onSettings,
    required this.onSearch,
    required this.onModels,
    required this.onHosts,
    required this.onWeb,
    required this.onExport,
  });
  final ClawController controller;
  final VoidCallback onSettings, onSearch, onModels, onHosts, onWeb, onExport;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller, l = context.l10n;
      final session = c.sessionKey;
      final open = session.isNotEmpty;
      final row = c.sessions.where((s) => s['key'] == session).firstOrNull;
      void push(Widget page) => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => page));
      GatewayFeatureScope scope({bool sessionOnly = false}) =>
          GatewayFeatureScope(c, session: sessionOnly ? session : null);
      Widget read(
        String id,
        IconData icon,
        String title,
        String summary,
        String method, {
        bool needsSession = false,
        Map<String, dynamic> params = const {},
        String? collection,
        List<String> fields = const ['name', 'description', 'status'],
        FeatureKind? art,
        String? note,
        void Function(BuildContext, Map)? onItem,
      }) => FeatureCard(
        key: ValueKey('gateway-feature-$id'),
        icon: icon,
        art: art == null ? null : FeatureTile(art, size: FeatureCard.glyph),
        title: title,
        subtitle: needsSession && !open ? l.catalogOpenChatFirst : summary,
        enabled: c.connected && (!needsSession || open),
        onTap: () => push(
          GatewayReadPage(
            scope: scope(sessionOnly: needsSession),
            title: title,
            method: method,
            params: params,
            collection: collection,
            fields: fields,
            note: note,
            onItem: onItem,
          ),
        ),
      );
      Widget action(
        String id,
        IconData icon,
        String title,
        String summary,
        VoidCallback tap, {
        bool enabled = true,
        String? badge,
        FeatureKind? art,
      }) => FeatureCard(
        key: ValueKey('gateway-feature-$id'),
        icon: icon,
        art: art == null ? null : FeatureTile(art, size: FeatureCard.glyph),
        title: title,
        subtitle: summary,
        onTap: tap,
        enabled: enabled,
        badge: badge,
      );
      bool available(Widget card) {
        final id = (card.key as ValueKey<String>?)?.value.replaceFirst('gateway-feature-', '');
        const methods = <String, List<String>>{
          'details': ['sessions.describe'],
          'artifacts': ['artifacts.list', 'artifacts.download'],
          'files': ['sessions.files.list', 'sessions.files.get'],
          'export': ['chat.history'],
          'progress': ['progressCard.get'],
          'skills': ['skills.status'],
          'cron': ['cron.list'],
          'plugins': ['plugins.list'],
          'agents': ['agents.list'],
          'models': ['models.list', 'sessions.patch'],
        };
        final advertised = (c.client.hello['features'] as Map?)?['methods'];
        if (id == 'usage') {
          return advertised is! List || ['sessions.usage', 'plugins.sessionAction'].any(advertised.contains);
        }
        return advertised is! List || (methods[id] ?? const <String>[]).every(advertised.contains);
      }

      Widget group(String title, List<Widget> cards) {
        final supported = cards.where(available).toList();
        if (supported.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              child: Text(title, style: groupTitleStyle(context)),
            ),
            TileGrid(children: supported),
          ],
        );
      }

      void files() {
        final owner = scope(sessionOnly: true);
        push(
          GatewayReadPage(
            scope: owner,
            title: l.catalogFiles,
            method: 'sessions.files.list',
            params: {'sessionKey': session},
            collection: 'files',
            note: l.ocFeatureFilesNote,
            onItem: (page, file) {
              final path = file['path'];
              if (path is String) {
                Navigator.of(page).push<void>(
                  MaterialPageRoute(
                    builder: (_) => GatewayFilePreview(scope: owner, path: path),
                  ),
                );
              }
            },
          ),
        );
      }

      return AppPage.list(
        title: l.catalogAllFeatures,
        subtitle: Text(l.ocFeatureHubSubtitle),
        children: [
          OverviewCard(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            leading: OverviewGlyph(AppIcons.chat),
            title: Text(open ? '${row?['displayName'] ?? row?['label'] ?? session}' : l.catalogNoOpenChat),
            subtitle: Text(open ? l.catalogOpenChat : l.catalogOpenOrCreateChat),
            onTap: open ? () => Navigator.of(context).pop() : null,
          ),
          group(l.catalogCurrentChat, [
            read(
              'details',
              AppIcons.sessionDetails,
              l.catalogChatDetails,
              l.ocFeatureDetailsSummary,
              'sessions.describe',
              needsSession: true,
              params: {'key': session},
              collection: 'session',
              fields: const [
                'displayName',
                'label',
                'key',
                'sessionId',
                'status',
                'model',
                'modelProvider',
                'category',
                'workspaceDir',
                'spawnedCwd',
                'permissionMode',
                'totalTokens',
                'updatedAt',
              ],
            ),
            read(
              'artifacts',
              AppIcons.artifacts,
              l.catalogArtifacts,
              l.ocFeatureArtifactsSummary,
              'artifacts.list',
              needsSession: true,
              params: {'sessionKey': session, 'messageRole': 'assistant'},
              collection: 'artifacts',
              fields: const ['title', 'type', 'mimeType', 'sizeBytes', 'download'],
              note: l.ocFeatureArtifactsNote,
              onItem: (page, item) => Navigator.of(page).push<void>(
                MaterialPageRoute(
                  builder: (_) => GatewayArtifactPage(scope: scope(sessionOnly: true), artifact: item),
                ),
              ),
            ),
            action(
              'files',
              AppIcons.files,
              l.catalogFiles,
              l.catalogFilesSummary,
              files,
              enabled: c.connected && open,
              art: FeatureKind.files,
            ),

            action(
              'export',
              AppIcons.exportLog,
              l.catalogExport,
              l.ocFeatureExportSummary,
              onExport,
              enabled: c.connected && open,
            ),
            read(
              'progress',
              AppIcons.goal,
              l.catalogPlanGoal,
              l.ocFeatureProgressSummary,
              'progressCard.get',
              needsSession: true,
              params: {'sessionKey': session},
              collection: 'card',
              fields: const ['markdown', 'steps', 'updatedAt'],
            ),
            read(
              'skills',
              AppIcons.skill,
              l.catalogSkills,
              l.ocFeatureSkillsSummary,
              'skills.status',
              needsSession: true,
              params: {'sessionKey': session},
              collection: 'skills',
              fields: const ['name', 'description', 'eligible', 'disabled', 'missing'],
            ),
          ]),
          group(l.catalogAutomationSection, [
            read(
              'cron',
              AppIcons.automation,
              l.catalogSchedules,
              l.ocFeatureCronSummary,
              'cron.list',
              params: const {'includeDisabled': true, 'limit': 100},
              collection: 'jobs',
              fields: const ['name', 'enabled', 'schedule', 'state'],
              art: FeatureKind.automation,
              note: l.ocFeatureReadOnly,
            ),
          ]),
          group(l.hubSettingsEngineExtensions, [
            read(
              'plugins',
              AppIcons.plugin,
              l.catalogPlugins,
              l.ocFeaturePluginsSummary,
              'plugins.list',
              collection: 'plugins',
              fields: const ['id', 'name', 'description', 'version', 'enabled', 'status'],
              art: FeatureKind.plugins,
              note: l.ocFeatureReadOnly,
            ),
            read(
              'agents',
              AppIcons.subagents,
              l.ocFeatureConfiguredAgents,
              l.ocFeatureAgentsSummary,
              'agents.list',
              collection: 'agents',
              fields: const ['id', 'name', 'identity'],
              art: FeatureKind.subagents,
            ),
          ]),
          group(l.ocFeatureTools, [
            action(
              'usage',
              Icons.bar_chart_rounded,
              l.ocUsageTitle,
              l.ocUsageSummary,
              () => push(GatewayUsagePage(scope: scope())),
              enabled: c.connected,
            ),
            action('search', AppIcons.search, l.catalogSearch, l.ocFeatureSearchSummary, onSearch),
            action(
              'workspaces',
              AppIcons.workspace,
              l.catalogWorkspaces,
              l.ocFeatureWorkspaceSummary,
              () => showGatewayWorkspaces(context, c),
              art: FeatureKind.workspace,
            ),
            action('web', AppIcons.web, l.commonWeb, l.ocFeatureGatewayWeb, onWeb, enabled: c.address.isNotEmpty),
          ]),
          group(l.commonSettings, [
            action(
              'models',
              AppIcons.model,
              l.catalogModels,
              l.ocFeatureModelsSummary,
              onModels,
              enabled: c.connected && open,
            ),

            action('hosts', AppIcons.remoteHosts, l.commonRemoteHost, l.catalogRemoteSummary, onHosts),
            action(
              'notifications',
              AppIcons.notifications,
              l.catalogNotifications,
              l.catalogNotificationsSummary,
              () => push(AppPage.list(title: l.ocNotifications, children: const [CoveNotificationSettings()])),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: ListPageCard(
              children: [
                ListPageRow(
                  key: const ValueKey('gateway-all-settings'),
                  icon: AppIcons.configure,
                  title: l.catalogAllSettings,
                  onTap: onSettings,
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}
