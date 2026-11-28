import AppKit
import CoreGraphics
import PDFKit
import SwiftUI

@main struct NativePDFViewportTests {
    @MainActor static func main() throws {
        let root = FileSafety.root
        try require(CommandLine.arguments.contains("--data-dir") && root.path.hasPrefix("/private/tmp/gaowenjian-tests."),
                    "The native regression requires an isolated temporary profile")
        _ = NSApplication.shared
        try run(in: root.deletingLastPathComponent().appendingPathComponent("PDFViewport", isDirectory: true))
        print("PASS: native PDF viewport restore, toolbar page tracking, and checkpoint")
    }

    @MainActor static func run(in directory: URL) throws {
        let profile = directory.appendingPathComponent("profile", isDirectory: true)
        let projectFolder = directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        let main = projectFolder.appendingPathComponent("main.md")
        let pdf = projectFolder.appendingPathComponent("proof.pdf")
        try Data("# Synthetic project\n".utf8).write(to: main)
        let originalPDF = try fixture()
        try originalPDF.write(to: pdf)

        let opening = ProjectPDFPosition(pageIndex: 1, offset: 0.21)
        let afterScroll = ProjectPDFPosition(pageIndex: 2, offset: 0.31)
        let seed = WorkspaceStore(dataRoot: profile)
        seed.open(main)
        seed.open(pdf)
        guard let seedTab = seed.active, seedTab.url == pdf else { throw failure("Could not open the fixture PDF") }
        seedTab.projectReading.restore(.init(document: opening))
        try seed.saveWritingProject(id: nil, name: "PDF viewport", folder: projectFolder.path, main: main.path)
        guard let projectID = seed.activeWritingProjectID else { throw failure("Could not save the fixture project") }

        let cold = WorkspaceStore(dataRoot: profile)
        try cold.restoreWritingProject(projectID, drafts: .requireSaved)
        guard let tab = cold.active, tab.url == pdf else { throw failure("The cold project did not select the saved PDF") }
        let tracker = tab.projectReading
        try require(tracker.capture().document == opening, "Cold position did not survive before the reader mounted")

        let model = PDFWorkspaceModel(url: pdf)
        let canvas = PDFCanvas(model: model, twoUp: false, placement: nil, onAnnotationDoubleClick: { _ in },
                               projectReading: tracker)
        try withHiddenHost(canvas) { host in
            guard let view = model.pdfView else { throw failure("SwiftUI did not mount the real PDF canvas") }
            try requirePosition(sampleViewport(view), opening, "Cold ordinary PDF viewport")
            try require(model.currentPage == 2, "The toolbar did not report page 2 after restoration")
            settle(host)
            try requirePosition(sampleViewport(view), opening, "Ordinary PDF viewport after another AppKit layout cycle")
            try require(model.currentPage == 2, "The toolbar page changed after restoration settled")

            try scrollClip(view, to: afterScroll)
            settle(host)
            try requirePosition(sampleViewport(view), afterScroll, "Viewport after scrolling the native clip")
            try require(model.currentPage == 3, "A native clip scroll did not update the toolbar to page 3")
            try cold.checkpointWritingProject()
        }
        let reloaded = WorkspaceStore(dataRoot: profile)
        try reloaded.restoreWritingProject(projectID, drafts: .requireSaved)
        try requirePosition(reloaded.active?.projectReading.capture().document, afterScroll, "Checkpoint from the scrolled viewport")

        let previewTracker = WritingProjectReadingTracker()
        previewTracker.restore(.init(latexPreview: opening))
        let controls = LaTeXPDFControls()
        let preview = LaTeXPDFPreview(url: pdf, controls: controls, highlightPage: nil, highlightPoint: nil,
                                      highlightGeneration: 0, onCommandClick: { _, _ in }, projectReading: previewTracker)
        try withHiddenHost(preview) { host in
            guard let view = controls.pdfView else { throw failure("SwiftUI did not mount the real LaTeX PDF preview") }
            try requirePosition(sampleViewport(view), opening, "Cold split LaTeX PDF viewport")
            settle(host)
            try requirePosition(sampleViewport(view), opening, "Split LaTeX PDF viewport after layout settled")
            try scrollClip(view, to: afterScroll)
            settle(host)
            try requirePosition(previewTracker.capture().latexPreview, afterScroll, "LaTeX tracker capture after native scroll")
        }
        let finalPDF = try Data(contentsOf: pdf)
        try require(finalPDF == originalPDF, "Viewport operations changed the original PDF bytes")
    }

    @MainActor private static func withHiddenHost<V: View>(_ root: V, body: (NSView) throws -> Void) throws {
        let host = NSHostingView(rootView: root.frame(width: 590, height: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        settle(host)
        try body(host)
    }

    @MainActor private static func settle(_ host: NSView) {
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
        }
    }

    // Probe the native clip through PDFKit page coordinates. It is independent of
    // the tracker's page-overlap algorithm and does not use PDFView.currentPage.
    @MainActor private static func sampleViewport(_ view: PDFView) -> ProjectPDFPosition? {
        guard let clip = view.documentView?.enclosingScrollView?.contentView,
              let document = view.document, !clip.bounds.isEmpty else { return nil }
        let bounds = clip.bounds
        let center = view.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: clip)
        guard let page = view.page(for: center, nearest: false) else { return nil }
        let topY = clip.isFlipped ? bounds.minY : bounds.maxY
        let top = view.convert(CGPoint(x: bounds.midX, y: topY), from: clip)
        let pageTop = view.convert(top, to: page).y
        let box = page.bounds(for: view.displayBox)
        guard box.height > 0 else { return nil }
        return ProjectPDFPosition(pageIndex: document.index(for: page), offset: Double((box.maxY - pageTop) / box.height))
    }

    @MainActor private static func scrollClip(_ view: PDFView, to position: ProjectPDFPosition) throws {
        guard let scroll = view.documentView?.enclosingScrollView,
              let page = view.document?.page(at: position.pageIndex) else { throw failure("No native PDF scroll view or fixture page") }
        let clip = scroll.contentView
        let box = page.bounds(for: view.displayBox)
        let point = view.convert(CGPoint(x: box.midX, y: box.maxY - box.height * CGFloat(position.offset)), from: page)
        let topY = clip.convert(point, from: view).y
        var bounds = clip.bounds
        bounds.origin.y = clip.isFlipped ? topY : topY - bounds.height
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private static func fixture() throws -> Data {
        let buffer = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 480, height: 720)
        guard let consumer = CGDataConsumer(data: buffer), let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
            throw failure("Could not construct the four-page fixture")
        }
        for index in 0..<4 {
            context.beginPDFPage(nil)
            context.setFillColor(red: CGFloat(index + 1) / 8, green: 0.4, blue: 0.6, alpha: 1)
            context.fill(CGRect(x: 24, y: 670, width: 120, height: 16))
            context.endPDFPage()
        }
        context.closePDF()
        return buffer as Data
    }

    private static func requirePosition(_ actual: ProjectPDFPosition?, _ expected: ProjectPDFPosition, _ phase: String) throws {
        guard let actual, actual.pageIndex == expected.pageIndex, abs(actual.offset - expected.offset) < 0.05 else {
            throw failure("\(phase) expected \(expected); received \(String(describing: actual))")
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
        guard condition() else { throw failure(detail) }
    }

    private static func failure(_ detail: String) -> FileIssue { .message("Native PDF viewport regression: \(detail)") }
}
