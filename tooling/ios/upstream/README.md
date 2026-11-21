# Official iOS channels used by Cove-Go

Source: [ccch1mneyyy/dsh-Go](https://github.com/ccch1mneyyy/dsh-Go/tree/da798027013851328f83f59af4adb52c3afaab23/app/ios/Runner),
revision `da798027013851328f83f59af4adb52c3afaab23` (2026-11-21).
Copyright belongs to the original contributors; AGPL-3.0, as in the repository
root LICENSE. Exact source paths and upstream/local hashes: `provenance.json`.

`VoiceChannel.swift`, `IOSAudioSessionCoordinator.swift`,
`NativeFilesChannel.swift` and `NativeMediaChannel.swift` are unchanged copies.
`DshPlugin.swift` is adapted: replace the plugin registration with a retained
remote-only channel owner, omit links/shortcuts/icon/notification handlers, and
rename the saved-files display folder to Cove-Go. Keep the upstream file,
PDF, photo-saving and helper implementations.

The build installer appends these reviewed sources to the generated
AppDelegate (already compiled by Flutter). This avoids fragile Xcode project
UUID edits. Run it **after** the existing local-notification installer. It is
idempotent and refuses an unknown registration template. Existing Cove
notifications retain sole ownership of UNUserNotificationCenter's delegate.

This is not the upstream local engine, guest Linux, phone-control runner,
widget or share extension. Those require a separate integration, dependency
and signing review. No App Group, JIT or push entitlement is added. Ordinary
remote use remains supported with self-signing and iOS 15+.

Files are saved to the app's Documents folder with collision-safe names and
exposed through Files. Quick Look handles supported previews; other formats
use the system share sheet. Audio uses the upstream coordinated sessions and
system speech recognition. Permissions are requested by the relevant action,
not automatically at launch. These channels also serve the existing DSH UI;
this change does not add a new OpenClaw microphone composer.

Updating: compare the five exact source files at the new upstream revision,
reapply the registration/folder adaptations, update provenance hashes, run the
installer and Flutter tests, then compile on macOS and verify on an iPhone.
