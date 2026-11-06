import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../state/app_info.dart';
import '../ui/settings/settings_widgets.dart';
import '../ui/shell/page_frame.dart';
import '../ui/theme/app_icons.dart';

/// Attribution for the dual-remote client, separate from the upstream DSH app.
class RemoteAboutPage extends StatelessWidget {
  const RemoteAboutPage({super.key});

  Future<void> _openLink(BuildContext context, String url) async {
    var opened = false;
    try {
      opened = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      // A missing platform handler should have the same feedback as a refusal.
    }
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.remoteAboutLinkFailed)));
    }
  }

  Widget _link(BuildContext context, {required String id, required String title, required String url}) => SettingsTile(
    key: ValueKey('remote-about-$id'),
    icon: AppIcons.link,
    tinted: false,
    title: title,
    subtitle: url,
    trailing: const Icon(AppIcons.openExternal, size: 18),
    onTap: () => unawaited(_openLink(context, url)),
  );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AppPage.list(
      title: l.remoteAboutTitle,
      subtitle: Text(l.remoteAboutDescription),
      children: [
        SettingsSection(
          title: l.remoteAboutProject,
          children: [
            const SettingsTile(icon: AppIcons.info, tinted: false, title: 'OpenClaw Go'),
            SettingsTile(
              key: const ValueKey('remote-about-version'),
              title: l.remoteAboutVersion,
              value: Text(AppInfo.displayVersion),
            ),
            _link(context, id: 'homepage', title: l.remoteAboutHomepage, url: 'https://github.com/yukinsnow/dsh-Go'),
            _link(context, id: 'author', title: l.remoteAboutAuthor('yukinsnow'), url: 'https://github.com/yukinsnow'),
          ],
        ),
        SettingsSection(
          title: l.remoteAboutUpstream,
          footer: Text(l.remoteAboutAttribution),
          children: [
            _link(context, id: 'upstream', title: 'DSH Go', url: 'https://github.com/ccch1mneyyy/dsh-Go'),
            _link(
              context,
              id: 'upstream-author',
              title: l.remoteAboutUpstreamAuthor('ccch1mneyyy'),
              url: 'https://github.com/ccch1mneyyy',
            ),
          ],
        ),
      ],
    );
  }
}
