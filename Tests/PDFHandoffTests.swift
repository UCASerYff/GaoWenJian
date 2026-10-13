import AppKit
import PDFKit
import CoreText

enum PDFHandoffTests {
    @MainActor static func run(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = try fixture(text: false)
        let searchable = try fixture(text: true)
        let provenance = OCRProvenance(sourceItemID: "scan", sourceSHA256: FileSafety.digest(source),
            engine: "Fixture", engineVersion: "1", languages: ["en"], coordinateSystem: "pdf-points-bottom-left",
            confidenceSource: "provider-declared", pages: [
                .init(pageNumber: 1, status: "completed", confidence: 0.8, confidenceSource: "fixture"),
                .init(pageNumber: 2, status: "completed", confidence: 0.8, confidenceSource: "fixture")])
        let valid = try PDFHandoffVerifier.inspect(resultData: searchable, originalData: source, provenance: provenance)
        try check(valid.isVerifiedSearchable, "Invisible text on two unchanged scans passes basic checks: \(valid.issues)")
        try check(valid.pageChecks.allSatisfy(\.hasSelectablePageText), "Searchability is based on real selectable page content")
        try check(valid.pageChecks[0].rotation == 90 && valid.pageChecks[1].rotation == 270, "Rotations retained")
        try check(valid.pageChecks[0].cropBox == [20, 30, 320, 420], "Nonzero crop retained")
        try check(valid.summary.contains("准确率与完整性"), "Checks do not promise OCR accuracy")

        let unverified = try PDFHandoffVerifier.inspect(resultData: searchable)
        try check(!unverified.isVerifiedSearchable && unverified.hasSearchablePageText, "Missing source remains readable but unverified")
        let image = NSImage(size: NSSize(width: 30, height: 30), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let imageBytes = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        var imageProvenance = provenance; imageProvenance.sourceSHA256 = FileSafety.digest(imageBytes)
        let imageInput = try PDFHandoffVerifier.inspect(resultData: searchable, originalData: imageBytes, provenance: imageProvenance)
        try check(imageInput.sourceDigestMatches == true && imageInput.hasSearchablePageText && !imageInput.isVerifiedSearchable,
            "Image-source OCR PDF remains readable, source hash verified, PDF geometry honestly unverified")
        var wrongHash = provenance; wrongHash.sourceSHA256 = String(repeating: "0", count: 64)
        let mismatchedHash = try PDFHandoffVerifier.inspect(resultData: searchable, originalData: source, provenance: wrongHash)
        try check(mismatchedHash.sourceDigestMatches == false && !mismatchedHash.isVerifiedSearchable, "Original digest mismatch flagged")
        let mismatchedItem = try PDFHandoffVerifier.inspect(resultData: searchable, originalData: source, provenance: provenance, expectedSourceItemID: "another-item")
        try check(mismatchedItem.sourceItemIDMatches == false && !mismatchedItem.isVerifiedSearchable, "Source item mismatch flagged independently of hash")
        var duplicatePages = provenance; duplicatePages.pages.append(duplicatePages.pages[0])
        let repeatedMetadata = try PDFHandoffVerifier.inspect(resultData: searchable, originalData: source, provenance: duplicatePages)
        try check(!repeatedMetadata.isVerifiedSearchable && repeatedMetadata.issues.contains { $0.code == "pageProvenanceInvalid" }, "Directly constructed repeated page metadata does not trap")
        let scanned = try PDFHandoffVerifier.inspect(resultData: source, originalData: source, provenance: provenance)
        try check(!scanned.hasSearchablePageText && !scanned.isVerifiedSearchable, "Flattened scans are not searchable PDFs")

        let notes = PDFDocument(data: source)!
        for index in 0..<notes.pageCount {
            let note = PDFAnnotation(bounds: CGRect(x: 30, y: 40, width: 180, height: 70), forType: .freeText, withProperties: nil)
            note.contents = "OCR sidebar placeholder"; note.font = .systemFont(ofSize: 12)
            notes.page(at: index)!.addAnnotation(note)
        }
        let annotated = try PDFHandoffVerifier.inspect(resultData: notes.dataRepresentation()!, originalData: source, provenance: provenance)
        try check(!annotated.hasSearchablePageText, "FreeText annotations do not masquerade as OCR page text")

        let reordered = PDFDocument(data: searchable)!
        let second = reordered.page(at: 1)!.copy() as! PDFPage
        let first = reordered.page(at: 0)!.copy() as! PDFPage
        // Equalize geometry to exercise the page-order rendering check itself.
        first.rotation = 90; second.rotation = 90
        let uniformOriginal = PDFDocument(data: source)!
        uniformOriginal.page(at: 1)!.rotation = 90
        let originalUniformBytes = uniformOriginal.dataRepresentation()!
        let reversed = PDFDocument(); reversed.insert(second, at: 0); reversed.insert(first, at: 1)
        var orderProvenance = provenance; orderProvenance.sourceSHA256 = FileSafety.digest(originalUniformBytes)
        let order = try PDFHandoffVerifier.inspect(resultData: reversed.dataRepresentation()!, originalData: originalUniformBytes, provenance: orderProvenance)
        try check(order.pageChecks.allSatisfy { $0.geometryMatchesSource == true }, "Reorder fixture has identical page geometry")
        try check(order.pageChecks.allSatisfy { $0.renderedPageMatchesSource == false } && !order.isVerifiedSearchable, "Reordered same-size scans detected by page content")

        let changed = PDFDocument(data: searchable)!
        changed.page(at: 0)!.setBounds(CGRect(x: 10, y: 30, width: 330, height: 420), for: .cropBox)
        let geometry = try PDFHandoffVerifier.inspect(resultData: changed.dataRepresentation()!, originalData: source, provenance: provenance)
        try check(geometry.pageChecks[0].geometryMatchesSource == false, "Crop mismatch flagged")
        let missing = PDFDocument(data: searchable)!; missing.removePage(at: 1)
        let missingPage = try PDFHandoffVerifier.inspect(resultData: missing.dataRepresentation()!, originalData: source, provenance: provenance)
        try check(missingPage.issues.contains { $0.code == "pageCountMismatch" }, "Missing page flagged")
        var partial = provenance; partial.pages[1].status = "failed"
        let partialReport = try PDFHandoffVerifier.inspect(resultData: searchable, originalData: source, provenance: partial)
        try check(!partialReport.isVerifiedSearchable && partialReport.pageChecks[1].declaredOCRStatus == "failed", "Partial OCR never marked complete")
        let offPage = try PDFHandoffVerifier.inspect(resultData: fixture(text: true, offPage: true), originalData: source, provenance: provenance)
        try check(!offPage.hasSearchablePageText, "Off-page text is not a selectable visible-page OCR layer")
        let visibleSideText = try PDFHandoffVerifier.inspect(resultData: fixture(text: true, visibleText: true), originalData: source, provenance: provenance)
        try check(!visibleSideText.isVerifiedSearchable && visibleSideText.issues.contains { $0.code == "pageAppearanceMismatch" }, "Adding visible sidebar text requires review")
        try rejects("Damaged PDF") { _ = try PDFHandoffVerifier.inspect(resultData: Data("not a PDF".utf8)) }
        try provenanceTests(provenance)
        try snapshotTests(in: directory, source: source)
        print("PDF handoff: source digest, page count/order, rotations, crop/media boxes, real selection, flattened/annotation/off-page negatives, partial provenance, new-file export and dirty/recovery preservation passed")
    }

    private static func provenanceTests(_ provenance: OCRProvenance) throws {
        let bytes = try JSONEncoder().encode(provenance)
        try check(try OCRProvenance.parse(jsonData: bytes) == provenance, "Provenance fields round trip")
        let minimal = try OCRProvenance.parse(jsonData: Data("{\"sourceItemID\":\"scan\",\"sourceSHA256\":\"\(provenance.sourceSHA256!)\"}".utf8))
        try check(minimal.pages.isEmpty && minimal.engine == nil, "Optional provider metadata may be absent")
        let objectEngine = try OCRProvenance.parse(jsonData: Data("{\"engine\":{\"name\":\"Fixture\",\"version\":\"1\"}}".utf8))
        try check(objectEngine.engine == "Fixture" && objectEngine.engineVersion == "1", "Structured engine metadata accepted")
        for json in ["{\"pages\":[{\"pageNumber\":1},{\"pageNumber\":1}]}",
                     "{\"pages\":[{\"pageNumber\":true}]}", "{\"pages\":[{\"pageNumber\":0}]}",
                     "{\"pages\":[{\"pageNumber\":1,\"confidence\":2}]}",
                     "{\"sourceSHA256\":\"wrong\"}", "{\"languages\":1}"] {
            try rejects("Invalid provenance") { _ = try OCRProvenance.parse(jsonData: Data(json.utf8)) }
        }
    }

    @MainActor private static func snapshotTests(in directory: URL, source: Data) throws {
        let sourceURL = directory.appendingPathComponent("原件 中文.pdf")
        try source.write(to: sourceURL)
        let model = PDFWorkspaceModel(url: sourceURL)
        try model.addText("未保存叠加内容", note: false, page: model.document!.page(at: 0)!, at: CGPoint(x: 50, y: 100))
        let recovery = FileSafety.root.appendingPathComponent("Recovery/PDF/\(FileSafety.digest(Data(sourceURL.standardizedFileURL.path.utf8)))")
        let beforeRecovery = try Data(contentsOf: recovery.appendingPathComponent("draft.pdf"))
        let originalBefore = try Data(contentsOf: sourceURL)
        let snapshot = try model.safeHandoffSnapshot(to: directory.appendingPathComponent("交接 副本.pdf"))
        let snapshotData = try Data(contentsOf: snapshot.url)
        try check(snapshot.sha256 == FileSafety.digest(snapshotData) && snapshot.pageCount == 2, "Snapshot digest and page count")
        try check(PDFDocument(data: snapshotData)?.page(at: 0)?.annotations.contains { $0.contents == "未保存叠加内容" } == true, "Snapshot includes current unsaved edits")
        try check(model.dirty && model.canUndo, "Handoff export retains dirty and undo state")
        try check(try Data(contentsOf: sourceURL) == originalBefore, "Handoff never rewrites original")
        try check(try Data(contentsOf: recovery.appendingPathComponent("draft.pdf")) == beforeRecovery, "Handoff keeps recovery bytes")
        let permissions = try FileManager.default.attributesOfItem(atPath: snapshot.url.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o600, "Snapshot is private 0600")
        try rejects("Existing output never overwritten") { _ = try model.safeHandoffSnapshot(to: snapshot.url) }
        try rejects("Original never overwritten") { _ = try model.safeHandoffSnapshot(to: sourceURL) }
        let aliasDirectory = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: directory)
        try rejects("Symlink parent alias of original") { _ = try model.safeHandoffSnapshot(to: aliasDirectory.appendingPathComponent(sourceURL.lastPathComponent)) }
        try FileManager.default.removeItem(at: sourceURL)
        try rejects("Missing original alias cannot be silently recreated") { _ = try model.safeHandoffSnapshot(to: aliasDirectory.appendingPathComponent(sourceURL.lastPathComponent)) }
        // The export helper must not reset the existing source digest: external
        // replacement still causes the ordinary model save to reject overwrite.
        var external = source; external.append(Data("\n% external edit\n".utf8))
        try external.write(to: sourceURL)
        try rejects("Export did not erase save conflict protection") { _ = try model.save() }
        try check(try Data(contentsOf: sourceURL) == external, "External replacement retained")
        model.discardDraft()
    }

