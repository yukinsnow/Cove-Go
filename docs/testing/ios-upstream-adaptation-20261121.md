# Cove-Go official iOS adaptation — 2026-11-21

## Baseline and scope

- Working tree: `/home/ubuntu/projects/openclaw-go-upstream-sync`, branch `sync/upstream-20261114`, base `416c87f8` (Cove-Go 0.1.25 / build 26).
- Official upstream fetched at `da798027013851328f83f59af4adb52c3afaab23`; initial iOS foundation was `645cdebc3`.
- Existing uncommitted single-tap attachment download/card changes preserved.
- Selectively import official remote-client native channels, not the complete app/runtime history. Registration and provenance live in `tooling/ios/upstream/`.
- Keep `main_openclaw.dart`, the OpenClaw/DSH dual remote UI, current bundle identity, artwork, notification ownership and standard self-signing entitlements.
- Native channels: file preview/PDF/save, Photos export, file pickers, system recognition/recording and coordinated native audio. These enable the existing DSH UI/platform callers; no new OpenClaw microphone composer is claimed.
- OpenClaw received-file page gains explicit iOS preview and Documents-save actions plus destination feedback; existing system sharing remains. Host/session retirement clears actions and destination.
- Documents exposed through Files. Add microphone, speech-recognition and photo-add permission descriptions, with no new startup permission requests.
- Build configuration prepared for **0.1.26 (27)**. No IPA produced or delivered by this source change.

## Deliberately not imported

Official embedded Node/Linux runtime, phone control and developer runner, share extension, companion widget, App Groups and alternate official artwork. These are separate features requiring their own integration/signing work. Upstream itself still labels iOS as development/device testing, not a publicly released install package.

## Verification

- `python3 -m unittest tooling/test_ios_platform_setup.py`: 2 passed. Repeated installers retain exactly one registration and one notification delegate, preserve identity, expose Files and refuse unknown templates without mutating them.
- `flutter analyze --no-pub lib/openclaw/received_file.dart test/openclaw/received_file_ui_test.dart`: no issues.
- Source provenance: SHA256 for all 5 imported/adapted Swift files verified against the manifest; 4 byte-identical upstream copies.
- `bash -n tooling/build-openclaw-ipa.sh`, localization generation/check, Dart format, `git diff --check`: passed.
- Flutter final regression: **36 passed** across received-file protocol/UI, attachment budgets, notifications, voice session ownership and native file lifetime. Command: `DSH_TEST_FONT_DIR=/home/ubuntu/.cache/cove-test-fonts flutter test --no-pub test/openclaw/received_file_test.dart test/openclaw/received_file_ui_test.dart test/openclaw/attachments_test.dart test/openclaw/notifications_test.dart test/chat/voice_channel_session_test.dart test/plugins/native/native_files_lifetime_test.dart --reporter expanded` (from `app/`). Final log: `logs/ios-tests.log`; `logs/ios-check-result.txt` records analyze/test exit codes both 0. Earlier UI fixture failures were test harness issues (fake-async completer/I/O and platform override cleanup); the final full run passes.

## Not verified

macOS/Xcode Swift compilation, actual iOS system pickers/audio/Quick Look/Files behavior and iPhone installation. Linux widget tests mock native channels and do not prove a native build or device behavior. No commit, push, upstream PR or release was performed.
