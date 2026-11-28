#!/usr/bin/env python3
"""Build a temporary, non-GUI harness around the provider's verbatim OCR method.

The sibling project is read only. This does not launch its application, request
screen capture, or substitute a fake OCR adapter. It exercises the provider's
transport, ledger, original performOCR method, Apple Vision/exporters and writer.
The harness supplies the UI-independent model fields and an isolated manual
result sink. The separate cross-implementation test exercises the mailbox.
"""

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys


CONTROLLER = "Sources/ScreenshotExchangeController.swift"
PERFORM_SIGNATURE = "    private func performOCR(_ package: ScreenshotGaoValidatedPackage) async throws {"
OUTPUT_SIGNATURE = "    private func outputURL(_ package: ScreenshotGaoValidatedPackage, name: String) throws -> URL {"
APP_SOURCES = {
    "ScreenshotApp.swift", "ScreenshotAppActions.swift", "ScreenshotMainView.swift",
    "ScreenshotOCRView.swift", "ScreenshotRecordingView.swift", "ScreenshotSettingsView.swift",
    "ScreenshotExchangeController.swift", "ScreenshotHostController.swift",
}
FRAMEWORKS = (
    "AppKit", "SwiftUI", "ScreenCaptureKit", "Vision", "VisionKit", "PDFKit",
    "AVFoundation", "CoreMedia", "CoreVideo", "CoreAudio", "AudioToolbox", "Accelerate",
    "ImageIO", "UniformTypeIdentifiers", "CryptoKit", "Security", "ApplicationServices",
)


