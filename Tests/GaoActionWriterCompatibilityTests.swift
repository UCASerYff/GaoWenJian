import AppKit
import Foundation
import ImageIO

/// Explicit per-provider path compatibility; the payload bytes are never moved
/// into an extra directory and the default OCR/result shape stays unchanged.
@MainActor enum GaoActionWriterCompatibilityTests {
    @discardableResult static func run(in directory: URL, researchValidatorExecutable: URL? = nil) throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw GaoActionContract.reject("writerCompatibilityTest", name) }; checks += 1
        }
        let now = Date(timeIntervalSince1970: 1_792_020_000)
        try check(NSApp == nil, "No application before writer compatibility checks")
        let original = directory.appendingPathComponent("原始 文档.md")
        let originalBytes = Data("# 磁盘原件\n\n保持不变 😀\n".utf8)
        try originalBytes.write(to: original)
        let store = WorkspaceStore(); store.open(original)
        guard let tab = store.active else { throw GaoActionContract.reject("writerCompatibilityTest", "Could not open generated source") }
        let editedText = "# 当前未保存副本\n\n研究导入需要的 Unicode e\u{301} 😀\n"
        tab.edited(editedText)
        let prepared = try CurrentDocumentDispatcher.prepare(store: store, registry: CurrentDocumentHandoffRegistry(), chooseVersion: { _ in .diskOriginal }, now: now)
        let request = try manifest(prepared.packageURL)
        try check(request.action == "research.importDocuments" && request.targetBundleID == "com.academic-achievement.manager", "Actual research dispatcher keeps the intended target/action")
        try check(request.items.count == 1 && request.items.allSatisfy { $0.relativePath.hasPrefix("payload/") && $0.relativePath.split(separator: "/").count == 2 }, "Actual research dispatcher opts into package-root payload paths")
        let item = request.items[0]
        let physicalPayload = prepared.packageURL.appendingPathComponent(item.relativePath)
        try check(try Data(contentsOf: physicalPayload) == Data(editedText.utf8), "Research prefix resolves to the one real payload file")
        try check(item.sha256 == FileSafety.digest(Data(editedText.utf8)) && item.byteCount == Int64(Data(editedText.utf8).count), "Research manifest binds the exact current text bytes")
        let received = try GaoActionTransport.receive(packageURL: prepared.packageURL, exchangeRoot: directory.appendingPathComponent("ResearchReadback"), expectedTargetBundleID: request.targetBundleID, now: now)
        try check(received.stagedItems.count == 1 && (try Data(contentsOf: received.stagedItems[0].url)) == Data(editedText.utf8), "Real local transport accepts the research prefix and copies the exact bytes")
        let privateSource = try GaoOutgoingJournal(exchangeRoot: GaoHandoffService.exchangeRoot).sourceURL(requestID: prepared.session.requestID, itemID: item.id)
        try check(try Data(contentsOf: privateSource) == Data(editedText.utf8), "Outgoing journal retains the same sent source version")
        try check(try Data(contentsOf: original) == originalBytes && tab.text == editedText && tab.dirty, "Research snapshot leaves the disk original and unsaved editor intact")

        if let researchValidatorExecutable {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = researchValidatorExecutable
            process.arguments = [prepared.packageURL.path, directory.appendingPathComponent("ActualResearchStaging").path]
            process.standardOutput = output; process.standardError = errors; try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile(), errorBytes = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0, let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  result["count"] as? Int == 1, (result["sha256"] as? [String]) == [item.sha256] else {
                throw GaoActionContract.reject("writerCompatibilityTest", "Actual research validator rejected prefix or bytes: " + (String(data: errorBytes, encoding: .utf8) ?? "non-UTF8 error"))
            }
            checks += 1
        }

        let image = directory.appendingPathComponent("ocr-source.png"), imageBytes = try png()
        try imageBytes.write(to: image)
        let ocr = try OCRHandoffDispatcher.prepare(files: [image], store: store, registry: CurrentDocumentHandoffRegistry(), chooseVersion: { _ in .diskOriginal }, now: now)
        let ocrManifest = try manifest(ocr.packageURL)
        try check(ocrManifest.items.count == 1 && ocrManifest.items.allSatisfy { !$0.relativePath.contains("/") }, "Actual default OCR dispatcher still uses payload-relative filenames")
        let ocrReadback = try GaoActionTransport.receive(packageURL: ocr.packageURL, exchangeRoot: directory.appendingPathComponent("OCRReadback"), expectedTargetBundleID: "com.gaoseries.GaoJieTu", now: now)
        try check(try Data(contentsOf: ocrReadback.stagedItems[0].url) == imageBytes && ocrManifest.items[0].sha256 == FileSafety.digest(imageBytes), "OCR physical payload and source digest are unchanged")

        let inboundURL = try GaoActionWriter.writeRequest(action: "documents.open", items: [.init(url: original, uti: "net.daringfireball.markdown")], sourceBundleID: "com.gaoseries.Fixture", targetBundleID: GaoActionContract.bundleID, exchangeRoot: directory.appendingPathComponent("Inbound"), now: now)
        let inbound = try manifest(inboundURL)
        let reply = try GaoActionWriter.writeResult(inReplyTo: inbound, status: "completed", items: [.init(url: original, uti: "net.daringfireball.markdown")], exchangeRoot: directory.appendingPathComponent("Reply"), now: now)
        let replyManifest = try manifest(reply)
        try check(replyManifest.items.count == 1 && replyManifest.items.allSatisfy { !$0.relativePath.contains("/") }, "Result writer default remains payload-relative")
        let resultReadback = try GaoActionTransport.receive(packageURL: reply, exchangeRoot: directory.appendingPathComponent("ResultReadback"), expectedTargetBundleID: "com.gaoseries.Fixture", now: now)
        try check(try Data(contentsOf: resultReadback.stagedItems[0].url) == originalBytes && replyManifest.items[0].sha256 == FileSafety.digest(originalBytes), "Result prefix compatibility does not alter bytes or digests")
        try check(try Data(contentsOf: original) == originalBytes && Data(contentsOf: image) == imageBytes && tab.dirty && tab.text == editedText, "Every writer/readback leaves both original files and editor state unchanged")
        try check(NSApp == nil, "No application after writer compatibility checks")
        print("GaoAction writer compatibility: \(checks) checks passed (research payload prefix, exact source bytes/hash, real transport readback, unchanged OCR/results; no UI)")
        return checks
    }
    private static func manifest(_ package: URL) throws -> GaoActionManifest {
        try JSONDecoder().decode(GaoActionManifest.self, from: Data(contentsOf: package.appendingPathComponent("manifest.json")))
    }
    private static func png() throws -> Data {
        let output = NSMutableData()
        guard let bitmap = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = bitmap.makeImage(), let writer = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw GaoActionContract.reject("writerCompatibilityTest", "PNG fixture failed") }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw GaoActionContract.reject("writerCompatibilityTest", "PNG write failed") }
        return output as Data
    }
}
