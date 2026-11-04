import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/l10n.dart';
import 'openclaw/backend_home.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui/theme/app_theme.dart';
import 'ui/common/third_party_licenses.dart';
import 'ui/settings/font_licenses.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerThirdPartyLicenses();
  registerFontLicenses();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['OpenClaw Go / DSH Go'], await rootBundle.loadString('assets/openclaw/LICENSE'));
  });
  runApp(const ProviderScope(child: OpenClawApp()));
}

class OpenClawApp extends StatefulWidget {
  const OpenClawApp({super.key});
  @override
  State<OpenClawApp> createState() => _OpenClawAppState();
}

class _OpenClawAppState extends State<OpenClawApp> {
  Locale locale = const Locale('zh', 'CN');
  @override
  Widget build(BuildContext context) {
    AppLocale.use(locale);
    return MaterialApp(
      title: 'OpenClaw Go',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
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
    );
  }
}