DRIVER = r'''import Foundation
import Darwin
import AppKit

@MainActor private final class MethodModel {
    struct Store { let exchange: URL }
    let store: Store
    var ocrOptions = ScreenshotOCROptions()
    var message = ""
    init(exchange: URL) { store = Store(exchange: exchange) }
}

@MainActor private final class RealOCRMethodFacade {
    let model: MethodModel
    private let ledger: ScreenshotGaoProcessedRequestStore
    private var ocrCancellation: ScreenshotOCRCancellationToken?
    private var resultURL: URL?
    private(set) var phase = "ready"
    init(exchange: URL) throws {
        model = MethodModel(exchange: exchange)
        ledger = try ScreenshotGaoProcessedRequestStore(root: exchange)
    }

    func run(_ requestURL: URL) async throws -> URL {
        phase = "transport.receive"
        let package = try ScreenshotGaoActionTransport.receive(packageURL: requestURL, exchangeRoot: model.store.exchange)
        guard package.manifest.kind == "request", package.manifest.action == "ocr.files",
              package.manifest.sourceBundleID == "com.gaoseries.GaoWenJian" else {
            throw ScreenshotGaoActionContract.reject("testInput", "This non-GUI driver accepts only a generated GaoWenJian ocr.files request.")
        }
        phase = "ledger.receive"
        switch try ledger.receive(package) {
        case .new: break
        case .duplicate(let old):
            guard let name = old.resultPackageName else {
                throw ScreenshotGaoActionContract.reject("testDuplicate", "An unfinished duplicate is not replayed.")
            }
            return model.store.exchange.appendingPathComponent("Outgoing/" + name)
        }
        // This CLI is an explicitly invoked isolated integration test, not an
        // application request receiver. No production confirmation UI is bypassed.
        try ScreenshotGaoActionTransport.verifyStagedOCR(package)
        _ = try ledger.transition(requestID: package.manifest.requestID, to: .approved)
        _ = try ledger.transition(requestID: package.manifest.requestID, to: .executing)
        do { phase = "performOCR"; try await performOCR(package) }
        catch {
            let status: String
            let code: String
            if case ScreenshotOCRError.unsupportedLanguages = error { status = "unsupported"; code = "unsupportedLanguages" }
            else if error is CancellationError { status = "cancelled"; code = "userCancelled" }
            else { status = "failed"; code = (error as? ScreenshotGaoActionIssue)?.code ?? "executionFailed" }
            try finish(package, status: status, error: code, provenance: ["reason": .string(error.localizedDescription)])
        }
        guard let resultURL else { throw ScreenshotGaoActionContract.reject("testMissingResult", "The real OCR method produced no result package.") }
        return resultURL
    }

__ORIGINAL_PERFORM_OCR__

__ORIGINAL_OUTPUT_URL__

    @discardableResult private func finish(_ package: ScreenshotGaoValidatedPackage, status: String,
        files: [ScreenshotGaoOutgoingFile] = [], error: String? = nil, provenance: [String: ScreenshotGaoJSONValue]) throws -> URL {
        phase = "writer.result"
        var resultProvenance = provenance
        resultProvenance["requestManifestSHA256"] = .string(package.manifestSHA256)
        let result = try ScreenshotGaoActionWriter.writeResult(inReplyTo: package.manifest, status: status, items: files,
            errorCode: error, provenance: resultProvenance, exchangeRoot: model.store.exchange)
        guard let phase = ScreenshotGaoRequestPhase(rawValue: status) else {
            throw ScreenshotGaoActionContract.reject("testResultStatus", "Unexpected terminal status.")
        }
        _ = try ledger.transition(requestID: package.manifest.requestID, to: phase,
            resultPackageName: result.lastPathComponent, errorCode: error)
        resultURL = result
        return result
    }

    // The existing harness returns the private package to the caller for manual import.
    // Never access the real user mailbox from this isolated driver.
    private func publishOCRReturn(_: URL) async {}
}

@main private struct RealOCRProviderDriver {
    @MainActor static func main() async {
        var facade: RealOCRMethodFacade?
        do {
            guard NSApp == nil else { throw ScreenshotGaoActionContract.reject("testUnexpectedApplication", "The non-GUI driver must not initialize NSApplication.") }
            guard CommandLine.arguments.count == 3 else {
                throw ScreenshotGaoActionContract.reject("testUsage", "Usage: RealOCRProvider <generated-request.gaoaction> <isolated-exchange>")
            }
            let request = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
            let exchange = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            func isolated(_ url: URL) -> Bool {
                url.path.hasPrefix("/private/tmp/") || url.path.hasPrefix("/tmp/")
            }
            guard isolated(request), isolated(exchange), request.pathExtension == "gaoaction" else {
                throw ScreenshotGaoActionContract.reject("testIsolation", "Only generated packages and data under the system temporary directory are accepted.")
            }
            let instance = try RealOCRMethodFacade(exchange: exchange)
            facade = instance
            let result = try await instance.run(request)
            guard NSApp == nil else { throw ScreenshotGaoActionContract.reject("testUnexpectedApplication", "OCR unexpectedly initialized NSApplication.") }
            let bytes = try JSONSerialization.data(withJSONObject: [
                "resultPackage": result.path,
                "originalPerformOCRSHA256": "__PERFORM_SHA256__",
                "nonGUI": true,
                "nsApplicationInitialized": false,
                "scope": "provider production business method and manual result; excludes UI and mailbox delivery"
            ], options: [.sortedKeys, .withoutEscapingSlashes])
            FileHandle.standardOutput.write(bytes)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            let code = (error as? ScreenshotGaoActionIssue)?.code ?? "unknown"
            let detail = "phase=" + (facade?.phase ?? "initializeExchange") + "; code=" + code + "; errno=" + String(errno)
            let bytes = Data(("Real OCR provider integration failed [" + detail + "]: " + error.localizedDescription + "\n").utf8)
            FileHandle.standardError.write(bytes)
            exit(1)
        }
    }
}
'''


def extract_method(source: str, signature: str) -> str:
    """Retain exact source bytes through the method's four-space closing brace."""
    matches = list(re.finditer(r"^" + re.escape(signature) + r"(?=\r?$)", source, re.MULTILINE))
    if len(matches) != 1:
        raise ValueError("Provider method signature changed; review the adapter rather than rewriting its algorithm.")
    start = matches[0].start()
    end = re.search(r"^    }(?=\r?$)", source[matches[0].end():], re.MULTILINE)
    if end is None:
        raise ValueError("Provider method boundary could not be verified.")
    method = source[start:matches[0].end() + end.end()]
    if any(token in method for token in ("NSApplication", "NSWindow", "NSWorkspace", "NSAlert", "performCapture(")):
        raise ValueError("The provider OCR method now requires a UI; this non-GUI harness must be reviewed.")
    return method


