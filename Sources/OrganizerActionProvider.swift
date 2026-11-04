import AppKit
import Foundation
import UniformTypeIdentifiers
import Darwin

/// The root access belongs to this application and is retained through selection and
/// reference identity capture. The returned GaoAction references do not export it.
@MainActor final class OrganizerSearchLease {
    let urls: [URL]
    private var releaseBody: (() -> Void)?
    init(urls: [URL], release: @escaping () -> Void) { self.urls = urls; releaseBody = release }
    func release() { let body = releaseBody; releaseBody = nil; body?() }
    deinit { releaseBody?() }
}

struct OrganizerProviderResult {
    var status: String
    var references: [GaoActionReference] = []
    var provenance: [String: GaoJSONValue] = [:]
    var errorCode: String?
    static var cancelled: Self { .init(status: "cancelled", provenance: ["workflowState": .string("cancelled")]) }
    static func failed(_ message: String) -> Self {
        .init(status: "failed", provenance: ["workflowState": .string("failed"), "reason": .string(HandoffNames.display(message, limit: 4096))], errorCode: "organizerActionFailed")
    }
    static func associationChanged(uti: String, readBackVerified: Bool) -> Self {
        guard readBackVerified else { return .failed("系统读回与目标关联不一致。") }
        return .init(status: "completed", provenance: ["workflowState": .string("changed"), "uti": .string(uti), "readBackVerified": .bool(true)])
    }
}

/// UI is injectable for focused tests. Default UI only performs a user's explicit
/// selection, sends references instead of copies, and never sends an entire search.
@MainActor struct OrganizerProviderInteraction {
    var search: (String, [URL]) -> [URL]?
    var choose: (GaoActionManifest) -> [URL]?
    var reveal: (GaoActionReference) throws -> Bool
    static let application = Self(search: { query, urls in
        let alert = NSAlert()
        alert.messageText = "搜索结果：" + HandoffNames.display(query, limit: 120)
        alert.informativeText = "仅显示搞文件已授权索引中的前 \(urls.count) 条文件。勾选后才发送路径引用；读取权限不会随引用传递。更多筛选和分页可在“文件整理/查找”中进行。"
        let boxes = urls.map { url -> NSButton in
            let box = NSButton(checkboxWithTitle: HandoffNames.display(url.path, limit: 500), target: nil, action: nil)
            box.state = .off
            return box
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
        stack.frame = NSRect(x: 0, y: 0, width: 650, height: CGFloat(max(1, boxes.count)) * 27)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 650, height: min(300, stack.frame.height)))
        scroll.hasVerticalScroller = true; scroll.documentView = stack
        alert.accessoryView = scroll
        alert.addButton(withTitle: "发送勾选引用"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return zip(urls, boxes).compactMap { $0.1.state == .on ? $0.0 : nil }
    }, choose: { manifest in
        let panel = NSOpenPanel()
        panel.title = "选择要返回的文件引用"
        panel.message = "这是搞文件内置选择器。只有你所选的普通文件会返回给请求应用；不复制正文，不转授访问权限。"
        panel.prompt = "发送所选引用"
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = manifest.parameters["multiple"]?.boolValue ?? true
        if let allowed = manifest.parameters["allowedUTIs"]?.arrayValue?.compactMap(\.stringValue), !allowed.isEmpty {
            panel.allowedContentTypes = allowed.compactMap { OrganizerActionProvider.declaredType($0) }
            // An unresolvable declared filter must not silently become unrestricted.
            guard panel.allowedContentTypes.count == allowed.count else { return nil }
        }
        if let ref = manifest.references.first { panel.directoryURL = try? GaoActionContract.localFileURL(ref.fileURL) }
        return panel.runModal() == .OK ? panel.urls : nil
    }, reveal: { reference in
        let declared = try GaoActionContract.localFileURL(reference.fileURL)
        let panel = NSOpenPanel()
        panel.title = "核对并定位原件"
        panel.message = "请选择“\(HandoffNames.display(reference.displayName))”。路径引用不授予权限，必须与请求中的原件身份相符。"
        panel.prompt = "核对并在 Finder 显示"
        panel.directoryURL = declared.deletingLastPathComponent()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let chosen = panel.url else { return false }
        let scoped = chosen.startAccessingSecurityScopedResource()
        defer { if scoped { chosen.stopAccessingSecurityScopedResource() } }
        try GaoActionTransport.verifyReference(reference, selectedURL: chosen)
        NSWorkspace.shared.activateFileViewerSelecting([chosen])
        return true
    })
}

@MainActor enum OrganizerActionProvider {
    static let actions: Set<String> = ["files.search", "files.choose", "files.reveal", "associations.manage"]
    /// Supplied by the lazily-created integrated organizer. No source application
    /// discovery and no callback to our own GaoAction client are involved.
    static var indexSearch: ((String, URL?) throws -> OrganizerSearchLease)?
    static var manageAssociations: ((String, @escaping @MainActor (OrganizerProviderResult) -> Void) -> Bool)?

