#!/usr/bin/env python3
"""Compile the pinned provider's production OCR path into a non-GUI test driver."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


PIN = "c3ee1ff8b5530c48ca008dbf4ea959dbc4617616"
CONTROLLER = "Sources/ScreenshotExchangeController.swift"
SOURCE_FILES = (
    "ScreenshotCore",
    "ScreenshotGaoActionModel",
    "ScreenshotGaoActionState",
    "ScreenshotGaoActionTransport",
    "ScreenshotMigration",
    "ScreenshotMigrationActivity",
    "ScreenshotMigrationActivityReader",
    "ScreenshotMigrationHistoryPolicy",
    "ScreenshotMigrationIO",
    "ScreenshotMigrationValidation",
    "ScreenshotOCRExporter",
    "ScreenshotOCRModels",
    "ScreenshotOCRRecoveryStore",
    "ScreenshotOCRReturn",
    "ScreenshotOCRService",
)
PATHS = [f"Sources/{name}.swift" for name in SOURCE_FILES] + ["Shared/GaoLocalization.swift"]
METHODS = {
    "PERFORM": "private func performOCR(",
    "OUTPUT": "private func outputURL(",
    "FINISH": "@discardableResult private func finish(",
    "PUBLISH": "private func publishOCRReturn(",
    "STORED": "private func storedManifestBytes(",
}


DRIVER = r"""import AppKit
import Darwin
import Foundation

__ORIGINAL_RESULT_TYPE__

@MainActor private final class FixtureModel {
    struct Store { let exchange: URL }
    let store: Store
    var ocrOptions = ScreenshotOCROptions()
    var message = ""
    init(exchange: URL) { store = Store(exchange: exchange) }
}

@MainActor private final class ProviderHarness {
    let model: FixtureModel
    private let ledger: ScreenshotGaoProcessedRequestStore?
    private let automaticReturnRoot: URL
    private var ocrCancellation: ScreenshotOCRCancellationToken?
    private var result: ScreenshotPendingActionResult?
    private(set) var phase = "initialize"

    init(exchange: URL, mailbox: URL) throws {
        model = FixtureModel(exchange: exchange)
        ledger = try ScreenshotGaoProcessedRequestStore(root: exchange)
        automaticReturnRoot = mailbox
    }

    func run(_ requestURL: URL) async throws -> ScreenshotPendingActionResult {
        phase = "transport.receive"
        let package = try ScreenshotGaoActionTransport.receive(packageURL: requestURL, exchangeRoot: model.store.exchange)
        let manifest = package.manifest
        guard manifest.kind == "request", manifest.action == "ocr.files",
              manifest.sourceBundleID == "com.gaoseries.GaoWenJian", let ledger else {
            throw ScreenshotGaoActionContract.reject("testInput", "This driver accepts only isolated GaoWenJian OCR fixture requests.")
        }
        phase = "ledger.receive"
        guard case .new = try ledger.receive(package) else {
            throw ScreenshotGaoActionContract.reject("testDuplicate", "Use a fresh provider exchange folder for every fixture request.")
        }
        // The caller invokes this non-GUI harness solely for its own generated inputs.
        // Run the same verification and ledger transitions as the approved controller path.
        phase = "transport.verifyStagedOCR"
        try await Task.detached(priority: .userInitiated) { try ScreenshotGaoActionTransport.verifyStagedOCR(package) }.value
        try ScreenshotGaoActionContract.validate(manifest, expectedTargetBundleID: ScreenshotGaoActionContract.bundleID, now: Date())
        _ = try ledger.transition(requestID: manifest.requestID, to: .approved)
        _ = try ledger.transition(requestID: manifest.requestID, to: .executing)
        phase = "performOCR"
        try await performOCR(package)
        guard let result, let record = ledger.lookup(result.requestID),
              record.phase.rawValue == result.status,
              record.resultPackageName == result.packageURL.lastPathComponent,
              record.automaticReturn == result.automaticReturn else {
            throw ScreenshotGaoActionContract.reject("testMissingResult", "Business result and persisted provider ledger differ.")
        }
        return result
    }

    private func queue(_ result: ScreenshotPendingActionResult) {
        self.result = result
    }

__ORIGINAL_PERFORM__

__ORIGINAL_OUTPUT__

__ORIGINAL_FINISH__

__ORIGINAL_PUBLISH__

__ORIGINAL_STORED__
}

