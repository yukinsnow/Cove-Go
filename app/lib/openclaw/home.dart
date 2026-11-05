import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:openclaw_client/openclaw_client.dart';

import '../l10n/l10n.dart';
import '../ui/theme/theme.dart';
import '../ui/theme/app_icons.dart';
import '../ui/chat/composer.dart';
import '../ui/chat/chat_header.dart';
import '../ui/chat/widgets/user_bubble.dart';
import '../ui/shell/drawer/session_tile.dart';
import '../ui/shell/page_frame.dart';
import '../ui/common/status_dot.dart';
import '../ui/common/glass_pill.dart';
import 'controller.dart';
import '../ui/remote/host_switcher.dart';
import '../ui/remote/remote_screen.dart';
import '../ui/shell/sessions_drawer.dart'
    show IdentityBar, HostIdentityPresentation, DrawerBrandHeader, SessionDrawerSurface;
import '../ui/shell/drawer/drawer_filter_bar.dart';
import '../ui/shell/adaptive/adaptive_layout.dart';
import '../state/app_info.dart';

import 'dart:math' as math;

import '../ui/settings/settings_widgets.dart';
import '../state/drawer_view_state.dart' show DrawerFilter, SessionDay, sessionDayOf, sessionDayLabels;
import '../ui/shell/session_search_page.dart';
import '../ui/web/web_view_page.dart';

class ClawHome extends StatefulWidget {
  const ClawHome({super.key, required this.onLanguage, this.controller});
  final ClawController? controller;
  final VoidCallback onLanguage;
  @override
  ClawHomeState createState() => ClawHomeState();
}

