import importlib.util
import os
from pathlib import Path
import plistlib
import tempfile
import unittest

SOURCE = Path(__file__).with_name("mac-cleanup.py")
spec = importlib.util.spec_from_file_location("pairbar_mac_cleanup", SOURCE)
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


def make_app(folder, bundle=cleanup.PAIRBAR_ID):
    plist = folder / "Contents" / "Info.plist"
    plist.parent.mkdir(parents=True)
    with plist.open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": bundle, "CFBundleShortVersionString": "2.0.1"}, stream)


class CleanupTests(unittest.TestCase):
    def test_only_old_known_builds_and_backups_are_candidates(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            make_app(home / "Applications" / "Pairbar.app")
            builds = home / "Library/Application Support/Pairbar Candidate Builds"
            older, newer = builds / "candidate.old", builds / "candidate.new"
            make_app(older / "Pairbar.app")
            make_app(newer / "Pairbar.app")
            os.utime(older, (100, 100))
            os.utime(newer, (200, 200))
            backups = home / "Library/Application Support/Pairbar Backups"
            original_old, original_new = backups / "original-app.old", backups / "original-app.new"
            make_app(original_old / "Pairbar.app")
            make_app(original_new / "Pairbar.app")
            os.utime(original_old, (100, 100))
            os.utime(original_new, (200, 200))
            (home / "Downloads").mkdir()
            (home / "Downloads/pairbar-work-probe.sh").write_text("safe test")
            items = {path for _, path in cleanup.safe_artifacts(home)}
            self.assertIn(older, items)
            self.assertNotIn(newer, items)
            self.assertIn(original_old, items)
            self.assertNotIn(original_new, items)
            self.assertIn(home / "Downloads/pairbar-work-probe.sh", items)
            self.assertNotIn(home / "Applications/Pairbar.app", items)
            self.assertFalse(any("Profiles" in str(p) for p in items))

    def test_installed_app_is_never_a_reviewed_duplicate(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            installed = home / "Applications/Pairbar.app"
            make_app(installed)
            with self.assertRaises(ValueError):
                cleanup.explicit_app(home, installed)
            nested = installed / "Contents" / "Resources" / "Another.app"
            make_app(nested)
            with self.assertRaises(ValueError):
                cleanup.explicit_app(home, nested)

    def test_trash_is_reversible_and_preserves_file_contents(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            original = home / "Downloads/pairbar-work-probe.sh"
            original.parent.mkdir()
            original.write_text("intact")
            self.assertEqual(cleanup.trash_batch(cleanup.safe_downloads(home), home), 0)
            self.assertFalse(original.exists())
            moved = list((home / ".Trash").glob("Pairbar-cleanup-*/01-pairbar-work-probe.sh"))
            self.assertEqual(len(moved), 1)
            self.assertEqual(moved[0].read_text(), "intact")


if __name__ == "__main__":
    unittest.main()
