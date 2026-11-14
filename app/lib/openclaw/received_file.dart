import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/l10n.dart';
import '../state/attachments.dart' show formatBytes;
import '../ui/shell/page_frame.dart';
import 'feature_data.dart';

String gatewayReceivedName(Map file) {
  final name = '${file['fileName'] ?? file['label'] ?? 'attachment'}'
      .split(RegExp(r'[/\\]'))
      .last
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '_');
  return name.isEmpty || name == '.' || name == '..' ? 'attachment' : name;
}

/// Only fresh, authenticated artifact download routes on the configured origin.
/// Never follow redirects, use arbitrary history URLs or expose bearer tickets.
Uri? gatewayDownloadUri(String address, Object? value) {
  if (value is! String || value.startsWith('//')) return null;
  final base = Uri.tryParse(address), ref = Uri.tryParse(value);
  if (base == null || ref == null || !['ws', 'wss'].contains(base.scheme) || base.host.isEmpty) return null;
  final origin = base.replace(scheme: base.scheme == 'wss' ? 'https' : 'http', query: null, fragment: null);
  if (origin.scheme == 'http' && !['127.0.0.1', '::1', 'localhost'].contains(origin.host)) return null;
  final prefix = origin.path.replaceFirst(RegExp(r'/+$'), '');
  Uri uri;
  if (ref.hasScheme) {
    uri = ref;
  } else {
    if (!value.startsWith('/')) return null;
    uri = origin.replace(path: prefix + ref.path, query: ref.hasQuery ? ref.query : null);
  }
  if (uri.scheme != origin.scheme ||
      uri.host != origin.host ||
      uri.port != origin.port ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    return null;
  }
  final path = uri.path.startsWith(prefix) ? uri.path.substring(prefix.length) : '';
  if (!RegExp(r'^/api/(?:chat/media/outgoing/[^/]+/[0-9a-fA-F-]{36}/full|artifacts/download/[^/]+/[^/]+)$')
      .hasMatch(path)) {
    return null;
  }
  return uri;
}

Future<File> downloadGatewayFile(
  GatewayFeatureScope scope,
  Map file,
  Directory directory, {
  int maxBytes = 100 * 1024 * 1024,
}) async {
  void current() {
    if (!scope.current) throw StateError('retired');
  }

  current();
  if (file['sizeBytes'] is num && file['sizeBytes'] > maxBytes) throw StateError('limit');
  final id = file['artifactId'];
  if (id is! String || id.isEmpty) throw StateError('unsupported');
  final c = scope.controller, address = c.transportAddress ?? c.address, token = c.token;
  final result = await scope.read('artifacts.download', {
    'sessionKey': scope.session,
    'artifactId': id,
    'transport': 'http',
  });
  current();
  if (result is! Map) throw StateError('invalid');
  final output = File('${directory.path}/${gatewayReceivedName(file)}');
  final sink = output.openWrite();
  var size = 0, success = false;
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    void add(List<int> bytes) {
      current();
      if (bytes.length > maxBytes - size) throw StateError('limit');
      size += bytes.length;
      sink.add(bytes);
    }

    if (result['encoding'] == 'base64' && result['data'] is String) {
      final data = result['data'] as String;
      if (data.length > ((maxBytes + 2) ~/ 3) * 4) throw StateError('limit');
      add(base64Decode(data));
    } else {
      final uri = gatewayDownloadUri(address, result['url']);
      if (uri == null) throw StateError('unsupported');
      final request = await http.getUrl(uri).timeout(const Duration(seconds: 15));
      current();
      request.followRedirects = false;
      if (token.isNotEmpty) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200 || response.contentLength > maxBytes) throw StateError('download');
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        add(chunk);
      }
    }
    await sink.flush();
    current();
    if (size == 0) throw StateError('empty');
    if (file['sizeBytes'] is num && file['sizeBytes'] > 0 && size != file['sizeBytes']) throw StateError('incomplete');
    success = true;
    return output;
  } finally {
    http.close(force: true);
    await sink.close();
    if (!success && await output.exists()) await output.delete();
  }
}

class GatewayReceivedFilePage extends StatefulWidget {
  const GatewayReceivedFilePage({super.key, required this.scope, required this.file});
  final GatewayFeatureScope scope;
  final Map file;
  @override
  State<GatewayReceivedFilePage> createState() => _GatewayReceivedFilePageState();
}

class _GatewayReceivedFilePageState extends State<GatewayReceivedFilePage> {
  File? file;
  bool busy = false, failed = false;
  @override
  void initState() {
    super.initState();
    widget.scope.controller.addListener(changed);
  }

  void changed() {
    if (mounted) {
      setState(() {
        if (!widget.scope.current) file = null;
      });
    }
  }

  @override
  void dispose() {
    widget.scope.controller.removeListener(changed);
    super.dispose();
  }

  Future<void> download() async {
    if (busy || !widget.scope.current) return;
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      // Isolated temp directory avoids clobbering another chat's same-named file.
      final directory = await (await getTemporaryDirectory()).createTemp('cove-download-');
      final result = await downloadGatewayFile(widget.scope, widget.file, directory);
      if (mounted && widget.scope.current) setState(() => file = result);
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (busy || file == null || !widget.scope.current) return;
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file!.path, mimeType: '${widget.file['mimeType'] ?? 'application/octet-stream'}')],
          fileNameOverrides: [gatewayReceivedName(widget.file)],
          sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AppPage.list(
      title: gatewayReceivedName(widget.file),
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            '${widget.file['mimeType'] ?? 'application/octet-stream'}${widget.file['sizeBytes'] is int ? ' · ${formatBytes(widget.file['sizeBytes'] as int)}' : ''}',
          ),
        ),
        if (!widget.scope.current)
          Padding(padding: const EdgeInsets.all(20), child: Text(l.ocFeatureScopeChanged))
        else ...[
          Padding(padding: const EdgeInsets.all(20), child: Text(l.ocReceivedFileNote)),
          if (failed) Padding(padding: const EdgeInsets.all(20), child: Text(l.ocReceivedFileFailed)),
          if (busy) const Center(child: CircularProgressIndicator()),
          Padding(
            padding: const EdgeInsets.all(20),
            child: FilledButton.icon(
              key: const ValueKey('received-file-download'),
              icon: const Icon(Icons.download),
              onPressed: busy ? null : download,
              label: Text(l.ocFeatureLoadArtifact),
            ),
          ),
          if (file != null)
            Padding(
              padding: const EdgeInsets.all(20),
              child: FilledButton.icon(
                key: const ValueKey('received-file-save'),
                icon: const Icon(Icons.ios_share),
                onPressed: busy ? null : save,
                label: Text(l.ocReceivedFileSave),
              ),
            ),
        ],
      ],
    );
  }
}
