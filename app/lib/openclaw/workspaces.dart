import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../ui/common/app_sheet.dart';
import '../ui/common/list_page_row.dart';
import '../ui/common/sheet_title_bar.dart';
import '../ui/shell/page_frame.dart';
import '../ui/theme/app_icons.dart';
import 'controller.dart';

/// Gateway categories organize conversations; their optional cwd is a separate
/// server-owned New Session default, not a phone filesystem workspace.
class GatewayWorkspaceSwitcher extends StatelessWidget {
  const GatewayWorkspaceSwitcher({super.key, required this.controller});
  final ClawController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Expanded(
      child: InkWell(
        key: const ValueKey('gateway-workspace-switcher'),
        onTap: () => showGatewayWorkspaces(context, c),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(c.selectedGroup == null ? AppIcons.conversations : AppIcons.workspace, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  c.selectedGroup == null
                      ? context.l10n.remoteWorkspaceAllChats
                      : c.selectedGroup!.isEmpty
                      ? context.l10n.remoteWorkspaceUngrouped
                      : c.selectedGroup!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              const Icon(AppIcons.expand, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showGatewayWorkspaces(BuildContext context, ClawController c, {String? moveKey}) async {
  final epoch = c.workspaceEpoch;
  final action = await showAppSheet<String>(
    context,
    isScrollControlled: true,
    builder: (sheet) => ListenableBuilder(
      listenable: c,
      builder: (sheet, _) {
        final l = sheet.l10n;
        final groups = <String>{
          ...c.sessionGroups,
          ...c.sessions.map((s) => s['category']).whereType<String>().where((s) => s.isNotEmpty),
        };
        final selected = moveKey == null
            ? c.selectedGroup
            : c.sessions.where((s) => s['key'] == moveKey).firstOrNull?['category'] ?? '';
        Widget choice(String? name) {
          final rows = name == null ? c.sessions : c.sessions.where((s) => (s['category'] ?? '') == name);
          final title = name == null
              ? l.remoteWorkspaceAllChats
              : name.isEmpty
              ? l.remoteWorkspaceUngrouped
              : name;
          return ListPageRow(
            key: ValueKey('gateway-group-${name ?? "all"}'),
            icon: name == null ? AppIcons.conversations : AppIcons.workspace,
            title: title,
            meta: '${rows.length}',
            trailing: selected == name ? const Icon(AppIcons.done) : const SizedBox(width: 24),
            chevron: false,
            onTap: c.workspaceEpoch != epoch
                ? null
                : () {
                    if (moveKey == null) {
                      c.selectGroup(name);
                    } else {
                      c.guard(() => c.moveSessionGroup(moveKey, name));
                    }
                    Navigator.pop(sheet);
                  },
          );
        }

        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * .8),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SheetTitleBar(moveKey == null ? l.remoteWorkspace : l.ocMoveToGroup),
                  if (moveKey == null) SheetGroup(children: [choice(null)]),
                  SheetGroup(children: [choice(''), for (final name in groups) choice(name)]),
                  if (moveKey == null)
                    SheetGroup(
                      children: [
                        ListPageRow(
                          icon: AppIcons.newFolder,
                          title: l.remoteWorkspaceAdd,
                          onTap: c.connected && c.groupCatalogSupported ? () => Navigator.pop(sheet, 'add') : null,
                        ),
                        ListPageRow(
                          icon: AppIcons.configure,
                          title: l.remoteWorkspaceManage,
                          onTap: () => Navigator.pop(sheet, 'manage'),
                        ),
                      ],
                    ),
                  Padding(padding: const EdgeInsets.all(20), child: Text(l.ocWorkspaceHint)),
                  if (!c.groupCatalogSupported)
                    Padding(padding: const EdgeInsets.all(20), child: Text(l.ocWorkspaceReadOnly)),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
  if (!context.mounted || c.workspaceEpoch != epoch) return;
  if (action == 'add') await _editName(context, c);
  if (action == 'manage' && context.mounted) {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => GatewayWorkspaceManager(controller: c, epoch: epoch),
      ),
    );
  }
}

Future<void> _editName(BuildContext context, ClawController c, {String? name}) async {
  final epoch = c.workspaceEpoch;
  final input = TextEditingController(text: name);
  final value = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => AlertDialog(
        title: Text(name == null ? ctx.l10n.remoteWorkspaceAdd : ctx.l10n.remoteWorkspaceRename),
        content: TextField(
          autofocus: true,
          controller: input,
          maxLength: 120,
          onChanged: (_) => update(() {}),
          decoration: InputDecoration(labelText: ctx.l10n.remoteWorkspaceName),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.l10n.commonCancel)),
          FilledButton(
            onPressed: input.text.trim().isEmpty ? null : () => Navigator.pop(ctx, input.text.trim()),
            child: Text(ctx.l10n.commonSave),
          ),
        ],
      ),
    ),
  );
  // Wait for the dialog exit animation before releasing its input.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  input.dispose();
  if (value == null || !context.mounted || c.workspaceEpoch != epoch) return;
  await c.guard(() => name == null ? c.addGroup(value) : c.renameGroup(name, value));
}

class GatewayWorkspaceManager extends StatelessWidget {
  const GatewayWorkspaceManager({super.key, required this.controller, required this.epoch});
  final ClawController controller;
  final int epoch;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller, l = context.l10n;
      final active = c.connected && c.workspaceEpoch == epoch && c.groupCatalogSupported;
      return AppPage.list(
        title: l.remoteWorkspaceManage,
        children: [
          Padding(padding: const EdgeInsets.all(20), child: Text(l.ocWorkspaceHint)),
          if (c.error.isNotEmpty) Padding(padding: const EdgeInsets.all(20), child: Text(c.error)),
          ListPageRow(
            icon: AppIcons.newFolder,
            title: l.remoteWorkspaceAdd,
            onTap: active ? () => _editName(context, c) : null,
          ),
          for (final name in c.sessionGroups)
            SheetGroup(
              title: name,
              children: [
                ListPageRow(
                  icon: AppIcons.configure,
                  title: l.remoteWorkspaceRename,
                  onTap: active ? () => _editName(context, c, name: name) : null,
                ),
                ListPageRow(
                  icon: AppIcons.workspace,
                  title: l.ocWorkspaceDirectory,
                  onTap: active ? () => _directory(context, c, name) : null,
                ),
                ListPageRow(
                  icon: AppIcons.delete,
                  title: l.remoteWorkspaceRemoveAction,
                  danger: true,
                  onTap: active ? () => _delete(context, c, name) : null,
                ),
              ],
            ),
          if (!active) Padding(padding: const EdgeInsets.all(20), child: Text(l.ocWorkspaceReadOnly)),
        ],
      );
    },
  );

  Future<void> _delete(BuildContext context, ClawController c, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.remoteWorkspaceRemoveTitle(name)),
        content: Text(ctx.l10n.ocGroupRemoveBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.l10n.commonDelete)),
        ],
      ),
    );
    if (confirmed == true && context.mounted && c.workspaceEpoch == epoch) await c.guard(() => c.deleteGroup(name));
  }

  Future<void> _directory(BuildContext context, ClawController c, String name) async {
    List<Map<String, dynamic>>? defaults;
    await c.guard(() async {
      defaults = await c.groupDefaults();
    });
    if (!context.mounted || defaults == null || c.workspaceEpoch != epoch) return;
    final current = defaults!.where((d) => d['name'] == name).firstOrNull;
    final input = TextEditingController(text: current?['cwd'] as String? ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.ocWorkspaceDirectory),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(ctx.l10n.ocWorkspaceDirectoryHint),
            TextField(
              controller: input,
              autocorrect: false,
              decoration: InputDecoration(labelText: ctx.l10n.ocWorkspaceDirectory),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, input.text.trim()), child: Text(ctx.l10n.commonSave)),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (value != null && context.mounted && c.workspaceEpoch == epoch) {
      await c.guard(() => c.updateGroupDirectory(name, value.isEmpty ? null : value));
    }
  }
}
