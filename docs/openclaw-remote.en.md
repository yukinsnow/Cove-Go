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

## iOS local notifications

Both backends expose notification settings with an opt-in switch, system-permission entry and test notification. Permission is requested only when enabling, never at startup. Lock-screen content is generic: no message bodies, private titles, host addresses or credentials. Taps route by backend, host and session; deleted Gateways are not recreated.

OpenClaw consumes both received `chat` final/error events and live `sessions.changed` lifecycle terminals, deduplicated across streams by session and client run ID. The subscribed session roster also covers chats that are not open. Lifecycle end/error events must match the terminal projection’s `lastRunId`; historical rows, metadata changes, yielded waiting runs and stale runs never notify. Explicitly sent, non-silent heartbeat events become new alerts, opening only their Gateway because the event does not guarantee a session key. No background-chat completion is inferred if the Gateway does not deliver its terminal event to this connection. DSH Remote reuses host events and HostAlertTracker for completion, failure/stop, approval and question alerts. Only the connected remote host is tracked; no local runtime is started. Initial history and events missed while disconnected do not create retrospective notifications.

The native bridge uses UNUserNotificationCenter. `tooling/setup-ios-notifications.py` installs it into the AppDelegate produced by flutter create without modifying shared Pub plugins or adding audio-background modes or APNs entitlements. iOS 15 falls back to app settings; iOS 16+ can open notification settings directly.

**Local notifications, not remote push.** Event delivery is not guaranteed when iOS suspends/closes the app or networking is unavailable. Reliable remote push needs a separate APNs backend and push-capable signing; ordinary self-signed IPA installation does not provide these automatically. Focus and system settings may suppress banners/sound.

Validation covers notification rules, permissions, deduplication, disabling/cleanup, host routing and existing UI/image selection. The Swift bridge and generated AppDelegate typecheck against the real Flutter headers and iOS SDK for arm64 / iOS 15. An unsigned IPA with local notifications was delivered as 0.1.19 (20); 0.1.21 (22) adds lifecycle terminal handling and connection-retirement guards. Physical iPhone notification/cold-start testing is still pending.

## Web entry and image-picking fixes (new source, not released)

- The web entry beside New chat now uses a globe without changing its destination.
- When DSH Remote cannot serve its web UI, top-left and system Back leave web mode for native chat rather than trying to pop the root Navigator. The current conversation is retained; normally pushed pages keep their existing back behavior.
- OpenClaw attachments open the system multi-image picker directly, without a single/multiple prompt. One image keeps its existing preview; multiple images use batch confirmation. Count/size limits and host/session ownership checks remain in place.
- 49 focused regressions passed with clean static analysis. No physical iPhone validation or new IPA containing these fixes yet.

## File and video attachments (new source, not released)

- OpenClaw's + first offers Photos / videos and Files. The gallery supports mixed media; Files opens the system document picker. Single-image confirmation and multi-image previews remain; other attachments show name, MIME and size before confirmation.
- `chat.send.attachments` carries actual base64 content and file metadata. Videos are files, not fake images. Previews and drafts do not upload anything; failed sends preserve the draft. Only display metadata is retained when history omits file details, never rendered as image bytes.
- Size is checked before reading and again while streaming. Combined attachments respect advertised Gateway `maxBytes`, `maxImageBytes`, WebSocket frame limits and a conservative local total cap. At most 9 attachments; cancellation or switching host/conversation cannot attach to another draft.
- DSH's gallery also supports photos/videos; files keep the existing staging route. Hosts without file uploads reject video with feedback. Upload support does not imply model understanding of every file/video format; older Gateways can reject non-image attachments, without a false success indication.
- Physical iPhone picker and real-account end-to-end validation have not been performed; no new IPA contains these changes yet.
- Verification: 123 OpenClaw/DSH attachment, budget, ownership and chat regressions passed; static analysis of 11 related files, localization and formatting checks passed.

## Workspace switching and management (new source, not released)

- All chats is now an interactive workspace selector using DSH's sheet design, with counts for all, ungrouped and server-owned custom groups. Selection filters the drawer without switching the current conversation; empty groups remain selectable.
- These OpenClaw workspaces map to server `category` groups, not automatically created directories. Add, rename and remove use `sessions.groups.*` with readback; removal clears membership while preserving conversations, directories and files. Long-press a conversation to move it to another group.
- Management can edit the Gateway-side New Session directory through `sessions.groups.defaults/update`. It is not a phone directory, does not move existing conversations and remains subject to server permissions/path validation. Empty restores the agent default; saving chooses the current checkout (disabling a new worktree). Existing worktree defaults are honored when creating a conversation.
- New chat inherits the selected named group and directory defaults; All chats and Ungrouped do not inherit a named category. The filter is cached within the Gateway/credential-scoped offline snapshot and resets on connection identity changes.
- Session listing follows `hasMore/nextOffset`, so counts no longer stop at 100 rows. Older Gateways can still filter existing row categories without pretending to support management. Permission errors remain visible; late results after host changes cannot overwrite the new connection.
- No group mutations were performed on real user data: verification uses protocol fixtures and Flutter UI tests. Physical-device validation and a new IPA are still pending.
- Verification: 66 workspace, ownership, send and multi-host regressions passed; static analysis of four related files, localization and diff checks passed.

