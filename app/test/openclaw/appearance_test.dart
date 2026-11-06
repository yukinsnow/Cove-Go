import 'dart:io';
import 'dart:async';

import 'package:dsh_app/state/settings_state.dart';

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:dsh_app/main_openclaw.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:dsh_app/openclaw/appearance_settings.dart';
import 'package:dsh_app/openclaw/home.dart';
import 'package:dsh_app/openclaw/mascot_settings.dart';
import 'package:dsh_app/openclaw/remote_theme.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/pets/pet_perch.dart';
import 'package:dsh_app/ui/pets/pet_stage.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    for (final name in ['dsh/runtime/events', 'dev.fluttercommunity.plus/connectivity_status']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
  });

  test('night palette matches blue slate reference with readable text and code', () {
    final theme = buildRemoteDarkTheme();
    final s = theme.extension<DshSurfaces>()!;
    final c = theme.extension<DshColors>()!;
    expect(s.backdropTop, const Color(0xFF242D3C));
    expect(s.backdropBottom, const Color(0xFF1D1D26));
    expect(c.codeWellBg, const Color(0xFF11161D));
    for (final ground in [
      s.backdropTop,
      s.backdropBottom,
      s.chrome.fallbackFill,
      theme.colorScheme.surfaceContainerHighest,
    ]) {
      expect(contrastRatio(theme.colorScheme.onSurface, ground), greaterThan(8));
      expect(contrastRatio(theme.colorScheme.onSurfaceVariant, ground), greaterThan(5));
      expect(contrastRatio(c.textTertiary, ground), greaterThan(4));
      expect(contrastRatio(theme.colorScheme.primary, ground), greaterThan(3));
    }
    for (final style in dshHighlightTheme(Brightness.dark).values) {
      if (style.color != null) {
        expect(contrastRatio(style.color!, style.backgroundColor ?? c.codeWellBg), greaterThan(4.5));
      }
    }
    expect(buildRemoteLightTheme().colorScheme, buildLightTheme().colorScheme);
    expect(buildDarkTheme().extension<DshSurfaces>()!.backdropTop, DshPalette.nightTop);
  });

  for (final mode in ['light', 'dark']) {
    testWidgets('visual proof for $mode chat and original mascot', (tester) async {
      SharedPreferences.setMockInitialValues({'theme_mode': mode});
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: const ProviderScope(child: OpenClawApp()),
        ),
      );
      await tester.pumpAndSettle();
      final state = tester.state<ClawHomeState>(find.byType(ClawHome));
      state.c.sessionKey = 'preview';
      state.c.messages = [
        {'role': 'user', 'content': '检查登录逻辑，顺便确认一下测试结果。'},
        {
          'role': 'assistant',
          'content': '已经调整好了。正文、工具记录和代码使用同一套夜间配色。\n\n```dart\ntry {\n  await api.login(email, password);\n} finally {\n  submitting = false;\n}\n```\n\n| 检查项 | 结果 |\n| --- | --- |\n| 输入框与键盘 | 通过 |\n\n小龙虾会待在输入栏上方，点击可以跳一下。',
        },
      ];
      state.c.changed();
      await tester.pumpAndSettle();
      final boundary = capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../build/openclaw/appearance-$mode.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('early theme selection survives delayed secure settings restoration', (tester) async {
    final gate = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async {
        await gate.future;
        return null;
      },
    );
    await tester.pumpWidget(const ProviderScope(child: OpenClawApp()));
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.byType(ClawHome)));
    await container.read(settingsProvider.notifier).setThemeMode(ThemeMode.dark);
    gate.complete();
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).loaded, true);
    expect(container.read(settingsProvider).themeMode, ThemeMode.dark);
  });

  testWidgets('settings switch day/night/system immediately and restore after restart', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpenClawApp()));
    await tester.pumpAndSettle();
    final home = tester.state<ClawHomeState>(find.byType(ClawHome));
    home.input.text = 'keep my draft';
    home.openSettings();
    await tester.pumpAndSettle();
    expect(find.byType(RemoteAppearanceSettings), findsOneWidget);
    await tester.ensureVisible(find.text('夜间'));
    await tester.tap(find.text('夜间'));
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.dark);
    expect(Theme.of(tester.element(find.byType(RemoteAppearanceSettings))).brightness, Brightness.dark);
    expect(home.input.text, 'keep my draft');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'dark');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(const ProviderScope(child: OpenClawApp()));
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.dark);
    tester.state<ClawHomeState>(find.byType(ClawHome)).openSettings();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('日间'));
    await tester.tap(find.text('日间'));
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.light);
    await tester.tap(find.text('跟随系统'));
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.system);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lobster follows composer and settings toggles persist independently', (tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ProviderScope(child: OpenClawApp()));
    await tester.pumpAndSettle();
    final lobster = find.byKey(const ValueKey('remote-mascot-lobster'));
    expect(lobster, findsOneWidget);
    expect(find.byKey(const ValueKey('remote-mascot-whale')), findsNothing);
    final initial = tester.getRect(lobster);
    expect(initial.bottom, closeTo(tester.getRect(find.byType(Composer)).top - 2, 1));
    await tester.tap(lobster);
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.getRect(lobster).bottom, closeTo(tester.getRect(find.byType(Composer)).top - 2, 1));
    expect(tester.getRect(lobster).top, lessThan(initial.top));
    tester.view.resetViewInsets();
    tester.state<ClawHomeState>(find.byType(ClawHome)).openSettings();
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('remote-mascot-lobster-switch'));
    await tester.ensureVisible(toggle);
    await tester.tap(find.descendant(of: toggle, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('remote.mascot.lobster'), false);
    final scope = ProviderScope.containerOf(tester.element(find.byType(RemoteAppearanceSettings)));
    expect(scope.read(mascotSettingsProvider)[RemoteMascot.whale], true);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(const ProviderScope(child: OpenClawApp()));
    await tester.pumpAndSettle();
    expect(lobster, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('DSH stage uses whale and shared settings in dual remote scope only', (tester) async {
    await tester.pumpWidget(
      ProviderScope(overrides: [dualRemoteUiProvider.overrideWithValue(true)], child: const OpenClawApp()),
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(ClawHome));
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byType(RemoteAppearanceSettings),
      350,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byType(RemoteAppearanceSettings), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    final whaleCapture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: whaleCapture,
        child: ProviderScope(
          overrides: [dualRemoteUiProvider.overrideWithValue(true)],
          child: MaterialApp(
            theme: buildRemoteDarkTheme(),
            locale: const Locale('zh', 'CN'),
            localizationsDelegates: const [
              L10n.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocale.supported,
            home: const Scaffold(
              body: PetStage(
                child: Column(
                  children: [
                    Expanded(child: SizedBox()),
                    PetPerch(
                      kind: PerchKind.composer,
                      child: SizedBox(height: 56, width: double.infinity),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remote-mascot-whale')), findsOneWidget);
    expect(find.byKey(const ValueKey('remote-mascot-lobster')), findsNothing);
    final boundary = whaleCapture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../build/openclaw/whale-preview.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    final stageContext = tester.element(find.byType(PetStage));
    await ProviderScope.containerOf(stageContext)
        .read(mascotSettingsProvider.notifier)
        .setEnabled(RemoteMascot.whale, false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remote-mascot-whale')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