    private static func fixture(text: Bool, offPage: Bool = false, visibleText: Bool = false) throws -> Data {
        let bytes = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 400, height: 500)
        guard let consumer = CGDataConsumer(data: bytes), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw PDFWorkspaceError.message("Cannot make PDF handoff fixture")
        }
        for index in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor); context.fill(media)
            context.setFillColor(index == 0 ? NSColor.systemRed.cgColor : NSColor.systemBlue.cgColor)
            context.fill(CGRect(x: 40, y: 70, width: index == 0 ? 200 : 130, height: 280))
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: index == 0 ? 270 : 220, y: 160, width: 35, height: 90))
            if text {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: index == 0 ? "PAGE ONE OCR" : "PAGE TWO OCR", attributes: [
                    .font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black]))
                context.saveGState()
                context.setTextDrawingMode(visibleText ? .fill : .invisible)
                context.textPosition = CGPoint(x: offPage ? 600 : 50, y: 390)
                CTLineDraw(line, context)
                context.restoreGState()
            }
            context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: bytes as Data) else { throw PDFWorkspaceError.message("Fixture PDF decode failed") }
        for index in 0..<document.pageCount {
            document.page(at: index)!.rotation = index == 0 ? 90 : 270
            document.page(at: index)!.setBounds(CGRect(x: 20, y: 30, width: 320, height: 420), for: .cropBox)
        }
        return document.dataRepresentation()!
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        if try !condition() { throw PDFWorkspaceError.message("PDF handoff test failed: " + label) }
    }
    private static func rejects(_ label: String, _ work: () throws -> Void) throws {
        do { try work() } catch { return }
        throw PDFWorkspaceError.message("PDF handoff test expected rejection: " + label)
    }
}
