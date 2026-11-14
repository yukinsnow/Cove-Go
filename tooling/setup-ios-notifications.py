#!/usr/bin/env python3
"""Install first-party notification bridge into the generated iOS runner.

Run after flutter create and before flutter build. No push entitlements or
background modes are added. The runner's existing registration stays intact.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parent.parent
runner = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'app/ios/Runner'
path = runner / 'AppDelegate.swift'
source = path.read_text()
marker = '\n// BEGIN COVE LOCAL NOTIFICATIONS\n'
if marker in source:
    source = source.split(marker)[0]
registration = '''    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CoveNotifications") {
      CoveNotifications.register(with: registrar)
    }
'''
needle = '    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)\n'
if registration not in source:
    if needle not in source:
        raise SystemExit('Unrecognized AppDelegate registration; refusing replacement')
    source = source.replace(needle, needle + registration, 1)
# Keep the bridge in the existing compiled source file: no hand-edited pbxproj.
source += marker + (root / 'tooling/ios/CoveNotifications.swift').read_text()
path.write_text(source)
print('Installed Cove local notification bridge:', path)
