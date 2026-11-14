import 'dart:convert';

String? gatewayImageReference(Map block) {
  final source = block['source'], imageUrl = block['image_url'];
  final value =
      block['url'] ?? (imageUrl is Map ? imageUrl['url'] : imageUrl) ?? (source is Map ? source['url'] : source);
  return value is String ? value : null;
}

bool gatewayImageUsable(Map block) {
  final source = block['source'];
  return gatewayImageReference(block) != null ||
      block['artifactId'] is String ||
      block['data'] is String ||
      (source is Map && source['data'] is String);
}

/// History can omit image bytes and expose an artifact reference instead.
List<Map> gatewayImages(Map message) {
  final content = message['openclawDisplayContent'] ?? message['content'];
  final metadata = message['__openclaw'];
  final facts = metadata is Map ? metadata['media'] : null;
  final images = <Map>[
    if (content is List)
      for (final block in content.whereType<Map>())
        if (block['type'] == 'image' || block['type'] == 'image_url')
          block
        else if (block['type'] == 'attachment' && block['attachment'] is Map)
          if ('${(block['attachment'] as Map)['mimeType']}'.startsWith('image/'))
            {...block['attachment'] as Map, 'type': 'image', 'fileName': (block['attachment'] as Map)['label']},
    if (facts is List)
      for (final fact in facts.whereType<Map>())
        if (fact['kind'] == 'image' ||
            fact['kind'] == 'sticker' ||
            '${fact['contentType']}'.startsWith('image/') ||
            RegExp(
              r'\.(?:png|jpe?g|gif|webp|heic)(?:[?#]|$)',
              caseSensitive: false,
            ).hasMatch('${fact['path'] ?? fact['url'] ?? fact['fileName']}'))
          {...fact, 'type': 'image', 'url': fact['path'] ?? fact['url']},
    // Display-only bytes retained when a Gateway history row omits its image.
    if (message['_localImages'] is List) ...(message['_localImages'] as List).whereType<Map>(),
  ];
  final seen = <String>{};
  final usable = images.any(gatewayImageUsable);
  return images
      .where((block) => !usable || gatewayImageUsable(block))
      .where((block) => seen.add('${block['artifactId'] ?? gatewayImageReference(block) ?? jsonEncode(block)}'))
      .toList();
}

/// Non-image history facts contain metadata, never interpreted as image bytes.
List<Map> gatewayFiles(Map message) {
  final content = message['openclawDisplayContent'] ?? message['content'];
  final metadata = message['__openclaw'];
  final facts = metadata is Map ? metadata['media'] : null;
  final seen = <String>{};
  return [
        if (content is List)
          for (final block in content.whereType<Map>())
            if (['file', 'video', 'audio', 'document'].contains(block['type']))
              block
            else if (block['type'] == 'attachment' && block['attachment'] is Map)
              if (!'${(block['attachment'] as Map)['mimeType']}'.startsWith('image/'))
                {...block['attachment'] as Map, 'fileName': (block['attachment'] as Map)['label']},
        if (facts is List)
          for (final fact in facts.whereType<Map>())
            if (['file', 'video', 'audio', 'document'].contains(fact['kind']) ||
                (fact['contentType'] is String && !'${fact['contentType']}'.startsWith('image/')))
              {...fact, 'mimeType': fact['contentType']},
        if (message['_localFiles'] is List) ...(message['_localFiles'] as List).whereType<Map>(),
      ]
      .where((f) => seen.add('${f['artifactId'] ?? f['url'] ?? f['path'] ?? '${f['fileName']}:${f['sizeBytes']}'}'))
      .toList();
}
