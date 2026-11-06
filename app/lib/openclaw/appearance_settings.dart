import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../state/settings_state.dart';
import '../ui/settings/settings_widgets.dart';
import '../ui/theme/app_icons.dart';
import 'mascot_settings.dart';

/// Shared controls in both protocol owners' settings, without exposing Android
/// launcher/overlay options in the iOS remote client.
class RemoteAppearanceSettings extends ConsumerWidget {
  const RemoteAppearanceSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final mode = ref.watch(settingsProvider.select((s) => s.themeMode));
    final returnKeySends = ref.watch(settingsProvider.select((s) => s.returnKeySends));
    final pets = ref.watch(mascotSettingsProvider);
    return SettingsSection(
      title: l.hubSettingsAppearance,
      children: [
        SettingsSegmentTile<ThemeMode>(
          key: const ValueKey('remote-theme-mode'),
          icon: AppIcons.theme,
          title: l.ocAppearanceMode,
          segments: [
            PillSegment(ThemeMode.light, l.ocDayMode),
            PillSegment(ThemeMode.dark, l.ocNightMode),
            PillSegment(ThemeMode.system, l.commonFollowSystem),
          ],
          selected: mode,
          onChanged: (value) => unawaited(ref.read(settingsProvider.notifier).setThemeMode(value)),
        ),
        SettingsSwitchTile(
          key: const ValueKey('remote-return-key-sends-switch'),
          icon: AppIcons.enterKey,
          title: l.returnKeySendsTitle,
          subtitle: l.returnKeySendsHint,
          value: returnKeySends,
          onChanged: (value) => unawaited(ref.read(settingsProvider.notifier).setReturnKeySends(value)),
        ),
        for (final pet in RemoteMascot.values)
          SettingsSwitchTile(
            key: ValueKey('remote-mascot-${pet.name}-switch'),
            icon: AppIcons.pet,
            title: pet == RemoteMascot.whale ? l.ocWhaleMascot : l.ocLobsterMascot,
            subtitle: l.ocMascotHint,
            value: pets[pet]!,
            onChanged: (value) => unawaited(ref.read(mascotSettingsProvider.notifier).setEnabled(pet, value)),
          ),
      ],
    );
  }
}
