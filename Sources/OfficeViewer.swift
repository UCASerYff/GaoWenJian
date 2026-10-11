import AppKit
import SwiftUI
import Quartz
import UniformTypeIdentifiers

struct OfficeReadOnlyRow: Identifiable {
    let id: String
    let label: String
    let text: String
    let formula: String
}
struct OfficeReadOnlySection: Identifiable {
    let id: String
    let title: String
    let rows: [OfficeReadOnlyRow]
    let isSpreadsheet: Bool
}

/// Quick Look only receives a temporary, read-only snapshot. This type deliberately has no save/apply API.
final class OfficeReadOnlySnapshot {
    let originalURL: URL
    let previewURL: URL
    let sections: [OfficeReadOnlySection]
    let contentNotice: String
    private let directory: URL

    init(url: URL) throws {
        originalURL = url
        let bytes = try Data(contentsOf: url)
        guard !bytes.isEmpty else { throw OfficeFailure.message("文件为空，无法预览。原文件未修改。") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GaoWenJian-OfficeViewer-\(UUID().uuidString)", isDirectory: true)
        previewURL = directory.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try bytes.write(to: previewURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: previewURL.path)
            guard try Data(contentsOf: previewURL) == bytes else { throw OfficeFailure.message("预览副本校验失败。原文件未修改。") }
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
        if ["docx", "docm", "dotx", "dotm", "xlsx", "xlsm", "xltx", "xltm", "pptx", "pptm", "potx", "potm", "ppsx", "ppsm"].contains(url.pathExtension.lowercased()) {
            do {
                sections = try Self.readContents(previewURL)
                contentNotice = sections.first?.isSpreadsheet == true
                    ? "内容查阅显示原始单元格值和文件已有的公式缓存，不重算公式；日期、数字格式和图表请看版式预览。"
                    : "内容查阅用于搜索和复制文字；图片、表格排版、母版等请看版式预览。"
            } catch {
                sections = []
                contentNotice = "无法提取文字内容：\(error.localizedDescription) 可尝试版式预览，或用外部应用打开。"
            }
        } else {
            sections = []
            contentNotice = "此格式使用 macOS 版式预览。若系统无法预览，请用外部应用打开。"
        }
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    private static func readContents(_ url: URL) throws -> [OfficeReadOnlySection] {
        let package = try OfficePackage(url: url)
        if package.exists("word/document.xml") {
            let document = try OfficeWordDocument(package: package)
            return [OfficeReadOnlySection(id: "body", title: "文档正文", rows: document.paragraphs.enumerated().map {
                OfficeReadOnlyRow(id: String($0.offset), label: "第 \($0.offset + 1) 段", text: $0.element.text, formula: "")
            }, isSpreadsheet: false)]
        }
        if package.exists("ppt/presentation.xml") {
            let document = try OfficePresentation(package: package)
            return document.slides.enumerated().map { index, slide in
                OfficeReadOnlySection(id: slide.id, title: "幻灯片 \(index + 1)", rows: slide.texts.enumerated().map {
                    OfficeReadOnlyRow(id: String($0.offset), label: $0.element.name, text: $0.element.text, formula: "")
                }, isSpreadsheet: false)
            }
        }
        guard package.exists("xl/workbook.xml"), let root = try package.xml("xl/workbook.xml").rootElement(),
              let sheets = OfficeXML.child(root, "sheets"), let relationships = try package.xml("xl/_rels/workbook.xml.rels").rootElement() else {
            throw OfficeFailure.message("未找到可查阅的正文、工作表或幻灯片。")
        }
        var sharedStrings: [String] = []
        if package.exists("xl/sharedStrings.xml"), let strings = try package.xml("xl/sharedStrings.xml").rootElement() {
            sharedStrings = OfficeXML.children(strings, "si").map { OfficeXML.descendants($0, "t").map { $0.stringValue ?? "" }.joined() }
        }
        // Read cached values directly: opening a viewer must never recalculate or mutate workbook content.
        return try OfficeXML.children(sheets, "sheet").compactMap { sheet in
            guard let identity = OfficeXML.attribute(sheet, "id"), let relationship = OfficeXML.children(relationships, "Relationship").first(where: { OfficeXML.attribute($0, "Id") == identity }),
                  OfficeXML.attribute(relationship, "TargetMode") != "External", let target = OfficeXML.attribute(relationship, "Target") else { return nil }
            let path = try package.resolve(target, relativeTo: "xl/workbook.xml")
            guard let worksheet = try package.xml(path).rootElement(), OfficeXML.local(worksheet) == "worksheet" else { return nil }
            let rows = OfficeXML.descendants(worksheet, "c").compactMap { cell -> OfficeReadOnlyRow? in
                guard let address = OfficeXML.attribute(cell, "r"), OfficeWorkbook.coordinates(address) != nil else { return nil }
                let kind = OfficeXML.attribute(cell, "t") ?? "n"
                let raw = OfficeXML.child(cell, "v")?.stringValue ?? ""
                let formulaNode = OfficeXML.child(cell, "f")
                let formula = formulaNode.map { "=" + ($0.stringValue ?? "") } ?? ""
                let value: String
                if kind == "s", let index = Int(raw), sharedStrings.indices.contains(index) { value = sharedStrings[index] }
                else if kind == "inlineStr" { value = OfficeXML.child(cell, "is").map { OfficeXML.descendants($0, "t").map { $0.stringValue ?? "" }.joined() } ?? "" }
                else if kind == "b" { value = raw == "1" ? "TRUE" : "FALSE" }
                else if formulaNode != nil && OfficeXML.child(cell, "v") == nil { value = "（文件未保存公式结果）" }
                else { value = raw }
                return OfficeReadOnlyRow(id: address, label: address, text: value, formula: formula)
            }.sorted {
                let left = OfficeWorkbook.coordinates($0.label)!, right = OfficeWorkbook.coordinates($1.label)!
                return left.row == right.row ? left.column < right.column : left.row < right.row
            }
            let hidden = (OfficeXML.attribute(sheet, "state") ?? "visible") != "visible"
            return OfficeReadOnlySection(id: identity, title: (OfficeXML.attribute(sheet, "name") ?? "工作表") + (hidden ? "（隐藏）" : ""), rows: rows, isSpreadsheet: true)
        }
    }
}

enum OfficeViewerRecovery {
    /// Export only to a new file; never overwrite the original, an existing file, or any recovery record.
    static func export(_ candidate: OfficeRecoveryCandidate, to target: URL) throws {
        let data = try Data(contentsOf: candidate.url)
        guard OfficePackage.hash(data) == candidate.record.documentDigest else { throw OfficeFailure.message("恢复草稿已变化或校验失败，未导出。已有资料保持不变。") }
        guard target.pathExtension.lowercased() == candidate.url.pathExtension.lowercased() else { throw OfficeFailure.message("请保留草稿原有文件扩展名。") }
        func canonicalPath(_ url: URL) -> String {
            let file = url.standardizedFileURL
            // Resolve the existing parent even when the final file has been deleted.
            return file.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent, isDirectory: false).path
        }
        let original = canonicalPath(URL(fileURLWithPath: candidate.record.originalPath))
        guard canonicalPath(target) != original else { throw OfficeFailure.message("恢复副本不能使用原文件路径，请选择新的文件名。") }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw OfficeFailure.message("恢复副本必须使用新的文件名，不会覆盖原件或其他已有文件。") }
        try data.write(to: target, options: .withoutOverwriting)
        guard try Data(contentsOf: target) == data else { throw OfficeFailure.message("恢复副本写入校验失败，请保留现有草稿。") }
    }
}

