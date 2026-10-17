import AppKit
import Foundation
import CryptoKit
import Darwin
import UniformTypeIdentifiers

/// An immutable, private copy of one explicitly selected editor version. Its
/// lifetime is independent of the original tab, dirty flag and recovery files.
@MainActor final class PreparedEditedDocumentExport {
    let sourceURL: URL
    let title: String
    let versionKind: String
    let sha256: String
    let byteCount: Int64
    let protectedOriginals: [URL]
    private let temporaryDirectory: URL

    fileprivate init(sourceURL: URL, title: String, versionKind: String,
                     sha256: String, byteCount: Int64, protectedOriginals: [URL], directory: URL) {
        self.sourceURL = sourceURL; self.title = title; self.versionKind = versionKind
        self.sha256 = sha256; self.byteCount = byteCount
        self.protectedOriginals = protectedOriginals; self.temporaryDirectory = directory
    }

    deinit { try? FileManager.default.removeItem(at: temporaryDirectory) }
}

/// Exports a user-reviewed file, never a documents.open result attachment. The
/// current research receiver deliberately requires its own edited-copy import.
@MainActor enum EditedDocumentExporter {
    static func prepare(store: WorkspaceStore, registry: CurrentDocumentHandoffRegistry? = nil,
                        protectedOriginal: URL? = nil,
                        chooseVersion: (URL) -> OCRPDFVersion) throws -> PreparedEditedDocumentExport {
        guard !store.showingNotes, let tab = store.active else {
            throw FileIssue.message("请先选择要导出副本的文档标签。")
        }
        guard NSApp?.keyWindow?.makeFirstResponder(nil) != false else {
            throw FileIssue.message("当前输入无法提交，请完成输入后重试；已有文档保留。")
        }
        let registry = registry ?? .shared
        let parent = FileSafety.root.appendingPathComponent("Exchange/Staging/EditedExports", isDirectory: true)
        let parentFD = try GaoPrivateIO.directory(parent, create: true, requirePrivate: true)
        let identifier = UUID().uuidString
        let directoryFD = try GaoPrivateIO.childDirectory(parentFD, identifier, create: true, requirePrivate: true)
        let directory = parent.appendingPathComponent(identifier, isDirectory: true)
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: directory) } }

        let titleURL = URL(fileURLWithPath: tab.title)
        let originalExtension = titleURL.pathExtension.isEmpty ? tab.suggestedExtension : titleURL.pathExtension
        guard originalExtension.utf8.count <= 200,
              GaoActionContract.safeFilename(originalExtension) == originalExtension else {
            throw FileIssue.message("文件扩展名过长或无效，请先使用保留原格式的名称另存副本。")
        }
        let suffix = "." + originalExtension
        var basename = GaoActionContract.safeFilename(titleURL.deletingPathExtension().lastPathComponent)
        while basename.utf8.count + suffix.utf8.count > 220 { basename.removeLast() }
        let name = (basename.isEmpty ? "文档" : basename) + suffix
        let destination = directory.appendingPathComponent(name)
        var version = "savedVersion"
        if tab.kind.isText {
            let bytes = Data(tab.text.utf8)
            guard bytes.count <= DocumentHandoffSafety.maximumTextBytes, !tab.text.contains("\0") else {
                throw FileIssue.message("导出文本须为不含空字符的 UTF-8，且不超过 8 MiB。")
            }
            try bytes.write(to: destination, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            version = "currentEdits"
        } else {
            guard let original = tab.url else { throw FileIssue.message("当前文档没有可导出的本机内容。") }
            let accessed = original.startAccessingSecurityScopedResource()
            defer { if accessed { original.stopAccessingSecurityScopedResource() } }
            var useCurrentPDF = false
            if tab.kind == .pdf {
                let model = try registry.commitCurrentPDF(for: original)
                if model?.dirty == true || tab.dirty || tab.moduleDirty {
                    switch chooseVersion(original) {
                    case .cancel: throw FileIssue.message("已取消导出；原件与未保存修改保留。")
                    case .diskOriginal: break
                    case .currentEdits: useCurrentPDF = true
                    }
                }
            } else if tab.dirty || tab.moduleDirty {
                throw FileIssue.message("此格式暂不能无损导出未保存修改。请先在原编辑器另存所需版本后重试；已有恢复稿保留。")
            }
            if useCurrentPDF {
                _ = try registry.snapshotCurrentPDF(for: original, to: destination)
                version = "currentEdits"
            } else {
                // Read-only formats are copied byte for byte, including unknown
                // Office objects/macros. Export does not convert or edit them.
                _ = try GaoPrivateIO.copy(GaoPrivateIO.regularURL(original), to: directoryFD,
                                          name: name, maximum: GaoActionContract.maximumPayloadBytes)
            }
        }
        let digest = try fingerprint(destination)
        var protected = [URL]()
        if let protectedOriginal { protected.append(protectedOriginal) }
        if let received = tab.incoming?.receivedCopyURL, let url = URL(string: received), url.isFileURL { protected.append(url) }
        if let current = tab.url { protected.append(current) }
        let result = PreparedEditedDocumentExport(sourceURL: destination, title: name, versionKind: version,
                                                  sha256: digest.1, byteCount: digest.0,
                                                  protectedOriginals: protected, directory: directory)
        keep = true
        return result
    }

    @discardableResult static func export(_ prepared: PreparedEditedDocumentExport, to destination: URL,
                                         overwrite: HandoffSafeExport.Overwrite = .rejectExisting) throws -> HandoffSafeExport.Receipt {
        guard destination.pathExtension.lowercased() == prepared.sourceURL.pathExtension.lowercased() else {
            throw FileIssue.message("导出副本保留原文件格式，请使用相同的扩展名。")
        }
        let current = try fingerprint(prepared.sourceURL)
        guard current.0 == prepared.byteCount, current.1 == prepared.sha256 else {
            throw FileIssue.message("待导出副本已发生变化，请重新选择当前文档版本。")
        }
        try protect(prepared.protectedOriginals, from: destination)
        let accessed = destination.startAccessingSecurityScopedResource()
        defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
        return try HandoffSafeExport.copy(source: prepared.sourceURL, to: destination,
            protectedOriginal: prepared.protectedOriginals.first, overwrite: overwrite,
            hooks: .init(check: { phase, _ in
                if case .beforeCommit = phase {
                    let checked = try fingerprint(prepared.sourceURL)
                    guard checked.0 == prepared.byteCount, checked.1 == prepared.sha256 else { throw HandoffSafeExport.Failure.changed }
                    try protect(prepared.protectedOriginals, from: destination)
                }
            }))
    }

    static func showPanel(store: WorkspaceStore) {
        do {
            let prepared = try prepare(store: store, chooseVersion: { _ in
                let alert = NSAlert(); alert.messageText = "选择要导出的 PDF 版本"
                alert.informativeText = "当前 PDF 有未保存的内容。导出副本不会保存原件，也不会清除未保存修改。"
                alert.addButton(withTitle: "导出当前修改"); alert.addButton(withTitle: "导出已保存版本"); alert.addButton(withTitle: "取消")
                switch alert.runModal() { case .alertFirstButtonReturn: return .currentEdits; case .alertSecondButtonReturn: return .diskOriginal; default: return .cancel }
            })
            let panel = NSSavePanel(); panel.title = "导出编辑副本"
            let original = URL(fileURLWithPath: prepared.title)
            panel.nameFieldStringValue = original.deletingPathExtension().lastPathComponent + "-编辑副本." + original.pathExtension
            if let type = UTType(filenameExtension: original.pathExtension) { panel.allowedContentTypes = [type]; panel.allowsOtherFileTypes = false }
            let incoming = store.active?.incoming
            let researchContext = incoming?.sourceBundleID == CurrentDocumentDispatcher.researchBundleID
                && incoming?.inboundAction == "documents.open"
                && incoming?.manifestSHA256.map(GaoActionContract.validSHA) == true
            panel.message = researchContext
                ? "来源声明为搞研究（未经身份认证）。导出后，请回搞研究原条目选择“导入编辑新版本…”，本人选择新版本或新附件；本次导出不表示已导入。"
                : "请选择新的文件位置。导出保留原格式，原件和当前未保存状态保留。"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            let accessed = destination.startAccessingSecurityScopedResource()
            defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
            var overwrite = HandoffSafeExport.Overwrite.rejectExisting
            if FileManager.default.fileExists(atPath: destination.path) {
                let reviewed = try fingerprint(destination)
                let alert = NSAlert(); alert.messageText = "覆盖所选目标并保留快照？"
                alert.informativeText = "目标：\(HandoffNames.display(destination.lastPathComponent))\n仅覆盖刚核对的版本；原内容先写入本地历史快照。原件或入站副本不能作为目标。"
                alert.addButton(withTitle: "保留快照并覆盖"); alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                overwrite = .replace(expectedSHA256: reviewed.1)
            }
            _ = try export(prepared, to: destination, overwrite: overwrite)
            store.status = researchContext ? "编辑副本已导出；请回搞研究原条目本人导入，尚未确认导入完成" : "编辑副本已导出；原件与未保存状态保留"
        } catch { store.error = error.localizedDescription }
    }

    private static func fingerprint(_ url: URL) throws -> (Int64, String) {
        let fd = try GaoPrivateIO.regularURL(url), before = try fd.statValue()
        guard before.st_size <= GaoActionContract.maximumPayloadBytes else { throw HandoffSafeExport.Failure.tooLarge }
        var hasher = SHA256(), total: Int64 = 0, buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd.value, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw HandoffSafeExport.Failure.io(errno) }
            total += Int64(count)
            guard total <= GaoActionContract.maximumPayloadBytes else { throw HandoffSafeExport.Failure.tooLarge }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        guard total == before.st_size, GaoPrivateIO.unchanged(before, try fd.statValue()) else { throw HandoffSafeExport.Failure.changed }
        return (total, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func canonical(_ url: URL) -> URL {
        let resolved: URL
        if (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true,
           let alias = try? URL(resolvingAliasFileAt: url, options: [.withoutUI]) { resolved = alias }
        else { resolved = url }
        return resolved.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func protect(_ originals: [URL], from destination: URL) throws {
        let target = canonical(destination)
        for original in originals {
            let source = canonical(original)
            if source == target { throw HandoffSafeExport.Failure.sameFile }
            var a = stat(), b = stat()
            if Darwin.lstat(source.path, &a) == 0, Darwin.lstat(target.path, &b) == 0,
               a.st_dev == b.st_dev, a.st_ino == b.st_ino { throw HandoffSafeExport.Failure.sameFile }
        }
    }
}
