import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:openclaw_client/openclaw_client.dart';

import '../l10n/l10n.dart';
import '../ui/theme/theme.dart';
import '../ui/theme/app_icons.dart';
import '../ui/chat/composer.dart';
import '../ui/chat/widgets/user_bubble.dart';
import '../ui/shell/drawer/session_tile.dart';
import '../ui/shell/page_frame.dart';
import '../ui/common/status_dot.dart';
import '../ui/common/glass_pill.dart';
import 'controller.dart';

class ClawHome extends StatefulWidget {
  const ClawHome({super.key, required this.onLanguage, this.onBackend});
  final VoidCallback onLanguage;
  final VoidCallback? onBackend;
  @override
  State<ClawHome> createState() => _ClawHomeState();
}

class _ClawHomeState extends State<ClawHome> with WidgetsBindingObserver {
  final c = ClawController();
  final scaffoldKey = GlobalKey<ScaffoldState>();
  final input = TextEditingController(), scroll = ScrollController();
  final attachments = <Map<String, dynamic>>[];
  String queue = 'followup';
  String sessionQuery = '';
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
    if (state == AppLifecycleState.resumed && c.connected) c.guard(c.history);
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

  void closeSidebar() {
    FocusManager.instance.primaryFocus?.unfocus();
    scaffoldKey.currentState?.closeDrawer();
  }

  Widget sessionList() {
    final l = context.l10n;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
          child: Row(
            children: [
              Expanded(child: Text('OpenClaw', style: Theme.of(context).textTheme.titleLarge)),
              GlassIconButton(
                icon: AppIcons.refresh,
                tooltip: l.ocRefresh,
                onPressed: c.connected ? () => c.guard(c.refreshSessions) : null,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: GlassSurface(
            tier: GlassTier.chrome,
            stadium: true,
            onTap: c.connected
                ? () {
                    closeSidebar();
                    c.guard(c.newSession);
                  }
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [const Icon(AppIcons.add, size: 20), const SizedBox(width: 10), Text(l.ocNew)]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            onChanged: (value) => setState(() => sessionQuery = value.trim().toLowerCase()),
            decoration: InputDecoration(
              hintText: l.ocSearchSessions,
              prefixIcon: const Icon(AppIcons.search),
              isDense: true,
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            children: [
              for (final session in c.sessions)
                if (sessionTitle(session).toLowerCase().contains(sessionQuery))
                  SessionTile(
                    title: sessionTitle(session),
                    running: session['hasActiveRun'] == true,
                    current: session['key'] == c.sessionKey,
                    onLongPress: null,
                    onTap: () {
                      closeSidebar();
                      c.guard(() => c.select(session['key'] as String));
                    },
                  ),
            ],
          ),
        ),
        const Divider(indent: 20, endIndent: 20),
        if (widget.onBackend != null)
          ListTile(
            leading: const Icon(AppIcons.swap),
            title: const Text('DSH Remote'),
            onTap: () {
              closeSidebar();
              widget.onBackend!();
            },
          ),
        ListTile(
          leading: const Icon(AppIcons.settings),
          title: Text(l.ocSettings),
          onTap: () {
            closeSidebar();
            settings();
          },
        ),
        ListTile(leading: const Icon(AppIcons.translate), title: Text(l.ocEnglish), onTap: widget.onLanguage),
        ListTile(
          leading: const Icon(AppIcons.info),
          title: Text(l.ocLicenses),
          onTap: () => showLicensePage(context: context, applicationName: 'OpenClaw Go'),
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
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: BackdropGroup(
          child: Row(
            children: [
              if (!wide) ...[
                GlassIconButton(
                  icon: AppIcons.menu,
                  tooltip: l.ocSessions,
                  onPressed: () {
                    composerFocus.unfocus();
                    scaffoldKey.currentState?.openDrawer();
                  },
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: GlassSurface(
                  tier: GlassTier.chrome,
                  stadium: true,
                  grouped: true,
                  onTap: c.busy ? null : settings,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        session == null ? 'OpenClaw Go' : sessionTitle(session),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Row(
                        children: [
                          StatusDot(tone: c.connected ? StatusTone.ok : StatusTone.idle, size: 6),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              c.connected ? l.ocConnected : l.ocDisconnected,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GlassIconButton(
                icon: AppIcons.model,
                tooltip: l.ocModels,
                onPressed: c.connected && c.sessionKey.isNotEmpty ? chooseModel : null,
              ),
              const SizedBox(width: 8),
              GlassIconButton(
                icon: AppIcons.add,
                tooltip: l.ocNew,
                onPressed: c.connected ? () => c.guard(c.newSession) : null,
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
        ),
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
    final wide = MediaQuery.sizeOf(context).width >= 850;
    return AppBackdrop(
      child: Scaffold(
        key: scaffoldKey,
        onDrawerChanged: (open) {
          if (open) FocusManager.instance.primaryFocus?.unfocus();
        },
        backgroundColor: Colors.transparent,
        appBar: PreferredSize(preferredSize: const Size.fromHeight(68), child: header(wide)),
        drawer: wide
            ? null
            : Drawer(
                child: AppBackdrop(child: SafeArea(child: sessionList())),
              ),
        body: Row(
          children: [
            if (wide) SizedBox(width: 280, child: sessionList()),
            Expanded(
              child: Column(
                children: [
                  if (c.busy) const LinearProgressIndicator(),
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
                              ],
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
