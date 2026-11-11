"""Isolated installation policy checks. Never launches an app or touches real data."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.dont_write_bytecode = True
PROJECT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("install_safety", PROJECT / "Scripts/install_safety.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def fixture(path, version, payload, bundle=installer.BUNDLE):
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": bundle,
        "CFBundleExecutable": "GaoWenJian", "CFBundleShortVersionString": version, "CFBundleVersion": "12"}))
    executable = path / "Contents/MacOS/GaoWenJian"
    executable.write_bytes(payload)
    executable.chmod(0o755)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="gaowenjian-install-tests-", suffix=".noindex", dir="/private/tmp")
        self.root = Path(self.temporary.name).resolve()
        self.target = self.root / "Applications/搞文件.app"
        self.source = self.root / "New/搞文件.app"
        fixture(self.target, "1.10", b"old program")
        fixture(self.source, "1.11", b"new program")
        self.data = self.root / "UserData"
        (self.data / "StickyNotes/Attachments/nested").mkdir(parents=True)
        (self.data / "workspace.json").write_bytes(b'{"recovery":"unsaved"}')
        (self.data / "StickyNotes/Attachments/nested/image.png").write_bytes(bytes(range(256)))
        self.preferences = self.root / "Preferences.plist"
        self.preferences.write_bytes(plistlib.dumps({"fontSize": 17}))
        self.record = self.root / "installation.json"
        self.args = argparse.Namespace(app=str(self.source), target=str(self.target), data_root=str(self.data),
            preferences=str(self.preferences), record=str(self.record), simulate=True)
        self.before = installer.inventory(self.data)

    def tearDown(self):
        self.temporary.cleanup()

    def install(self):
        with contextlib.redirect_stdout(io.StringIO()):
            installer.install(self.args)
        return installer.load_manifest(self.record)

    def finalize(self):
        args = argparse.Namespace(manifest=str(self.record), verified=True, verification_note="isolated installation test; no app launch")
        with contextlib.redirect_stdout(io.StringIO()):
            installer.finalize(args)

    def test_update_preserves_real_data_and_removes_old_program_and_stage(self):
        record = self.install()
        self.assertEqual((self.target / "Contents/MacOS/GaoWenJian").read_bytes(), b"new program")
        self.assertEqual(installer.inventory(self.data), self.before)
        self.assertFalse(Path(record["stage_dir"]).exists())
        self.assertTrue(record["no_backups"])
        self.assertNotIn("backups", record)
        self.assertNotIn("retained_previous_program", record)
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ["Applications", "New", "Preferences.plist", "UserData", "installation.json"])
        self.assertNotIn(b"unsaved", self.record.read_bytes())
        self.finalize()
        final = installer.load_manifest(self.record)
        self.assertEqual(final["state"], "verified")
        self.assertTrue(final["unchanged_data_verified"])
        self.assertTrue(final["uniqueness"]["not_a_real_uniqueness_verification"])

    def test_first_install_records_missing_data_without_creating_blank_data(self):
        shutil.rmtree(self.target)
        shutil.rmtree(self.data)
        self.preferences.unlink()
        record = self.install()
        self.assertEqual(record["data_checks"]["data"]["inventory"]["state"], "missing")
        self.finalize()
        self.assertFalse(self.data.exists())
        self.assertFalse(self.preferences.exists())

    def test_unresolved_attachment_refuses_before_old_program_changes(self):
        (self.data / "lost-attachment").symlink_to(self.root / "missing")
        with self.assertRaisesRegex(RuntimeError, "符号链接"):
            self.install()
        self.assertEqual((self.target / "Contents/MacOS/GaoWenJian").read_bytes(), b"old program")
        self.assertFalse(any(self.target.parent.glob("*.noindex")))

    def test_changed_data_refuses_finalize_without_restoring_or_overwriting(self):
        self.install()
        changed = self.data / "workspace.json"
        changed.write_bytes(b"legitimate later edits")
        with self.assertRaisesRegex(RuntimeError, "摘要发生变化"):
            self.finalize()
        self.assertEqual(changed.read_bytes(), b"legitimate later edits")
        self.assertEqual(installer.load_manifest(self.record)["state"], "installed_pending_verification")
        self.assertEqual((self.target / "Contents/MacOS/GaoWenJian").read_bytes(), b"new program")

    def test_failure_after_replacement_keeps_candidate_without_rollback_copy(self):
        actual = installer.verify_candidate
        def verification(path, simulate):
            if path == self.target:
                raise RuntimeError("synthetic installed verification failure")
            actual(path, simulate)
        with patch.object(installer, "verify_candidate", side_effect=verification), self.assertRaisesRegex(RuntimeError, "synthetic installed"):
            self.install()
        self.assertEqual((self.target / "Contents/MacOS/GaoWenJian").read_bytes(), b"new program")
        self.assertEqual(installer.inventory(self.data), self.before)
        self.assertEqual(installer.load_manifest(self.record)["state"], "failed")
        self.assertFalse(any(self.target.parent.glob("*.noindex")))
        self.assertFalse(any(p.name in {"previous.app", "ProgramRecovery.noindex", "Backups"} for p in self.root.rglob("*")))

    def test_partial_copy_failure_cleans_only_exact_private_stage(self):
        def failed_copy(source, destination, **kwargs):
            destination.mkdir()
            (destination / "partial-resource").write_bytes(b"incomplete")
            raise RuntimeError("synthetic partial copy failure")
        with patch.object(installer.shutil, "copytree", side_effect=failed_copy), self.assertRaisesRegex(RuntimeError, "partial copy"):
            self.install()
        self.assertEqual((self.target / "Contents/MacOS/GaoWenJian").read_bytes(), b"old program")
        self.assertEqual(installer.inventory(self.data), self.before)
        self.assertFalse(any(self.target.parent.glob("*.noindex")))

    def test_wrong_bundle_and_indexed_source_refuse_without_modification(self):
        bad = self.root / "Bad/搞文件.app"
        fixture(bad, "1.11", b"other", bundle="com.example.Other")
        self.args.app = str(bad)
        with self.assertRaisesRegex(RuntimeError, "Bundle ID"):
            self.install()
        self.assertEqual((self.target / "Contents/MacOS/GaoWenJian").read_bytes(), b"old program")
        with self.assertRaisesRegex(RuntimeError, "noindex"):
            installer.require_private_noindex(Path("/Applications/Other.app"))

    def test_legacy_backup_record_cannot_execute(self):
        self.record.write_text(json.dumps({"format": 1, "bundle_id": installer.BUNDLE}))
        with self.assertRaisesRegex(RuntimeError, "历史记录不可"):
            installer.load_manifest(self.record)

    def test_unique_entry_requires_real_formal_path_in_both_sources(self):
        dump = "bundle id: 123\nidentifier: " + installer.BUNDLE + "\npath: /Applications/搞文件.app (0x123)\n"
        target = Path("/Applications/搞文件.app")
        with patch.object(installer, "run", side_effect=[dump, ""]), self.assertRaisesRegex(RuntimeError, "不能有重复或空结果"):
            installer.session_uniqueness(target)
        with patch.object(installer, "run", side_effect=[dump, str(target) + "\n/private/tmp/Other.app\n"]), self.assertRaisesRegex(RuntimeError, "不能有重复或空结果"):
            installer.session_uniqueness(target)
        with patch.object(installer, "run", side_effect=[dump, str(target) + "\n"]), patch.object(Path, "is_dir", return_value=True):
            self.assertEqual(installer.session_uniqueness(target)["spotlight"], [str(target)])

    def test_removed_backup_and_rollback_cli_options_refuse(self):
        for args in (["install", "--app", str(self.source), "--backup-root", str(self.root / "Backups")],
                     ["finalize", "--manifest", str(self.record), "--rollback"]):
            result = subprocess.run([sys.executable, str(PROJECT / "Scripts/install_safety.py"), *args], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((self.target / "Contents/MacOS/GaoWenJian").read_bytes(), b"old program")


if __name__ == "__main__":
    unittest.main(verbosity=2)
