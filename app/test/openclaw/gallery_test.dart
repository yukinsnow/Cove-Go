import 'package:dsh_app/openclaw/images.dart';
import 'package:dsh_app/ui/chat/artifact_preview.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'send_test.dart' show SlowGateway, UiController, home;

void main() {
  testWidgets('received Gateway images open at the selected page and swipe within the message', (tester) async {
    final gateway = SlowGateway();
    final controller = UiController(gateway)..sessionKey = 'a';
    controller.messages = [
      {
        'role': 'assistant',
        'content': [
          {'type': 'image', 'data': SlowGateway.png, 'fileName': 'first.png'},
          {'type': 'image', 'data': SlowGateway.png, 'fileName': 'second.png'},
        ],
      },
    ];
    await tester.pumpWidget(home(controller, buildLightTheme()));
    await tester.pumpAndSettle();
    final thumbnails = find.byType(GatewayImage);
    expect(thumbnails, findsNWidgets(2));
    await tester.tap(thumbnails.last);
    await tester.pumpAndSettle();
    final viewer = tester.widget<ImageViewerPage>(find.byType(ImageViewerPage));
    expect(viewer.initial, 1);
    expect(viewer.images, hasLength(2));
    expect(find.text('second.png'), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(find.text('first.png'), findsOneWidget);
    expect(gateway.downloads, 0);
  });
}