## OpenClaw all-features hub (new source, not released)

- The drawer's nine-dot button opens a dedicated hub reusing DSH's AppPage, large title, conversation overview, two-column FeatureCard and FeatureTile visuals, without reading DSH connection/provider data.
- Native entries include conversation metadata, assistant-delivered outputs, referenced-file text/image previews, progress cards, skills, scheduled jobs, plugins and configured agents. Search, workspaces, model selection, hosts, notifications and all settings use existing flows.
- Output queries require `messageRole: assistant`; incompatible Gateways show an error rather than falling back to mixed uploaded/output files. Byte-mode artifacts load only on explicit action, up to 20 MB. Supported images/text preview locally; system share/save is a separate action. URL-mode downloads are not fetched, redirected or given Gateway credentials.
- Export deliberately shares the latest up to 150 display messages returned by the Gateway as JSON, not a complete raw transcript or ZIP backup. The page warns about private conversations/attachments and does not share automatically.
- Automations/plugins are read-only inventories (first 100 automations); configured agents do not implement DSH's team task board. Terminal, background jobs and permissions are explicitly web-only links to the Gateway UI, not native operation pages or guaranteed panel deep links. No on-phone execution is implied.
- Readers capture the connection/conversation scope and hide retired results, support retry and surface missing APIs or permission errors. Explicit display-field projections avoid dumping complete configuration/credentials.
- Native UI/protocol fixture tests do not establish real-Gateway or physical iPhone behavior. System sharing, WebView login and real-account validation remain unverified. Earlier upload/workspace changes remain; no new IPA contains this hub yet.
- Verification: 81 integrated hub, artifacts, file preview, workspace, model, home, multi-host and send tests passed; static analysis of seven files, localization/diff checks and light/dark phone screenshot inspection passed.

### Feature-hub visibility

- Per user preference, remove Terminal, Background jobs and Permissions web-only placeholders; keep the dedicated Gateway web entry.
- If `hello.features.methods` is present, hide cards whose required RPCs are absent, including empty section headings. Legacy Gateways without a roster keep implemented entries with explicit unsupported/permission errors; an unknown roster is not proof of support.
- Rename Agent team to Configured agents to avoid implying DSH team/task-board parity.

## Model usage

All features → Model usage shows the connected Gateway without requiring an open chat. API wallets and ChatGPT subscription windows use the installed API Usage plugin’s read-only operation; provider credentials never reach the phone. A missing/denied plugin does not hide independent Gateway accounting. DeepSeek offers balance only; missing details are not shown as zero.

Gateway accounting uses `sessions.usage`, `agentScope: all` and UTC 7/30/90-day ranges, displaying every visible recorded model’s input/output/cache tokens and estimated USD cost, rather than the old plugin’s top-eight list from a single provider. Only recorded usage accessible to the current identity is included, not unused models. Limited session rows do not limit aggregate totals. Partial/stale/computing results and missing cost estimates are flagged. Subscription resets use device local time. Refresh is manual: no background polling, cross-Gateway aggregation, or provider-key requests.

## Received assistant attachments

0.1.23 (24) parses real delivery-mirror `type: attachment` blocks with nested `attachment` metadata and label-based filenames. File cards open a native download page and the system share sheet for saving to Files; image attachments remain images. A subscribed `session.message` refreshes current chat history without waiting for the entire run to finish.

Downloads request fresh `artifacts.download` HTTP transport grants and accept only controlled attachment-download paths on the configured Gateway origin, never cross-origin credentials or redirects. Transfers stream into isolated temporary directories with a 100 MB limit; size mismatches, quota/permission failures and retired sessions/connections fail without sharing partial files. Files are never installed, extracted or automatically renamed from ZIP to IPA. Gateway ZIP filenames remain unchanged. Saving to Files uses the iOS system share sheet; physical iPhone testing remains pending.

## OpenClaw conversation interactions

- Initial conversation synchronization keeps existing history visible, shows sync status in the header and composer, and pauses sending. After failure, Sync again re-establishes the message subscription and reloads history.
- The attachment panel uses the same three DSH tiles: photos/videos, camera, and files, while retaining OpenClaw size limits and connection ownership checks. Unsupported Gateway permission and plan-mode controls are omitted.
- Models are grouped by provider in two-column cards. The current model determines the initial group; selection follows the server session.
- Tap the conversation title for trajectory, changes, files, progress, and context sections. Statistics reflect loaded history only; unrecorded durations and diffs are not inferred. File references are not a workspace listing.
