import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';

import '../l10n/l10n.dart';
import '../state/attachments.dart' show formatBytes;
import '../ui/theme/app_icons.dart';

/// Keep file contents on disk until the bounded reader admits them.
final gatewayFilePickerProvider = Provider<Future<List<XFile>> Function(int limit)>((ref) {
  return (_) async => [for (final file in await FilePicker.pickFiles()) file.xFile];
});

final gatewayCameraPickerProvider = Provider<Future<List<XFile>> Function(int limit)>((ref) {
  return (_) async => [
    ?await ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85,
      requestFullMetadata: false,
    ),
  ];
});

Future<Uint8List> readGatewayAttachment(XFile file, int limit) async {
  if (await file.length() > limit) throw StateError(appL10n.ocAttachmentTooLarge(file.name, formatBytes(limit)));
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in file.openRead()) {
    if (chunk.length > limit - bytes.length) {
      throw StateError(appL10n.ocAttachmentTooLarge(file.name, formatBytes(limit)));
    }
    bytes.add(chunk);
  }
  if (bytes.isEmpty) throw StateError(appL10n.stateAttachmentEmpty(file.name));
  return bytes.takeBytes();
}

String gatewayAttachmentMime(XFile file, Uint8List bytes) =>
    lookupMimeType(file.name, headerBytes: bytes.take(32).toList()) ?? file.mimeType ?? 'application/octet-stream';

class GatewayFileTile extends StatelessWidget {
  const GatewayFileTile({super.key, required this.file, this.onTap});
  final Map file;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 220,
    child: Material(
      color: Colors.transparent,
      child: ListTile(
        onTap: onTap,
        trailing: onTap == null ? null : const Icon(Icons.download_outlined),
        leading: Icon('${file['mimeType']}'.startsWith('video/') ? AppIcons.videoFile : AppIcons.files),
        title: Text('${file['fileName'] ?? context.l10n.chatFile}', maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${file['mimeType'] ?? 'application/octet-stream'}${file['sizeBytes'] is int ? ' · ${formatBytes(file['sizeBytes'] as int)}' : ''}',
        ),
      ),
    ),
  );
}

class GatewayAttachmentSelection extends StatelessWidget {
  const GatewayAttachmentSelection({super.key, required this.files});
  final List<Map<String, dynamic>> files;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.ocAttach)),
    body: ListView(children: [for (final file in files) GatewayFileTile(file: file)]),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(context.l10n.ocAttachSelectedFiles(files.length)),
        ),
      ),
    ),
  );
}