    /// nil means an actual association editor is waiting for an explicit user
    /// action. Its completion is the only route to a final association result.
    static func perform(_ request: GaoActionManifest, interaction: OrganizerProviderInteraction,
                        associationCompletion: @escaping @MainActor (OrganizerProviderResult) -> Void) throws -> OrganizerProviderResult? {
        guard request.kind == "request", request.targetBundleID == GaoActionContract.bundleID, actions.contains(request.action) else {
            throw GaoActionContract.reject("wrongTarget", "文件整理请求的目标或动作不匹配，未执行。")
        }
        switch request.action {
        case "files.search":
            guard let query = request.parameters["query"]?.stringValue, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let search = indexSearch else { throw GaoActionContract.reject("indexUnavailable", "请先在“文件整理/查找”建立并授权索引。") }
            let scope = try request.references.first.map { try GaoActionContract.localFileURL($0.fileURL) }
            let lease = try search(query, scope)
            defer { lease.release() }
            guard lease.urls.count <= 256, !lease.urls.isEmpty else { throw GaoActionContract.reject("noIndexedMatches", "当前已授权索引中没有匹配文件；未改用文件选择器冒充搜索结果。") }
            guard let selected = interaction.search(query, lease.urls) else { return .cancelled }
            let candidates = Set(lease.urls.map { $0.standardizedFileURL.path })
            guard selected.allSatisfy({ candidates.contains($0.standardizedFileURL.path) }) else { throw GaoActionContract.reject("selectionMismatch", "所选文件不属于本次真实索引结果。") }
            return try selection(selected, for: request)
        case "files.choose":
            guard let selected = interaction.choose(request) else { return .cancelled }
            return try selection(selected, for: request)
        case "files.reveal":
            guard let reference = request.references.first, request.references.count == 1 else { throw GaoActionContract.reject("invalidReference", "定位请求缺少原件引用。") }
            guard try interaction.reveal(reference) else { return .cancelled }
            return .init(status: "completed", provenance: ["workflowState": .string("revealed"), "identityVerified": .bool(true), "revealRequestIssued": .bool(true)])
        case "associations.manage":
            guard let manage = manageAssociations else { throw GaoActionContract.reject("organizerUnavailable", "文件关联管理尚不可用，未改动系统默认关联。") }
            let uti = request.parameters["uti"]?.stringValue ?? ""
            guard manage(uti, associationCompletion) else { throw GaoActionContract.reject("providerBusy", "请先完成或取消当前文件关联请求。") }
            return nil
        default: throw GaoActionContract.reject("unsupportedAction", "不是文件整理/查找动作。")
        }
    }

