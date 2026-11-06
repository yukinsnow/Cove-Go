# OpenClaw Go: dual-backend remote client

[简体中文](openclaw-remote.md)

Directly based on `ccch1mneyyy/dsh-Go`, baseline
`70507b00a5ed84ca21d58c5e60420fb47084f095`, not the third-party iOS repository.
AGPL-3.0 and upstream third-party notices are retained. The original entry point is unchanged.

## Architecture

`app/lib/main_openclaw.dart` offers OpenClaw and DSH Remote in one app.
The drawer footer opens a shared host picker. The remote-host page groups OpenClaw and DSH Remote separately, with SSH inside their respective add/edit flows. Gateway settings and its web console are on the OpenClaw section rather than a separate top-right entry.
The DSH page is initialized lazily. Backend selection is saved, while each backend
owns its credentials, session identifiers, transport and chat state independently.
Switching does not convert or migrate conversations between services.

DSH Remote keeps the original browser-login/polling, self-hosted login, host trust,
LAN/WebRTC/P2P/TURN/relay and SSH implementations and original native chat UI.
The remote entry point never installs or automatically starts the Android Linux runtime.

OpenClaw uses the new pure Dart `packages/openclaw_client`: Gateway WebSocket v4,
Ed25519 device/challenge authentication, RPC, sessions, history, streaming text,
tool activity, model selection, images, followups, steer and interrupt.
Remote URLs must use WSS. Approve a new device on the Gateway, then reconnect.
Credentials and device seed stay in local secure storage, never in Git or build arguments.
The client does not relax Gateway security or tunnel Gateway through DSH Remote.
DSH reconnects expose an immediate retry and expandable errors. The iOS archive includes a local-network usage description; allow access to your computer when prompted.
Opening, switching or reopening an OpenClaw conversation starts at the newest message; UI refreshes do not force readers back down while browsing older messages.
Both connections may stay open, but iOS background execution is not guaranteed.

## Run and build

```sh
cd app
flutter pub get
python3 tool/l10n_merge.py
flutter run --target lib/main_openclaw.dart --dart-define=REMOTE_DUAL_APP=true
```

On macOS with Xcode and Flutter 3.47.9, run `bash tooling/build-openclaw-ipa.sh`.
The output is `build/openclaw/OpenClaw-Go-0.1.10-build11-<revision>-unsigned.ipa` for your own signing process.
The GitHub workflow uploads an artifact, not a public release. Linux cannot build
with Xcode or prove iPhone functionality.

## Remaining integration

OpenClaw approval/question forms, voice, inline widgets, device commands,
history pagination (currently the latest 150 messages) and saved multi-Gateway profiles.
DSH Remote still needs end-to-end iPhone testing. Android local execution and
accessibility-based phone control are not iOS remote features.
The dual-backend build uses an original network icon, disables the upstream brand/mascots,
and excludes their assets from the IPA; the original DSH development entry point is unchanged.
See `ASSETS.md`. This remains an unverified development build until iPhone testing.

## Checks

```sh
(cd packages/openclaw_client && dart pub get && dart analyze && dart test)
(cd app && flutter analyze lib/main_openclaw.dart lib/openclaw test/openclaw)
(cd app && flutter test test/openclaw test/remote/relay_backend_test.dart)
python3 app/tool/l10n_merge.py --check
```

Protocol tests use a local mock Gateway, not user conversations or paid model runs.

### SSH Gateway connections

Choose or add an SSH profile in the Gateway connection form. Use a Gateway `ws://` address reachable from that SSH server (for example `ws://127.0.0.1:18789`). The encrypted SSH tunnel forwards the existing Gateway and never launches DSH. Passwords and private keys stay in secure storage; host fingerprints must be trusted. Legacy SSH hosts remain in the DSH section; Gateway-only profiles are excluded from DSH host switching. The Gateway web console uses the same tunnel without adding its token to the URL. Direct remote connections still require `wss://`.
