import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class OfficeSession: ObservableObject {
    @Published var revision = 0
    @Published var loading = true
    @Published var dirty = false
    @Published var message = ""
    @Published var previewBusy = false
    @Published var recoveryAvailable = false
    @Published var draftFailure: String?
    var pendingCell: (sheet: Int, address: String, input: String)?
    private var draftTask: Task<Void, Never>?
    private var savedDigest: String?
    private var recoveryCandidate: OfficeRecoveryCandidate?
    var package: OfficePackage?
    var word: OfficeWordDocument?
    var workbook: OfficeWorkbook?
    var presentation: OfficePresentation?
    var openedURL: URL?
    func load(_ url: URL) throws {
        loading = true; defer { loading = false }
        draftTask?.cancel(); pendingCell = nil; openedURL = url; word = nil; workbook = nil; presentation = nil; package = nil; savedDigest = nil; recoveryAvailable = false; draftFailure = nil
        let package = try OfficePackage(url: url)
        switch url.pathExtension.lowercased() {
        case "docx": word = try OfficeWordDocument(package: package)
        case "xlsx": workbook = try OfficeWorkbook(package: package)
        case "pptx": presentation = try OfficePresentation(package: package)
        default: throw OfficeFailure.message("本编辑器支持 .docx、.xlsx、.pptx。旧格式请用 LibreOffice 转换后打开。")
        }
        self.package = package; dirty = false; revision += 1; message = "本地打开 · 保存前自动备份原件"
        savedDigest = try OfficePackage.digest(url); draftFailure = nil; recoveryCandidate = nil
        do { recoveryCandidate = try OfficeRecovery.read(for: url) }
        catch { draftFailure = error.localizedDescription; recoveryCandidate = try? OfficeRecovery.read(for: url, previous: true) }
        recoveryAvailable = recoveryCandidate != nil
    }
    func changed() {
        dirty = true; revision += 1
        if let url = openedURL { NotificationCenter.default.post(name: Notification.Name("GaoWenJian.moduleDirty"), object: url.path, userInfo: ["dirty": true]) }
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            guard let self, !Task.isCancelled, self.dirty, !self.recoveryAvailable, let package = self.package, let original = self.openedURL, let digest = self.savedDigest else { return }
            do { try self.apply(); try OfficeRecovery.persist(package: package, original: original, originalDigest: digest); self.draftFailure = nil }
            catch { self.draftFailure = "恢复草稿保存失败：" + error.localizedDescription }
        }
    }
    func apply() throws {
        if let pending = pendingCell, let workbook, (workbook.cell(sheet: pending.sheet, address: pending.address)?.input ?? "") != pending.input { try workbook.set(sheet: pending.sheet, address: pending.address, input: pending.input) }
        try word?.apply(); try workbook?.apply(); try presentation?.apply()
    }
    func restoreDraft() throws {
        guard let candidate = recoveryCandidate, let original = openedURL else { return }
        guard !dirty else { throw OfficeFailure.message("当前已有修改，请先保存当前内容，再重新打开文件选择恢复草稿。") }
        let recovered = try OfficePackage(url: candidate.url)
        try recovered.bindOriginal(original, expectedDigest: candidate.record.originalDigest)
        var restoredWord: OfficeWordDocument?
        var restoredWorkbook: OfficeWorkbook?
        var restoredPresentation: OfficePresentation?
        switch original.pathExtension.lowercased() {
        case "docx": restoredWord = try OfficeWordDocument(package: recovered)
        case "xlsx": restoredWorkbook = try OfficeWorkbook(package: recovered)
        case "pptx": restoredPresentation = try OfficePresentation(package: recovered)
        default: return
        }
        try OfficeRecovery.archiveExisting(for: original)
        word = restoredWord; workbook = restoredWorkbook; presentation = restoredPresentation
        package = recovered; savedDigest = candidate.record.originalDigest; recoveryAvailable = false; pendingCell = nil; message = "草稿已恢复；原件尚未修改"; changed()
    }
    func keepDraftSeparate() throws {
        guard let original = openedURL else { return }
        try OfficeRecovery.archiveExisting(for: original)
        recoveryAvailable = false; recoveryCandidate = nil; draftFailure = nil; message = "旧草稿已保留到恢复目录，继续编辑原件"
        if dirty { changed() }
    }
    func save() throws {
        guard let package, let url = openedURL else { throw OfficeFailure.message("没有可保存的 Office 文档。") }
        guard !recoveryAvailable else { throw OfficeFailure.message("请先选择恢复草稿，或保留草稿并编辑原件。") }
        draftTask?.cancel(); try apply(); try package.save(to: url)
        savedDigest = try OfficePackage.digest(url); OfficeRecovery.cleanValidDrafts(for: url); recoveryAvailable = false; draftFailure = nil
        dirty = false; revision += 1; message = "已保存 · 原件快照已保留"
        NotificationCenter.default.post(name: Notification.Name("GaoWenJian.moduleDirty"), object: url.path, userInfo: ["dirty": false])
    }
    func discardDraft() {
        draftTask?.cancel(); pendingCell = nil
        if let original = openedURL, let savedDigest { OfficeRecovery.discardIfSafe(for: original, expectedOriginalDigest: savedDigest) }
        dirty = false
        if let original = openedURL { NotificationCenter.default.post(name: Notification.Name("GaoWenJian.moduleDirty"), object: original.path, userInfo: ["dirty": false]) }
    }
    func saveCopy(to url: URL) throws { guard let package else { throw OfficeFailure.message("没有可保存的 Office 文档。") }; try apply(); try package.save(to: url, updateSource: false); message = "副本已保存：\(url.lastPathComponent)" }
    func advancedEdit(onError: @escaping (String) -> Void) {
        guard let url = openedURL else { return }
        let app = URL(fileURLWithPath: "/Applications/LibreOffice.app")
        guard FileManager.default.fileExists(atPath: app.path) else { onError("高级编辑需要本机安装 LibreOffice。当前文件仍可在搞文件中编辑。") ; return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { DispatchQueue.main.async { onError(error.localizedDescription) } }
        }
    }
    func exportPDF(to url: URL, onError: @escaping (String) -> Void) {
        guard let package, let openedURL else { return }
        let executable = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
        guard FileManager.default.isExecutableFile(atPath: executable) else { onError("PDF 导出需要本机安装 LibreOffice。") ; return }
        do {
            try apply()
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GaoWenJian-OfficePreview-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let input = folder.appendingPathComponent(openedURL.lastPathComponent)
            try package.save(to: input, updateSource: false)
            previewBusy = true; message = "正在本地排版 PDF…"
            Task {
                let result: Result<Void, Error> = await Task.detached {
                    do {
                        defer { try? FileManager.default.removeItem(at: folder) }
                        let profile = folder.appendingPathComponent("lo-profile", isDirectory: true)
                        try OfficePackage.run(executable, ["-env:UserInstallation=" + profile.absoluteString, "--headless", "--convert-to", "pdf", "--outdir", folder.path, input.path])
                        let generated = folder.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".pdf")
                        let data = try Data(contentsOf: generated)
                        guard data.count > 10, String(data: data.prefix(5), encoding: .ascii) == "%PDF-" else { throw OfficeFailure.message("本地引擎未生成有效 PDF。") }
                        try FileSafety.write(data, to: url)
                        return .success(())
                    } catch { return .failure(error) }
                }.value
                previewBusy = false
                switch result {
                case .success: message = "PDF 已导出：\(url.lastPathComponent)"; NSWorkspace.shared.open(url)
                case .failure(let error): message = "PDF 导出失败"; onError(error.localizedDescription)
                }
            }
        } catch { previewBusy = false; onError(error.localizedDescription) }
    }
}

