import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/openclaw/about_page.dart';
import 'package:dsh_app/openclaw/remote_theme.dart';
import 'package:dsh_app/state/app_info.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');

Future<void> _pumpAbout(WidgetTester tester, Locale locale) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildRemoteLightTheme(),
      locale: locale,
      supportedLocales: AppLocale.supported,
      localizationsDelegates: L10n.localizationsDelegates,
      home: const RemoteAboutPage(),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapLink(WidgetTester tester, String id) async {
  final row = find.byKey(ValueKey('remote-about-$id'));
  await tester.scrollUntilVisible(row, 250, scrollable: find.byType(Scrollable).first);
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_launcherChannel, null);
  });

  for (final locale in AppLocale.supported) {
    testWidgets('shows project, build version and upstream attribution in ${locale.languageCode}', (tester) async {
      await _pumpAbout(tester, locale);
      final l = lookupL10n(locale);
      expect(find.text(l.remoteAboutTitle), findsWidgets);
      expect(l.remoteAboutTitle, contains('Cove-Go'));
      expect(l.remoteAboutAttribution, contains('Cove-Go'));
      expect(find.text('OpenClaw Go'), findsNothing);
      expect(find.text(l.remoteAboutDescription), findsOneWidget);
      expect(find.text('Cove-Go'), findsOneWidget);
      expect(find.text(AppInfo.displayVersion), findsOneWidget);
      expect(find.text(l.remoteAboutAuthor('yukinsnow')), findsOneWidget);
      final upstream = find.byKey(const ValueKey('remote-about-upstream'));
      await tester.scrollUntilVisible(upstream, 250, scrollable: find.byType(Scrollable).first);
      expect(tester.widget<SettingsTile>(upstream).title, 'DSH Go');
      final credit = find.text(l.remoteAboutAttribution);
      await tester.scrollUntilVisible(credit, 250, scrollable: find.byType(Scrollable).first);
      expect(credit, findsOneWidget);
      expect(l.remoteAboutAttribution, contains('AGPL-3.0'));
      expect(find.text(l.remoteAboutUpstreamAuthor('ccch1mneyyy')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final throws in [false, true]) {
      testWidgets('localizes link ${throws ? 'exception' : 'refusal'} in ${locale.languageCode}', (tester) async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_launcherChannel, (_) async {
          if (throws) throw PlatformException(code: 'unavailable');
          return false;
        });
        await _pumpAbout(tester, locale);
        await _tapLink(tester, 'homepage');
        expect(find.widgetWithText(SnackBar, lookupL10n(locale).remoteAboutLinkFailed), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  const links = {
    'homepage': 'https://github.com/yukinsnow/dsh-Go',
    'author': 'https://github.com/yukinsnow',
    'upstream': 'https://github.com/ccch1mneyyy/dsh-Go',
    'upstream-author': 'https://github.com/ccch1mneyyy',
  };
  for (final entry in links.entries) {
    testWidgets('one tap launches ${entry.key} externally', (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_launcherChannel, (call) async {
        calls.add(call);
        return true;
      });
      await _pumpAbout(tester, AppLocale.en);
      await _tapLink(tester, entry.key);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'launch');
      final arguments = calls.single.arguments as Map;
      expect(arguments['url'], entry.value);
      expect(arguments['useSafariVC'], false);
      expect(arguments['useWebView'], false);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a delayed failure after leaving the page does not show feedback or throw', (tester) async {
    final result = Completer<bool>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_launcherChannel, (_) => result.future);
    await _pumpAbout(tester, AppLocale.en);
    await _tapLink(tester, 'homepage');
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    result.complete(false);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
