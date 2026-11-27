import AppKit
import PDFKit

enum ProjectPDFRole: Hashable {
    case document, latexPreview, latexReader
}

extension ProjectReadingPositions {
    subscript(role: ProjectPDFRole) -> ProjectPDFPosition? {
        get {
            switch role {
            case .document: return document
            case .latexPreview: return latexPreview
            case .latexReader: return latexReader
            }
        }
        set {
            switch role {
            case .document: document = newValue
            case .latexPreview: latexPreview = newValue
            case .latexReader: latexReader = newValue
            }
        }
    }
}

enum ProjectPDFViewport {
    /// PDFKit's currentPage can lag behind scrolling. Select the page with the
    /// greatest actual intersection, preferring the current page only for a tie.
    static func position(viewport: CGRect, pages: [(Int, CGRect)], flipped: Bool, preferred: Int?) -> ProjectPDFPosition? {
        guard !viewport.isEmpty else { return nil }
        var best: (index: Int, rect: CGRect, area: CGFloat)?
        for (index, rect) in pages where rect.width > 0 && rect.height > 0 {
            let intersection = rect.intersection(viewport)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if let previous = best, area < previous.area || (area == previous.area && index != preferred) { continue }
            best = (index, rect, area)
        }
        guard let best else { return nil }
        let distance = flipped ? viewport.minY - best.rect.minY : best.rect.maxY - viewport.maxY
        return ProjectPDFPosition(pageIndex: best.index, offset: Double(max(0, min(1, distance / best.rect.height))))
    }

    static func scrollY(page: CGRect, viewportHeight: CGFloat, flipped: Bool, offset: Double) -> CGFloat {
        let advance = page.height * CGFloat(offset)
        return flipped ? page.minY + advance : page.maxY - advance - viewportHeight
    }
}

@MainActor final class WritingProjectReadingTracker {
    @MainActor private final class Reader {
        weak var view: PDFView?
        weak var document: PDFDocument?
        var pending: Bool

        init(view: PDFView, pending: Bool) {
            self.view = view
            self.document = view.document
            self.pending = pending
        }
    }

    private var saved = ProjectReadingPositions()
    private var readers: [ProjectPDFRole: Reader] = [:]

    func capture() -> ProjectReadingPositions {
        for (role, reader) in readers {
            if !reader.pending, let view = reader.view, let position = position(in: view) { saved[role] = position }
        }
        return saved
    }

    func restore(_ reading: ProjectReadingPositions) {
        saved = reading
        for (role, reader) in readers {
            reader.pending = reading[role] != nil
            if let view = reader.view { applyPending(in: view, role: role) }
        }
    }

    func attach(_ view: PDFView, role: ProjectPDFRole) {
        if let reader = readers[role], reader.view === view, reader.document === view.document { return }
        readers[role] = Reader(view: view, pending: saved[role] != nil)
        DispatchQueue.main.async { [weak self, weak view] in
            if let view { self?.applyPending(in: view, role: role) }
        }
    }

    func hasPosition(for role: ProjectPDFRole) -> Bool { saved[role] != nil }

    func detach(_ view: PDFView, role: ProjectPDFRole) {
        guard let reader = readers[role], reader.view === view else { return }
        if !reader.pending, let position = position(in: view) { saved[role] = position }
        readers.removeValue(forKey: role)
    }

    func applyPending(in view: PDFView, role: ProjectPDFRole) {
        guard let reader = readers[role], reader.view === view, reader.pending,
              let anchor = saved[role], anchor.isValid,
              view.window != nil, view.bounds.width > 40, view.bounds.height > 40,
              let document = view.document, document.pageCount > 0,
              let page = document.page(at: min(anchor.pageIndex, document.pageCount - 1)) else { return }
        reader.pending = false
        view.go(to: page)
        view.layoutDocumentView()
        guard let scroll = view.documentView?.enclosingScrollView else { return }
        let clip = scroll.contentView
        let box = clip.convert(view.convert(page.bounds(for: view.displayBox), from: page), from: view).standardized
        var bounds = clip.bounds
        bounds.origin.y = ProjectPDFViewport.scrollY(page: box, viewportHeight: bounds.height, flipped: clip.isFlipped, offset: anchor.offset)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    func position(in view: PDFView) -> ProjectPDFPosition? {
        guard view.window != nil, let document = view.document else { return nil }
        let clip = view.documentView?.enclosingScrollView?.contentView
        let viewport = clip?.bounds ?? view.visibleRect
        let pages = view.visiblePages.map { page -> (Int, CGRect) in
            let region = view.convert(page.bounds(for: view.displayBox), from: page)
            return (document.index(for: page), (clip?.convert(region, from: view) ?? region).standardized)
        }
        return ProjectPDFViewport.position(viewport: viewport, pages: pages, flipped: clip?.isFlipped ?? view.isFlipped,
                                           preferred: view.currentPage.map { document.index(for: $0) })
    }
}
