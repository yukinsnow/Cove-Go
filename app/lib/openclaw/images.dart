import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:openclaw_client/openclaw_client.dart';

import '../l10n/l10n.dart';
import 'image_blocks.dart';
import '../ui/chat/artifact_preview.dart' show ImageViewerPage;
import '../ui/common/display_image.dart';
import '../ui/theme/app_icons.dart';

export 'image_blocks.dart';

/// Only send the Gateway credential to the exact configured origin. Never
/// follow redirects with it or infer filesystem URLs from private paths.
Future<ImageProvider?> loadGatewayImage(
  Map block,
  GatewayClient client,
  String sessionKey, {
  String? address,
  String token = '',
}) async {
  const maxBytes = 12 * 1024 * 1024;
  final source = block['source'];
  final data = block['data'] ?? (source is Map ? source['data'] : null);
  if (data is String && data.isNotEmpty) return MemoryImage(base64Decode(data));
  dynamic value;
  final reference = gatewayImageReference(block);
  final managed = reference == null
      ? null
      : RegExp(r'^/api/chat/media/outgoing/[^/]+/([0-9a-fA-F-]{36})/(?:full|thumbnail)$').firstMatch(reference);
  final artifact = block['artifactId'] ?? (managed == null ? null : 'artifact_managed_image_${managed[1]}');
  if (artifact is String && artifact.isNotEmpty) {
    final result = await client.request('artifacts.download', {'sessionKey': sessionKey, 'artifactId': artifact});
    if (result is Map) {
      if (result['encoding'] == 'base64' && result['data'] is String) {
        return MemoryImage(base64Decode(result['data'] as String));
      }
      value = result['url'];
    }
  }
  final imageUrl = block['image_url'];
  value ??= block['url'] ?? (imageUrl is Map ? imageUrl['url'] : imageUrl) ?? (source is Map ? source['url'] : source);
  if (value is! String || value.isEmpty) return null;
  if (value.startsWith('data:image/')) return MemoryImage(UriData.parse(value).contentAsBytes());
  var uri = Uri.tryParse(value);
  final gateway = address == null ? null : Uri.tryParse(address);
  final origin = gateway != null && ['ws', 'wss'].contains(gateway.scheme) && gateway.host.isNotEmpty
      ? gateway.replace(scheme: gateway.scheme == 'wss' ? 'https' : 'http', query: null, fragment: null)
      : null;
  if (uri?.scheme == 'media' && uri?.host == 'inbound' && origin != null) {
    uri = origin.replace(
      path: '${origin.path.replaceFirst(RegExp(r'/+$'), '')}/__openclaw__/assistant-media',
      queryParameters: {'source': value, 'sessionKey': sessionKey},
    );
  } else if (uri != null && !uri.hasScheme && origin != null && value.startsWith('/') && !value.startsWith('//')) {
    final base = origin.path.replaceFirst(RegExp(r'/+$'), '');
    uri = origin.replace(path: base + uri.path, query: uri.hasQuery ? uri.query : null);
  }
  if (uri == null || !['https', 'http'].contains(uri.scheme) || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    return null;
  }
  final sameOrigin =
      origin != null && uri.scheme == origin.scheme && uri.host == origin.host && uri.port == origin.port;
  if (!sameOrigin) return NetworkImage(uri.toString());
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await http.getUrl(uri).timeout(const Duration(seconds: 15));
    request.followRedirects = false;
    if (token.isNotEmpty) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != 200 || response.contentLength > maxBytes) return null;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      if (bytes.length + chunk.length > maxBytes) return null;
      bytes.add(chunk);
    }
    return MemoryImage(bytes.takeBytes());
  } finally {
    http.close(force: true);
  }
}

class GatewayImage extends StatefulWidget {
  const GatewayImage({
    super.key,
    required this.block,
    required this.client,
    required this.sessionKey,
    this.size = 144,
    this.address,
    this.token = '',
  });
  final Map block;
  final GatewayClient client;
  final String sessionKey;
  final double size;
  final String? address;
  final String token;

  @override
  State<GatewayImage> createState() => _GatewayImageState();
}

class _GatewayImageState extends State<GatewayImage> {
  late Future<ImageProvider?> _image;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(GatewayImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.block != widget.block ||
        oldWidget.client != widget.client ||
        oldWidget.sessionKey != widget.sessionKey ||
        oldWidget.address != widget.address ||
        oldWidget.token != widget.token) {
      _load();
    }
  }

  void _load() => _image = loadGatewayImage(
    widget.block,
    widget.client,
    widget.sessionKey,
    address: widget.address,
    token: widget.token,
  );

  @override
  Widget build(BuildContext context) {
    final title = '${widget.block['fileName'] ?? context.l10n.ocAttach}';
    return SizedBox.square(
      dimension: widget.size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: FutureBuilder<ImageProvider?>(
            future: _image,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final image = snapshot.data;
              if (image == null) {
                return IconButton(
                  tooltip: context.l10n.ocRefresh,
                  onPressed: () => setState(_load),
                  icon: const Icon(AppIcons.image),
                );
              }
              return Semantics(
                label: title,
                button: true,
                image: true,
                child: GestureDetector(
                  onTap: () => Navigator.of(context).push(ImageViewerPage.route(title: title, image: image)),
                  child: Image(
                    image: imageForDisplay(
                      image,
                      width: widget.size,
                      height: widget.size,
                      pixelRatio: MediaQuery.devicePixelRatioOf(context),
                    ),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Center(child: Icon(AppIcons.image)),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Picking an image first opens a zoomable confirmation, not an immediate upload.
class GatewayImageSelection extends StatelessWidget {
  const GatewayImageSelection({super.key, required this.image, required this.name});
  final ImageProvider image;
  final String name;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      ImageViewerPage(title: name, image: image),
      Positioned(
        left: 24,
        right: 24,
        bottom: 16,
        child: SafeArea(
          top: false,
          child: FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(AppIcons.done),
            label: Text(context.l10n.ocAttach),
          ),
        ),
      ),
    ],
  );
}

/// Confirm a batch together; tap any thumbnail for the existing zoom viewer.
class GatewayImagesSelection extends StatelessWidget {
  const GatewayImagesSelection({super.key, required this.images});
  final List<({ImageProvider image, String name})> images;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.ocSelectMultipleImages)),
    body: GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: images.length,
      itemBuilder: (ctx, index) => InkWell(
        key: ValueKey('gateway-image-preview-$index'),
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => ImageViewerPage(title: images[index].name, image: images[index].image),
          ),
        ),
        child: Semantics(
          label: images[index].name,
          button: true,
          child: Image(image: images[index].image, fit: BoxFit.cover),
        ),
      ),
    ),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(true),
          icon: const Icon(AppIcons.done),
          label: Text(context.l10n.ocAttachSelectedImages(images.length)),
        ),
      ),
    ),
  );
}
