import AppKit
import Foundation
import Darwin

/// A handoff must use the same PDF model that the editor is displaying. Recovery
/// files deliberately lag form entry and are not an authoritative export source.
/// The registry is weak so closing a tab never keeps its model alive.
@MainActor
final class CurrentDocumentHandoffRegistry {
    static let shared = CurrentDocumentHandoffRegistry()

    typealias FormCommitter = @MainActor (PDFWorkspaceModel) throws -> Void
    private final class Entry {
        weak var model: PDFWorkspaceModel?
        init(_ model: PDFWorkspaceModel) { self.model = model }
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private let formCommitter: FormCommitter

    init(formCommitter: @escaping FormCommitter = CurrentDocumentHandoffRegistry.commitDisplayedForm) {
        self.formCommitter = formCommitter
    }

    func register(_ model: PDFWorkspaceModel) {
        removeClosedModels()
        entries[ObjectIdentifier(model)] = Entry(model)
    }

    func unregister(_ model: PDFWorkspaceModel) {
        entries.removeValue(forKey: ObjectIdentifier(model))
    }

    /// Ambiguous copies of one document require the user to choose an editor;
    /// guessing could send another window's unsaved text or form values.
    func currentPDF(for url: URL) throws -> PDFWorkspaceModel? {
        guard url.isFileURL else { throw PDFWorkspaceError.message("交接文档必须是本机文件。") }
        removeClosedModels()
        let matches = entries.values.compactMap(\.model).filter { Self.sameFileContext($0.sourceURL, url) }
        guard matches.count <= 1 else {
            throw PDFWorkspaceError.message("此 PDF 在多个编辑器中打开，无法确认要发送哪份未保存修改。请先保存所需版本或关闭重复标签。")
        }
        return matches.first
    }

    /// Call before choosing between the disk version and the current editor.
    /// The real field editor is committed synchronously, without waiting for the
    /// PDF model's delayed recovery writer. No app/window is created here.
    @discardableResult
    func commitCurrentPDF(for url: URL) throws -> PDFWorkspaceModel? {
        guard let model = try currentPDF(for: url) else { return nil }
        try formCommitter(model)
        return model
    }

    /// Explicit current-editor export. A missing editor is an error, never a
    /// reason to instantiate a second model from a stale recovery file.
    func snapshotCurrentPDF(for url: URL, to destination: URL) throws -> PDFHandoffSnapshot {
        guard let model = try commitCurrentPDF(for: url) else {
            throw PDFWorkspaceError.message("当前 PDF 编辑器尚未就绪，不能确认最新未保存内容。请返回该标签后重试，或明确选择磁盘上的已保存版本。")
        }
        return try model.safeHandoffSnapshot(to: destination)
    }

    private func removeClosedModels() {
        entries = entries.filter { $0.value.model != nil }
    }

    private static func commitDisplayedForm(_ model: PDFWorkspaceModel) throws {
        if let window = model.pdfView?.window, !window.makeFirstResponder(nil) {
            throw PDFWorkspaceError.message("当前 PDF 表单仍在编辑且无法提交，请先完成输入后重试。原件与未保存修改仍保留。")
        }
    }

    private static func sameFileContext(_ left: URL, _ right: URL) -> Bool {
        let canonicalLeft = left.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalRight = right.standardizedFileURL.resolvingSymlinksInPath()
        if canonicalLeft == canonicalRight { return true }
        var lhs = stat(), rhs = stat()
        guard Darwin.lstat(canonicalLeft.path, &lhs) == 0, Darwin.lstat(canonicalRight.path, &rhs) == 0,
              lhs.st_mode & S_IFMT == S_IFREG, rhs.st_mode & S_IFMT == S_IFREG else { return false }
        return lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }
}
