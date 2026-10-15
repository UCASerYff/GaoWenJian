import AppKit
import Foundation
import PDFKit

enum CurrentDocumentHandoffTests {
    @MainActor static func run(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("即时 表单.pdf")
        let sourceBytes = try fixture()
        try sourceBytes.write(to: source)
        let model = PDFWorkspaceModel(url: source)
        guard let page = model.document?.page(at: 0) else {
            throw PDFWorkspaceError.message("Current document fixture could not load its form")
        }
        // The disk recovery still contains this earlier value when the next
        // field entry occurs, reproducing the 1.5-second recovery delay risk.
        try model.addText("保留的未保存批注", note: false, page: page, at: CGPoint(x: 20, y: 80))
        guard let widget = model.formEntries.first?.annotation else { throw PDFWorkspaceError.message("Current document fixture lost its form") }
        let recovery = FileSafety.root.appendingPathComponent("Recovery/PDF/\(FileSafety.digest(Data(source.standardizedFileURL.path.utf8)))/draft.pdf")
        let recoveryBefore = try Data(contentsOf: recovery)
        var commits = 0
        let registry = CurrentDocumentHandoffRegistry(formCommitter: { current in
            commits += 1
            try check(current === model, "Committer receives the actual registered editor model")
            widget.widgetStringValue = "刚输入，尚未写入恢复稿"
            current.formMayHaveChanged()
        })
        registry.register(model)
        try check(try registry.currentPDF(for: source) === model, "Lookup returns the actual editor, not another model")
        let output = directory.appendingPathComponent("即时编辑副本.pdf")
        let snapshot = try registry.snapshotCurrentPDF(for: source, to: output)
        try check(commits == 1, "Field commit runs before snapshot")
        let exported = try Data(contentsOf: output)
        let reopened = PDFDocument(data: exported)
        try check(reopened?.page(at: 0)?.annotations.first(where: { $0.fieldName == "Latest" })?.widgetStringValue == "刚输入，尚未写入恢复稿", "Immediate in-memory form input reaches export without waiting for recovery")
        try check(reopened?.page(at: 0)?.annotations.contains(where: { $0.contents == "保留的未保存批注" }) == true, "Unsaved annotation is exported with the same current model")
        try check(snapshot.sha256 == FileSafety.digest(exported) && snapshot.pageCount == 1, "Snapshot bytes have a verified digest and page count")
        try check(model.dirty && model.canUndo, "Export retains editor dirty/undo state")
        try check(try Data(contentsOf: recovery) == recoveryBefore, "Export does not replace or delete the earlier recovery draft")
        try check(try Data(contentsOf: source) == sourceBytes, "Export never changes original bytes")

        let alias = directory.appendingPathComponent("符号链接.pdf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        try check(try registry.currentPDF(for: alias) === model, "Symlink aliases resolve to the same current model")
        let hardlink = directory.appendingPathComponent("硬链接.pdf")
        try FileManager.default.linkItem(at: source, to: hardlink)
        try check(try registry.currentPDF(for: hardlink) === model, "Same-inode aliases resolve to the same current model")
        let otherModel = PDFWorkspaceModel(url: source)
        registry.register(otherModel)
        try rejects("Two current editors are ambiguous") { _ = try registry.snapshotCurrentPDF(for: source, to: directory.appendingPathComponent("不应生成.pdf")) }
        try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("不应生成.pdf").path), "Ambiguity does not write output")
        registry.unregister(otherModel)
        registry.register(model)
        try check(try registry.currentPDF(for: source) === model, "Repeated registration remains one model")

        let rejection = CurrentDocumentHandoffRegistry(formCommitter: { _ in throw PDFWorkspaceError.message("fixture commit refused") })
        rejection.register(model)
        try rejects("Refused field commit stops capture") { _ = try rejection.snapshotCurrentPDF(for: source, to: directory.appendingPathComponent("拒绝输入.pdf")) }
        try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("拒绝输入.pdf").path), "Refused commit preserves all paths")
        let unchanged = Data("existing destination".utf8), existing = directory.appendingPathComponent("已有目标.pdf")
        try unchanged.write(to: existing)
        try rejects("Existing file is exclusive") { _ = try registry.snapshotCurrentPDF(for: source, to: existing) }
        try check(try Data(contentsOf: existing) == unchanged, "Existing destination is unchanged")
        try rejects("Original is never an export target") { _ = try registry.snapshotCurrentPDF(for: source, to: source) }
        try check(try Data(contentsOf: source) == sourceBytes, "Rejected source target is unchanged")
        try rejects("Missing parent export fails") { _ = try registry.snapshotCurrentPDF(for: source, to: directory.appendingPathComponent("missing/new.pdf")) }
        try check(try Data(contentsOf: recovery) == recoveryBefore && model.dirty && model.canUndo, "Failed export keeps recovery and edit state")

        var external = sourceBytes; external.append(Data("\n% external replacement\n".utf8))
        try external.write(to: source)
        try rejects("Export preserves ordinary save conflict checks") { _ = try model.save() }
        try check(try Data(contentsOf: source) == external, "External version survives failed save")
        registry.unregister(model)
        try check(try registry.commitCurrentPDF(for: source) == nil, "Closed editor is not reconstructed")
        try rejects("No current editor refuses unsaved export") { _ = try registry.snapshotCurrentPDF(for: source, to: directory.appendingPathComponent("不能重建.pdf")) }
        try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("不能重建.pdf").path), "Missing-model path does not create a stale export")

        let weakSource = directory.appendingPathComponent("可释放.pdf")
        try sourceBytes.write(to: weakSource)
        var transient: PDFWorkspaceModel? = PDFWorkspaceModel(url: weakSource)
        weak var weakModel = transient
        registry.register(transient!)
        transient = nil
        try check(weakModel == nil && (try registry.currentPDF(for: weakSource)) == nil, "Registry never retains closed models")
        model.discardDraft()
        print("Current PDF handoff: live-model capture, immediate form commit, aliases, weak lifecycle, ambiguity, original/recovery/undo preservation, failed export and external conflicts passed")
    }

    private static func fixture() throws -> Data {
        let bytes = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let consumer = CGDataConsumer(data: bytes), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw PDFWorkspaceError.message("Cannot create current document PDF fixture")
        }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor); context.fill(media)
        context.endPDFPage(); context.closePDF()
        guard let document = PDFDocument(data: bytes as Data), let page = document.page(at: 0) else {
            throw PDFWorkspaceError.message("Cannot decode current document PDF fixture")
        }
        let widget = PDFAnnotation(bounds: CGRect(x: 20, y: 300, width: 240, height: 25), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        widget.fieldName = "Latest"
        widget.widgetStringValue = "saved value"
        widget.font = NSFont(name: "Helvetica", size: 12)
        page.addAnnotation(widget)
        guard let data = document.dataRepresentation() else { throw PDFWorkspaceError.message("Cannot serialize current document PDF fixture") }
        return data
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        if try !condition() { throw PDFWorkspaceError.message("Current document handoff: " + label) }
    }
    private static func rejects(_ label: String, _ work: () throws -> Void) throws {
        do { try work() } catch { return }
        throw PDFWorkspaceError.message("Expected rejection: " + label)
    }
}
