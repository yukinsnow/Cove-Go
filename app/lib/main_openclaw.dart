import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/l10n.dart';
import 'openclaw/backend_home.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'openclaw/remote_theme.dart';
import 'openclaw/mascot_settings.dart';
import 'state/settings_state.dart';
import 'ui/common/third_party_licenses.dart';
import 'ui/settings/font_licenses.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerThirdPartyLicenses();
  registerFontLicenses();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['Cove-Go / DSH Go'], await rootBundle.loadString('assets/openclaw/LICENSE'));
  });
  runApp(const ProviderScope(child: OpenClawApp()));
}

class OpenClawApp extends ConsumerStatefulWidget {
  const OpenClawApp({super.key});
  @override
  ConsumerState<OpenClawApp> createState() => _OpenClawAppState();
}

class _OpenClawAppState extends ConsumerState<OpenClawApp> {
  Locale locale = const Locale('zh', 'CN');
  final light = buildRemoteLightTheme();
  final dark = buildRemoteDarkTheme();
  @override
  Widget build(BuildContext context) {
    AppLocale.use(locale);
    return ProviderScope(
      overrides: [dualRemoteUiProvider.overrideWithValue(true)],
      child: MaterialApp(
        title: 'Cove-Go',
        debugShowCheckedModeBanner: false,
        theme: light,
        darkTheme: dark,
        themeMode: ref.watch(settingsProvider.select((s) => s.themeMode)),
        locale: locale,
        localizationsDelegates: const [
          L10n.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocale.supported,
        home: BackendHome(
          onLanguage: () => setState(() {
            locale = locale.languageCode == 'zh' ? const Locale('en') : const Locale('zh', 'CN');
          }),
        ),
      ),
    );
  }
}
