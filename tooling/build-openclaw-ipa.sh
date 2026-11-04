#!/usr/bin/env bash
# Run on macOS with Flutter/Xcode. Produces unsigned IPA for user-controlled signing.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/app"
# Keep the original DSH target unchanged; omit restricted upstream mascots from this artifact.
BACKUP="$(mktemp -d)"
cp pubspec.yaml "$BACKUP/pubspec.yaml"
trap 'cp "$BACKUP/pubspec.yaml" "$ROOT/app/pubspec.yaml"' EXIT
python3 - <<'PYASSETS'
from pathlib import Path
p=Path('pubspec.yaml')
blocked=('assets/whale/', 'assets/pets/deepy-whale/', 'assets/pets/whale-girl/', 'assets/star/')
p.write_text('\n'.join(line for line in p.read_text().splitlines() if not any(b in line for b in blocked))+'\n')
PYASSETS
flutter create --platforms=ios --org io.github.yukinsnow --project-name dsh_app .
python3 - "$PWD/ios/Runner/Info.plist" <<'PY'
import plistlib,sys
p=sys.argv[1]
with open(p,'rb') as f: data=plistlib.load(f)
data['CFBundleDisplayName']='OpenClaw Go'
data['CFBundleName']='OpenClaw Go'
data['CFBundleIconFiles']=['AppIcon60x60']
data['NSPhotoLibraryUsageDescription']='Attach selected images to OpenClaw conversations.'
data['NSCameraUsageDescription']='Capture images for OpenClaw conversations.'
with open(p,'wb') as f: plistlib.dump(data,f)
PY
# iOS secure-storage keychain group for a standard signed app.
cat > ios/Runner/Runner.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>keychain-access-groups</key><array><string>$(AppIdentifierPrefix)$(CFBundleIdentifier)</string></array></dict></plist>
PLIST
python3 - <<'PY'
from pathlib import Path
p=Path('ios/Runner.xcodeproj/project.pbxproj')
s=p.read_text().replace('PRODUCT_BUNDLE_IDENTIFIER = ', 'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;\nPRODUCT_BUNDLE_IDENTIFIER = ')
p.write_text(s)
PY
swift "$ROOT/tooling/openclaw_icon.swift" "$PWD/ios/Runner/Assets.xcassets/AppIcon.appiconset"
flutter pub get
python3 tool/l10n_merge.py
flutter build ios --release --no-codesign --target lib/main_openclaw.dart --dart-define=REMOTE_DUAL_APP=true --build-name 0.1.1 --build-number 2 --dart-define=DSH_APP_VERSION=0.1.1+2
# Fresh temporary payload; never deletes an existing checkout path.
OUT="$ROOT/build/openclaw"
mkdir -p "$OUT"
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/Payload"
cp -R build/ios/iphoneos/Runner.app "$STAGE/Payload/"
(cd "$STAGE" && zip -qry "$OUT/OpenClaw-Go-unsigned.ipa" Payload)
printf 'Unsigned IPA: %s\n' "$OUT/OpenClaw-Go-unsigned.ipa"
