import 'package:flutter/material.dart';

import '../ui/theme/theme.dart';

ThemeData buildRemoteLightTheme() => buildLightTheme();

/// Blue-slate glass, soft periwinkle controls and a near-black code well.
/// Scoped to the dual-remote entry point; the original DSH palette is intact.
ThemeData buildRemoteDarkTheme() {
  final base = buildDarkTheme();
  final surfaces = base.extension<DshSurfaces>()!;
  final colors = base.extension<DshColors>()!;
  const page = Color(0xFF212632);
  const raised = Color(0xFF2A2E3A);
  final scheme = base.colorScheme.copyWith(
    surface: page,
    surfaceContainerLowest: const Color(0xFF171C24),
    surfaceContainerLow: const Color(0xFF252A35),
    surfaceContainer: raised,
    surfaceContainerHigh: const Color(0xFF303440),
    surfaceContainerHighest: const Color(0xFF383C48),
  );
  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: page,
    canvasColor: page,
    extensions: [
      colors.copyWith(codeWellBg: const Color(0xFF11161D), codeWellHeader: const Color(0xFF191E27)),
      surfaces.copyWith(
        backdropTop: const Color(0xFF242D3C),
        backdropBottom: const Color(0xFF1D1D26),
        chrome: surfaces.chrome.copyWith(fill: raised.withValues(alpha: 0.80), fallbackFill: raised),
        sheet: surfaces.sheet.copyWith(fill: raised.withValues(alpha: 0.94), fallbackFill: raised),
      ),
    ],
    dialogTheme: base.dialogTheme.copyWith(backgroundColor: raised),
    bottomSheetTheme: base.bottomSheetTheme.copyWith(backgroundColor: raised, modalBackgroundColor: raised),
    popupMenuTheme: base.popupMenuTheme.copyWith(color: raised),
  );
}
