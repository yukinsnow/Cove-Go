"""Runner-generation regressions; run: python3 -m unittest tooling/test_ios_platform_setup.py."""
import importlib.util
import plistlib
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('ios_platform', ROOT / 'tooling/setup-ios-platform.py')
platform = importlib.util.module_from_spec(spec)
spec.loader.exec_module(platform)


class PlatformSetupTests(unittest.TestCase):
    def test_repeated_install_keeps_one_registration_and_notification_delegate(self):
        with tempfile.TemporaryDirectory() as folder:
            runner = Path(folder)
            app = runner / 'AppDelegate.swift'
            app.write_text('import Flutter\nclass AppDelegate {\nfunc setup() {\n'
                           + platform.NEEDLE + '}\n}\n')
            plist = runner / 'Info.plist'
            plist.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'io.github.yukinsnow.dshApp'}))
            for _ in range(2):
                subprocess.run(['python3', str(ROOT / 'tooling/setup-ios-notifications.py'), str(runner)],
                               check=True, capture_output=True)
                platform.install(runner)
                platform.install(runner)
            source = app.read_text()
            self.assertEqual(source.count(platform.REGISTRATION), 1)
            self.assertEqual(source.count('final class CovePlatformChannels:'), 1)
            self.assertEqual(source.count('final class CoveNotifications:'), 1)
            self.assertEqual(source.count('UNUserNotificationCenter.current().delegate ='), 1)
            self.assertNotIn('EngineChannel(', source)
            info = plistlib.loads(plist.read_bytes())
            self.assertEqual(info['CFBundleIdentifier'], 'io.github.yukinsnow.dshApp')
            self.assertTrue(info['UIFileSharingEnabled'])
            self.assertTrue(info['LSSupportsOpeningDocumentsInPlace'])
            self.assertIn('NSSpeechRecognitionUsageDescription', info)
            self.assertNotIn('UIBackgroundModes', info)

    def test_unknown_template_fails_without_changing_runner(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / 'AppDelegate.swift'
            app.write_text('unknown template')
            with self.assertRaisesRegex(ValueError, 'Unrecognized AppDelegate'):
                platform.install(Path(folder))
            self.assertEqual(app.read_text(), 'unknown template')


if __name__ == '__main__':
    unittest.main()
