import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:openclaw_client/openclaw_client.dart';

import '../l10n/l10n.dart';
import '../ui/theme/glass.dart';
import '../ui/common/glass_pill.dart';
import 'controller.dart';

class ClawHome extends StatefulWidget {
  const ClawHome({super.key, required this.onLanguage});
  final VoidCallback onLanguage;
  @override
  State<ClawHome> createState() => _ClawHomeState();
}

class _ClawHomeState extends State<ClawHome> with WidgetsBindingObserver {
  final c = ClawController();
  final input = TextEditingController(), scroll = ScrollController();
  final attachments = <Map<String, dynamic>>[];
  String queue = 'followup';
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

  Widget sessionList() {
    final l = context.l10n;
    return Column(
      children: [
        ListTile(
          title: Text(l.ocSessions),
          trailing: IconButton(
            tooltip: l.ocRefresh,
            onPressed: c.connected ? () => c.guard(c.refreshSessions) : null,
            icon: const Icon(Icons.refresh),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.add),
          title: Text(l.ocNew),
          onTap: c.connected ? () => c.guard(c.newSession) : null,
        ),
        Expanded(
          child: ListView(
            children: [
              for (final s in c.sessions)
                ListTile(
                  selected: s['key'] == c.sessionKey,
                  leading: Icon(s['hasActiveRun'] == true ? Icons.play_circle_outline : Icons.chat_bubble_outline),
                  title: Text(
                    '${s['displayName'] ?? s['label'] ?? s['key']}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => c.guard(() => c.select(s['key'] as String)),
                ),
            ],
          ),
        ),
        ListTile(leading: const Icon(Icons.settings_outlined), title: Text(l.ocSettings), onTap: settings),
        ListTile(
          leading: const Icon(Icons.description_outlined),
          title: Text(l.ocLicenses),
          onTap: () => showLicensePage(context: context, applicationName: 'OpenClaw Go'),
        ),
        ListTile(leading: const Icon(Icons.language), title: Text(l.ocEnglish), onTap: widget.onLanguage),
      ],
    );
  }

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
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 780),
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: GlassSurface(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(user ? 'You' : 'OpenClaw', style: Theme.of(context).textTheme.labelMedium),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: context.l10n.ocCopy,
                    onPressed: () => Clipboard.setData(ClipboardData(text: text)),
                    icon: const Icon(Icons.copy, size: 15),
                  ),
                ],
              ),
              SelectionArea(child: GptMarkdown(text)),
            ],
          ),
        ),
      ),
    );
  }

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
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('OpenClaw Go'),
            Text(c.connected ? l.ocConnected : l.ocDisconnected, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
        actions: [
          IconButton(
            tooltip: l.ocModels,
            onPressed: c.connected && c.sessionKey.isNotEmpty ? chooseModel : null,
            icon: const Icon(Icons.tune),
          ),
          IconButton(tooltip: l.ocSettings, onPressed: c.busy ? null : settings, icon: const Icon(Icons.link)),
        ],
      ),
      drawer: wide ? null : Drawer(child: SafeArea(child: sessionList())),
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
                        )
                      : RefreshIndicator(
                          onRefresh: () => c.guard(c.history),
                          child: ListView(
                            controller: scroll,
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
                    child: GlassSurface(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (attachments.isNotEmpty)
                            Wrap(
                              children: [
                                for (var i = 0; i < attachments.length; i++)
                                  InputChip(
                                    label: Text('${attachments[i]['fileName']}'),
                                    onDeleted: () => setState(() => attachments.removeAt(i)),
                                  ),
                              ],
                            ),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              IconButton(
                                tooltip: l.ocAttach,
                                onPressed: c.connected ? attach : null,
                                icon: const Icon(Icons.add_photo_alternate_outlined),
                              ),
                              Expanded(
                                child: TextField(
                                  controller: input,
                                  minLines: 1,
                                  maxLines: 6,
                                  enabled: c.connected,
                                  decoration: InputDecoration(hintText: l.ocHint, border: InputBorder.none),
                                ),
                              ),
                              IconButton(
                                tooltip: l.ocStop,
                                onPressed: c.connected && c.sessionKey.isNotEmpty ? () => c.guard(c.abort) : null,
                                icon: const Icon(Icons.stop_circle_outlined),
                              ),
                              IconButton.filled(
                                tooltip: l.ocSend,
                                onPressed: c.connected && !c.sending ? send : null,
                                icon: const Icon(Icons.arrow_upward),
                              ),
                            ],
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: DropdownButton<String>(
                              value: queue,
                              isDense: true,
                              underline: const SizedBox.shrink(),
                              items: [
                                DropdownMenuItem(value: 'followup', child: Text(l.ocQueue)),
                                DropdownMenuItem(value: 'steer', child: Text(l.ocSteer)),
                                DropdownMenuItem(value: 'interrupt', child: Text(l.ocInterrupt)),
                              ],
                              onChanged: (v) => setState(() => queue = v!),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
