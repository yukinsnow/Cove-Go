import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:openclaw_client/openclaw_client.dart';

import '../l10n/l10n.dart';
import '../ui/theme/theme.dart';
import '../ui/theme/app_icons.dart';
import '../ui/chat/composer.dart';
import '../ui/chat/render/markdown_body.dart';
import '../ui/chat/chat_header.dart';
import '../ui/chat/widgets/user_bubble.dart';
import '../ui/shell/drawer/session_tile.dart';
import '../ui/shell/page_frame.dart';
import '../ui/common/status_dot.dart';
import 'controller.dart';
import 'about_page.dart';
import 'appearance_settings.dart';
import 'mascot_settings.dart';
import 'mascot_stage.dart';
import 'tool_activity.dart';
import 'images.dart';
import 'attachments.dart';
import 'received_file.dart';
import 'interaction_sheets.dart';
import 'session_details.dart';
import '../ui/chat/widgets/plus_panel.dart' show AttachSource;
import 'feature_data.dart';
import 'workspaces.dart';
import 'features.dart';
import 'feature_export.dart';
import 'ssh_tunnel.dart';
import '../state/hosts_state.dart';
import '../state/settings_state.dart';
import '../state/attachments.dart' show maxAttachments;
import '../remote/ssh/ssh_transport.dart';
import '../remote/ssh/ssh_link.dart';
import '../ui/remote/host_key_dialog.dart';
import '../ui/remote/ssh_host_form.dart';
import '../ui/remote/host_switcher.dart';
import '../ui/remote/remote_screen.dart';
import '../ui/shell/sessions_drawer.dart'
    show IdentityBar, HostIdentityPresentation, DrawerBrandHeader, SessionDrawerSurface;
import '../ui/shell/drawer/drawer_filter_bar.dart';
import '../ui/shell/adaptive/adaptive_layout.dart';

import 'dart:math' as math;

import '../ui/settings/settings_widgets.dart';
import '../ui/shell/session_search_page.dart';
import '../ui/web/web_view_page.dart';

/// Native gallery selection; overridden by widget tests without platform UI.
final gatewayImagePickerProvider = Provider<Future<List<XFile>> Function(int limit)>((ref) {
  return (limit) => ImagePicker().pickMultipleMedia(
    maxWidth: 2048,
    maxHeight: 2048,
    imageQuality: 85,
    requestFullMetadata: false,
    limit: limit,
  );
});

String gatewayModelId(Map<String, dynamic> model) {
  final id = model['id'] as String? ?? '';
  final provider = model['provider'] as String? ?? '';
  return provider.isEmpty || id.startsWith('$provider/') ? id : '$provider/$id';
}

bool gatewayModelSelected(ClawController controller, Map<String, dynamic> model) {
  final session = controller.sessions.where((s) => s['key'] == controller.sessionKey).firstOrNull;
  final current = session?['model'] ?? session?['modelOverride'];
  if (current is! String || current.isEmpty) return false;
  final provider = session?['modelProvider'] ?? session?['providerOverride'];
  if (provider is String && provider.isNotEmpty) {
    return gatewayModelId({'id': current, 'provider': provider}) == gatewayModelId(model);
  }
  if (current == gatewayModelId(model)) return true;
  // An unqualified legacy id is safe only when the catalog match is unique.
  final candidates = controller.models.where((m) => m['id'] == current).toList();
  return candidates.length == 1 && gatewayModelId(candidates.single) == gatewayModelId(model);
}

class ClawHome extends ConsumerStatefulWidget {
  const ClawHome({super.key, required this.onLanguage, this.controller, this.ownsController = true});
  final ClawController? controller;
  final bool ownsController;
  final VoidCallback onLanguage;
  @override
  ClawHomeState createState() => ClawHomeState();
}

