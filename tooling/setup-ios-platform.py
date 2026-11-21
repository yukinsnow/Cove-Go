#!/usr/bin/env python3
"""Install the reviewed upstream remote-client channels into Flutter's runner.

Like setup-ios-notifications.py, use the already compiled AppDelegate file;
never depend on generated Xcode project UUIDs or duplicate plugin registration.
Run after setup-ios-notifications.py. No engine, App Groups or JIT entitlement.
"""
from pathlib import Path
import plistlib
import sys

ROOT = Path(__file__).resolve().parent.parent
SOURCES = (
    'DshPlugin.swift', 'PetOverlayAudioRecoveryState.swift',
    'IOSAudioSessionCoordinator.swift', 'VoiceChannel.swift',
    'NativeFilesChannel.swift', 'NativeMediaChannel.swift',
)
MARKER = '\n// BEGIN COVE IOS PLATFORM\n'
REGISTRATION = '''    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CovePlatformChannels") {
      CovePlatformChannels.register(with: registrar)
    }
'''
NEEDLE = '    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)\n'


def install(runner: Path) -> None:
    path = runner / 'AppDelegate.swift'
    source = path.read_text().split(MARKER)[0]
    if NEEDLE not in source:
        raise ValueError('Unrecognized AppDelegate registration; refusing replacement')
    if REGISTRATION not in source:
        source = source.replace(NEEDLE, NEEDLE + REGISTRATION, 1)
    source += MARKER + '\n'.join(
        (ROOT / 'tooling/ios/upstream' / name).read_text() for name in SOURCES
    )
    plist = runner / 'Info.plist'
    with plist.open('rb') as stream:
        info = plistlib.load(stream)
    info.update({
        'UIFileSharingEnabled': True,
        'LSSupportsOpeningDocumentsInPlace': True,
        'NSMicrophoneUsageDescription': 'Record voice input for your conversations in Cove-Go.',
        'NSSpeechRecognitionUsageDescription': 'Transcribe your voice into the Cove-Go message composer.',
        'NSPhotoLibraryAddUsageDescription': 'Save images and videos you choose from Cove-Go to Photos.',
    })
    path.write_text(source)
    with plist.open('wb') as stream:
        plistlib.dump(info, stream)


if __name__ == '__main__':
    install(Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'app/ios/Runner')
