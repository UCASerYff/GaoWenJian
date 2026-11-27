"""Install the release package into temporary paths and verify the frozen APIs."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path
from urllib.error import URLError
from urllib.request import ProxyHandler, Request, build_opener


def run_installer(executable: Path, *options: str) -> None:
    subprocess.run([str(executable), "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", *options],
                   check=True, timeout=150, creationflags=subprocess.CREATE_NO_WINDOW)


def verify_checksum(installer: Path) -> None:
    expected = Path(str(installer) + ".sha256").read_text(encoding="utf-8").split()[0]
    with installer.open("rb") as handle:
        assert hashlib.file_digest(handle, "sha256").hexdigest() == expected


@contextmanager
def running_app(cli: Path, profile: Path):
    with subprocess.Popen([str(cli), "--no-browser", "--data-dir", str(profile)],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                          creationflags=subprocess.CREATE_NO_WINDOW) as child:
        try:
            yield child, _connect(child)
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=15)


def smoke(installer: Path, *, native: bool = False, tray: bool = False, provider: Path | None = None,
          previous: Path | None = None, evidence: Path | None = None) -> None:
    verify_checksum(installer)
    target = re.fullmatch(r"GaoWenJian-Windows-(\d+\.\d+)-build(\d+)-x64-Setup\.exe", installer.name)
    assert target, f"Unexpected setup name: {installer.name}"
    marketing, build = target.groups()
    with tempfile.TemporaryDirectory(prefix="gao-wenjian-installed-") as temporary:
        root = Path(temporary)
        program = root / "程序"
        profile = root / "旧资料"
        profile.mkdir()
        old_settings = {"appearance": "dark", "latexEngine": "auto", "futureWindowsSetting": {"keep": True}}
        (profile / "settings.json").write_text(json.dumps(old_settings), encoding="utf-8")
        (profile / "workspace.json").write_text(json.dumps({"recent": [], "folder": None, "futureField": 7}), encoding="utf-8")
        (profile / "recovery.json").write_text(json.dumps([{"id": "whats-new", "kind": "markdown", "text": "旧版本恢复稿", "encoding": 4}]), encoding="utf-8")
        cli = program / "GaoWenJian-cli.exe"
        note_id = None
        if previous:
            verify_checksum(previous)
            run_installer(previous, "/SP-", "/GAOISOLATED=1", f"/DIR={program}", f"/LOG={root / 'setup-old.log'}")
            previous_marketing, previous_build = subprocess.check_output([str(cli), "--version"], text=True, timeout=15).strip().split("+")
            assert previous_marketing == marketing and int(previous_build) < int(build)
            with running_app(cli, profile) as (child, app):
                old = app("api/state")
                assert old["tabs"][0]["text"] == "旧版本恢复稿"
                note_id = app("api/notes/create", {"title": "上一版便笺"})["result"]["id"]
                app("api/notes/update", {"id": note_id, "html": "<b>待复核</b>", "plain": "待复核"})
                attachment = root / "旧便笺附件.txt"
                attachment.write_text("隔离升级样本", encoding="utf-8")
                app("api/notes/attach", {"id": note_id, "path": str(attachment)})
                app("api/shutdown", {"force": True})
                assert child.wait(timeout=20) == 0

        run_installer(installer, "/SP-", "/GAOISOLATED=1", f"/DIR={program}", f"/LOG={root / 'setup.log'}")
        assert subprocess.check_output([str(cli), "--version"], text=True, timeout=15).strip() == f"{marketing}+{build}"
        for selector_resource in ("_tcl_data/init.tcl", "_tk_data/tk.tcl"):
            assert (program / "_internal" / selector_resource).is_file(), "Browser file picker resources missing"
        with running_app(cli, profile) as (child, app):
            _check_app(app, root, profile, note_id)
            app("api/shutdown", {})
            assert child.wait(timeout=20) == 0
        scripts = Path(__file__).resolve().parent
        capture = [str(evidence.resolve())] if evidence else []
        if native:
            subprocess.run(["node", str(scripts / "native_desktop_smoke.mjs"), str(cli), *capture], check=True, timeout=150)
        if tray:
            subprocess.run(["node", str(scripts / "tray_desktop_smoke.mjs"), str(program / "GaoWenJian.exe"),
                            sys.executable, *capture], check=True, timeout=240)
        if provider:
            subprocess.run([sys.executable, str(scripts / "ocr_interop_smoke.py"), "--provider-setup", str(provider),
                            "--client-cli", str(cli)], check=True, timeout=180)
        run_installer(program / "unins000.exe")
        for name in ("GaoWenJian.exe", "GaoWenJian-cli.exe"):
            assert not (program / name).exists(), f"Uninstall did not remove {name}"
        assert (profile / "settings.json").is_file() and (root / "保存后的旧稿.md").is_file()
    print("installed smoke OK: SHA-256, version, old profile, offline TeX/PDF, save, shutdown, uninstall"
          + (", in-place upgrade with notes and attachments" if previous else ""))


def _connect(child):
    url = child.stdout.readline().strip()
    assert url.startswith("http://127.0.0.1:"), url
    opener = build_opener(ProxyHandler({}))
    for _ in range(40):
        try:
            html = opener.open(url, timeout=3).read().decode("utf-8")
            break
        except URLError:
            time.sleep(.1)
    else:
        raise AssertionError("Frozen workspace did not respond")
    token = re.search(r'name="gao-token" content="([^"]+)"', html)[1]
    headers = {"X-Gao-Token": token, "Content-Type": "application/json"}

    def app(path: str, body=None, *, binary=False):
        payload = None if body is None else json.dumps(body, ensure_ascii=False).encode()
        with opener.open(Request(url + path, headers=headers, data=payload), timeout=75) as response:
            return response.read() if binary else json.load(response)

    return app


def _check_app(app, root: Path, profile: Path, note_id: str | None) -> None:
    before = app("api/state")
    assert before["tabs"][0]["text"] == "旧版本恢复稿" and before["tabs"][0]["restored"]
    assert before["settings"]["appearance"] == "dark" and before["engines"]["tectonic"]
    if note_id:
        note = next(item for item in before["notes"]["notes"] if item["id"] == note_id)
        assert note["title"] == "上一版便笺" and note["plainText"] == "待复核"
        assert note["attachments"] == ["旧便笺附件.txt"]
    destination = root / "保存后的旧稿.md"
    app("api/tabs/save", {"id": "whats-new", "path": str(destination)})
    assert destination.read_text(encoding="utf-8") == "旧版本恢复稿"
    app("api/settings", {"editorFontSize": 18})
    current_settings = json.loads((profile / "settings.json").read_text(encoding="utf-8"))
    assert current_settings["futureWindowsSetting"] == {"keep": True}
    assert current_settings["editorFontSize"] == 18
    assert json.loads((profile / "workspace.json").read_text(encoding="utf-8"))["futureField"] == 7
    source = root / "离线编译.tex"
    source.write_text(r"\documentclass{article}" "\n" r"\begin{document}" "\n" r"$x^2+\frac{1}{2}$" "\n" r"\end{document}", encoding="utf-8")
    tab = app("api/tabs/open", {"path": str(source)})["result"]["id"]
    compile_result = app("api/tabs/compile", {"id": tab})["result"]
    assert compile_result["success"], compile_result
    assert app(f"api/latex/document?tab={tab}", binary=True).startswith(b"%PDF")
    assert app(f"api/latex/page?tab={tab}&page=0", binary=True).startswith(b"\x89PNG")
    fallback = app("api/tabs/new", {"kind": "latex"})
    fallback_id = fallback["result"]["id"]
    template = next(item["text"] for item in fallback["state"]["tabs"] if item["id"] == fallback_id)
    template = template.replace("Microsoft YaHei", "Missing Fixture Font A").replace("SimSun", "Missing Fixture Font B")
    app("api/tabs/edit", {"id": fallback_id, "text": template})
    app("api/tabs/save", {"id": fallback_id, "path": str(root / "缺少中文系统字体.tex")})
    fallback_result = app("api/tabs/compile", {"id": fallback_id})["result"]
    assert fallback_result["success"], fallback_result
    assert app(f"api/latex/document?tab={fallback_id}", binary=True).startswith(b"%PDF")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("installer", type=Path)
    parser.add_argument("--native", action="store_true", help="test hidden WebView2 windows using Node.js 24")
    parser.add_argument("--tray", action="store_true", help="test the installed GUI and Win32 tray on an inactive desktop")
    parser.add_argument("--ocr-provider", type=Path)
    parser.add_argument("--previous", type=Path, help="install the previous build first to verify an in-place upgrade")
    parser.add_argument("--evidence", type=Path, help="save screenshots from --native or --tray")
    args = parser.parse_args()
    smoke(args.installer.resolve(strict=True), native=args.native, tray=args.tray, provider=args.ocr_provider,
          previous=args.previous.resolve(strict=True) if args.previous else None, evidence=args.evidence)
