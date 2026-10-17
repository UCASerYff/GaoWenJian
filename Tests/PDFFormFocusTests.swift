import AppKit
import Foundation
import PDFKit
import CoreText

/// These tests exercise the real model's form-change/undo/recovery boundaries.
/// They never create an App/window or claim to verify a real field editor.
enum PDFFormFocusTests {
    @MainActor static func run(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("Form lifecycle.pdf")
        try writeUIFixture(to: source)
        let original = try Data(contentsOf: source)
        let model = PDFWorkspaceModel(url: source)
        let recovery = recoveryURL(for: source)
        let first = try field("Title", in: model)

        model.formInteractionWillBegin()
        model.formMayHaveChanged()
        try check(!model.dirty && !model.canUndo, "Entering or polling an unchanged field is not an edit")
        try check(!FileManager.default.fileExists(atPath: recovery.path), "A click does not manufacture a recovery draft")

        first.widgetStringValue = "first actual value"
        model.formMayHaveChanged()
        try check(model.dirty && model.canUndo, "An actual widget change records dirty and undo without a mouse click")
        try check(try fieldValue("Title", at: recovery) == "first actual value", "The first observed value immediately reaches recovery")
        first.widgetStringValue = "latest value in same field"
        model.formMayHaveChanged()
        try check(try fieldValue("Title", at: recovery) == "latest value in same field", "Later typing is not lost behind a one-shot click timer")
        try model.undo()
        try check(try field("Title", in: model).widgetStringValue == "DISK TITLE", "One form editing group undoes to the pre-input value")
        try model.redo()
        try check(try field("Title", in: model).widgetStringValue == "latest value in same field", "Redo restores the complete form edit")

        model.formInteractionWillBegin()
        try field("Followup", in: model).widgetStringValue = "keyboard reached second page"
        model.formMayHaveChanged(endingEditing: true)
        try model.undo()
        try check(try field("Followup", in: model).widgetStringValue == "DISK FOLLOWUP", "Keyboard-style field changes receive their own undo state")
        try check(try field("Title", in: model).widgetStringValue == "latest value in same field", "Undo of the next field retains the previous field")
        try model.redo()
        try check(try field("Followup", in: model).widgetStringValue == "keyboard reached second page", "Redo retains the second-page field")

        // A form edit must be the next undo operation, not silently erase the
        // earlier text annotation as the old external-edit path did.
        try model.addText("KEEP ANNOTATION", note: false, page: model.document!.page(at: 0)!, at: CGPoint(x: 50, y: 160))
        let annotationCount = model.annotationEntries.count
        try field("Title", in: model).widgetStringValue = "after annotation"
        model.formMayHaveChanged(endingEditing: true)
        try model.undo()
        try check(model.annotationEntries.count == annotationCount && model.annotationEntries.contains { $0.annotation.contents == "KEEP ANNOTATION" }, "Undoing a form change preserves prior unsaved annotations")
        try check(try field("Title", in: model).widgetStringValue == "latest value in same field", "Undo reaches the form value from before that edit")
        try model.redo()
        try check(try field("Title", in: model).widgetStringValue == "after annotation" && model.annotationEntries.count == annotationCount, "Redo restores the form without duplicating the annotation")

        // An explicit commit/snapshot synchronizes even before the next poll.
        try field("Title", in: model).widgetStringValue = "IMMEDIATE COMMIT"
        let registry = CurrentDocumentHandoffRegistry()
        registry.register(model)
        let snapshot = try registry.snapshotCurrentPDF(for: source, to: directory.appendingPathComponent("current-copy.pdf"))
        try check(try fieldValue("Title", at: snapshot.url) == "IMMEDIATE COMMIT", "The default commit boundary captures an unpolled actual value")
        try check(try fieldValue("Title", at: recovery) == "IMMEDIATE COMMIT", "Recovery agrees with the committed handoff snapshot")
        try check(model.dirty && model.canUndo, "Handoff keeps unsaved state and its undo history")
        try check(try Data(contentsOf: source) == original, "Handoff never writes the original")
        let recovered = PDFWorkspaceModel(url: source)
        try check(recovered.dirty && (try field("Title", in: recovered)).widgetStringValue == "IMMEDIATE COMMIT", "A reconstructed recovery model contains the same committed value")
        try check(recovered.annotationEntries.contains { $0.annotation.contents == "KEEP ANNOTATION" }, "Recovery retains prior unsaved annotations")

        let beforeNoChangeUndo = model.canUndo
        model.formInteractionWillBegin()
        model.formMayHaveChanged(endingEditing: true)
        try check(model.canUndo == beforeNoChangeUndo, "Unchanged editing notifications do not create another undo state")
        try model.undo()
        try check(try field("Title", in: model).widgetStringValue == "after annotation", "Undo after handoff still restores the immediate preceding value")
        try model.redo()
        try check(try field("Title", in: model).widgetStringValue == "IMMEDIATE COMMIT", "Redo after handoff restores the exported value")
        try check(try Data(contentsOf: source) == original, "Undo and redo leave disk bytes unchanged")
        model.discardDraft()

        let closeSource = directory.appendingPathComponent("Close boundary.pdf")
        try original.write(to:closeSource)
        let closeModel = PDFWorkspaceModel(url:closeSource)
        let store = WorkspaceStore()
        let tab = FileSession(url:closeSource,kind:.pdf)
        store.tabs.append(tab)
        CurrentDocumentHandoffRegistry.shared.register(closeModel)
        let closeAlias = directory.appendingPathComponent("Hard-link close boundary.pdf")
        try FileManager.default.linkItem(at:closeSource,to:closeAlias)
        let aliasModel = PDFWorkspaceModel(url:closeAlias)
        CurrentDocumentHandoffRegistry.shared.register(aliasModel)
        defer {
            CurrentDocumentHandoffRegistry.shared.unregister(closeModel)
            CurrentDocumentHandoffRegistry.shared.unregister(aliasModel)
        }
        try check(!tab.moduleDirty,"Close-boundary session starts clean")
        try field("Title",in:closeModel).widgetStringValue="UNOBSERVED BEFORE CLOSE"
        try store.commitCurrentPDFEdits(for:tab)
        try check(tab.moduleDirty && closeModel.dirty && !aliasModel.dirty,"The close/quit boundary commits the exact session even when an inode alias is open, without waiting for a UI observer")
        try check(try fieldValue("Title",at:recoveryURL(for:closeSource)) == "UNOBSERVED BEFORE CLOSE","The close/quit boundary persists the focused-field model value")
        try check(try Data(contentsOf:closeSource) == original,"The close/quit boundary keeps source bytes untouched")
        closeModel.discardDraft()
        print("PDF form model boundaries passed: actual-value dirty checks, grouped undo/redo, annotation retention, immediate commit, recovery and snapshot consistency. Real input focus remains a separate GUI check.")
    }