class ClawHomeState extends ConsumerState<ClawHome> with WidgetsBindingObserver {
  late final c = widget.controller ?? ClawController();
  final scaffoldKey = GlobalKey<ScaffoldState>();
  final input = TextEditingController(), scroll = ScrollController(keepScrollOffset: false);
  final attachments = <Map<String, dynamic>>[];
  String queue = 'followup';
  bool pickingImages = false;
  final composerFocus = FocusNode();
  final gatewayTunnel = GatewaySshTunnel();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(update);
    c.closeTransport = gatewayTunnel.close;
    c.resolveAddress = (address, sshId) async {
      if (sshId == null) {
        await gatewayTunnel.close();
        return address;
      }
      final container = ProviderScope.containerOf(context, listen: false);
      final hosts = container.read(hostsProvider.notifier);
      await hosts.ready;
      if (!mounted) throw StateError("View disposed");
      final config = container.read(hostsProvider).sshById(sshId);
      if (config == null) throw StateError(context.l10n.ocSshMissing);
      return gatewayTunnel.open(address, SshConnectParams.of(config, await hosts.loadSecrets(sshId)), (key) async {
        if (config.hostKeyFingerprint != null) {
          return config.hostKeyFingerprint == key.fingerprint && config.hostKeyType == key.type;
        }
        if (!mounted ||
            !await confirmHostKey(context, HostKeyPrompt(hostName: config.name, address: config.address, key: key))) {
          return false;
        }
        await hosts.pinHostKey(sshId, key);
        return true;
      });
    };
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
    if (widget.ownsController) c.dispose();
    composerFocus.dispose();
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> settings({BuildContext? from, bool requireSsh = false}) async {
    final url = TextEditingController(text: c.address), secret = TextEditingController(text: c.token);
    String? selectedSsh = c.sshId;
    final container = ProviderScope.containerOf(from ?? context, listen: false);
    await container.read(hostsProvider.notifier).ready;
    if (!mounted || (from != null && !from.mounted)) {
      url.dispose();
      secret.dispose();
      return;
    }
    if (selectedSsh != null && container.read(hostsProvider).sshById(selectedSsh) == null) selectedSsh = null;
    if (requireSsh && selectedSsh == null) {
      final saved = await Navigator.of(from ?? context)
          .push<SshHostConfig>(MaterialPageRoute(builder: (_) => const SshHostFormPage(gatewayOnly: true)));
      if (!mounted || saved == null || (from != null && !from.mounted)) {
        url.dispose();
        secret.dispose();
        return;
      }
      selectedSsh = saved.id;
      if (url.text.isEmpty) url.text = 'ws://127.0.0.1:18789';
    }

    final result = await showDialog<(String, String)>(
      context: from ?? context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          final l = ctx.l10n;
          return AlertDialog(
            title: Text(l.ocConnect),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
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
                    DropdownButtonFormField<String>(
                      key: ValueKey(selectedSsh),
                      initialValue: selectedSsh ?? '',
                      decoration: InputDecoration(labelText: l.ocTransport),
                      items: [
                        DropdownMenuItem(value: '', child: Text(l.ocDirect)),
                        for (final h in container.read(hostsProvider).ssh)
                          DropdownMenuItem(value: h.id, child: Text('SSH · ${h.name}')),
                      ],
                      onChanged: (value) => update(() => selectedSsh = value == '' ? null : value),
                    ),
                    TextButton.icon(
                      icon: const Icon(AppIcons.add),
                      label: Text(l.ocAddSsh),
                      onPressed: () async {
                        final saved = await Navigator.of(ctx).push<SshHostConfig>(
                          MaterialPageRoute(builder: (_) => const SshHostFormPage(gatewayOnly: true)),
                        );
                        if (saved != null && ctx.mounted) update(() => selectedSsh = saved.id);
                      },
                    ),
                    if (selectedSsh != null) Text(l.ocSshGatewayHelp),
                    Text(l.ocPairHelp),
                  ],
                ),
              ),
            ),
            actions: [
              FilledButton(onPressed: () => Navigator.pop(ctx, (url.text, secret.text)), child: Text(l.ocConnect)),
            ],
          );
        },
      ),
    );
    // Controllers are disposed after the dialog route's exit animation.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    url.dispose();
    secret.dispose();
    if (mounted && result != null && !c.busy) {
      c.sshId = selectedSsh;
      await c.connect(result.$1, result.$2);
    }
  }

  Future<void> attach() => c.guard(() async {
    if (pickingImages) return;
    pickingImages = true;
    try {
      final host = c.address, credential = c.token, session = c.sessionKey, selection = c.selectionRevision;
      bool current() =>
          mounted &&
          c.address == host &&
          c.token == credential &&
          c.sessionKey == session &&
          c.selectionRevision == selection;
      await hideKeyboard();
      if (!mounted || !current()) return;
      final room = maxAttachments - attachments.length;
      if (room <= 0) throw StateError(context.l10n.chatAttachmentLimit(maxAttachments));
      final source = await showGatewayAttachmentPanel(context);
      if (!current() || source == null) return;
      final files = await ref.read(switch (source) {
        AttachSource.gallery => gatewayImagePickerProvider,
        AttachSource.camera => gatewayCameraPickerProvider,
        AttachSource.files => gatewayFilePickerProvider,
      })(room);
      if (!mounted || !current() || files.isEmpty) return;
      if (files.length > room) throw StateError(context.l10n.chatAttachmentLimit(maxAttachments));
      final policy = c.client.hello['policy'] as Map? ?? {};
      final limits = policy['attachments'] as Map? ?? {};
      final limit = limits['maxImageBytes'] as int? ?? 6 * 1024 * 1024;
      final maxBytes = limits['maxBytes'] as int? ?? 20 * 1024 * 1024;
      // Reserve space for JSON/base64 overhead; client.request checks the exact frame.
      final frameBytes = policy['maxPayload'] as int? ?? 26214400;
      final byteBudget = ((frameBytes - 65536) * 3 ~/ 4).clamp(0, 20 * 1024 * 1024);
      var usedBytes = attachments.fold<int>(
        0,
        (n, a) => n + (a['sizeBytes'] as int? ?? base64Decode(a['content'] as String).length),
      );
      final pending = <Map<String, dynamic>>[];
      final previews = <({ImageProvider image, String name})>[];
      for (final file in files) {
        final remaining = byteBudget - usedBytes;
        final bytes = await readGatewayAttachment(file, remaining < maxBytes ? remaining : maxBytes);
        if (!mounted || !current()) return;
        final mime = gatewayAttachmentMime(file, bytes);
        final image = mime.startsWith('image/');
        if (image && bytes.length > limit) {
          throw StateError(context.l10n.ocAttachmentTooLarge(file.name, '$limit B'));
        }
        usedBytes += bytes.length;
        pending.add({
          'type': image ? 'image' : 'file',
          'mimeType': mime,
          'fileName': file.name,
          'content': base64Encode(bytes),
          'sizeBytes': bytes.length,
          'origin': 'file',
        });
        if (image) previews.add((image: MemoryImage(bytes), name: file.name));
      }
      if (!mounted || !current()) return;
      final confirmed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => previews.length != pending.length
              ? GatewayAttachmentSelection(files: pending)
              : previews.length == 1
              ? GatewayImageSelection(image: previews.single.image, name: previews.single.name)
              : GatewayImagesSelection(images: previews),
        ),
      );
      if (!mounted || !current() || confirmed != true) return;
      if (attachments.length + pending.length > maxAttachments) {
        throw StateError(context.l10n.chatAttachmentLimit(maxAttachments));
      }
      setState(() => attachments.addAll(pending));
    } finally {
      pickingImages = false;
    }
  });
  Future<void> send() async {
    final text = input.text.trim();
    if (text.isEmpty && attachments.isEmpty) return;
    if (c.sending || c.syncing || c.syncFailed) return;
    final files = List<Map<String, dynamic>>.from(attachments);
    final host = c.address, token = c.token, session = c.sessionKey;
    final selection = c.selectionRevision;
    setState(() {
      input.clear();
      attachments.clear();
    });
    if (scroll.hasClients) scroll.jumpTo(0);
    await c.guard(() async {
      try {
        await c.send(text, queueMode: queue, attachments: files);
      } catch (_) {
        // Do not overwrite a newer draft or restore it onto another host/chat.
        if (mounted &&
            c.address == host &&
            c.token == token &&
            (session.isEmpty ? c.selectionRevision <= selection + 1 : c.sessionKey == session) &&
            input.text.isEmpty &&
            attachments.isEmpty) {
          setState(() {
            input.text = text;
            attachments.addAll(files);
          });
        }
        rethrow;
      }
    });
  }

  Future<void> hideKeyboard() async {
    composerFocus.unfocus();
    FocusManager.instance.primaryFocus?.unfocus();
    // A native IME can outlive Flutter focus (notably during iOS transitions).
    // Always request dismissal, even when the composer is already unfocused.
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }

  void switchHost() {
    showHostSheet(context, onManage: manageHosts);
  }

  void manageHosts() {
    Navigator.of(context).push(
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
    );
  }

  String get hostName =>
      Uri.tryParse(c.address)?.host.isNotEmpty == true ? Uri.parse(c.address).host : context.l10n.commonRemoteHost;

  void closeSidebar() {
    FocusManager.instance.primaryFocus?.unfocus();
    scaffoldKey.currentState?.closeDrawer();
  }

  Future<void> openGatewayWeb({BuildContext? from}) async {
    closeSidebar();
    if (c.sshId != null && !c.connected) {
      await c.connect(c.address, c.token);
      if (!mounted || (from != null && !from.mounted)) return;
      if (!c.connected) {
        ScaffoldMessenger.of(from ?? context)
            .showSnackBar(SnackBar(content: Text(c.error.isEmpty ? context.l10n.ocDisconnected : c.error)));
        return;
      }
    }
    final address = Uri.tryParse(c.transportAddress ?? c.address);
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
    Navigator.of(from ?? context).push(
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
                    running: c.connected && c.isSessionRunning(session),
                    runningSpinner: true,
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
    if (features) {
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (page) => GatewayFeaturesPage(
            controller: c,
            onSettings: () => openSettings(),
            onSearch: searchSessions,
            onModels: chooseModel,
            onHosts: manageHosts,
            onWeb: () => openGatewayWeb(from: page),
            onExport: () =>
                Navigator.of(page).push<void>(MaterialPageRoute(builder: (_) => GatewayExportPage(controller: c))),
          ),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (pageContext) {
          final l = pageContext.l10n;
          return AppPage.list(
            title: l.commonSettings,
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
                  SettingsTile(
                    icon: AppIcons.configure,
                    title: l.remoteManageHosts,
                    onTap: () {
                      Navigator.of(pageContext).pop();
                      manageHosts();
                    },
                  ),
                ],
              ),
              const RemoteAppearanceSettings(),
              SettingsSection(
                title: l.commonSettings,
                children: [
                  SettingsTile(icon: AppIcons.translate, title: l.ocEnglish, onTap: widget.onLanguage),
                  SettingsTile(
                    icon: AppIcons.info,
                    title: l.remoteAboutTitle,
                    onTap: () =>
                        Navigator.of(pageContext)
                            .push(MaterialPageRoute<void>(builder: (_) => const RemoteAboutPage())),
                  ),
                  SettingsTile(
                    icon: AppIcons.info,
                    title: l.ocLicenses,
                    onTap: () => showLicensePage(context: pageContext, applicationName: 'Cove-Go'),
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
            GatewayWorkspaceSwitcher(controller: c),
            DrawerViewButton(onTap: () => showGatewayWorkspaces(context, c)),
          ],
        ),
      ),
    ];
    DateTime? updatedAt(Map<String, dynamic> session) {
      final value = session['updatedAt'];
      if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
      return value is String ? DateTime.tryParse(value) : null;
    }

    final visible = List<Map<String, dynamic>>.of(
      c.scopedSessions,
    )..sort((a, b) => (updatedAt(b)?.millisecondsSinceEpoch ?? 0).compareTo(updatedAt(a)?.millisecondsSinceEpoch ?? 0));
    final groups = <String, List<Map<String, dynamic>>>{
      for (final name in c.sessionGroups)
        if (c.selectedGroup == null || c.selectedGroup == name) name: [],
    };
    for (final session in visible) {
      final category = session['category'];
      final name = category is String ? category : '';
      (groups[name] ??= []).add(session);
    }
    // Groups follow their newest conversation, not catalog/manual order.
    // Preserve catalog order only for ties (including empty groups).
    final catalogOrder = groups.keys.toList();
    int latest(List<Map<String, dynamic>> sessions) =>
        sessions.isEmpty ? -1 : updatedAt(sessions.first)?.millisecondsSinceEpoch ?? 0;
    final orderedGroups = groups.entries.toList()
      ..sort((a, b) {
        final byActivity = latest(b.value).compareTo(latest(a.value));
        return byActivity != 0 ? byActivity : catalogOrder.indexOf(a.key).compareTo(catalogOrder.indexOf(b.key));
      });
    final rows = <Widget>[
      if (visible.isEmpty) Padding(padding: const EdgeInsets.all(20), child: Text(l.remoteWorkspaceNoChats)),
      for (final group in orderedGroups) ...[
        DrawerEyebrow(group.key.isEmpty ? l.remoteWorkspaceUngrouped : group.key),
        for (final session in group.value)
          SessionTile(
            title: sessionTitle(session),
            running: c.connected && c.isSessionRunning(session),
            runningSpinner: true,
            current: session['key'] == c.sessionKey,
            onLongPress: c.connected && c.groupCatalogSupported
                ? () => showGatewayWorkspaces(context, c, moveKey: session['key'] as String)
                : null,
            onTap: () {
              closeSidebar();
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
    final images = gatewayImages(message);
    final files = gatewayFiles(message);
    if (text.isEmpty && images.isEmpty && files.isEmpty) return const SizedBox.shrink();
    final pictures = images.isEmpty && files.isEmpty
        ? null
        : Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final file in files)
                GatewayFileTile(
                  file: file,
                  onTap: () {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => GatewayReceivedFilePage(
                          scope: GatewayFeatureScope(c, session: c.sessionKey),
                          file: file,
                        ),
                      ),
                    );
                  },
                ),
              for (final image in images)
                GatewayImage(
                  block: image,
                  client: c.client,
                  sessionKey: c.sessionKey,
                  address: c.transportAddress ?? c.address,
                  token: c.token,
                ),
            ],
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: user
          ? UserBubble(text: text, attachments: pictures)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ?pictures,
                if (text.isNotEmpty) MarkdownBody(text: text),
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

  List<Widget> messageRows() {
    final rows = <Widget>[];
    var tools = <GatewayToolEntry>[];
    void flushTools() {
      if (tools.isEmpty) return;
      rows.add(GatewayToolActivity(entries: tools));
      tools = [];
    }

    for (final message in c.visibleMessages) {
      final role = message['role'];
      final text = messageText(message);
      if (role == 'toolResult' || role == 'tool') {
        tools.add(
          GatewayToolEntry(
            name: '${message['toolName'] ?? message['name'] ?? context.l10n.ocTools}',
            details: text.isEmpty ? c.toolText(message) : text,
          ),
        );
      } else if (text.isNotEmpty || gatewayImages(message).isNotEmpty || gatewayFiles(message).isNotEmpty) {
        flushTools();
        rows.add(bubble(message));
      }
      // Tool-call-only assistant envelopes have no visible body and do not
      // split an otherwise consecutive block of tool results.
    }
    flushTools();
    return rows;
  }

  Widget header(bool wide) {
    final l = context.l10n;
    final session = c.sessions.where((s) => s['key'] == c.sessionKey).firstOrNull;
    final model = session?['model'] ?? session?['modelOverride'];
    return ChatHeader(
      useDshState: false,
      title: session == null ? 'Cove-Go' : sessionTitle(session),
      status: HeaderStatus(
        c.syncFailed
            ? StatusTone.warn
            : c.syncing
            ? StatusTone.busy
            : c.connected
            ? StatusTone.ok
            : StatusTone.idle,
        c.syncFailed
            ? l.ocSyncFailed
            : c.syncing
            ? l.stateChatSynchronizing
            : c.connected
            ? l.ocConnected
            : l.ocDisconnected,
      ),
      onOpenDrawer: wide
          ? null
          : () {
              composerFocus.unfocus();
              scaffoldKey.currentState?.openDrawer();
            },
      onTitleTap: c.sessionKey.isEmpty
          ? switchHost
          : () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => GatewaySessionDetailsPage(scope: GatewayFeatureScope(c, session: c.sessionKey)),
              ),
            ),
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
            TextFieldTapRegion(
              // Let the button finish its tap before dismissing the keyboard.
              child: GlassIconButton(
                icon: Icons.keyboard_hide_outlined,
                tooltip: l.ocHideKeyboard,
                onPressed: hideKeyboard,
              ),
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
    final host = c.address, token = c.token, session = c.sessionKey, revision = c.selectionRevision;
    final selected = await showGatewayModelSheet(context, c);
    if (selected != null &&
        mounted &&
        c.address == host &&
        c.token == token &&
        c.sessionKey == session &&
        c.selectionRevision == revision) {
      await c.guard(() => c.model(selected));
    }
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
              child: RemoteMascotStage(
                pet: RemoteMascot.lobster,
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
                        actions: [
                          TextButton(onPressed: () => c.connect(c.address, c.token), child: Text(l.ocReconnect)),
                        ],
                      ),
                    Expanded(
                      child: c.sessionKey.isEmpty && c.visibleMessages.isEmpty
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
                              onRefresh: () => c.guard(c.resync),
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
                                  ...messageRows(),
                                  if (c.tools.isNotEmpty)
                                    GatewayToolActivity(
                                      entries: [
                                        for (final tool in c.tools.values)
                                          GatewayToolEntry(
                                            name: '${tool['name'] ?? l.ocTools}',
                                            details: c.toolText(tool),
                                          ),
                                      ],
                                    ),
                                  for (final text in c.live.values) bubble({'role': 'assistant', 'content': text}),
                                ].reversed.toList(),
                              ),
                            ),
                    ),
                    if (c.syncing || c.syncFailed)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: Card(
                          color: Theme.of(context).colorScheme.secondaryContainer,
                          child: ListTile(
                            key: const ValueKey('gateway-sync-status'),
                            leading: const Icon(Icons.info_outline),
                            title: Text(c.syncFailed ? l.ocSyncFailed : l.stateChatSynchronizing),
                            trailing: TextButton(
                              key: const ValueKey('gateway-sync-retry'),
                              onPressed: c.resyncing || !c.connected ? null : () => c.guard(c.resync),
                              child: Text(l.ocResync),
                            ),
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
                            returnKeySends: ref.watch(settingsProvider.select((s) => s.returnKeySends)),
                            focusNode: composerFocus,
                            connected: c.connected && !c.syncing && !c.syncFailed,
                            running: c.live.isNotEmpty,
                            busy: c.sending,
                            placeholder: c.syncing ? l.stateChatSynchronizing : l.ocHint,
                            maxLines: Composer.linesFor(context),
                            onSend: send,
                            onStop: () => c.guard(c.abort),
                            onSendOptions: sendOptions,
                            accessory: IconButton(
                              // Match the composer's 40dp text and send-key row.
                              style: IconButton.styleFrom(
                                minimumSize: const Size(40, 40),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              tooltip: l.ocQueue,
                              onPressed: sendOptions,
                              icon: const Icon(AppIcons.queued, size: 20),
                            ),
                            hasAttachments: attachments.isNotEmpty,
                            leading: IconButton(
                              // Match the composer's 40dp text and send-key row.
                              style: IconButton.styleFrom(
                                minimumSize: const Size(40, 40),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              tooltip: l.ocAttach,
                              onPressed: c.connected ? attach : null,
                              icon: const Icon(AppIcons.add),
                            ),
                            tray: attachments.isEmpty
                                ? null
                                : Wrap(
                                    children: [
                                      for (var i = 0; i < attachments.length; i++)
                                        Stack(
                                          children: [
                                            Padding(
                                              padding: const EdgeInsets.all(4),
                                              child: attachments[i]['type'] != 'image'
                                                  ? GatewayFileTile(file: attachments[i])
                                                  : GatewayImage(
                                                      block: {
                                                        'type': 'image',
                                                        'fileName': attachments[i]['fileName'],
                                                        'data': attachments[i]['content'],
                                                      },
                                                      client: c.client,
                                                      sessionKey: c.sessionKey,
                                                      size: 72,
                                                    ),
                                            ),
                                            Positioned(
                                              right: 0,
                                              top: 0,
                                              child: IconButton.filledTonal(
                                                tooltip: l.ocRemove,
                                                onPressed: () => setState(() => attachments.removeAt(i)),
                                                icon: const Icon(AppIcons.close, size: 16),
                                                style: IconButton.styleFrom(
                                                  minimumSize: const Size(28, 28),
                                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                  padding: EdgeInsets.zero,
                                                ),
                                              ),
                                            ),
                                          ],
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
            ),
          ],
        ),
      ),
    );
  }
}