    /// Real, bounded reference construction is shared by production and tests.
    static func selection(_ urls: [URL], for request: GaoActionManifest) throws -> OrganizerProviderResult {
        let multiple = request.parameters["multiple"]?.boolValue ?? true
        guard !urls.isEmpty, urls.count <= 256, multiple || urls.count == 1,
              Set(urls.map { $0.standardizedFileURL.path }).count == urls.count else { throw GaoActionContract.reject("invalidSelection", "请选择符合数量要求且不重复的普通文件；未选择文件时请取消请求。") }
        let scopeReference = request.references.first
        let scopeURL = try scopeReference.map { try GaoActionContract.localFileURL($0.fileURL) }
        let allowed = request.parameters["allowedUTIs"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let refs = try urls.enumerated().map { index, url -> GaoActionReference in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let scopeURL, let scopeReference {
                try GaoActionTransport.verifyReference(scopeReference, selectedURL: scopeURL)
                let base = scopeURL.standardizedFileURL.path
                guard url.standardizedFileURL.path.hasPrefix(base == "/" ? "/" : base + "/") else { throw GaoActionContract.reject("outsideScope", "所选文件不在请求目录范围。") }
            }
            // Anchor every path component with O_NOFOLLOW, not just the leaf.
            let fd = try selectedFile(url)
            let before = try fd.statValue()
            let actual = try selectionType(url: url) {
                try url.resourceValues(forKeys: [.isPackageKey, .contentTypeKey])
            }
            if !allowed.isEmpty {
                guard allowed.contains(where: { id in declaredType(id).map { actual.identifier == $0.identifier || actual.conforms(to: $0) } == true }) else { throw GaoActionContract.reject("typeMismatch", "所选文件不符合请求的类型限制。") }
            }
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let modified = Date(timeIntervalSince1970: Double(before.st_mtimespec.tv_sec) + Double(before.st_mtimespec.tv_nsec) / 1_000_000_000)
            let reference = GaoActionReference(id: "selected-\(index + 1)", kind: "file", fileURL: url.standardizedFileURL.absoluteString,
                displayName: url.lastPathComponent, declaredIdentity: .init(device: UInt64(before.st_dev), inode: UInt64(before.st_ino), byteCount: before.st_size, modifiedAt: formatter.string(from: modified)))
            try GaoActionTransport.verifyReference(reference, selectedURL: url)
            guard GaoPrivateIO.unchanged(before, try fd.statValue()) else { throw GaoActionContract.reject("referenceChanged", "文件在选择期间发生变化，请重新选择。") }
            return reference
        }
        return .init(status: "completed", references: refs, provenance: ["workflowState": .string("selected"), "selectionCount": .number(Double(refs.count)), "accessRequiresReceiverVerification": .bool(true)])
    }

    /// Called only after a readable ordinary file descriptor is fixed. A
    /// headless LaunchServices metadata miss is not a failed file read; every
    /// permission, filesystem and unknown metadata error must still propagate.
    static func selectionType(url: URL, readMetadata: () throws -> URLResourceValues) throws -> UTType {
        let packageExtensions: Set<String> = ["app", "bundle", "framework", "plugin", "appex", "kext", "package", "rtfd", "playground", "xcworkspace", "xcodeproj", "scptd", "wdgt", "mdimporter", "saver"]
        guard !packageExtensions.contains(url.pathExtension.lowercased()) else {
            throw GaoActionContract.reject("invalidSelection", "不能将应用包或目录作为普通文件返回。")
        }
        let values: URLResourceValues?
        do { values = try readMetadata() }
        catch {
            guard unavailableTypeMetadata(error as NSError) else { throw error }
            values = nil
        }
        guard values?.isPackage != true else { throw GaoActionContract.reject("invalidSelection", "不能将应用包或目录作为普通文件返回。") }
        // Only the explicit LS metadata-miss path uses this finite canonical
        // table. It does not create or register imported/dynamic type identities.
        let type: UTType
        if let values {
            type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        } else {
            type = standardExtensionType(url.pathExtension) ?? .data
        }
        guard !type.conforms(to: .package) else { throw GaoActionContract.reject("invalidSelection", "不能将包类型作为普通文件返回。") }
        return type
    }
    /// Canonical framework constants work even when headless LaunchServices
    /// cannot resolve an identifier through UTType.init(_:) or extension tags.
    /// Other declared types still require a real, non-dynamic platform type.
    static func declaredType(_ identifier: String) -> UTType? {
        let standards: [UTType] = [.data, .content, .text, .plainText, .utf8PlainText, .rtf, .html, .xml, .json,
                                  .pdf, .image, .png, .jpeg, .tiff, .gif, .heic, .heif, .commaSeparatedText, .tabSeparatedText]
        if let known = standards.first(where: { $0.identifier == identifier }) { return known }
        guard let registered = UTType(identifier), !registered.isDynamic else { return nil }
        return registered
    }
    private static func standardExtensionType(_ name: String) -> UTType? {
        switch name.lowercased() {
        case "txt", "text", "log", "md", "markdown", "tex", "bib", "sty", "cls", "yaml", "yml": return .plainText
        case "csv": return .commaSeparatedText
        case "tsv": return .tabSeparatedText
        case "rtf": return .rtf
        case "html", "htm": return .html
        case "xml": return .xml
        case "json": return .json
        case "pdf": return .pdf
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "tif", "tiff": return .tiff
        case "gif": return .gif
        case "heic": return .heic
        case "heif": return .heif
        default: return nil
        }
    }

    private static func unavailableTypeMetadata(_ error: NSError, depth: Int = 0) -> Bool {
        guard depth < 8 else { return false }
        if error.domain == NSOSStatusErrorDomain { return error.code == -10813 } // kLSDataUnavailableErr
        guard error.domain == NSCocoaErrorDomain, error.code == NSFileReadUnknownError,
              let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
        return unavailableTypeMetadata(underlying, depth: depth + 1)
    }

    private static func selectedFile(_ url: URL) throws -> GaoFixedFD {
        _ = try GaoActionContract.localFileURL(url.absoluteString)
        let parts = url.path.split(separator: "/").map(String.init)
        guard let last = parts.last else { throw GaoActionContract.reject("invalidSelection", "不能选择文件系统根。") }
        var parent = try GaoFixedFD(Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        for part in parts.dropLast() {
            parent = try GaoFixedFD(openat(parent.value, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        }
        let file = try GaoFixedFD(openat(parent.value, last, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
        try GaoPrivateIO.checkRegular(file.statValue())
        return file
    }

    static func validateCompletion(_ result: OrganizerProviderResult, request: GaoActionManifest) throws {
        guard ["completed", "cancelled", "failed"].contains(result.status) else { throw GaoActionContract.reject("invalidProviderResult", "文件整理动作返回了无效状态。") }
        guard request.action == "associations.manage" else { return }
        guard result.references.isEmpty else { throw GaoActionContract.reject("invalidProviderResult", "关联管理不能返回文件引用。") }
        if result.status == "completed" {
            let requested = request.parameters["uti"]?.stringValue ?? ""
            guard result.provenance["workflowState"]?.stringValue == "changed", result.provenance["readBackVerified"]?.boolValue == true,
                  let actual = result.provenance["uti"]?.stringValue, let type = declaredType(actual), !type.isDynamic,
                  requested.isEmpty || requested == actual else { throw GaoActionContract.reject("invalidAssociationReceipt", "关联完成需要本次明确修改和对应类型的系统读回，不把打开界面当成完成。") }
        }
    }
}
