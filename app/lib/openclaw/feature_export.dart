import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/l10n.dart';
import '../ui/shell/page_frame.dart';
import 'controller.dart';
import 'feature_data.dart';

/// Export only the server's returned display history, never a credential dump.
/// Native share is a separate, deliberate user action after reading the note.
class GatewayExportPage extends StatefulWidget {
  const GatewayExportPage({super.key, required this.controller});
  final ClawController controller;
  @override
  State<GatewayExportPage> createState() => _GatewayExportPageState();
}

class _GatewayExportPageState extends State<GatewayExportPage> {
  late final GatewayFeatureScope scope;
  @override
  void initState() {
    super.initState();
    scope = GatewayFeatureScope(widget.controller, session: widget.controller.sessionKey);
  }

  bool busy = false;
  String? error;
  Future<void> share() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await scope.read('chat.history', {'sessionKey': scope.session, 'limit': 150});
      if (!mounted || !scope.current) return;
      final bytes = utf8.encode(
        const JsonEncoder.withIndent('  ').convert({
          'format': 'cove-go-display-history-v1',
          'sessionKey': scope.session,
          'exportedAt': DateTime.now().toUtc().toIso8601String(),
          'note': 'Gateway display history; may be truncated, not a full transcript backup.',
          'history': data,
        }),
      );
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, mimeType: 'application/json', name: 'Cove-Go-chat.json')],
          fileNameOverrides: ['Cove-Go-chat.json'],
          sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = safeFeatureError(e, widget.controller));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AppPage.list(
    title: context.l10n.catalogExport,
    children: [
      Padding(padding: const EdgeInsets.all(20), child: Text(context.l10n.ocFeatureExportNote)),
      if (error != null) Padding(padding: const EdgeInsets.all(20), child: Text(error!)),
      Padding(
        padding: const EdgeInsets.all(20),
        child: FilledButton(
          onPressed: busy ? null : share,
          child: busy ? const CircularProgressIndicator() : Text(context.l10n.ocFeatureExportAction),
        ),
      ),
    ],
  );
}
