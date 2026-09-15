import importlib.util
from pathlib import Path
import plistlib
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('installer', Path(__file__).parents[1] / 'scripts/install-local.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

class BackupTests(unittest.TestCase):
    def test_archive_preserves_bundle_bytes_and_symlinks(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / 'LiveCopilot.app.previous.test'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': installer.BUNDLE_ID}))
            (app / 'Contents/binary').write_bytes(bytes(range(256)) * 100)
            (app / 'Contents/link').symlink_to('binary')
            backup = installer.archive(app, root)
            self.assertTrue(backup.name.endswith('.tar.gz'))
            restored = root / 'restored'
            with tarfile.open(backup) as tar:
                # Archive consists solely of this test's generated files.
                tar.extractall(restored)
            self.assertEqual(installer.digest(app / 'Contents/binary'), installer.digest(restored / app.name / 'Contents/binary'))
            self.assertTrue((restored / app.name / 'Contents/link').is_symlink())
            self.assertTrue(app.exists(), 'archiving must not delete source')

    def test_unrelated_bundle_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / 'Other.app'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.example.other'}))
            with self.assertRaises(ValueError):
                installer.archive(app, Path(folder))

if __name__ == '__main__':
    unittest.main()
