import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/l10n.dart';
import '../ui/common/list_page_row.dart';
import '../ui/shell/page_frame.dart';
import '../ui/theme/app_icons.dart';
import 'feature_data.dart';

class GatewayArtifactPage extends StatefulWidget {
  const GatewayArtifactPage({super.key, required this.scope, required this.artifact});
  final GatewayFeatureScope scope;
  final Map artifact;
  @override
  State<GatewayArtifactPage> createState() => _GatewayArtifactPageState();
}

class _GatewayArtifactPageState extends State<GatewayArtifactPage> {
  Uint8List? bytes;
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    widget.scope.controller.addListener(changed);
  }

  void changed() {
    if (!widget.scope.current) bytes = null;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.scope.controller.removeListener(changed);
    super.dispose();
  }

  String get mime => '${widget.artifact['mimeType'] ?? 'application/octet-stream'}';
  String get name => '${widget.artifact['title'] ?? widget.artifact['id']}'.split(RegExp(r'[/\\]')).last;
  Future<void> download() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.scope.read('artifacts.download', {
        'sessionKey': widget.scope.session,
        'artifactId': widget.artifact['id'],
        'messageRole': 'assistant',
      });
      if (!mounted || !widget.scope.current) return;
      // Do not fetch returned arbitrary URLs, follow redirects or forward the
      // Gateway credential to another origin. Native supports bounded bytes.
      if (result is! Map || result['encoding'] != 'base64' || result['data'] is! String) {
        throw StateError(context.l10n.ocFeaturePreviewUnavailable);
      }
      final data = result['data'] as String;
      if (data.length > 28 * 1024 * 1024) throw StateError(context.l10n.ocFeaturePreviewUnavailable);
      final decoded = base64Decode(data);
      if (decoded.length > 20 * 1024 * 1024) throw StateError(context.l10n.ocFeaturePreviewUnavailable);
      setState(() => bytes = decoded);
    } catch (e) {
      if (mounted) setState(() => error = safeFeatureError(e, widget.scope.controller));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> share() async {
    if (!widget.scope.current || bytes == null || busy) return;
    setState(() => busy = true);
    try {
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes!, mimeType: mime, name: name)],
          fileNameOverrides: [name],
          sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = safeFeatureError(e, widget.scope.controller));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.scope.current;
    final data = bytes;
    return AppPage.list(
      title: name,
      children: [
        Padding(padding: const EdgeInsets.all(20), child: Text('$mime · ${widget.artifact['sizeBytes'] ?? '?'} B')),
        if (!current)
          Padding(padding: const EdgeInsets.all(20), child: Text(context.l10n.ocFeatureScopeChanged))
        else ...[
          Padding(padding: const EdgeInsets.all(20), child: Text(context.l10n.ocFeatureArtifactDownloadNote)),
          if (error != null) Padding(padding: const EdgeInsets.all(20), child: Text(error!)),
          ListPageRow(
            icon: AppIcons.files,
            title: context.l10n.ocFeatureLoadArtifact,
            onTap: busy || (widget.artifact['download'] as Map?)?['mode'] != 'bytes' ? null : download,
          ),
          if (busy) const Center(child: CircularProgressIndicator()),
          if (data != null) ...[
            if (mime.startsWith('image/'))
              Image.memory(data, errorBuilder: (_, _, _) => Text(context.l10n.ocFeaturePreviewUnavailable))
            else if (mime.startsWith('text/') || mime == 'application/json')
              Padding(
                padding: const EdgeInsets.all(20),
                child: SelectableText(utf8.decode(data, allowMalformed: true)),
              ),
            ListPageRow(icon: AppIcons.share, title: context.l10n.ocFeatureShareArtifact, onTap: busy ? null : share),
          ],
        ],
      ],
    );
  }
}
