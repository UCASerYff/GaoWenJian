import hashlib
import json
import os
import re
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path
from urllib.request import ProxyHandler, Request, build_opener

import pytest

LAUNCHER = Path(__file__).resolve().parents[1] / "launch.py"
BACKGROUND_PROCESS = getattr(subprocess, "CREATE_NO_WINDOW", 0)
# Enter the real startup path for each mode but host any resulting workspace
# without creating a user-visible desktop window.
ISOLATED_LAUNCHER = """
import json
import sys
import threading
from gaowenjian import cli
run = cli._run
def run_headless(args, directory, tray):
    if tray is not None:
        def log_activation():
            while (activation := tray.events.get()) is not None:
                print('activated=' + json.dumps(activation[1]), flush=True)
        threading.Thread(target=log_activation, daemon=True).start()
    args.no_browser = True
    return run(args, directory, tray)
cli._run = run_headless
sys.frozen = True
sys.executable = 'GaoWenJian-cli.exe'
raise SystemExit(cli.main())
"""


@pytest.fixture
def environment(tmp_path):
    roaming = tmp_path / "roaming"
    env = {**os.environ, "APPDATA": str(roaming), "LOCALAPPDATA": str(tmp_path / "local"),
           "XDG_DATA_HOME": str(roaming), "PYTHONPATH": str(LAUNCHER.parent / "src"), "PYTHONUTF8": "1"}
    return env, roaming / "GaoSeries" / "GaoWenJian"


def command(*args, never_show=False):
    launcher = ["-c", ISOLATED_LAUNCHER] if never_show else [str(LAUNCHER)]
    return [sys.executable, *launcher, *map(str, args)]


def invoke(env, *args, never_show=False):
    return subprocess.run(command(*args, never_show=never_show), env=env, capture_output=True, text=True,
                          encoding="utf-8", timeout=20, creationflags=BACKGROUND_PROCESS)


@contextmanager
def serve_cli(tmp_path, env, *args, never_show=False):
    log = tmp_path / "owner.log"
    with log.open("wb") as output, subprocess.Popen(command(*args, never_show=never_show), env=env, stdout=output,
                                                     stderr=subprocess.STDOUT, creationflags=BACKGROUND_PROCESS) as process:
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                text = log.read_text(encoding="utf-8")
                if url := re.search(r"^http://127\.0\.0\.1:\d+/", text, re.MULTILINE):
                    break
                if process.poll() is not None:
                    pytest.fail(f"Workspace exited during startup\n{text}")
                time.sleep(.025)
            else:
                pytest.fail(f"Workspace did not start\n{text}")
            opener = build_opener(ProxyHandler({}))
            address = url.group()
            with opener.open(address, timeout=5) as response:
                token = re.search(r'name="gao-token" content="([^"]+)"', response.read().decode("utf-8"))[1]

            def request(path, body=None):
                data = None if body is None else json.dumps(body).encode("utf-8")
                headers = {"X-Gao-Token": token, "Content-Type": "application/json"}
                with opener.open(Request(address + "api/" + path, data, headers), timeout=5) as response:
                    return json.load(response)

            yield request
            request("shutdown", {"force": True})
            assert process.wait(timeout=10) == 0
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)


def test_inspect_is_read_only_and_rejects_open(environment, tmp_path):
    env, profile = environment
    original = tmp_path / "original.md"
    original.write_text("# private fixture", encoding="utf-8")
    inspection = invoke(env, "--inspect")
    assert inspection.returncode == 0 and "dirty=0" in inspection.stdout
    assert not profile.exists()
    rejected = invoke(env, "--inspect", "--open", original)
    assert rejected.returncode == 2 and "--open" in rejected.stderr
    assert not profile.exists()


def test_self_check_never_touches_explicit_or_default_profile(environment):
    env, profile = environment
    assert invoke(env, "--self-check").returncode == 0
    assert not profile.exists()
    profile.mkdir(parents=True)
    record = profile / "recovery.json"
    recovery = b'[{"id":"synthetic","kind":"markdown","text":"keep original draft"}]'
    record.write_bytes(recovery)
    for options in [[], ["--data-dir", profile]]:
        checked = invoke(env, "--self-check", *options)
        assert checked.returncode == 0 and "self-check ok" in checked.stdout
        assert list(profile.iterdir()) == [record] and record.read_bytes() == recovery
    result = invoke(env, "--inspect")
    assert result.returncode == 0 and "tabs=1" in result.stdout and "dirty=1" in result.stdout
    assert list(profile.iterdir()) == [record] and record.read_bytes() == recovery


