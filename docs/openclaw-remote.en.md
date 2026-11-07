# Cove-Go: dual-backend remote client

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

## Appearance and companions

Both protocol settings offer Day, Night and Follow system. The choice persists on-device and applies to both protocols. Night uses blue-slate glass, soft periwinkle controls and near-black code blocks. Native DSH chats show an original pixel whale; native OpenClaw chats show an original pixel lobster. Each has an independent persistent visibility switch. Tap to hop; the companion follows the input/status perch and respects reduced motion. Embedded web pages are not modified. Restricted upstream Deepy/whale-girl artwork remains excluded.

## Run and build

```sh
cd app
flutter pub get
python3 tool/l10n_merge.py
flutter run --target lib/main_openclaw.dart --dart-define=REMOTE_DUAL_APP=true
```

On macOS with Xcode and Flutter 3.47.9, run `bash tooling/build-openclaw-ipa.sh`.
The output is `build/openclaw/Cove-Go-0.1.15-build16-<revision>-unsigned.ipa` for your own signing process.
The GitHub workflow uploads an artifact, not a public release. Linux cannot build
with Xcode or prove iPhone functionality.

## Remaining integration

OpenClaw approval/question forms, voice, inline widgets, device commands,
and history pagination (currently the latest 150 messages).
DSH Remote still needs end-to-end iPhone testing. Android local execution and
accessibility-based phone control are not iOS remote features.
The dual-backend build uses the approved ocean-terminal icon (D9 palette with D14 waves), disables the upstream brand/mascots,
and excludes their assets from the IPA. The new companions are independently drawn; the original DSH development entry point is unchanged.
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

## Multiple OpenClaw hosts and About

- Remote hosts always offers direct and SSH add actions. Each Gateway owns its credentials, device identity, SSH tunnel, history and draft. Switching native pages does not disconnect other Gateways; iOS suspension still does not guarantee background connections.
- The legacy single-Gateway configuration is copied into a secure `legacy` profile. Old keys are cleaned only after the catalog is committed. Its paired identity is preserved; new profiles use separate identities.
- Swipe OpenClaw/SSH rows left to reveal Delete on the right, or long-press for a deletion menu. Confirmation is required; only that phone-side connection is removed, not the server or conversations. DSH Remote has no native deletion API: its gesture routes to real console management instead of pretending to delete locally.
- Settings → About Cove-Go shows the build version, project and author links, and original DSH Go project/author attribution. Links open in an external browser.

## Image recovery and the input keyboard

- History images are read from content blocks, `openclawDisplayContent` and `__openclaw.media`. Canonical `media://inbound` references use the current Gateway's authenticated media endpoint. Managed outgoing images request fresh download grants instead of reusing expired URLs. SSH connections use the current tunnel.
- If an older Gateway echoes only text, sent images remain as display-only fallbacks across history refreshes and session switches. The existing encrypted, host-scoped snapshot budget still applies: 2 MiB per snapshot and at most 20 cached histories. This is not a full photo backup; images already lost by an older client cannot be recreated when the server has no reference, and large fallbacks can be evicted by the cache budget.
- Both attachment entry points explicitly dismiss the keyboard before presenting their menu or native picker. Changing host/session during selection still retires the old pick.
- Return to send defaults to off in both settings pages. Enabling it changes the software keyboard action to Send, guards active IME composition, disconnected and submitting states, and keeps hardware Shift+Enter as newline. The preference persists locally, independently of the hardware Enter setting.

Mock-Gateway, widget and encrypted-snapshot tests cover these paths; iPhone keyboard and photo-picker behavior still needs real-device validation.

## Cove-Go branding

The product name is `Cove-Go` in every language, with no separate Chinese name. Its ocean-terminal icon combines the D9 palette with D14 waves. This is a display-brand change only: the repository was renamed to `yukinsnow/Cove-Go` for the 0.1.15 public release, with `openclaw` as the default branch. GitHub redirects the old repository URLs, including the homepage link in the already-built binary. The iOS bundle ID, Gateway protocol client ID, device identities and secure-storage keys remain unchanged for installation and pairing continuity. Original DSH Go attribution is retained.

## Public release

The current test release is [v0.1.15](https://github.com/yukinsnow/Cove-Go/releases/tag/v0.1.15). Its binary corresponds exactly to tagged commit `6708c24dc8dbdc51fdaadcd4cacfdb06bf798545`; subsequent README changes do not alter it. The landing page now describes this derivative rather than advertising upstream Android local-engine features or restricted mascots as Cove-Go features. See the [README](../README.en.md) for downloads, signing, verification scope and licensing boundaries.