@MainActor final class OfficeViewerSession: ObservableObject {
    @Published private(set) var snapshot: OfficeReadOnlySnapshot?
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published private(set) var recovery: OfficeRecoveryCandidate?
    @Published private(set) var recoveryNotice: String?
    @Published private(set) var viewingRecovery = false
    private var generation = UUID()

    func load(_ original: URL, showRecovery: Bool = false) async {
        let token = UUID(); generation = token
        loading = true; failure = nil
        if !showRecovery {
            recovery = nil; recoveryNotice = nil
            for previous in [false, true] {
                do { if let candidate = try OfficeRecovery.read(for: original, previous: previous), recovery == nil { recovery = candidate } }
                catch { recoveryNotice = "旧版 Office 草稿读取或校验失败，资料已原样保留。" }
            }
        }
        let source = showRecovery ? recovery?.url ?? original : original
        let result = await Task.detached { Result { try OfficeReadOnlySnapshot(url: source) } }.value
        guard token == generation else { return }
        loading = false
        switch result {
        case .success(let value): snapshot = value; viewingRecovery = showRecovery
        case .failure(let error): snapshot = nil; failure = error.localizedDescription
        }
    }
}

struct OfficeViewer: View {
    let url: URL
    let onError: (String) -> Void
    @StateObject private var session = OfficeViewerSession()
    @State private var mode = 0
    @State private var selectedSection = ""
    @State private var search = ""
    @State private var exportMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if session.recovery != nil || session.recoveryNotice != nil { recoveryBar }
            Divider()
            if session.loading { ProgressView("正在读取本地文档…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let snapshot = session.snapshot {
                if mode == 0 { OfficeQuickLook(snapshot: snapshot).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { contents(snapshot) }
            } else {
                ContentUnavailableView("无法预览文件", systemImage: "doc.questionmark", description: Text(session.failure ?? "请重新读取或在外部应用中打开。"))
            }
            Divider()
            HStack {
                Label(session.viewingRecovery ? "旧版恢复草稿 · 只读" : "Office 查看器 · 只读", systemImage: "eye").font(.caption)
                if let exportMessage { Text(exportMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Text("本地查看 · 原文件不变").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.vertical, 8)
        }
        .task(id: url) { await session.load(url) }
    }
    private var toolbar: some View {
        HStack(spacing: 10) {
            Label(url.pathExtension.uppercased(), systemImage: "doc.text.magnifyingglass").font(.system(size: 12, weight: .semibold))
            Picker("查看方式", selection: $mode) {
                Text("版式预览").tag(0)
                Text("内容查阅").tag(1)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
            Spacer()
            Button("用外部应用打开…") { openExternally() }.help("选择办公软件打开原文件")
            Menu {
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("重新读取原文件") { Task { await session.load(url) } }
            } label: { Image(systemName: "ellipsis.circle") }
        }.buttonStyle(.bordered).padding(.horizontal, 12).padding(.vertical, 9)
    }
    private var recoveryBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label("旧版未保存草稿已保留", systemImage: "clock.arrow.circlepath").font(.caption)
                Spacer()
                if session.recovery != nil {
                    Button(session.viewingRecovery ? "查看原文件" : "查看草稿") { Task { await session.load(url, showRecovery: !session.viewingRecovery) } }
                    Button("导出恢复副本…") { exportRecovery() }
                }
                Button("查看恢复目录") { NSWorkspace.shared.open(OfficeRecovery.documentURL(for: url).deletingLastPathComponent()) }
            }
            if let notice = session.recoveryNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }.padding(10).background(Color.orange.opacity(0.10))
    }
    @ViewBuilder private func contents(_ snapshot: OfficeReadOnlySnapshot) -> some View {
        if snapshot.sections.isEmpty {
            ContentUnavailableView("此文件没有可提取的查阅内容", systemImage: "doc.text.magnifyingglass", description: Text(snapshot.contentNotice))
        } else {
            HSplitView {
                List(selection: $selectedSection) {
                    ForEach(snapshot.sections) { section in
                        Label(section.title, systemImage: section.isSpreadsheet ? "tablecells" : "doc.text").tag(section.id)
                    }
                }.frame(minWidth: 150, idealWidth: 190, maxWidth: 260)
                VStack(alignment: .leading, spacing: 10) {
                    TextField("搜索内容、单元格或公式", text: $search).textFieldStyle(.roundedBorder)
                    if let section = snapshot.sections.first(where: { $0.id == selectedSection }) ?? snapshot.sections.first {
                        Text(section.title).font(.headline)
                        let rows = section.rows.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) || $0.text.localizedCaseInsensitiveContains(search) || $0.formula.localizedCaseInsensitiveContains(search) }
                        if section.isSpreadsheet {
                            Table(rows) {
                                TableColumn("单元格") { Text($0.label).monospaced().textSelection(.enabled) }.width(min: 65, ideal: 75, max: 100)
                                TableColumn("原始值／缓存结果") { Text($0.text).textSelection(.enabled) }
                                TableColumn("公式") { Text($0.formula).monospaced().textSelection(.enabled) }
                            }
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 18) {
                                    ForEach(rows) { row in
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(row.label).font(.caption).foregroundStyle(.secondary)
                                            Text(row.text.isEmpty ? "（空白）" : row.text).font(.system(size: 15)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }.padding(14)
                            }.background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    Text(snapshot.contentNotice).font(.caption).foregroundStyle(.secondary)
                }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func exportRecovery() {
        guard let candidate = session.recovery else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " 恢复副本." + url.pathExtension
        panel.allowedContentTypes = [UTType(filenameExtension: url.pathExtension) ?? .data]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do { try OfficeViewerRecovery.export(candidate, to: target); exportMessage = "恢复副本已导出；旧草稿继续保留" }
        catch { onError(error.localizedDescription) }
    }
    private func openExternally() {
        let panel = NSOpenPanel(); panel.title = "选择用于打开此文件的办公软件"; panel.prompt = "打开"; panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        guard Bundle(url: app)?.bundleIdentifier != Bundle.main.bundleIdentifier else { onError("请选择 Word、Excel、PowerPoint 或 LibreOffice 等外部办公软件。"); return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { DispatchQueue.main.async { onError(error.localizedDescription) } }
        }
    }
}

private struct OfficeQuickLook: NSViewRepresentable {
    let snapshot: OfficeReadOnlySnapshot
    final class Coordinator {
        var snapshot: OfficeReadOnlySnapshot
        init(_ snapshot: OfficeReadOnlySnapshot) { self.snapshot = snapshot }
    }
    func makeCoordinator() -> Coordinator { Coordinator(snapshot) }
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false; view.autostarts = false
        view.previewItem = snapshot.previewURL as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if context.coordinator.snapshot.previewURL != snapshot.previewURL {
            view.previewItem = snapshot.previewURL as NSURL
            context.coordinator.snapshot = snapshot
        }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) { view.close() }
}
