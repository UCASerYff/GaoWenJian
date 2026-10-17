import AppKit
import Foundation
import PDFKit
import CoreText
import ImageIO
import CoreImage

/// Generated fixtures only. No app, window, external document or screen capture.
enum PDFImageHandoffTests {
    @MainActor @discardableResult static func run(in directory: URL, providerExecutable: URL? = nil) throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw GaoActionContract.reject("imagePDFTest", name) }; checks += 1
        }
        try check(NSApp == nil, "No application at entry")
        let png = try imageData(jpeg: false)
        let jpeg = try imageData(jpeg: true, orientation: 6)
        for (name, bytes) in [("PNG", png), ("EXIF6 JPEG", jpeg)] {
            let image = try decoded(bytes, honorOrientation: true)
            let result = try pdf(image: image)
            let provenance = metadata(for: bytes)
            let report = try PDFHandoffVerifier.inspect(resultData: result, originalData: bytes, provenance: provenance, expectedSourceItemID: "scan-image")
            try check(report.isVerifiedSearchable && report.issues.isEmpty, name + " original drawing plus invisible text verifies: " + report.issues.map(\.code).joined(separator: ","))
            try check(report.sourceDigestMatches == true && report.sourceItemIDMatches == true && report.pageChecks.count == 1, name + " source and page count bind")
            try check(report.pageChecks[0].geometryMatchesSource == true && report.pageChecks[0].renderedPageMatchesSource == true && report.pageChecks[0].hasSelectablePageText, name + " actual geometry, drawing and text agree")
            try check(report.pageChecks[0].mediaBox == [0, 0, Double(image.width), Double(image.height)] && report.pageChecks[0].rotation == 0, name + " upright pixel size maps to PDF units")

            let flattened = try PDFHandoffVerifier.inspect(resultData: pdf(image: image, text: false), originalData: bytes, provenance: provenance)
            try check(!flattened.isVerifiedSearchable && !flattened.hasSearchablePageText, name + " unchanged flattened image is not OCR text")
            var partial = provenance; partial.pages[0].status = "failed"
            let failed = try PDFHandoffVerifier.inspect(resultData: result, originalData: bytes, provenance: partial)
            try check(!failed.isVerifiedSearchable && failed.issues.contains { $0.code == "pageOCRNotCompleted" }, name + " failed page never claims completion")
            var wrongDigest = provenance; wrongDigest.sourceSHA256 = String(repeating: "a", count: 64)
            let mismatch = try PDFHandoffVerifier.inspect(resultData: result, originalData: bytes, provenance: wrongDigest)
            try check(!mismatch.isVerifiedSearchable && mismatch.sourceDigestMatches == false, name + " original digest mismatch remains a review issue")
        }
        let pngImage = try decoded(png, honorOrientation: true)
        let anotherImage = try decoded(imageData(jpeg: false, variety: 1), honorOrientation: true)
        let changed = try PDFHandoffVerifier.inspect(resultData: pdf(image: anotherImage), originalData: png, provenance: metadata(for: png))
        try check(changed.pageChecks[0].geometryMatchesSource == true && changed.pageChecks[0].renderedPageMatchesSource == false && !changed.isVerifiedSearchable, "Another same-size image cannot pass by geometry alone")
        let doubled = try PDFHandoffVerifier.inspect(resultData: pdf(image: pngImage, count: 2), originalData: png, provenance: metadata(for: png, count: 2))
        try check(!doubled.isVerifiedSearchable && doubled.issues.contains { $0.code == "pageCountMismatch" }, "Single image cannot silently become two pages")
        let rotatedPDF = PDFDocument(data: try pdf(image: pngImage))!
        rotatedPDF.page(at: 0)!.rotation = 90
        let wrongRotation = try PDFHandoffVerifier.inspect(resultData: rotatedPDF.dataRepresentation()!, originalData: png, provenance: metadata(for: png))
        try check(!wrongRotation.isVerifiedSearchable && wrongRotation.pageChecks[0].geometryMatchesSource == false, "PDF rotation must be zero for oriented image sources")
        let rawJPEG = try decoded(jpeg, honorOrientation: false)
        let wrongExif = try PDFHandoffVerifier.inspect(resultData: pdf(image: rawJPEG), originalData: jpeg, provenance: metadata(for: jpeg))
        try check(!wrongExif.isVerifiedSearchable && wrongExif.pageChecks[0].geometryMatchesSource == false, "Ignoring EXIF6 causes a dimension/direction mismatch")
        let upsideDown = CIImage(cgImage: pngImage).oriented(forExifOrientation: 3)
        let inverted = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(upsideDown, from: upsideDown.extent)!
        let sameSizeWrongDirection = try PDFHandoffVerifier.inspect(resultData: pdf(image: inverted), originalData: png, provenance: metadata(for: png))
        try check(sameSizeWrongDirection.pageChecks[0].geometryMatchesSource == true && sameSizeWrongDirection.pageChecks[0].renderedPageMatchesSource == false && !sameSizeWrongDirection.isVerifiedSearchable, "Same-size upside-down drawing is caught by appearance")
        let unrelated = try PDFHandoffVerifier.inspect(resultData: pdf(image: pngImage), originalData: Data("not an image".utf8), provenance: metadata(for: Data("not an image".utf8)))
        try check(!unrelated.isVerifiedSearchable && unrelated.issues.contains { $0.code == "sourceNotComparable" }, "Undecodable source keeps a readable result unverified")

        if let providerExecutable {
            checks += try realProvider(in: directory.appendingPathComponent("RealProvider"), executable: providerExecutable, inputs: [("image.png", png), ("exif6.jpg", jpeg)])
        }
        try check(NSApp == nil, "No application after image comparison and provider subprocess")
        print("Image PDF handoff: \(checks) checks passed (PNG, EXIF6 JPEG, wrong image/direction/page count/partial negatives; no UI)")
        return checks
    }

    private static func metadata(for bytes: Data, count: Int = 1) -> OCRProvenance {
        OCRProvenance(sourceItemID: "scan-image", sourceSHA256: FileSafety.digest(bytes), pages: (1...count).map { .init(pageNumber: $0, status: "completed") })
    }

    private static func imageData(jpeg: Bool, orientation: Int32 = 1, variety: Int = 0) throws -> Data {
        guard let bitmap = CGContext(data: nil, width: 720, height: 480, bitsPerComponent: 8, bytesPerRow: 720 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw issue("Cannot create bitmap") }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 720, height: 480))
        bitmap.setFillColor(CGColor(red: variety == 0 ? 0.1 : 0.8, green: 0.3, blue: 0.7, alpha: 1))
        bitmap.fill(CGRect(x: variety == 0 ? 20 : 470, y: 25, width: 180, height: 65))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 34, nil)
        for (index, line) in ["OCR IMAGE ALPHA", "ORIGINAL PAGE ONE"].enumerated() {
            bitmap.textPosition = CGPoint(x: 40, y: 350 - index * 65)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])), bitmap)
        }
        guard let upright = bitmap.makeImage() else { throw issue("Bitmap unavailable") }
        let raw: CGImage
        if orientation == 6 {
            // Raw pixels compensate for EXIF6 so the provider sees upright
            // printed text after applying the real metadata transformation.
            let rotated = CIImage(cgImage: upright).oriented(forExifOrientation: 8)
            guard let image = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(rotated, from: rotated.extent) else { throw issue("Cannot rotate fixture") }
            raw = image
        } else { raw = upright }
        let output = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(output, (jpeg ? "public.jpeg" : "public.png") as CFString, 1, nil) else { throw issue("Image writer unavailable") }
        CGImageDestinationAddImage(writer, raw, [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw issue("Image fixture write failed") }
        if orientation != 1 {
            let source = CGImageSourceCreateWithData(output as CFData, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
            guard (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value == orientation else { throw issue("Fixture EXIF metadata was not retained") }
        }
        return output as Data
    }
    private static func decoded(_ bytes: Data, honorOrientation: Bool) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), let raw = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw issue("Fixture decode failed") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        if !honorOrientation || orientation == 1 { return raw }
        let image = CIImage(cgImage: raw).oriented(forExifOrientation: orientation)
        guard let upright = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(image, from: image.extent) else { throw issue("Fixture orientation decode failed") }
        return upright
    }
    private static func pdf(image: CGImage, text: Bool = true, count: Int = 1) throws -> Data {
        let output = NSMutableData(); var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let consumer = CGDataConsumer(data: output), let writer = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw issue("PDF fixture write failed") }
        for _ in 0..<count {
            writer.beginPDFPage(nil); writer.draw(image, in: box)
            if text {
                writer.setTextDrawingMode(.invisible); writer.textPosition = CGPoint(x: 40, y: 350)
                let font = CTFontCreateWithName("Helvetica" as CFString, 34, nil)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "OCR IMAGE ALPHA", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])), writer)
            }
            writer.endPDFPage()
        }
        writer.closePDF(); return output as Data
    }

    @MainActor private static func realProvider(in directory: URL, executable: URL, inputs: [(String, Data)]) throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var files: [GaoOutgoingFile] = []
        for (name, bytes) in inputs {
            let url = directory.appendingPathComponent(name); try bytes.write(to: url)
            files.append(.init(url: url, uti: name.hasSuffix("png") ? "public.png" : "public.jpeg"))
        }
        let store = WorkspaceStore()
        let prepared = try OCRHandoffDispatcher.prepare(files: files.map(\.url), store: store,
            registry: CurrentDocumentHandoffRegistry(), outputs: ["text", "json", "searchablePDF"], chooseVersion: { _ in .diskOriginal })
        let requestURL = prepared.packageURL
        let request = try JSONDecoder().decode(GaoActionManifest.self, from: Data(contentsOf: requestURL.appendingPathComponent("manifest.json")))
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = executable; process.arguments = [requestURL.path, directory.appendingPathComponent("ProviderExchange").path]
        process.standardOutput = output; process.standardError = errors; try process.run()
        let resultBytes = output.fileHandleForReading.readDataToEndOfFile(), errorBytes = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0,
              let record = try JSONSerialization.jsonObject(with: resultBytes) as? [String: Any],
              let path = record["resultPackage"] as? String else { throw issue("Real provider failed: " + (String(data: errorBytes, encoding: .utf8) ?? "non-UTF8 error")) }
        let resultURL = URL(fileURLWithPath: path)
        let result = try JSONDecoder().decode(GaoActionManifest.self, from: Data(contentsOf: resultURL.appendingPathComponent("manifest.json")))
        guard result.status == "completed", result.inReplyTo == request.requestID, result.items.count == inputs.count * 3,
              let maps = result.provenance?["outputs"]?.arrayValue else { throw issue("Real provider did not produce all requested image results") }
        var checks = 1
        for (offset, source) in request.items.enumerated() {
            guard let pdfMap = maps.first(where: { $0.objectValue?["sourceItemID"]?.stringValue == source.id && $0.objectValue?["format"]?.stringValue == "searchablePDF" })?.objectValue,
                  let resultID = pdfMap["resultItemID"]?.stringValue,
                  let item = result.items.first(where: { $0.id == resultID }) else { throw issue("Provider PDF map missing") }
            let provenance = try OCRResultProvenance.normalize(manifest: result, resultItemID: resultID, sourceItemID: source.id, sourceSHA256: source.sha256)
            let pdfData = try Data(contentsOf: payloadURL(resultURL, item.relativePath))
            let report = try PDFHandoffVerifier.inspect(resultData: pdfData, originalData: inputs[offset].1, provenance: provenance, expectedSourceItemID: source.id)
            guard report.isVerifiedSearchable, report.sourceDigestMatches == true, report.pageChecks.count == 1,
                  report.pageChecks[0].geometryMatchesSource == true, report.pageChecks[0].renderedPageMatchesSource == true else { throw issue("Real image PDF verification failed for \(inputs[offset].0): \(report.issues.map(\.code))") }
            guard try Data(contentsOf: files[offset].url) == inputs[offset].1 else { throw issue("Provider altered generated image source") }
            checks += 2
            if let jsonMap = maps.first(where: { $0.objectValue?["sourceItemID"]?.stringValue == source.id && $0.objectValue?["format"]?.stringValue == "json" })?.objectValue,
               let jsonID = jsonMap["resultItemID"]?.stringValue, let json = result.items.first(where: { $0.id == jsonID }),
               let providerID = jsonMap["sourceID"]?.stringValue {
                try OCRJSONPayloadVerifier.verify(data: Data(contentsOf: payloadURL(resultURL, json.relativePath)), provenance: provenance,
                    expectedSourceSHA256: source.sha256, expectedProviderSourceID: providerID, expectedPageCount: 1, expectedByteCount: source.byteCount)
                checks += 1
            } else { throw issue("Real image JSON association missing") }
        }
        let interaction = GaoHandoffInteraction(confirm: { _ in true }, selectReference: { _ in nil }, offerResult: { _, _ in })
        let outcome = try GaoHandoffService.receive(url: resultURL, store: store, interaction: interaction)
        let tabs = store.tabs.filter { outcome.openedTabIDs.contains($0.id) }
        guard outcome.status == "completed", tabs.count == 6,
              tabs.filter({ $0.url == nil && $0.dirty && $0.kind == .text }).count == 4,
              tabs.filter({ $0.kind == .pdf && $0.incoming?.pdfReport?.isVerifiedSearchable == true }).count == 2,
              tabs.filter({ $0.incoming?.originalName.hasSuffix(".json") == true }).count == 2 else { throw issue("Real provider images did not enter the consumer's correct new text/JSON/PDF tabs") }
        checks += 1
        print("PASS: actual provider OCR/export methods → consumer dispatcher produced source-matched PNG + EXIF6 JPEG text/JSON/searchable PDFs (no app or UI exchange)")
        return checks
    }
    private static func payloadURL(_ package: URL, _ relativePath: String) -> URL {
        // Provider V1 writer stores manifest paths relative to payload root.
        package.appendingPathComponent("payload").appendingPathComponent(relativePath)
    }
    private static func issue(_ detail: String) -> GaoActionIssue { GaoActionContract.reject("imagePDFTest", detail) }
}