    /// Self-generated, private acceptance input. No real document is read.
    @MainActor static func writeUIFixture(to url: URL) throws {
        let bytes = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: bytes), let context = CGContext(consumer: consumer, mediaBox: &media, nil) else {
            throw PDFWorkspaceError.message("Cannot create form lifecycle fixture")
        }
        for index in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor); context.fill(media)
            context.textPosition = CGPoint(x: 50, y: 730)
            let heading = NSAttributedString(string: "GAO FILE FORM ACCEPTANCE - PAGE \(index + 1)", attributes: [.font: NSFont(name: "Helvetica", size: 16)!])
            CTLineDraw(CTLineCreateWithAttributedString(heading), context)
            context.textPosition = CGPoint(x: 50, y: 680)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: index == 0 ? "Title: click field, type and hand off without clicking blank space" : "Followup: reach by keyboard, then verify page order", attributes: [.font: NSFont(name: "Helvetica", size: 11)!])), context)
            context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: bytes as Data) else { throw PDFWorkspaceError.message("Cannot read generated form fixture") }
        for (index, name, value) in [(0, "Title", "DISK TITLE"), (1, "Followup", "DISK FOLLOWUP")] {
            let widget = PDFAnnotation(bounds: CGRect(x: 50, y: 630, width: 420, height: 28), forType: .widget, withProperties: nil)
            widget.widgetFieldType = .text; widget.fieldName = name; widget.widgetStringValue = value
            widget.font = NSFont(name: "Helvetica", size: 14); widget.fontColor = .black
            widget.color = .lightGray; widget.backgroundColor = .white
            let border = PDFBorder(); border.lineWidth = 1; widget.border = border
            document.page(at: index)?.addAnnotation(widget)
        }
        guard let output = document.dataRepresentation() else { throw PDFWorkspaceError.message("Cannot serialize generated form fixture") }
        try output.write(to: url, options: .withoutOverwriting)
    }

    private static func recoveryURL(for source: URL) -> URL {
        FileSafety.root.appendingPathComponent("Recovery/PDF/\(FileSafety.digest(Data(source.standardizedFileURL.path.utf8)))/draft.pdf")
    }
    @MainActor private static func field(_ name: String, in model: PDFWorkspaceModel) throws -> PDFAnnotation {
        guard let field = model.formEntries.first(where: { $0.annotation.fieldName == name })?.annotation else { throw PDFWorkspaceError.message("Missing test form " + name) }
        return field
    }
    private static func fieldValue(_ name: String, at url: URL) throws -> String? {
        guard let document = PDFDocument(url: url) else { throw PDFWorkspaceError.message("Missing test PDF " + url.lastPathComponent) }
        return (0..<document.pageCount).compactMap { index in document.page(at: index)?.annotations.first(where: { $0.fieldName == name })?.widgetStringValue }.first
    }
    private static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        if try !condition() { throw PDFWorkspaceError.message("PDF form test: " + label) }
    }
}
