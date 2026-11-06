import 'package:dsh_app/openclaw/appearance_settings.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

Future<void> _loaded(ProviderContainer container) async {
  container.read(settingsProvider);
  for (var i = 0; i < 40; i++) {
    if (container.read(settingsProvider).loaded) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Settings did not finish loading');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => call.method == 'readAll' ? <String, String>{} : null,
    );
  });

  Future<(TextEditingController, FocusNode)> pump(
    WidgetTester tester, {
    bool returnKeySends = false,
    bool hardwareEnterSends = false,
    bool connected = true,
    bool sessionReady = true,
    bool busy = false,
    bool hasAttachments = false,
    String text = '草稿',
    required VoidCallback onSend,
  }) async {
    final input = TextEditingController(text: text);
    final focus = FocusNode();
    addTearDown(input.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Composer(
            controller: input,
            focusNode: focus,
            returnKeySends: returnKeySends,
            hardwareEnterSends: hardwareEnterSends,
            connected: connected,
            sessionReady: sessionReady,
            busy: busy,
            hasAttachments: hasAttachments,
            running: false,
            onSend: onSend,
            onStop: () => fail('Return must not stop a turn'),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    return (input, focus);
  }

  testWidgets('software Return defaults to newline and never submits', (tester) async {
    var sends = 0;
    final (input, _) = await pump(tester, onSend: () => sends++);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.textInputAction, TextInputAction.newline);
    expect(field.onSubmitted, isNull);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '草稿\n', selection: TextSelection.collapsed(offset: 3)),
    );
    await tester.testTextInput.receiveAction(TextInputAction.newline);
    expect(input.text, '草稿\n');
    expect(sends, 0);
    // Even a stale keyboard send action cannot opt the user into sending.
    await tester.testTextInput.receiveAction(TextInputAction.send);
    expect(sends, 0);
  });

  testWidgets('enabled software Return sends once and keeps editor focus', (tester) async {
    var sends = 0;
    final (input, focus) = await pump(tester, returnKeySends: true, onSend: () => sends++);
    expect(tester.widget<TextField>(find.byType(TextField)).textInputAction, TextInputAction.send);
    await tester.testTextInput.receiveAction(TextInputAction.send);
    expect(sends, 1);
    expect(input.text, '草稿');
    expect(focus.hasFocus, isTrue);
  });

  testWidgets('software Return preserves active IME candidates instead of sending', (tester) async {
    var sends = 0;
    final (input, focus) = await pump(tester, returnKeySends: true, onSend: () => sends++);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '拼',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      ),
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    expect(sends, 0);
    expect(input.value.composing, const TextRange(start: 0, end: 1));
    expect(focus.hasFocus, isTrue);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '拼',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 1, end: 1),
      ),
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    expect(sends, 1, reason: 'A committed, collapsed composition may send');
  });

  for (final blocked in ['offline', 'unready', 'busy', 'empty', 'whitespace']) {
    testWidgets('enabled software Return cannot send when $blocked', (tester) async {
      var sends = 0;
      final (input, _) = await pump(
        tester,
        returnKeySends: true,
        connected: blocked != 'offline',
        sessionReady: blocked != 'unready',
        busy: blocked == 'busy',
        text: blocked == 'empty'
            ? ''
            : blocked == 'whitespace'
            ? ' \n '
            : '草稿',
        onSend: () => sends++,
      );
      final draft = input.text;
      await tester.testTextInput.receiveAction(TextInputAction.send);
      expect(sends, 0);
      expect(input.text, draft);
    });
  }

  testWidgets('enabled software Return can send an attachment-only draft', (tester) async {
    var sends = 0;
    await pump(tester, returnKeySends: true, hasAttachments: true, text: '', onSend: () => sends++);
    await tester.testTextInput.receiveAction(TextInputAction.send);
    expect(sends, 1);
  });

  for (final hardwareEnterSends in [false, true]) {
    testWidgets('software send preserves Shift+Enter newline (hardware send $hardwareEnterSends)', (tester) async {
      var sends = 0;
      final (input, _) = await pump(
        tester,
        returnKeySends: true,
        hardwareEnterSends: hardwareEnterSends,
        onSend: () => sends++,
      );
      input.selection = const TextSelection.collapsed(offset: 1);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(input.text, '草\n稿');
      expect(input.selection, const TextSelection.collapsed(offset: 2));
      expect(sends, 0);
    });
  }

  testWidgets('shared settings switch updates software action live without changing hardware choice', (tester) async {
    final input = TextEditingController();
    addTearDown(input.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ListView(
              children: [
                const RemoteAppearanceSettings(),
                Composer(
                  controller: input,
                  connected: true,
                  running: false,
                  returnKeySends: ref.watch(settingsProvider.select((s) => s.returnKeySends)),
                  onSend: () {},
                  onStop: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('换行键发送'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).textInputAction, TextInputAction.newline);
    final toggle = find.byKey(const ValueKey('remote-return-key-sends-switch'));
    await tester.tap(find.descendant(of: toggle, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).textInputAction, TextInputAction.send);
    final container = ProviderScope.containerOf(tester.element(find.byType(RemoteAppearanceSettings)));
    expect(container.read(settingsProvider).returnKeySends, isTrue);
    expect(container.read(settingsProvider).hardwareEnterSends, isFalse);
    await tester.tap(find.descendant(of: toggle, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).textInputAction, TextInputAction.newline);
  });

  test('software Return choice defaults off, persists and reloads separately from hardware Enter', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await _loaded(container);
    expect(container.read(settingsProvider).returnKeySends, isFalse);
    await container.read(settingsProvider.notifier).setHardwareEnterSends(true);
    await container.read(settingsProvider.notifier).setReturnKeySends(true);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('return_key_sends'), isTrue);
    container.invalidate(settingsProvider);
    await _loaded(container);
    expect(container.read(settingsProvider).returnKeySends, isTrue);
    expect(container.read(settingsProvider).hardwareEnterSends, isTrue);
    await container.read(settingsProvider.notifier).setReturnKeySends(false);
    container.invalidate(settingsProvider);
    await _loaded(container);
    expect(container.read(settingsProvider).returnKeySends, isFalse);
    expect(container.read(settingsProvider).hardwareEnterSends, isTrue);
    expect(prefs.getBool('return_key_sends'), isFalse);
  });
}
