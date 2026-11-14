import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../ui/settings/settings_widgets.dart';
import 'notifications.dart';

class CoveNotificationSettings extends ConsumerStatefulWidget {
  const CoveNotificationSettings({super.key});
  @override
  ConsumerState<CoveNotificationSettings> createState() => _CoveNotificationSettingsState();
}

class _CoveNotificationSettingsState extends ConsumerState<CoveNotificationSettings> with WidgetsBindingObserver {
  Map? status;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  Future<void> refresh() async {
    final value = await ref.read(coveNotificationBridgeProvider).status();
    if (mounted) setState(() => status = value);
  }

  Future<void> toggle(bool value) async {
    setState(() => busy = true);
    try {
      final bridge = ref.read(coveNotificationBridgeProvider);
      final result = value ? await bridge.status(request: true) : await bridge.status();
      if (!mounted) return;
      await ref.read(coveNotificationsEnabledProvider.notifier).setEnabled(value && result['enabled'] == true);
      if (mounted) setState(() => status = result);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return SettingsSection(
      title: l.ocNotifications,
      footer: Text(l.ocNotificationLimit),
      children: [
        SettingsSwitchTile(
          key: const ValueKey('cove-notifications-enabled'),
          icon: Icons.notifications_outlined,
          title: l.ocNotifications,
          subtitle: l.ocNotificationPrivacy,
          value: ref.watch(coveNotificationsEnabledProvider),
          onChanged: busy ? null : toggle,
        ),
        if (status?['native'] == true && status?['enabled'] != true)
          SettingsTile(
            title: l.ocNotificationPermission,
            subtitle: l.ocNotificationPermissionHint,
            onTap: () => ref.read(coveNotificationBridgeProvider).settings(),
          ),
        SettingsTile(
          key: const ValueKey('cove-notifications-test'),
          title: l.ocNotificationTest,
          onTap: !busy && ref.watch(coveNotificationsEnabledProvider)
              ? () async {
                  final shown = await ref
                      .read(coveNotificationBridgeProvider)
                      .show(
                        id: 'cove-test',
                        title: 'Cove-Go',
                        body: l.ocNotificationTestBody,
                        target: const CoveNotificationTarget(backend: 'openclaw', host: 'settings', session: ''),
                      );
                  if (context.mounted && !shown) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.ocNotificationPermissionHint)));
                  }
                }
              : null,
        ),
      ],
    );
  }
}
