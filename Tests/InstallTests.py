#!/usr/bin/python3
"""Installer regression tests use only a fresh system-temporary directory."""
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import shutil
import importlib.util
from unittest import mock

PROJECT = Path(__file__).resolve().parent.parent
INSTALL = PROJECT / "Scripts/install.sh"
FINALIZE = PROJECT / "Scripts/finalize-install.sh"
BUNDLE = "com.gaoseries.GaoWenJian"


def invoke(command, expected=0):
    result = subprocess.run([str(item) for item in command], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert result.returncode == expected, result.stdout + result.stderr
    return result.stdout


def fixture(path, version, payload, bundle=BUNDLE):
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle, "CFBundleExecutable": "GaoWenJian",
        "CFBundleShortVersionString": version, "CFBundleVersion": str(int(round(float(version) * 100)) - 99)
    }))
    (path / "Contents/MacOS/GaoWenJian").write_bytes(payload)
    (path / "Contents/MacOS/GaoWenJian").chmod(0o755)


def main():
    spec = importlib.util.spec_from_file_location("install_safety", PROJECT / "Scripts/install_safety.py")
    installer = importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)
    own = "bundle id: fixture\npath: /tmp/previous.app (0x123)\nidentifier: " + BUNDLE + "\n"
    other = "bundle id: other\npath: /tmp/other.app (0x124)\nidentifier: com.example.Other\n"
    assert installer.registered_paths(own + other) == {"/tmp/previous.app"}
    with mock.patch.object(installer, "run", return_value=other) as command:
        installer.register(Path("/tmp/previous.app"), False, remove=True)
        assert command.call_count == 1  # Unregistered transaction copy: query only.
    with mock.patch.object(installer, "run", side_effect=[own, ""]) as command:
        installer.register(Path("/tmp/previous.app"), False, remove=True)
        assert command.call_args_list[-1].args[0] == [installer.LSREGISTER, "-u", "/tmp/previous.app"]
    with mock.patch.object(installer, "run", side_effect=[own, RuntimeError("cannot unregister")]):
        try: installer.register(Path("/tmp/previous.app"), False, remove=True)
        except RuntimeError: pass
        else: raise AssertionError("A real registration failure must stop cleanup")
    try: installer.registered_paths("")
    except RuntimeError: pass
    else: raise AssertionError("Unreadable registry must not become empty")
    root = Path(tempfile.mkdtemp(prefix="GaoFiles-InstallTests-")).resolve()
    try:
        source = root / "new/搞文件.app"
        fixture(source, "1.00", b"initial candidate")
        target = root / "Applications/搞文件.app"
        data = root / "UserData"
        preferences = root / "Preferences.plist"
        backups = root / "Backups"
        args = [INSTALL, "--app", source, "--target", target, "--data-root", data,
                "--preferences", preferences, "--backup-root", backups, "--defer-cleanup", "--simulate"]

        def install():
            output = invoke(args)
            return Path(next(line[len("MANIFEST="):] for line in output.splitlines() if line.startswith("MANIFEST=")))

        # First install explicitly records missing data and preferences.
        manifest_path = install()
        manifest = json.loads(manifest_path.read_text())
        assert manifest["state"] == "installed_pending_verification"
        assert manifest["backups"]["data"]["inventory"]["state"] == "missing"
        assert manifest["backups"]["preferences"]["inventory"]["state"] == "missing"
        invoke([FINALIZE, "--manifest", manifest_path, "--rollback"])
        assert not target.exists()
        assert not Path(manifest["stage_dir"]).exists()
        assert manifest_path.exists()

        # Verify a successful first install removes staging, and keeps the manifest.
        manifest_path = install()
        manifest = json.loads(manifest_path.read_text())
        invoke([FINALIZE, "--manifest", manifest_path, "--verified"])
        assert target.exists() and not Path(manifest["stage_dir"]).exists()
        assert json.loads(manifest_path.read_text())["state"] == "verified"

        # An update backs up attachments and preferences byte-for-byte.
        (data / "attachments/nested").mkdir(parents=True)
        (data / "database.sqlite").write_bytes(b"actual database\x00\x01")
        (data / "attachments/nested/图片.png").write_bytes(bytes(range(256)))
        prefs = plistlib.dumps({"fontSize": 17, "privateSetting": "kept local"})
        preferences.write_bytes(prefs)
        shutil.rmtree(source)
        fixture(source, "1.01", b"updated candidate")
        manifest_path = install()
        manifest = json.loads(manifest_path.read_text())
        previous = Path(manifest["stage_dir"]) / "previous.app"
        assert previous.exists()
        assert (previous / "Contents/MacOS/GaoWenJian").read_bytes() == b"initial candidate"
        backup_data = Path(manifest["backups"]["data"]["backup_path"])
        assert (backup_data / "database.sqlite").read_bytes() == (data / "database.sqlite").read_bytes()
        assert (backup_data / "attachments/nested/图片.png").read_bytes() == bytes(range(256))
        assert Path(manifest["backups"]["preferences"]["backup_path"]).read_bytes() == prefs
        invoke([FINALIZE, "--manifest", manifest_path, "--rollback"])
        assert (target / "Contents/MacOS/GaoWenJian").read_bytes() == b"initial candidate"
        assert preferences.read_bytes() == prefs and (data / "database.sqlite").exists()

        # Verification is explicit; a non-GUI update can require unchanged real data.
        manifest_path = install()
        manifest = json.loads(manifest_path.read_text())
        (data / "database.sqlite").write_bytes(b"concurrent data change")
        invoke([FINALIZE, "--manifest", manifest_path, "--verified", "--require-unchanged-data"], expected=1)
        assert (Path(manifest["stage_dir"]) / "previous.app").exists()
        (data / "database.sqlite").write_bytes(b"actual database\x00\x01")
        invoke([FINALIZE, "--manifest", manifest_path, "--verified", "--require-unchanged-data", "--verification-note", "isolated tests and static install verification; no smoke test"])
        checked = json.loads(manifest_path.read_text())
        assert checked["unchanged_data_verified"] is True and "no smoke test" in checked["verification_note"]
        assert not Path(manifest["stage_dir"]).exists()
        assert Path(manifest["backups"]["data"]["backup_path"]).exists()
        assert (target / "Contents/MacOS/GaoWenJian").read_bytes() == b"updated candidate"

        # Wrong bundle IDs, damaged backups and unresolved attachments cannot be cleared.
        bad = root / "bad/搞文件.app"
        fixture(bad, "1.02", b"unrelated", bundle="com.example.OtherApp")
        bad_args = list(args); bad_args[bad_args.index("--app") + 1] = bad
        invoke(bad_args, expected=1)
        assert (target / "Contents/MacOS/GaoWenJian").read_bytes() == b"updated candidate"
        (data / "unresolved-attachment").symlink_to(root / "missing-attachment")
        invoke(args, expected=1)
        assert (target / "Contents/MacOS/GaoWenJian").read_bytes() == b"updated candidate"
        (data / "unresolved-attachment").unlink()
        manifest_path = install()
        manifest = json.loads(manifest_path.read_text())
        (Path(manifest["backups"]["data"]["backup_path"]) / "database.sqlite").write_bytes(b"damaged backup")
        invoke([FINALIZE, "--manifest", manifest_path, "--verified"], expected=1)
        assert (Path(manifest["stage_dir"]) / "previous.app").exists()
        print("Install tests passed: missing records, initial install, update backups, nested attachments, preferences, rollback, verified cleanup, wrong bundle rejection, unresolved data rejection and damaged backup protection.")
    finally:
        shutil.rmtree(root)


if __name__ == "__main__":
    main()
