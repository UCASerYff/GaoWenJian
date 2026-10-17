import AppKit
import Foundation
import PDFKit

enum EditedDocumentExportTests {
    @MainActor static func run(in directory: URL) throws {
        try check(NSApp == nil, "No application is initialized")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = WorkspaceStore()
        store.tabs = []; store.selection = nil
        let original = directory.appendingPathComponent("研究 原稿.md")
        let originalBytes = Data("原始附件\n".utf8)
        try originalBytes.write(to: original)
        store.open(original)
        guard let text = store.active else { throw FileIssue.message("Missing export text fixture") }
        text.edited("当前未保存内容：α + β\n")
        store.checkpoint()
        let recovery = FileSafety.root.appendingPathComponent("recovery.json")
        let recoveryBefore = try Data(contentsOf: recovery)
        let prepared = try EditedDocumentExporter.prepare(store: store, chooseVersion: { _ in .currentEdits })
        try check(prepared.versionKind == "currentEdits" && prepared.title == original.lastPathComponent, "Text version and source format are explicit")
        let output = directory.appendingPathComponent("编辑副本.md")
        let receipt = try EditedDocumentExporter.export(prepared, to: output)
        try check(try String(contentsOf: output, encoding: .utf8) == text.text, "Current Unicode UTF8 text is exported")
        try check(receipt.sha256 == prepared.sha256 && receipt.byteCount == prepared.byteCount, "Private snapshot digest and exported bytes agree")
        try check(try Data(contentsOf: original) == originalBytes && text.dirty && text.url == original, "Export keeps original, dirty flag and tab path")
        try check((try Data(contentsOf: recovery)) == recoveryBefore, "Export does not write or remove the text recovery draft")
        try rejects("Original file cannot be an export destination") { _ = try EditedDocumentExporter.export(prepared, to: original, overwrite: .replace(expectedSHA256: FileSafety.digest(originalBytes))) }
        let hardlink = directory.appendingPathComponent("原稿硬链接.md")
        try FileManager.default.linkItem(at: original, to: hardlink)
        try rejects("Hard link to original is protected") { _ = try EditedDocumentExporter.export(prepared, to: hardlink, overwrite: .replace(expectedSHA256: FileSafety.digest(originalBytes))) }
        try FileManager.default.removeItem(at: hardlink)
        let symlink = directory.appendingPathComponent("原稿软链接.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        try rejects("Symbolic link to original is protected") { _ = try EditedDocumentExporter.export(prepared, to: symlink, overwrite: .replace(expectedSHA256: FileSafety.digest(originalBytes))) }
        let existing = Data("目标旧版本\n".utf8)
        try existing.write(to: output)
        try rejects("Existing output requires explicit approval") { _ = try EditedDocumentExporter.export(prepared, to: output) }
        let replaced = try EditedDocumentExporter.export(prepared, to: output, overwrite: .replace(expectedSHA256: FileSafety.digest(existing)))
        try check(try replaced.snapshotURL.map { try Data(contentsOf: $0) } == existing, "Overwriting keeps verified destination snapshot")
        try rejects("Extension changes are not silent conversions") { _ = try EditedDocumentExporter.export(prepared, to: directory.appendingPathComponent("错误转换.pdf")) }

        let inbound = directory.appendingPathComponent("最初收到的副本.md")
        try originalBytes.write(to: inbound)
        var incoming = IncomingDocument(requestID: UUID().uuidString, itemID: "source", sourceBundleID: CurrentDocumentDispatcher.researchBundleID,
                                        type: "markdown", receivedAt: GaoActionContract.timestamp(Date()),
                                        contentSHA256: FileSafety.digest(originalBytes), originalName: inbound.lastPathComponent)
        incoming.inboundAction = "documents.open"; incoming.manifestSHA256 = FileSafety.digest(Data("fixture manifest".utf8))
        incoming.receivedCopyURL = inbound.absoluteString
        text.incoming = incoming
        let recorded = try EditedDocumentExporter.prepare(store: store, chooseVersion: { _ in .currentEdits })
        try check(recorded.protectedOriginals.contains(inbound) && recorded.protectedOriginals.contains(original), "Persisted inbound context protects initial and current Save As paths")
        try rejects("Persisted inbound URL is never an output") { _ = try EditedDocumentExporter.export(recorded, to: inbound, overwrite: .replace(expectedSHA256: FileSafety.digest(originalBytes))) }
        let extra = try EditedDocumentExporter.prepare(store: store, protectedOriginal: inbound, chooseVersion: { _ in .currentEdits })
        try rejects("An original inbound copy remains protected after Save As") { _ = try EditedDocumentExporter.export(extra, to: inbound, overwrite: .replace(expectedSHA256: FileSafety.digest(originalBytes))) }
        try rejects("The current Save As path is protected as well") { _ = try EditedDocumentExporter.export(extra, to: original, overwrite: .replace(expectedSHA256: FileSafety.digest(originalBytes))) }
        try FileManager.default.removeItem(at: inbound)
        try rejects("A deleted inbound path is not silently recreated") { _ = try EditedDocumentExporter.export(extra, to: inbound) }
        try check(!FileManager.default.fileExists(atPath: inbound.path), "Deleted protected path stays absent")

        try Data("changed private snapshot".utf8).write(to: prepared.sourceURL)
        let tamperedOutput = directory.appendingPathComponent("不应导出.md")
        try rejects("Tampered prepared data is rejected before commit") { _ = try EditedDocumentExporter.export(prepared, to: tamperedOutput) }
        try check(!FileManager.default.fileExists(atPath: tamperedOutput.path), "Tampering creates no user output")

        store.newText(.latex, text: "\\documentclass{article}\n\\begin{document}当前源码\\end{document}")
        let latex = try EditedDocumentExporter.prepare(store: store, chooseVersion: { _ in .currentEdits })
        let latexURL = directory.appendingPathComponent("源码副本.tex")
        _ = try EditedDocumentExporter.export(latex, to: latexURL)
        try check(try String(contentsOf: latexURL, encoding: .utf8) == store.active?.text && latex.title.hasSuffix(".tex"), "Ordinary LaTeX export keeps source extension and content")

        let office = directory.appendingPathComponent("只读宏文档.docm"), officeBytes = Data([0x50, 0x4b, 0x03, 0x04, 0, 255, 128])
        try officeBytes.write(to: office)
        store.open(office)
        let officeExport = try EditedDocumentExporter.prepare(store: store, chooseVersion: { _ in .currentEdits })
        let officeURL = directory.appendingPathComponent("只读副本.docm")
        _ = try EditedDocumentExporter.export(officeExport, to: officeURL)
        try check(try Data(contentsOf: officeURL) == officeBytes && store.active?.kind.isOfficeViewer == true, "Read-only Office copy preserves every byte without converting or editing")
        store.active?.moduleDirty = true
        try rejects("Unsupported legacy dirty format must be saved explicitly") { _ = try EditedDocumentExporter.prepare(store: store, chooseVersion: { _ in .currentEdits }) }
        try check(store.active?.moduleDirty == true, "Refusal keeps legacy dirty state")

        let pdfURL = directory.appendingPathComponent("当前表单.pdf"), pdfBytes = try fixture()
        try pdfBytes.write(to: pdfURL)
        store.open(pdfURL)
        let model = PDFWorkspaceModel(url: pdfURL)
        guard let page = model.document?.page(at: 0) else { throw FileIssue.message("Missing PDF form fixture") }
        try model.addText("未保存批注", note: false, page: page, at: CGPoint(x: 20, y: 80))
        guard let field = model.formEntries.first?.annotation else { throw FileIssue.message("Missing PDF form field") }
        let pdfRecovery = FileSafety.root.appendingPathComponent("Recovery/PDF/\(FileSafety.digest(Data(pdfURL.standardizedFileURL.path.utf8)))/draft.pdf")
        var commits = 0
        let registry = CurrentDocumentHandoffRegistry(formCommitter: { current in
            commits += 1
            try check(current === model, "Exporter commits the currently registered model")
            field.widgetStringValue = "最新输入尚未定时落盘"
            current.formMayHaveChanged()
        })
        registry.register(model)
        let pdf = try EditedDocumentExporter.prepare(store: store, registry: registry, chooseVersion: { _ in .currentEdits })
        let pdfRecoveryAfterPreparation = try Data(contentsOf: pdfRecovery)
        let exportedPDF = directory.appendingPathComponent("表单编辑副本.pdf")
        _ = try EditedDocumentExporter.export(pdf, to: exportedPDF)
        let reopened = PDFDocument(url: exportedPDF)
        try check(commits >= 1 && reopened?.page(at: 0)?.annotations.first(where: { $0.fieldName == "Latest" })?.widgetStringValue == "最新输入尚未定时落盘", "Immediate form value reaches edited copy")
        try check(reopened?.page(at: 0)?.annotations.contains(where: { $0.contents == "未保存批注" }) == true, "Unsaved annotation is in the same PDF snapshot")
        try check(model.dirty && model.canUndo && (try Data(contentsOf: pdfRecovery)) == pdfRecoveryAfterPreparation && (try Data(contentsOf: pdfURL)) == pdfBytes, "PDF original, committed recovery, dirty and undo state survive export")
        let disk = try EditedDocumentExporter.prepare(store: store, registry: registry, chooseVersion: { _ in .diskOriginal })
        try check(disk.versionKind == "savedVersion" && disk.sha256 == FileSafety.digest(pdfBytes), "Explicit saved-version export uses exact disk bytes")
        try rejects("PDF version cancellation stops export preparation") { _ = try EditedDocumentExporter.prepare(store: store, registry: registry, chooseVersion: { _ in .cancel }) }
        registry.unregister(model)
        store.active?.moduleDirty = true
        try rejects("Missing live PDF model never rebuilds from recovery") { _ = try EditedDocumentExporter.prepare(store: store, registry: registry, chooseVersion: { _ in .currentEdits }) }
        store.showingNotes = true
        try rejects("Notes view cannot export a hidden document without selecting it") { _ = try EditedDocumentExporter.prepare(store: store, chooseVersion: { _ in .currentEdits }) }
        store.showingNotes = false
        let longPDF = directory.appendingPathComponent(String(repeating: "p", count: 235) + ".pdf")
        try pdfBytes.write(to: longPDF); store.open(longPDF)
        let longPDFExport = try EditedDocumentExporter.prepare(store: store, chooseVersion: { _ in .diskOriginal })
        let longPDFCopy = directory.appendingPathComponent("长文件名副本.pdf")
        _ = try EditedDocumentExporter.export(longPDFExport, to: longPDFCopy)
        try check(longPDFExport.title.hasSuffix(".pdf") && longPDFExport.title.utf8.count <= 220 && PDFDocument(url: longPDFCopy)?.pageCount == 1, "Long PDF basenames truncate without losing the PDF extension or bytes")
        let longOffice = directory.appendingPathComponent(String(repeating: "m", count: 235) + ".docm")
        try officeBytes.write(to: longOffice); store.open(longOffice)
        let longOfficeExport = try EditedDocumentExporter.prepare(store: store, chooseVersion: { _ in .diskOriginal })
        let longOfficeCopy = directory.appendingPathComponent("长文件名宏副本.docm")
        _ = try EditedDocumentExporter.export(longOfficeExport, to: longOfficeCopy)
        try check(longOfficeExport.title.hasSuffix(".docm") && longOfficeExport.title.utf8.count <= 220 && (try Data(contentsOf: longOfficeCopy)) == officeBytes, "Long Office basenames retain the complete original format and macro bytes")
        model.discardDraft()
        try check(NSApp == nil, "Export tests never create app or windows")
        print("Edited document export: current UTF8/PDF snapshots, read-only byte preservation, target snapshots, inbound/current/hardlink/symlink protection, cancellation and failure state passed")
    }

    private static func fixture() throws -> Data {
        let bytes = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let consumer = CGDataConsumer(data: bytes), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw FileIssue.message("Cannot create PDF fixture") }
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        guard let document = PDFDocument(data: bytes as Data), let page = document.page(at: 0) else { throw FileIssue.message("Cannot decode PDF fixture") }
        let field = PDFAnnotation(bounds: CGRect(x: 20, y: 300, width: 240, height: 25), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text; field.fieldName = "Latest"; field.widgetStringValue = "saved value"
        field.font = NSFont(name: "Helvetica", size: 12); page.addAnnotation(field)
        guard let result = document.dataRepresentation() else { throw FileIssue.message("Cannot serialize PDF fixture") }
        return result
    }
    private static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw FileIssue.message("Edited export: " + message) }
    }
    private static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw FileIssue.message("Expected edited export rejection: " + message)
    }
}