@main private struct RealOCRProviderDriver {
    @MainActor static func main() async {
        var harness: ProviderHarness?
        do {
            let arguments = CommandLine.arguments
            guard NSApp == nil, arguments.count == 3 || arguments.count == 4 else {
                throw ScreenshotGaoActionContract.reject("testUsage",
                    "RealOCRProvider <synthetic request.gaoaction> <new isolated exchange> [isolated mailbox]")
            }
            func file(_ argument: String, directory: Bool = true) -> URL {
                URL(fileURLWithPath: argument, isDirectory: directory).standardizedFileURL.resolvingSymlinksInPath()
            }
            let request = file(arguments[1])
            let exchange = file(arguments[2])
            let mailbox = arguments.count == 4 ? file(arguments[3])
                : exchange.appendingPathComponent("UnusedTestMailbox", isDirectory: true)
            func isolated(_ url: URL) -> Bool {
                url.path.hasPrefix("/private/tmp/") || url.path.hasPrefix("/tmp/")
            }
            guard isolated(request), isolated(exchange), isolated(mailbox), request.pathExtension == "gaoaction",
                  !FileManager.default.fileExists(atPath: exchange.path) else {
                throw ScreenshotGaoActionContract.reject("testIsolation", "Use only generated packages and a fresh data root under the system temporary directory.")
            }
            let instance = try ProviderHarness(exchange: exchange, mailbox: mailbox)
            harness = instance
            let result = try await instance.run(request)
            guard NSApp == nil else {
                throw ScreenshotGaoActionContract.reject("testUnexpectedApplication", "OCR initialized NSApplication.")
            }
            let canonical = UUID(uuidString: result.requestID)?.uuidString.lowercased()
            let automaticPackage = canonical.map {
                mailbox.appendingPathComponent($0, isDirectory: true).appendingPathComponent("result.gaoaction", isDirectory: true)
            }
            let evidence: [String: Any] = [
                "resultPackage": result.packageURL.path,
                "resultStatus": result.status,
                "automaticReturn": result.automaticReturn?.rawValue ?? "none",
                "automaticReturnPackage": result.automaticReturn == .published ? automaticPackage?.path ?? "" : "",
                "providerCommit": "__PROVIDER_COMMIT__",
                "originalPerformOCRSHA256": "__PERFORM_SHA256__",
                "nonGUI": true,
                "nsApplicationInitialized": false
            ]
            let bytes = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .withoutEscapingSlashes])
            FileHandle.standardOutput.write(bytes)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            let code = (error as? ScreenshotGaoActionIssue)?.code ?? "unknown"
            let detail = "phase=" + (harness?.phase ?? "initializeExchange") + "; code=" + code + "; errno=" + String(errno)
            FileHandle.standardError.write(Data(("Real OCR integration failed [" + detail + "]: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
"""


def blob(repo: Path, path: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(repo), "show", f"{PIN}:{path}"])


def digest(source: bytes) -> str:
    return hashlib.sha256(source).hexdigest()


def extract(source: str, signature: str, indent: str) -> str:
    pattern = rf"^{re.escape(indent + signature)}[^\n]*\n.*?^{re.escape(indent)}}}$"
    matches = list(re.finditer(pattern, source, re.MULTILINE | re.DOTALL))
    if len(matches) != 1:
        raise ValueError(f"Expected a single complete source block for {signature}; got {len(matches)}.")
    block = matches[0].group()
    forbidden = ("NSApplication", "NSWindow", "NSWorkspace", "NSAlert", "performCapture(")
    if any(token in block for token in forbidden):
        raise ValueError(f"{signature} requires a GUI. The non-GUI adapter needs review.")
    return block


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider-project", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True,
                        help="A fresh directory under /private/tmp for a macOS build.")
    parser.add_argument("--prepare-only", action="store_true",
                        help="Extract the pinned sources and build evidence without invoking native Swift.")
    args = parser.parse_args()
    project = args.provider_project.resolve(strict=True)
    output = args.output_dir.resolve()
    if output.exists():
        raise ValueError("Output directory already exists.")
    if not args.prepare_only and not output.is_relative_to(Path("/private/tmp").resolve()):
        raise ValueError("Compile into a fresh directory under /private/tmp.")
    if subprocess.check_output(["git", "-C", str(project), "rev-parse", f"{PIN}^{{commit}}"], text=True).strip() != PIN:
        raise ValueError("Provider commit mismatch.")
    controller = blob(project, CONTROLLER)
    source = controller.decode("utf-8")
    parts = {name: extract(source, signature, "    ") for name, signature in METHODS.items()}
    parts["RESULT_TYPE"] = extract(source, "struct ScreenshotPendingActionResult:", "")
    generated = DRIVER
    for name, part in parts.items():
        placeholder = f"__ORIGINAL_{name}__"
        if generated.count(placeholder) != 1:
            raise ValueError(f"Expected exactly one driver placeholder {placeholder}.")
        generated = generated.replace(placeholder, part)
    method_digest = digest(parts["PERFORM"].encode("utf-8"))
    generated = generated.replace("__PERFORM_SHA256__", method_digest).replace("__PROVIDER_COMMIT__", PIN)
    if any(generated.count(part) != 1 for part in parts.values()):
        raise ValueError("A provider source block was not copied verbatim.")

    inputs = {path: blob(project, path) for path in PATHS}
    output.mkdir(mode=0o700)
    files = []
    for path, data in inputs.items():
        target = output / Path(path).name
        target.write_bytes(data)
        target.chmod(0o600)
        files.append(str(target))
    driver = output / "RealOCRProviderDriver.swift"
    driver.write_bytes(generated.encode("utf-8"))
    driver.chmod(0o600)
    executable = output / "RealOCRProvider"
    command = [
        "xcrun", "swiftc", "-parse-as-library", "-Xfrontend", "-disable-sandbox",
        "-swift-version", "5", "-target", "arm64-apple-macos14.0",
        "-module-cache-path", str(output / "cache"), *files, str(driver), "-o", str(executable),
    ]
    if not args.prepare_only:
        subprocess.run(command, check=True, cwd=output)
    evidence = {
        "providerCommit": PIN,
        "providerController": CONTROLLER,
        "controllerSHA256": digest(controller),
        "originalPerformOCRSHA256": method_digest,
        "exactProviderSourceBlocks": {part: digest(code.encode("utf-8")) for part, code in parts.items()},
        "providerSources": {path: digest(data) for path, data in inputs.items()},
        "facadeSHA256": digest(driver.read_bytes()),
        "swiftCommand": command,
        "compiled": not args.prepare_only,
        "nonGUI": True,
    }
    evidence_file = output / "compile-evidence.json"
    evidence_file.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    evidence_file.chmod(0o600)
    print(json.dumps({"executable": str(executable) if not args.prepare_only else None,
                      "evidence": str(evidence_file), "methodSHA256": method_digest}))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Prepare non-GUI provider failed: {error}", file=sys.stderr)
        sys.exit(1)