struct OfficeWorkspace: View {
    let url: URL
    let onSaved: () -> Void
    let onError: (String) -> Void
    @StateObject private var session = OfficeSession()
    @State private var paragraphID: UUID?
    @State private var selectedSheet = 0
    @State private var address = "A1"
    @State private var addressField = "A1"
    @State private var cellInput = ""
    @State private var sheetName = ""
    @State private var selectedSlide = 0
    @State private var shapeID: String?
    @State private var search = ""
    @State private var confirmParagraphDelete = false
    @State private var confirmAdvanced = false
    var body: some View {
        let _ = session.revision
        VStack(spacing: 0) {
            toolbar
            if session.recoveryAvailable {
                HStack { Label("发现未保存的 Office 草稿", systemImage: "clock.arrow.circlepath").font(.caption); Spacer(); Button("恢复草稿") { do { try session.restoreDraft(); paragraphID = session.word?.paragraphs.first?.id; selectedSheet = 0; selectedSlide = 0; shapeID = session.presentation?.slides.first?.texts.first?.id; cellInput = session.workbook?.cell(sheet: 0, address: address)?.input ?? "" } catch { onError(error.localizedDescription) } }; Button("保留草稿并编辑原件") { do { try session.keepDraftSeparate() } catch { onError(error.localizedDescription) } } }.padding(10).background(Color.orange.opacity(0.1))
            }
            if let failure = session.draftFailure { HStack { Text(failure).font(.caption).foregroundStyle(.orange); Spacer(); if !session.recoveryAvailable { Button("保留旧草稿并启用新恢复") { do { try session.keepDraftSeparate() } catch { onError(error.localizedDescription) } } } }.padding(.horizontal, 10).padding(.vertical, 5) }
            Divider()
            if session.loading { ProgressView("正在读取本地文档…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let word = session.word { wordEditor(word).disabled(session.recoveryAvailable) }
            else if let workbook = session.workbook { excelEditor(workbook).disabled(session.recoveryAvailable) }
            else if let presentation = session.presentation { presentationEditor(presentation).disabled(session.recoveryAvailable) }
            else { ContentUnavailableView("无法打开文档", systemImage: "doc.badge.ellipsis", description: Text(session.message)) }
            Divider()
            HStack(spacing: 8) {
                Circle().fill(session.dirty ? Color.orange : Color.green).frame(width: 6, height: 6)
                Text(session.dirty ? "有未保存修改" : session.message).font(.system(size: 11)).lineLimit(1)
                Spacer()
                Text("OOXML · 本地编辑").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 7)
        }
        .task { load() }
        .onChange(of: url) { _, _ in load() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoWenJian.saveActive"))) { note in
            if let path = note.object as? String, path == url.path { save() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoWenJian.discardDraft"))) { note in
            if let path = note.object as? String, path == url.path { session.discardDraft() }
        }
        .alert("删除这一段？", isPresented: $confirmParagraphDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                if let id = paragraphID { session.word?.removeParagraph(id: id); paragraphID = session.word?.paragraphs.first?.id; session.changed() }
            }
        } message: { Text("该段落及其包含的图片、字段或其他对象会一并删除。覆盖保存前会保留原件快照。") }
        .alert("打开 LibreOffice 高级编辑？", isPresented: $confirmAdvanced) {
            Button("取消", role: .cancel) {}
            Button("保存并打开") { do { try commitCell(); try session.save(); onSaved(); session.advancedEdit(onError: onError) } catch { onError(error.localizedDescription) } }
        } message: { Text("先保存当前修改，再在本机 LibreOffice 中打开。外部编辑完成后请重新打开文件以读取最新版。") }
    }
    private var toolbar: some View {
        HStack(spacing: 10) {
            Label(url.pathExtension.uppercased(), systemImage: url.pathExtension == "xlsx" ? "tablecells" : url.pathExtension == "pptx" ? "rectangle.on.rectangle" : "doc.richtext").font(.system(size: 12, weight: .semibold))
            Spacer()
            Button { save() } label: { Label("保存", systemImage: "square.and.arrow.down") }.help("保存当前文件（⌘S）；先保留原件快照")
            Button("另存副本") { saveCopy() }
            Button { exportPDF() } label: { Label("导出 PDF", systemImage: "doc") }.disabled(session.previewBusy)
            Menu {
                Button("在 LibreOffice 高级编辑…") { confirmAdvanced = true }
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("重新读取磁盘文件") { if !session.dirty { load() } else { onError("当前有未保存修改，请先保存或另存副本，再重新打开文件。") } }
            } label: { Image(systemName: "ellipsis.circle") }
        }.buttonStyle(.bordered).padding(.horizontal, 12).padding(.vertical, 9)
    }
    private func load() {
        do {
            try session.load(url); paragraphID = session.word?.paragraphs.first?.id; selectedSheet = 0; selectedSlide = 0; shapeID = session.presentation?.slides.first?.texts.first?.id
            address = "A1"; addressField = address; cellInput = session.workbook?.cell(sheet: 0, address: address)?.input ?? ""; sheetName = session.workbook?.sheets.first?.name ?? ""
        } catch { session.loading = false; session.message = error.localizedDescription; onError(error.localizedDescription) }
    }
    private func save() { do { try commitCell(); try session.save(); onSaved() } catch { onError(error.localizedDescription) } }
    private func saveCopy() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " 副本." + url.pathExtension
        panel.allowedContentTypes = [UTType(filenameExtension: url.pathExtension) ?? .data]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do { try commitCell(); if target.standardizedFileURL == url.standardizedFileURL { try session.save(); onSaved() } else { try session.saveCopy(to: target) } } catch { onError(error.localizedDescription) }
    }
    private func exportPDF() {
        do { try commitCell() } catch { onError(error.localizedDescription); return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".pdf"; panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let target = panel.url else { return }; session.exportPDF(to: target, onError: onError)
    }
    private func wordEditor(_ word: OfficeWordDocument) -> some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                TextField("搜索段落", text: $search).textFieldStyle(.roundedBorder).padding(10)
                List(selection: $paragraphID) {
                    ForEach(word.paragraphs.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }) { paragraph in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(paragraph.text.isEmpty ? "空段落" : paragraph.text).font(paragraph.style.localizedCaseInsensitiveContains("heading") || paragraph.style == "Title" ? .system(size: 15, weight: .semibold) : .system(size: 13)).lineLimit(3)
                            HStack { Text(word.styles.first(where: { $0.id == paragraph.style })?.name ?? paragraph.style); if paragraph.containsObjects { Image(systemName: "square.on.square") } }.font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(paragraph.id)
                    }
                }
                HStack {
                    Button { paragraphID = word.addParagraph(after: paragraphID); session.changed() } label: { Label("新段落", systemImage: "plus") }
                    Spacer()
                    Button { confirmParagraphDelete = true } label: { Image(systemName: "trash") }.disabled(paragraphID == nil)
                }.padding(10)
            }.frame(minWidth: 220, idealWidth: 280, maxWidth: 380)
            VStack(alignment: .leading, spacing: 12) {
                if let id = paragraphID, let paragraph = word.paragraphs.first(where: { $0.id == id }) {
                    HStack {
                        Text("段落编辑").font(.headline)
                        Spacer()
                        Picker("样式", selection: Binding(get: { word.paragraphs.first(where: { $0.id == id })?.style ?? "Normal" }, set: { word.setStyle(id: id, style: $0); session.changed() })) {
                            ForEach(word.styles, id: \.id) { style in Text(style.name).tag(style.id) }
                            if !word.styles.contains(where: { $0.id == paragraph.style }) { Text(paragraph.style).tag(paragraph.style) }
                        }.frame(width: 230)
                    }
                    TextEditor(text: Binding(get: { word.paragraphs.first(where: { $0.id == id })?.text ?? "" }, set: { word.setText(id: id, text: $0); session.changed() }))
                        .font(.system(size: 16)).padding(10).background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
                    if paragraph.containsObjects { Label("这一段含复杂对象；修改文字会保留对象及已有文字运行格式。完整分页请导出 PDF 查看。", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                } else { ContentUnavailableView("选择或新建一个段落", systemImage: "paragraph") }
                Text("编辑正文和表格内段落、应用文档已有样式。图片、页眉页脚、批注、修订等原有部件会保留；复杂排版可在本机 LibreOffice 高级编辑。").font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func commitCell() throws {
        guard let workbook = session.workbook, workbook.sheets.indices.contains(selectedSheet) else { return }
        if (workbook.cell(sheet: selectedSheet, address: address)?.input ?? "") != cellInput { try workbook.set(sheet: selectedSheet, address: address, input: cellInput); session.changed() }
        session.pendingCell = nil
    }
    private func selectCell(_ target: String) {
        do { try commitCell(); guard OfficeWorkbook.coordinates(target) != nil else { throw OfficeFailure.message("单元格地址无效。") }; address = target.uppercased().replacingOccurrences(of: "$", with: ""); addressField = address; cellInput = session.workbook?.cell(sheet: selectedSheet, address: address)?.input ?? "" } catch { onError(error.localizedDescription) }
    }
    private func excelEditor(_ workbook: OfficeWorkbook) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("A1", text: $addressField).frame(width: 74).onSubmit { selectCell(addressField) }.textFieldStyle(.roundedBorder)
                Text("fx").font(.system(size: 14, weight: .semibold, design: .serif)).foregroundStyle(.secondary)
                TextField("单元格内容或 =SUM(A1:A5)", text: $cellInput).textFieldStyle(.roundedBorder).onSubmit { do { try commitCell() } catch { onError(error.localizedDescription) } }
                    .onChange(of: cellInput) { _, new in if new != (workbook.cell(sheet: selectedSheet, address: address)?.input ?? "") { session.pendingCell = (selectedSheet, address, new); session.changed() } else { session.pendingCell = nil } }
                Button("应用") { do { try commitCell() } catch { onError(error.localizedDescription) } }
            }.padding(10)
            if workbook.sheets.indices.contains(selectedSheet) {
                let sheet = workbook.sheets[selectedSheet]
                let rowCount = max(40, min(sheet.maxRow + 10, 200))
                let columnCount = max(8, min(sheet.maxColumn + 2, 30))
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Text("").frame(width: 42, height: 27).background(Color(nsColor: .controlBackgroundColor))
                            ForEach(1...columnCount, id: \.self) { column in Text(OfficeWorkbook.columnName(column)).font(.system(size: 11, weight: .semibold)).frame(width: 112, height: 27).background(Color(nsColor: .controlBackgroundColor)).border(Color.secondary.opacity(0.18), width: 0.5) }
                        }
                        ForEach(1...rowCount, id: \.self) { row in
                            HStack(spacing: 0) {
                                Text(String(row)).font(.system(size: 11)).frame(width: 42, height: 30).background(Color(nsColor: .controlBackgroundColor))
                                ForEach(1...columnCount, id: \.self) { column in
                                    let reference = OfficeWorkbook.columnName(column) + String(row)
                                    let cell = sheet.cells[reference]
                                    Button { selectCell(reference) } label: {
                                        Text(cell?.display ?? "").font(.system(size: 12)).foregroundStyle(cell?.error != nil ? Color.orange : Color.primary).lineLimit(1).frame(width: 102, height: 30, alignment: .leading).padding(.horizontal, 5).background(address == reference ? Color.accentColor.opacity(0.14) : Color(nsColor: .textBackgroundColor)).border(address == reference ? Color.accentColor : Color.secondary.opacity(0.18), width: address == reference ? 1.5 : 0.5)
                                    }.buttonStyle(.plain).help(cell?.formula.map { "=" + $0 } ?? cell?.display ?? reference)
                                }
                            }
                        }
                    }
                }
                if let error = workbook.cell(sheet: selectedSheet, address: address)?.error { Text(error).font(.caption).foregroundStyle(.orange).padding(5) }
                HStack {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(Array(workbook.sheets.enumerated()), id: \.element.id) { index, item in
                                Button(item.name + (item.hidden ? "（隐藏）" : "")) {
                                    do { try commitCell(); selectedSheet = index; cellInput = workbook.cell(sheet: index, address: address)?.input ?? ""; sheetName = item.name } catch { onError(error.localizedDescription) }
                                }.buttonStyle(.bordered).tint(selectedSheet == index ? Color.accentColor : Color.secondary)
                            }
                        }
                    }
                    Button { do { try commitCell(); selectedSheet = try workbook.addSheet(); cellInput = ""; sheetName = workbook.sheets[selectedSheet].name; session.changed() } catch { onError(error.localizedDescription) } } label: { Image(systemName: "plus") }
                    TextField("工作表名称", text: $sheetName).frame(width: 130).textFieldStyle(.roundedBorder)
                    Button("重命名") { do { try workbook.renameSheet(index: selectedSheet, name: sheetName); session.changed() } catch { onError(error.localizedDescription) } }
                }.padding(10)
                Text("支持数值、文本、算术和 SUM / AVERAGE / MIN / MAX / COUNT / ABS / ROUND。其他公式保留原公式与缓存；日期、图表、合并单元格等样式保留于文件，完整显示可导出 PDF。网格显示前 200 行、30 列，地址栏可编辑任意单元格。").font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
    }
    private func presentationEditor(_ presentation: OfficePresentation) -> some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: Binding<Int?>(get: { selectedSlide }, set: { if let index = $0 { selectedSlide = index; shapeID = presentation.slides[index].texts.first?.id } })) {
                    ForEach(Array(presentation.slides.enumerated()), id: \.element.id) { index, slide in
                        HStack(alignment: .top) { Text(String(index + 1)).font(.caption).foregroundStyle(.secondary); Text(slide.title).font(.system(size: 13)).lineLimit(3) }.padding(.vertical, 8).tag(index)
                    }
                }
                Button { do { selectedSlide = try presentation.addSlide(); shapeID = try presentation.addText(slide: selectedSlide); session.changed() } catch { onError(error.localizedDescription) } } label: { Label("新增幻灯片", systemImage: "plus") }.padding(10)
            }.frame(minWidth: 160, idealWidth: 190, maxWidth: 260)
            if presentation.slides.indices.contains(selectedSlide) {
                let slide = presentation.slides[selectedSlide]
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("第 \(selectedSlide + 1) 页 · 文字布局").font(.headline); Spacer(); Button("新增文本框") { do { shapeID = try presentation.addText(slide: selectedSlide); session.changed() } catch { onError(error.localizedDescription) } } }
                    GeometryReader { geometry in
                        let scale = min(geometry.size.width / presentation.width, geometry.size.height / presentation.height)
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(Color.white).frame(width: presentation.width * scale, height: presentation.height * scale)
                            ForEach(slide.texts) { text in
                                Button { shapeID = text.id } label: {
                                    Text(text.text).font(.system(size: max(9, min(24, scale * 0.7)))).foregroundStyle(Color.black).frame(width: max(10, text.width * scale), height: max(10, text.height * scale), alignment: .topLeading).background(shapeID == text.id ? Color.blue.opacity(0.08) : Color.clear).overlay(Rectangle().stroke(shapeID == text.id ? Color.blue : Color.gray.opacity(0.3), lineWidth: 1))
                                }.buttonStyle(.plain).position(x: (text.x + text.width / 2) * scale, y: (text.y + text.height / 2) * scale)
                            }
                        }.frame(width: presentation.width * scale, height: presentation.height * scale).clipped().overlay(Rectangle().stroke(Color.gray.opacity(0.25), lineWidth: 1))
                    }.frame(minHeight: 220, idealHeight: 300, maxHeight: 420)
                    Picker("文本框", selection: Binding(get: { shapeID ?? "" }, set: { shapeID = $0 })) { ForEach(slide.texts) { Text($0.name).tag($0.id) } }
                    if let id = shapeID, let text = slide.texts.first(where: { $0.id == id }) {
                        TextEditor(text: Binding(get: { presentation.slides[selectedSlide].texts.first(where: { $0.id == id })?.text ?? "" }, set: { presentation.setText(slide: selectedSlide, id: id, text: $0); session.changed() })).font(.system(size: 14)).frame(minHeight: 80, idealHeight: 110, maxHeight: 200).padding(6).background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
                        HStack {
                            geometryField("X", value: text.x) { presentation.setGeometry(slide: selectedSlide, id: id, x: $0) }
                            geometryField("Y", value: text.y) { presentation.setGeometry(slide: selectedSlide, id: id, y: $0) }
                            geometryField("宽", value: text.width) { presentation.setGeometry(slide: selectedSlide, id: id, width: $0) }
                            geometryField("高", value: text.height) { presentation.setGeometry(slide: selectedSlide, id: id, height: $0) }
                            Text("cm").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("布局视图显示可编辑文本框；图片、图表、动画、母版等原有对象在文件内保留。完整幻灯片效果可导出 PDF 查看，复杂排版可在 LibreOffice 高级编辑。").font(.caption).foregroundStyle(.secondary)
                }.padding(14).frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    private func geometryField(_ title: String, value: Double, apply: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) { Text(title).font(.caption); TextField(title, value: Binding(get: { value }, set: { apply($0); session.changed() }), format: .number.precision(.fractionLength(0...2))).textFieldStyle(.roundedBorder).frame(width: 68) }
    }
}
