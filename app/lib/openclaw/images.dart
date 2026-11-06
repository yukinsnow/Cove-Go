import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:openclaw_client/openclaw_client.dart';

import '../l10n/l10n.dart';
import '../ui/chat/artifact_preview.dart' show ImageViewerPage;
import '../ui/common/display_image.dart';
import '../ui/theme/app_icons.dart';

/// History can omit image bytes and expose an artifact reference instead.
List<Map> gatewayImages(Map message) {
  final content = message['content'];
  return [
    if (content is List)
      for (final block in content.whereType<Map>())
        if (block['type'] == 'image' || block['type'] == 'image_url') block,
  ];
}

ImageProvider? _imageUrl(dynamic value) {
  if (value is! String || value.isEmpty) return null;
  if (value.startsWith('data:image/')) {
    return MemoryImage(UriData.parse(value).contentAsBytes());
  }
  final uri = Uri.tryParse(value);
  if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && uri.host.isNotEmpty) {
    return NetworkImage(value);
  }
  return null;
}

Future<ImageProvider?> _loadImage(Map block, GatewayClient client, String sessionKey) async {
  final source = block['source'];
  final data = block['data'] ?? (source is Map ? source['data'] : null);
  if (data is String && data.isNotEmpty) return MemoryImage(base64Decode(data));
  final artifact = block['artifactId'];
  if (artifact is String && artifact.isNotEmpty) {
    final result = await client.request('artifacts.download', {'sessionKey': sessionKey, 'artifactId': artifact});
    if (result is Map) {
      if (result['encoding'] == 'base64' && result['data'] is String) {
        return MemoryImage(base64Decode(result['data'] as String));
      }
      return _imageUrl(result['url']);
    }
  }
  final imageUrl = block['image_url'];
  return _imageUrl(
    block['url'] ?? (imageUrl is Map ? imageUrl['url'] : imageUrl) ?? (source is Map ? source['url'] : null),
  );
}

class GatewayImage extends StatefulWidget {
  const GatewayImage({super.key, required this.block, required this.client, required this.sessionKey, this.size = 144});
  final Map block;
  final GatewayClient client;
  final String sessionKey;
  final double size;

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
        oldWidget.sessionKey != widget.sessionKey) {
      _load();
    }
  }

  void _load() => _image = _loadImage(widget.block, widget.client, widget.sessionKey);

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
