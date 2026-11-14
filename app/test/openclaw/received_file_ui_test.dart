import 'package:dsh_app/openclaw/attachments.dart';
import 'package:dsh_app/openclaw/received_file.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'send_test.dart' show SlowGateway, UiController, home;

void main() {
  testWidgets('real delivery-mirror ZIP appears in assistant bubble and opens native download page', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = UiController(SlowGateway())..sessionKey = 'fixture';
    c.messages = [
      {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Package delivered'},
          {
            'type': 'attachment',
            'attachment': {
              'artifactId': 'artifact_managed_media_e0e85255-5999-429c-82e9-d1a2d8e6c42a',
              'url': '/api/chat/media/outgoing/fixture/e0e85255-5999-429c-82e9-d1a2d8e6c42a/full',
              'kind': 'document',
              'label': 'Cove-Go-0.1.22-build23-unsigned.zip',
              'mimeType': 'application/zip',
              'sizeBytes': 28258724,
            },
          },
        ],
      },
    ];
    await tester.pumpWidget(home(c, buildLightTheme()));
    await tester.pumpAndSettle();
    expect(find.byType(GatewayFileTile), findsOneWidget);
    expect(find.text('Cove-Go-0.1.22-build23-unsigned.zip'), findsOneWidget);
    await tester.tap(find.byType(GatewayFileTile));
    await tester.pumpAndSettle();
    expect(find.byType(GatewayReceivedFilePage), findsOneWidget);
    expect(find.byKey(const ValueKey('received-file-download')), findsOneWidget);
    expect(find.byKey(const ValueKey('received-file-save')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
