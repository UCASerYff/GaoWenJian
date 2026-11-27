"""Run the real GaoCaoZuo setup and round-trip a scanned PDF and PNG with GaoWenJian."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener

from PIL import Image, ImageDraw, ImageFont


class Workbench:
    def __init__(self, url, token):
        self.url = url
        self.token = token
        self.session = build_opener(ProxyHandler({}))

    def post(self, path, value):
        request = Request(self.url + path, data=json.dumps(value).encode(),
                          headers={"X-Gao-Token": self.token, "Content-Type": "application/json"})
        try:
            with self.session.open(request, timeout=180) as response:
                return json.load(response)
        except HTTPError as exc:
            raise RuntimeError(f"{path}: {exc.read().decode('utf-8', errors='replace')}") from exc

    def call(self, path, value):
        return self.post(path, value)["result"]


@contextmanager
def serve(cli, data, *, package=None):
    stdout_path = data.with_suffix(".out")
    stderr_path = data.with_suffix(".err")
    data.mkdir()
    command = [*cli, "--no-browser", "--port", "0", "--data-dir", str(data)]
    if package:
        command += ["--gaoaction", str(package)]
    with stdout_path.open("wb") as output, stderr_path.open("wb") as errors:
        process = subprocess.Popen(command, stdout=output, stderr=errors, creationflags=subprocess.CREATE_NO_WINDOW)
        workbench = None
        try:
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                logged = stdout_path.read_bytes()
                urls = re.findall(rb"http://127\.0\.0\.1:\d+/", logged)
                if urls:
                    url = urls[0].decode("ascii")
                    response = build_opener(ProxyHandler({})).open(url, timeout=15)
                    token = re.search(rb'name="gao-token" content="([^"]+)"', response.read())[1].decode("ascii")
                    workbench = Workbench(url, token)
                    break
                if process.poll() is not None:
                    break
                time.sleep(0.2)
            if not workbench:
                raise RuntimeError(f"Workbench did not start, code={process.poll()}. {stderr_path.read_text(encoding='utf-8', errors='replace')}")
            yield workbench
        finally:
            try:
                if workbench and process.poll() is None:
                    workbench.post("api/shutdown", {"force": True})
                    process.wait(timeout=20)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=15)


def create_fixtures(folder: Path) -> list[Path]:
    font = ImageFont.truetype(str(Path(os.environ["WINDIR"]) / "Fonts" / "arial.ttf"), 86)
    paths = [folder / "image.png", folder / "scan.pdf"]
    for path, text in zip(paths, ("12345 67890", "98765 43210"), strict=True):
        image = Image.new("RGB", (1220, 320), "white")
        ImageDraw.Draw(image).text((74, 100), text, fill="black", font=font)
        image.save(path, resolution=120)
    return paths


def verify_setup(archive: Path) -> None:
    with archive.open("rb") as stream:
        sha = hashlib.file_digest(stream, "sha256").hexdigest()
    assert sha == archive.with_suffix(archive.suffix + ".sha256").read_text(encoding="utf-8-sig").split()[0].lower()


def main() -> None:
    options = argparse.ArgumentParser()
    options.add_argument("--provider-setup", type=Path, required=True)
    options.add_argument("--client-cli", type=Path)
    args = options.parse_args()
    args.provider_setup = args.provider_setup.resolve(strict=True)
    verify_setup(args.provider_setup)
    with tempfile.TemporaryDirectory(prefix="GaoWenJian-ocr-smoke-") as directory:
        root = Path(directory)
        target = root / "isolated provider"
        subprocess.run([str(args.provider_setup), "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART",
                        "/SP-", "/ISOLATEDSMOKE=1", f"/DIR={target}"],
                       check=True, timeout=140, creationflags=subprocess.CREATE_NO_WINDOW)
        provider_cli = target / "GaoCaoZuo-cli.exe"
        capability = json.loads(subprocess.check_output([str(provider_cli), "--capabilities"],
                                                        creationflags=subprocess.CREATE_NO_WINDOW, timeout=30))
        assert capability["bundleID"] == "com.gaoseries.GaoCaoZuo"
        assert any(item["action"] == "ocr.files" for item in capability["actions"])

        files = create_fixtures(root)
        cli = [str(args.client_cli)] if args.client_cli else [sys.executable, str(Path(__file__).parents[1] / "launch.py")]
        with serve(cli, root / "client data") as client:
            request = client.call("api/handoff/ocr", {"confirm": True, "paths": [str(path) for path in files],
                                                      "outputs": ["text", "markdown", "json", "searchablePDF"]})
            with serve([str(provider_cli)], root / "provider data", package=request["path"]) as workbench:
                languages = workbench.call("api/screenshot/ocr/languages", {})["languages"]
                assert languages, "No Windows OCR language is installed"
                jobs = workbench.call("api/ocr-provider/jobs", {})["jobs"]
                assert any(job["requestID"] == request["requestID"] and job["status"] == "pending" for job in jobs)
                approved = workbench.call("api/ocr-provider/approve", {"requestID": request["requestID"], "confirm": True})
                assert approved["status"] == "completed", approved
                assert approved["resultCount"] == 8
                result = workbench.call("api/ocr-provider/result", {"requestID": request["requestID"],
                                         "directory": str(root), "confirm": True})
                review = client.call("api/handoff/inspect", {"path": result["path"]})
                accepted = client.post("api/handoff/import", {"path": result["path"], "sha256": review["sha256"]})
                tabs = accepted["state"]["tabs"]
                assert len(tabs) == 8 and sum(tab["kind"] == "pdf" for tab in tabs) == 2
                assert all(tab["incoming"]["inReplyTo"] == request["requestID"] for tab in tabs)
                assert all(tab["incoming"]["status"] == "completed" for tab in tabs)
                actual_text = "".join("".join(tab["text"].split()) for tab in tabs if tab["title"].endswith(".txt"))
                assert "1234567890" in actual_text and "9876543210" in actual_text, actual_text
                assert all(len(tab["preview"]["pages"]) == 1 for tab in tabs if tab["kind"] == "pdf")
                repeated = workbench.call("api/ocr-provider/result", {"requestID": request["requestID"],
                                          "directory": str(root), "confirm": True})
                try:
                    client.post("api/handoff/import", {"path": repeated["path"]})
                except RuntimeError as exc:
                    assert '"code": "duplicate"' in str(exc), exc
                else:
                    raise AssertionError("Re-exported OCR result reopened existing tabs")
    print("OK · installed GaoCaoZuo capabilities, review, offline PNG/PDF OCR and verified GaoWenJian import (8 pieces).")


if __name__ == "__main__":
    main()