class ClawHomeState extends State<ClawHome> with WidgetsBindingObserver {
  late final c = widget.controller ?? ClawController();
  final scaffoldKey = GlobalKey<ScaffoldState>();
  final input = TextEditingController(), scroll = ScrollController(keepScrollOffset: false);
  final attachments = <Map<String, dynamic>>[];
  String queue = 'followup';
  DrawerFilter filter = DrawerFilter.all;
  final seen = <String, Object?>{};
  bool isUnread(Map<String, dynamic> session) =>
      session['key'] != c.sessionKey &&
      session['updatedAt'] != null &&
      (!seen.containsKey(session['key']) || seen[session['key']] != session['updatedAt']);
  final composerFocus = FocusNode();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(update);
    c.guard(c.load);
  }

  void update() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (c.connected) {
      c.guard(c.history);
    } else if (!c.busy && c.address.isNotEmpty && c.token.isNotEmpty) {
      c.connect(c.address, c.token);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(update);
    c.dispose();
    composerFocus.dispose();
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> settings() async {
    final url = TextEditingController(text: c.address), secret = TextEditingController(text: c.token);
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (ctx) {
        final l = ctx.l10n;
        return AlertDialog(
          title: Text(l.ocConnect),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: url,
                  autocorrect: false,
                  decoration: InputDecoration(labelText: l.ocAddress),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: secret,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(labelText: l.ocToken),
                ),
                const SizedBox(height: 16),
                Text(l.ocPairHelp),
              ],
            ),
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx, (url.text, secret.text)), child: Text(l.ocConnect)),
          ],
        );
      },
    );
    // Controllers are disposed after the dialog route's exit animation.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    url.dispose();
    secret.dispose();
    if (result != null) await c.connect(result.$1, result.$2);
  }

  Future<void> attach() => c.guard(() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2048, imageQuality: 85);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final policy = c.client.hello['policy'] as Map? ?? {};
    final limits = policy['attachments'] as Map? ?? {};
    final limit = limits['maxImageBytes'] as int? ?? 6 * 1024 * 1024;
    if (bytes.length > limit) throw StateError('Image exceeds Gateway limit ($limit bytes)');
    // image_picker may return PNG/HEIC; do not mislabel the upload as JPEG.
    final mime =
        file.mimeType ??
        (bytes.length > 3 && bytes[0] == 0x89 && bytes[1] == 0x50
            ? 'image/png'
            : bytes.length > 2 && bytes[0] == 0xff && bytes[1] == 0xd8
            ? 'image/jpeg'
            : null);
    if (mime == null) throw StateError('Choose a JPEG or PNG image');
    setState(
      () => attachments.add({'type': 'image', 'mimeType': mime, 'fileName': file.name, 'content': base64Encode(bytes)}),
    );
  });
  Future<void> send() async {
    final text = input.text.trim();
    if (text.isEmpty && attachments.isEmpty) return;
    final files = List<Map<String, dynamic>>.from(attachments);
    await c.guard(() async {
      await c.send(text, queueMode: queue, attachments: files);
      if (mounted) {
        setState(() {
          if (input.text.trim() == text) input.clear();
          attachments.removeWhere((file) => files.contains(file));
        });
      }
    });
  }

  void switchHost() {
    showHostSheet(
      context,
      onManage: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ProviderScope(
            overrides: [
              gatewayHostEntryProvider.overrideWithValue(
                ProviderScope.containerOf(context).read(gatewayHostEntryProvider),
              ),
            ],
            child: const RemoteScreen(),
          ),
        ),
      ),
    );
  }

  String get hostName =>
      Uri.tryParse(c.address)?.host.isNotEmpty == true ? Uri.parse(c.address).host : context.l10n.commonRemoteHost;

  void closeSidebar() {
    FocusManager.instance.primaryFocus?.unfocus();
    scaffoldKey.currentState?.closeDrawer();
  }

  void openGatewayWeb() {
    closeSidebar();
    final address = Uri.tryParse(c.address);
    if (address == null || address.host.isEmpty) {
      settings();
      return;
    }
    // Only the origin; do not put a stored Gateway token into a URL.
    final url = Uri(
      scheme: address.scheme == 'wss' || address.scheme == 'https' ? 'https' : 'http',
      host: address.host,
      port: address.hasPort ? address.port : null,
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WebViewPage(url: url, title: hostName, allowOpenExternal: true),
      ),
    );
  }

  void searchSessions() {
    closeSidebar();
    var query = '';
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (page) => StatefulBuilder(
          builder: (page, updateSearch) => AppPage.list(
            title: page.l10n.shellSearchChats,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  autofocus: true,
                  onChanged: (value) => updateSearch(() => query = value.trim().toLowerCase()),
                  decoration: InputDecoration(
                    hintText: page.l10n.shellSearchChats,
                    prefixIcon: const Icon(AppIcons.search),
                  ),
                ),
              ),
              for (final session in c.sessions)
                if (sessionTitle(session).toLowerCase().contains(query))
                  SessionTile(
                    title: sessionTitle(session),
                    running: session['hasActiveRun'] == true,
                    current: session['key'] == c.sessionKey,
                    onLongPress: null,
                    onTap: () {
                      Navigator.of(page).pop();
                      c.guard(() => c.select(session['key'] as String));
                    },
                  ),
            ],
          ),
        ),
      ),
    );
  }

  void openSettings({bool features = false}) {
    closeSidebar();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (pageContext) {
          final l = pageContext.l10n;
          return AppPage.list(
            title: features ? l.hubSettingsAllFeatures : l.commonSettings,
            children: [
              SettingsSection(
                title: l.commonRemoteHost,
                children: [
                  SettingsTile(
                    icon: AppIcons.remoteHost,
                    title: l.remoteSwitchHost,
                    subtitle: hostName,
                    onTap: () {
                      Navigator.of(pageContext).pop();
                      switchHost();
                    },
                  ),
                  SettingsTile(icon: AppIcons.settings, title: l.ocSettings, onTap: settings),
                  SettingsTile(icon: AppIcons.info, title: AppInfo.displayVersion, subtitle: AppInfo.sourceRevision),
                ],
              ),
              if (features)
                SettingsSection(
                  title: l.ocSessions,
                  children: [
                    SettingsTile(
                      icon: AppIcons.refresh,
                      title: l.ocRefresh,
                      onTap: c.connected ? () => c.guard(c.refreshSessions) : null,
                    ),
                    SettingsTile(
                      icon: AppIcons.add,
                      title: l.commonNewChat,
                      onTap: c.connected
                          ? () {
                              Navigator.of(pageContext).pop();
                              c.guard(c.newSession);
                            }
                          : null,
                    ),
                    SettingsTile(
                      icon: AppIcons.model,
                      title: l.ocModels,
                      onTap: c.connected && c.sessionKey.isNotEmpty ? chooseModel : null,
                    ),
                  ],
                ),
              SettingsSection(
                title: l.commonSettings,
                children: [
                  SettingsTile(icon: AppIcons.translate, title: l.ocEnglish, onTap: widget.onLanguage),
                  SettingsTile(
                    icon: AppIcons.info,
                    title: l.ocLicenses,
                    onTap: () => showLicensePage(context: pageContext, applicationName: 'OpenClaw Go'),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget sessionList() {
    final l = context.l10n;
    final theme = Theme.of(context);
    final top = <Widget>[
      DrawerBrandHeader(
        onWeb: openGatewayWeb,
        onNewChat: () {
          closeSidebar();
          if (c.connected) {
            c.guard(c.newSession);
          } else {
            settings();
          }
        },
      ),
      SessionSearchBar(onClose: closeSidebar, onSearch: searchSessions),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 10, 0),
        child: Row(
          children: [
            const Icon(AppIcons.conversations, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: PopupMenuButton<DrawerFilter>(
                onSelected: (value) => setState(() => filter = value),
                itemBuilder: (_) => [
                  PopupMenuItem(value: DrawerFilter.all, child: Text(l.remoteWorkspaceAllChats)),
                  PopupMenuItem(value: DrawerFilter.running, child: Text(l.commonRunning)),
                ],
                child: Row(
                  children: [
                    Flexible(child: Text(l.remoteWorkspaceAllChats, style: theme.textTheme.titleSmall)),
                    const Icon(AppIcons.expand, size: 18),
                  ],
                ),
              ),
            ),
            DrawerViewButton(onTap: () => openSettings(features: true)),
          ],
        ),
      ),
      SessionFilterRow(
        enabled: (value) => value != DrawerFilter.pending,
        selected: filter,
        label: (value) {
          final count = value == DrawerFilter.unread ? c.sessions.where(isUnread).length : 0;
          return count > 0 ? '${value.label} $count' : value.label;
        },
        onSelected: (value) => setState(() => filter = value),
      ),
    ];
    DateTime? updatedAt(Map<String, dynamic> session) {
      final value = session['updatedAt'];
      if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
      return value is String ? DateTime.tryParse(value) : null;
    }

    final visible =
        c.sessions
            .where(
              (session) => switch (filter) {
                DrawerFilter.all => true,
                DrawerFilter.running => session['hasActiveRun'] == true,
                // The sessions API does not expose approval state. Never borrow DSH's
                // pending interactions or invent a Gateway approval from a running flag.
                DrawerFilter.pending => false,
                DrawerFilter.unread => isUnread(session),
              },
            )
            .toList()
          ..sort(
            (a, b) => (updatedAt(b)?.millisecondsSinceEpoch ?? 0).compareTo(updatedAt(a)?.millisecondsSinceEpoch ?? 0),
          );
    final groups = <SessionDay?, List<Map<String, dynamic>>>{};
    final now = DateTime.now();
    for (final session in visible) {
      final at = updatedAt(session);
      (groups[at == null ? null : sessionDayOf(at, now)] ??= []).add(session);
    }
    final rows = <Widget>[
      for (final group in groups.entries) ...[
        if (group.key != null) DrawerEyebrow(sessionDayLabels[group.key]!),
        for (final session in group.value)
          SessionTile(
            title: sessionTitle(session),
            running: session['hasActiveRun'] == true,
            current: session['key'] == c.sessionKey,
            unread: isUnread(session),
            onLongPress: null,
            onTap: () {
              closeSidebar();
              seen[session['key'] as String] = session['updatedAt'];
              c.guard(() => c.select(session['key'] as String));
            },
          ),
      ],
    ];
    final short = MediaQuery.sizeOf(context).height < WindowClass.compactHeight;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!short) ...top,
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(10, 4, 10, 16), children: [if (short) ...top, ...rows]),
        ),
        IdentityBar(
          presentation: HostIdentityPresentation(
            name: hostName,
            status: c.connected ? l.ocConnected : l.ocDisconnected,
            tone: c.connected ? StatusTone.ok : StatusTone.idle,
            icon: AppIcons.remoteHost,
          ),
          onHost: switchHost,
          onLocalDetails: () => openSettings(),
          onFeatures: () => openSettings(features: true),
          onSettings: () => openSettings(),
        ),
      ],
    );
  }

  String sessionTitle(Map<String, dynamic> session) =>
      '${session['displayName'] ?? session['label'] ?? session['key']}';

  Widget bubble(Map<String, dynamic> message) {
    final text = messageText(message), user = message['role'] == 'user';
    if (text.isEmpty) return const SizedBox.shrink();
    if (message['role'] == 'toolResult' || message['role'] == 'tool') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: ExpansionTile(
          title: Text('${message['toolName'] ?? context.l10n.ocTools}'),
          children: [SelectableText(text)],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: user
          ? UserBubble(text: text)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectionArea(child: GptMarkdown(text, style: AppType.chatBody(context))),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: context.l10n.ocCopy,
                  onPressed: () => Clipboard.setData(ClipboardData(text: text)),
                  icon: const Icon(AppIcons.copy, size: 18),
                ),
              ],
            ),
    );
  }

  Widget header(bool wide) {
    final l = context.l10n;
    final session = c.sessions.where((s) => s['key'] == c.sessionKey).firstOrNull;
    final model = session?['model'] ?? session?['modelOverride'];
    return ChatHeader(
      useDshState: false,
      title: session == null ? 'OpenClaw Go' : sessionTitle(session),
      status: HeaderStatus(
        c.connected ? StatusTone.ok : StatusTone.idle,
        c.connected ? l.ocConnected : l.ocDisconnected,
      ),
      onOpenDrawer: wide
          ? null
          : () {
              composerFocus.unfocus();
              scaffoldKey.currentState?.openDrawer();
            },
      onTitleTap: switchHost,
      onNewChat: c.connected ? () => c.guard(c.newSession) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: GlassSurface(
              tier: GlassTier.chrome,
              stadium: true,
              grouped: true,
              onTap: c.connected && c.sessionKey.isNotEmpty ? chooseModel : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(AppIcons.model, size: 14, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          model == null ? l.ocModels : '$model'.split('/').last,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(fontSize: 13),
                        ),
                      ),
                      const Icon(AppIcons.expand, size: 16),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (MediaQuery.viewInsetsOf(context).bottom > 0) ...[
            const SizedBox(width: 8),
            GlassIconButton(
              icon: Icons.keyboard_hide_outlined,
              tooltip: l.ocHideKeyboard,
              onPressed: composerFocus.unfocus,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> sendOptions() => showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in [
            ('followup', context.l10n.ocQueue),
            ('steer', context.l10n.ocSteer),
            ('interrupt', context.l10n.ocInterrupt),
          ])
            ListTile(
              selected: queue == item.$1,
              leading: Icon(queue == item.$1 ? AppIcons.done : AppIcons.queued),
              title: Text(item.$2),
              onTap: () {
                setState(() => queue = item.$1);
                Navigator.pop(ctx);
              },
            ),
        ],
      ),
    ),
  );

  Future<void> chooseModel() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text(ctx.l10n.ocModels)),
            for (final model in c.models)
              ListTile(
                title: Text('${model['name'] ?? model['id']}'),
                subtitle: Text('${model['provider'] ?? ''}'),
                onTap: () {
                  final id = '${model['id']}';
                  Navigator.pop(ctx, id.contains('/') ? id : '${model['provider']}/$id');
                },
              ),
          ],
        ),
      ),
    );
    if (selected != null) await c.guard(() => c.model(selected));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final wide =
        MediaQuery.sizeOf(context).width >= WindowClass.expandedMin &&
        MediaQuery.sizeOf(context).height >= WindowClass.compactHeight;
    return AppBackdrop(
      child: Scaffold(
        key: scaffoldKey,
        onDrawerChanged: (open) {
          if (open) FocusManager.instance.primaryFocus?.unfocus();
        },
        backgroundColor: Colors.transparent,
        appBar: PreferredSize(preferredSize: Size.fromHeight(ChatHeader.barHeightOf(context) + 8), child: header(wide)),
        drawer: wide
            ? null
            : SizedBox(
                width: math.min(
                  AdaptiveMetrics.sidebarWidth + MediaQuery.paddingOf(context).left,
                  MediaQuery.sizeOf(context).width - 56,
                ),
                child: SessionDrawerSurface(child: sessionList()),
              ),
        body: Row(
          children: [
            if (wide)
              SizedBox(
                width: AdaptiveMetrics.sidebarWidth,
                child: SessionDrawerSurface(child: sessionList()),
              ),
            Expanded(
              child: Column(
                children: [
                  if (c.busy && c.messages.isEmpty) const LinearProgressIndicator(),
                  if (c.readingCache)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Text(l.ocCachedHistory, style: Theme.of(context).textTheme.bodySmall),
                    ),
                  if (c.error.isNotEmpty)
                    MaterialBanner(
                      content: SelectableText(c.error),
                      actions: [TextButton(onPressed: () => c.connect(c.address, c.token), child: Text(l.ocReconnect))],
                    ),
                  Expanded(
                    child: c.sessionKey.isEmpty
                        ? Center(
                            child: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.hub_outlined, size: 56, color: Theme.of(context).colorScheme.primary),
                                  const SizedBox(height: 20),
                                  Text(l.ocWelcome, style: Theme.of(context).textTheme.headlineSmall),
                                  const SizedBox(height: 8),
                                  Text(l.ocWelcomeHint),
                                  const SizedBox(height: 24),
                                  FilledButton(
                                    onPressed: c.busy
                                        ? null
                                        : c.connected
                                        ? () => c.guard(c.newSession)
                                        : settings,
                                    child: Text(c.connected ? l.ocNew : l.ocConnect),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: () => c.guard(c.history),
                            child: ListView(
                              key: ValueKey(('gateway-messages', c.sessionKey, c.selectionRevision)),
                              // Zero is the newest message. A new conversation gets
                              // a fresh viewport; streaming does not pull a reader
                              // away from older messages they scrolled up to read.
                              reverse: true,
                              controller: scroll,
                              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                              children: [
                                for (final message in c.messages) bubble(message),
                                if (c.tools.isNotEmpty)
                                  GlassPill(
                                    child: Text('${l.ocTools} · ${c.tools.length}'),
                                    onTap: () => showModalBottomSheet<void>(
                                      context: context,
                                      isScrollControlled: true,
                                      builder: (ctx) => SafeArea(
                                        child: SizedBox(
                                          height: MediaQuery.sizeOf(ctx).height * .7,
                                          child: ListView(
                                            children: [
                                              for (final tool in c.tools.values)
                                                ExpansionTile(
                                                  title: Text('${tool['name'] ?? l.ocTools} · ${tool['phase'] ?? ''}'),
                                                  children: [
                                                    Padding(
                                                      padding: const EdgeInsets.all(16),
                                                      child: SelectableText(c.toolText(tool)),
                                                    ),
                                                  ],
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                for (final text in c.live.values) bubble({'role': 'assistant', 'content': text}),
                              ].reversed.toList(),
                            ),
                          ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      child: TextFieldTapRegion(
                        onTapOutside: (_) => composerFocus.unfocus(),
                        child: Composer(
                          controller: input,
                          focusNode: composerFocus,
                          connected: c.connected,
                          running: c.live.isNotEmpty,
                          busy: c.sending,
                          placeholder: l.ocHint,
                          maxLines: Composer.linesFor(context),
                          onSend: send,
                          onStop: () => c.guard(c.abort),
                          onSendOptions: sendOptions,
                          accessory: IconButton(
                            tooltip: l.ocQueue,
                            onPressed: sendOptions,
                            icon: const Icon(AppIcons.queued, size: 20),
                          ),
                          hasAttachments: attachments.isNotEmpty,
                          leading: IconButton(
                            tooltip: l.ocAttach,
                            onPressed: c.connected ? attach : null,
                            icon: const Icon(AppIcons.add),
                          ),
                          tray: attachments.isEmpty
                              ? null
                              : Wrap(
                                  children: [
                                    for (var i = 0; i < attachments.length; i++)
                                      InputChip(
                                        label: Text('${attachments[i]['fileName']}'),
                                        onDeleted: () => setState(() => attachments.removeAt(i)),
                                      ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