@pytest.mark.skipif(os.name != "nt", reason="requires Windows activation namespaces")
@pytest.mark.parametrize("owner_mode", ["--no-browser", "--hidden", "--serve"])
def test_writable_modes_share_default_profile_and_fail_without_forwarding(environment, tmp_path, owner_mode):
    env, profile = environment
    fixture = tmp_path / "must-not-open.md"
    fixture.write_text("# no second writer", encoding="utf-8")
    with serve_cli(tmp_path, env, owner_mode, never_show=owner_mode != "--no-browser") as owner:
        assert owner("state")["tabs"] == []
        for mode in ["--no-browser", "--hidden", "--serve", "--port"]:
            args = [mode] if mode != "--port" else [mode, "1"]
            contender = invoke(env, *args, "--data-dir", profile / ".." / profile.name, "--open", fixture, never_show=True)
            assert contender.returncode == 2, contender.stdout + contender.stderr
            assert "另一个搞文件进程" in contender.stderr and "http://" not in contender.stdout
        assert owner("state")["tabs"] == []
        assert owner("state")["recent"] == []
    with serve_cli(tmp_path, env, "--no-browser", "--open", fixture) as new_owner:
        assert new_owner("state")["tabs"][0]["path"] == str(fixture)


@pytest.mark.skipif(os.name != "nt", reason="requires Windows activation window")
def test_ordinary_activation_can_forward_but_requested_port_cannot(environment, tmp_path):
    env, _ = environment
    fixture = tmp_path / "ordinary.md"
    fixture.write_text("# forward this path", encoding="utf-8")
    with serve_cli(tmp_path, env, never_show=True):
        duplicate = invoke(env, "--open", fixture, never_show=True)
        assert duplicate.returncode == 0, duplicate.stdout + duplicate.stderr
        service_request = invoke(env, "--port", "1", "--open", fixture, never_show=True)
        assert service_request.returncode == 2 and "另一个搞文件进程" in service_request.stderr
        log = (tmp_path / "owner.log").read_text(encoding="utf-8").splitlines()
        assert [json.loads(line.removeprefix("activated=")) for line in log if line.startswith("activated=")] == [str(fixture)]


@pytest.mark.skipif(os.name != "nt", reason="requires Windows activation namespaces")
@pytest.mark.parametrize("namespace, use_event", [("Global", False), ("Local", False), ("Global", True)])
def test_profile_fails_closed_for_global_legacy_local_and_incompatible_object(environment, namespace, use_event):
    import ctypes
    from ctypes import wintypes as types

    env, profile = environment
    identity = hashlib.sha256(os.path.normcase(str(profile.resolve())).encode()).hexdigest()
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    create = kernel.CreateMutexW
    create.argtypes, create.restype = (types.LPVOID, types.BOOL, types.LPCWSTR), types.HANDLE
    create_event = kernel.CreateEventW
    create_event.argtypes, create_event.restype = (types.LPVOID, types.BOOL, types.BOOL, types.LPCWSTR), types.HANDLE
    release = kernel.ReleaseMutex
    release.argtypes, release.restype = (types.HANDLE,), types.BOOL
    close = kernel.CloseHandle
    close.argtypes, close.restype = (types.HANDLE,), types.BOOL
    name = f"{namespace}\\GaoWenJian-{identity}"
    handle = create_event(None, True, True, name) if use_event else create(None, True, name)
    assert handle
    try:
        contender = invoke(env, "--no-browser")
        assert contender.returncode == 2
        assert contender.stderr and (use_event or "另一个搞文件进程" in contender.stderr)
        assert not profile.exists(), "contention must be detected before Workspace initialization"
    finally:
        if not use_event:
            release(handle)
        close(handle)


@pytest.mark.skipif(os.name == "nt", reason="requires the POSIX browser launcher")
def test_posix_service_uses_the_same_profile_exclusively(environment, tmp_path):
    env, profile = environment
    with serve_cli(tmp_path, env, "--no-browser"):
        contender = invoke(env, "--no-browser", "--data-dir", profile)
        assert contender.returncode == 2 and "另一个搞文件进程" in contender.stderr
    with serve_cli(tmp_path, env, "--no-browser") as restarted:
        assert restarted("state")["tabs"] == []
