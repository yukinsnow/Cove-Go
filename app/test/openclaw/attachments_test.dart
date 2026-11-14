import 'dart:typed_data';

import 'package:dsh_app/openclaw/attachments.dart';
import 'package:dsh_app/openclaw/image_blocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

class StreamingFile extends XFile {
  StreamingFile(this.reported, this.chunks) : super('report.pdf');
  final int reported;
  final List<Uint8List> chunks;
  int reads = 0;
  bool closed = false;
  @override
  Future<int> length() async => reported;
  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    try {
      for (final chunk in chunks) {
        reads++;
        yield chunk;
      }
    } finally {
      closed = true;
    }
  }
}

void main() {
  test('oversize metadata rejects before opening a stream', () async {
    final file = StreamingFile(100, [Uint8List(100)]);
    await expectLater(readGatewayAttachment(file, 4), throwsStateError);
    expect(file.reads, 0);
  });
  test('stream budget rejects stale sizes and cancels before further chunks', () async {
    final file = StreamingFile(1, [Uint8List(3), Uint8List(3), Uint8List(3)]);
    await expectLater(readGatewayAttachment(file, 4), throwsStateError);
    expect(file.reads, 2);
    expect(file.closed, isTrue);
  });
  test('exact limit passes and empty files are rejected', () async {
    final file = StreamingFile(4, [Uint8List(2), Uint8List(2)]);
    expect(await readGatewayAttachment(file, 4), hasLength(4));
    await expectLater(readGatewayAttachment(StreamingFile(0, []), 4), throwsStateError);
  });
  test('MIME sniffs bytes before trusting extensions, with binary fallback', () {
    expect(
      gatewayAttachmentMime(XFile('fake.txt'), Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10])),
      'image/png',
    );
    expect(gatewayAttachmentMime(XFile('blob.unknown'), Uint8List.fromList([0, 1, 2])), 'application/octet-stream');
    expect(gatewayAttachmentMime(XFile('clip.mov'), Uint8List.fromList([0, 1, 2])), 'video/quicktime');
  });
  test('history distinguishes image from video and preserves file metadata', () {
    final message = {
      '__openclaw': {
        'media': [
          {'kind': 'image', 'contentType': 'image/png', 'fileName': 'photo.png'},
          {'kind': 'video', 'contentType': 'video/mp4', 'fileName': 'clip.mp4', 'sizeBytes': 100},
          {'kind': 'file', 'contentType': 'application/pdf', 'fileName': 'report.pdf'},
        ],
      },
    };
    expect(gatewayFiles(message).map((f) => f['fileName']), ['clip.mp4', 'report.pdf']);
    expect(gatewayImages(message), hasLength(1));
  });
}