def provider_sources(project: pathlib.Path) -> list[pathlib.Path]:
    sources = sorted(p for p in (project / "Sources").glob("Screenshot*.swift") if p.name not in APP_SOURCES)
    required = {"ScreenshotOCRService.swift", "ScreenshotGaoActionTransport.swift", "ScreenshotGaoActionState.swift"}
    if not required.issubset({p.name for p in sources}):
        raise ValueError("Expected current GaoCaoZuo OCR provider sources.")
    return sources + [project / "Sources/HostedInputGeneration.swift", project / "Shared/GaoLocalization.swift"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider-project", type=pathlib.Path, required=True)
    parser.add_argument("--output-dir", type=pathlib.Path, required=True,
                        help="A new directory under /private/tmp; no sibling files are modified.")
    options = parser.parse_args()
    project = options.provider_project.resolve(strict=True)
    output = options.output_dir.resolve()
    if not output.is_relative_to(pathlib.Path("/private/tmp").resolve()) or output.exists():
        raise ValueError("Output must be a new isolated temporary directory.")
    controller = project / CONTROLLER
    source_bytes = controller.read_bytes()
    source = source_bytes.decode("utf-8")
    method = extract_method(source, PERFORM_SIGNATURE)
    output_method = extract_method(source, OUTPUT_SIGNATURE)
    digest = hashlib.sha256(method.encode("utf-8")).hexdigest()
    generated = DRIVER.replace("__ORIGINAL_PERFORM_OCR__", method).replace("__ORIGINAL_OUTPUT_URL__", output_method).replace("__PERFORM_SHA256__", digest)
    if method not in generated or generated.count(method) != 1:
        raise ValueError("The original OCR method was not preserved verbatim.")
    sources = provider_sources(project)
    source_digests = {str(p.relative_to(project)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    output.mkdir(mode=0o700, parents=False)
    facade = output / "RealOCRProviderDriver.swift"
    facade.write_bytes(generated.encode("utf-8"))
    facade.chmod(0o600)
    executable = output / "RealOCRProvider"
    command = ["xcrun", "swiftc", "-Xfrontend", "-disable-sandbox", "-swift-version", "5",
               "-target", "arm64-apple-macos14.0", "-module-cache-path", str(output / "cache"),
               *map(str, sources), str(facade),
               *[argument for framework in FRAMEWORKS for argument in ("-framework", framework)],
               "-Xlinker", "-weak_framework", "-Xlinker", "Translation", "-o", str(executable)]
    subprocess.run(command, check=True, cwd=output)
    if controller.read_bytes() != source_bytes or source_digests != {
        str(p.relative_to(project)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources
    }:
        raise ValueError("Provider sources changed during compilation; discard this build and review before retrying.")
    evidence = {
        "providerMethodRelativePath": CONTROLLER,
        "providerControllerSHA256": hashlib.sha256(source_bytes).hexdigest(),
        "originalPerformOCRSHA256": digest,
        "originalOutputURLSHA256": hashlib.sha256(output_method.encode("utf-8")).hexdigest(),
        "providerSources": source_digests,
        "generatedFacadeSHA256": hashlib.sha256(facade.read_bytes()).hexdigest(),
        "nonGUI": True,
        "limitations": ["No app launch, NSWorkspace exchange or mailbox delivery", "No GUI confirmation or installed-app acceptance", "Use generated fixtures only"],
    }
    evidence_file = output / "compile-evidence.json"
    evidence_file.write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    evidence_file.chmod(0o600)
    print(json.dumps({"executable": str(executable), "evidence": str(evidence_file), "methodSHA256": digest}))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print("Prepare non-GUI provider failed: " + str(error), file=sys.stderr)
        sys.exit(1)
