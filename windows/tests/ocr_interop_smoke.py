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

    def get(self, path):
        request = Request(self.url + path, headers={"X-Gao-Token": self.token})
        with self.session.open(request, timeout=15) as response:
            return json.load(response)


@contextmanager
def serve(cli, data, *, local_appdata, package=None):
    stdout_path = data.with_suffix(".out")
    stderr_path = data.with_suffix(".err")
    data.mkdir()
    command = [*cli, "--no-browser", "--port", "0", "--data-dir", str(data)]
    if package:
        command += ["--gaoaction", str(package)]
    with stdout_path.open("wb") as output, stderr_path.open("wb") as errors:
        environment = {**os.environ, "LOCALAPPDATA": str(local_appdata), "PYTHONDONTWRITEBYTECODE": "1"}
        process = subprocess.Popen(command, stdout=output, stderr=errors, env=environment, creationflags=subprocess.CREATE_NO_WINDOW)
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
    provider = options.add_mutually_exclusive_group(required=True)
    provider.add_argument("--provider-setup", type=Path)
    provider.add_argument("--provider-source", type=Path, help="use the provider's source launch_cli.py and prebuilt native OCR helper")
    options.add_argument("--client-cli", type=Path)
    options.add_argument("--automatic", action="store_true", help="expect the provider to publish an automatic return before manual export")
    args = options.parse_args()
    with tempfile.TemporaryDirectory(prefix="GaoWenJian-ocr-smoke-") as directory:
        root = Path(directory)
        local_appdata = root / "LocalAppData"
        local_appdata.mkdir()
        if args.provider_setup:
            installer = args.provider_setup.resolve(strict=True)
            verify_setup(installer)
            target = root / "isolated provider"
            subprocess.run([str(installer), "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART",
                            "/SP-", "/ISOLATEDSMOKE=1", f"/DIR={target}"],
                           check=True, timeout=140, creationflags=subprocess.CREATE_NO_WINDOW)
            provider_cli = [str(target / "GaoCaoZuo-cli.exe")]
        else:
            provider_cli = [sys.executable, "-B", str(args.provider_source.resolve(strict=True))]
        capability = json.loads(subprocess.check_output([*provider_cli, "--capabilities"],
                                                        creationflags=subprocess.CREATE_NO_WINDOW, timeout=30))
        assert capability["bundleID"] == "com.gaoseries.GaoCaoZuo"
        assert any(item["action"] == "ocr.files" for item in capability["actions"])

        files = create_fixtures(root)
        original_digests = {file: hashlib.sha256(file.read_bytes()).hexdigest() for file in files}
        cli = [str(args.client_cli)] if args.client_cli else [sys.executable, str(Path(__file__).parents[1] / "launch.py")]
        with serve(cli, root / "client data", local_appdata=local_appdata) as client:
            request = client.call("api/handoff/ocr", {"confirm": True, "paths": [str(path) for path in files],
                                                      "outputs": ["text", "markdown", "json", "searchablePDF"]})
            assert request["returnEnabled"] is True
            slot = local_appdata / "GaoSeries" / "GaoAction" / "OcrReturns-v1" / request["requestID"]
            ticket = json.loads((slot / "request.json").read_text(encoding="utf-8"))
            assert ticket["requestManifestSHA256"] == hashlib.sha256((Path(request["path"]) / "manifest.json").read_bytes()).hexdigest()
            assert client.get("api/handoff/ocr-returns")["pending"]
            with serve(provider_cli, root / "provider data", local_appdata=local_appdata, package=request["path"]) as workbench:
                languages = workbench.call("api/screenshot/ocr/languages", {})["languages"]
                assert languages, "No Windows OCR language is installed"
                jobs = workbench.call("api/ocr-provider/jobs", {})["jobs"]
                assert any(job["requestID"] == request["requestID"] and job["status"] == "pending" for job in jobs)
                approved = workbench.call("api/ocr-provider/approve", {"requestID": request["requestID"], "confirm": True})
                assert approved["status"] == "completed", approved
                assert approved["resultCount"] == 8
                if args.automatic:
                    waiting = client.get("api/handoff/ocr-returns")
                    [item] = waiting["results"]
                    assert item["requestID"] == request["requestID"] and Path(item["path"]) == slot / "result.gaoaction"
                    assert client.get("api/handoff/ocr-returns") == waiting
                    assert client.get("api/state")["tabs"] == [], "An automatic return opened document tabs before approval"
                    result_path = item["path"]
                    try:
                        client.post("api/handoff/import", {"path": result_path})
                    except RuntimeError:
                        pass
                    else:
                        raise AssertionError("Automatic return was imported without its reviewed digest")
                else:
                    result_path = workbench.call("api/ocr-provider/result", {"requestID": request["requestID"],
                                                 "directory": str(root), "confirm": True})["path"]
                review = client.call("api/handoff/inspect", {"path": result_path})
                assert {source["sourceSHA256"] for source in review["ocrSources"]} == set(original_digests.values())
                accepted = client.post("api/handoff/import", {"path": result_path, "sha256": review["sha256"]})
                tabs = accepted["state"]["tabs"]
                assert len(tabs) == 8 and sum(tab["kind"] == "pdf" for tab in tabs) == 2
                assert all(tab["incoming"]["inReplyTo"] == request["requestID"] for tab in tabs)
                assert all(tab["incoming"]["status"] == "completed" for tab in tabs)
                assert {tab["incoming"]["sourceName"] for tab in tabs} == {file.name for file in files}
                assert all([page["pageNumber"] for page in tab["incoming"]["pages"]] == [1] for tab in tabs)
                assert {file: hashlib.sha256(file.read_bytes()).hexdigest() for file in files} == original_digests
                assert client.get("api/handoff/ocr-returns")["results"] == []
                actual_text = "".join("".join(tab["text"].split()) for tab in tabs if tab["title"].endswith(".txt"))
                assert "1234567890" in actual_text and "9876543210" in actual_text, actual_text
                assert all(len(tab["preview"]["pages"]) == 1 for tab in tabs if tab["kind"] == "pdf")
                repeated = workbench.call("api/ocr-provider/result", {"requestID": request["requestID"],
                                          "directory": str(root), "confirm": True})
                try:
                    repeat_sha = hashlib.sha256((Path(repeated["path"]) / "manifest.json").read_bytes()).hexdigest()
                    client.post("api/handoff/import", {"path": repeated["path"], "sha256": repeat_sha})
                except RuntimeError as exc:
                    assert '"code": "duplicate"' in str(exc), exc
                else:
                    raise AssertionError("Re-exported OCR result reopened existing tabs")
    route = "automatic return" if args.automatic else "manual export"
    executable = "installed GaoCaoZuo" if args.provider_setup else "GaoCaoZuo source with the native helper"
    print(f"OK · {executable} offline PNG/PDF OCR, {route}, GaoWenJian approval (8 outputs).")


if __name__ == "__main__":
    main()
