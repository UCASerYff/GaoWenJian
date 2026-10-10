import AppKit
import SwiftUI
import PDFKit

public enum LaTeXSidebarTab: String, CaseIterable, Identifiable {
    case structure = "大纲结构"
    case diagnostics = "编译诊断"
    public var id: String { rawValue }
}

@MainActor
public final class LaTeXBuildModel: ObservableObject {
    @Published public var busy = false
    @Published public var output = "选择主文件后编译。内置编译器强制离线；本机引擎支持完整宏包。"
    @Published public var pdfURL: URL?
    @Published public var diagnostics: [LaTeXDiagnostic] = []
    @Published public var engine = "tectonic"
    @Published public var mainPath = ""
    @Published public var detectedRootPath: String?
    @Published public var compiledEditorText: String?
    @Published public var structureNodes: [LaTeXStructureNode] = []
    @Published public var labels: [String] = []
    @Published public var citations: [String] = []
    @Published public var showSidebar = true
    @Published public var showLog = false
    @Published public var sidebarTab: LaTeXSidebarTab = .structure
    @Published public var targetHighlightPage: Int?
    @Published public var targetHighlightPoint: CGPoint?
    @Published public var highlightGeneration = 0
    @Published public var statusMessage: String?

    private var generation = UUID()

    public var effectiveMainURL: URL? {
        if !mainPath.isEmpty {
            return URL(fileURLWithPath: mainPath)
        }
        if let detectedRootPath, !detectedRootPath.isEmpty {
            return URL(fileURLWithPath: detectedRootPath)
        }
        return nil
    }

    public func refreshIndex(editorText: String, currentURL: URL?) {
        // 1. 检测 % !TeX root = ...
        if let detected = LaTeXIndexer.rootDirective(in: editorText, currentURL: currentURL) {
            detectedRootPath = detected.path
        } else {
            detectedRootPath = nil
        }

        // 2. 提取大纲节点、标签和文献
        let (nodes, lbls, cites) = LaTeXIndexer.parseIndex(in: editorText, fileURL: currentURL)
        structureNodes = nodes
        labels = lbls
        citations = cites
    }

    public func compile(_ file: URL, editorText: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        output = "正在准备本地编译…"
        diagnostics = []

        let currentGen = UUID()
        self.generation = currentGen

        do {
            let source = effectiveMainURL ?? file
            guard FileManager.default.fileExists(atPath: source.path), source.pathExtension.lowercased() == "tex" else {
                throw FileIssue.message("请选择有效的 .tex 主文件。")
            }
            let inputDigest = FileSafety.digest(try Data(contentsOf: source))
            let build = FileSafety.root.appendingPathComponent("Builds/" + FileSafety.digest(Data(source.path.utf8)).prefix(24), isDirectory: true)
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            let run = build.appendingPathComponent(currentGen.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)

            let result: ToolResult
            if engine == "tectonic" {
                guard let tool = LocalTools.tectonic else { throw FileIssue.message("找不到本地 Tectonic 编译器。") }
                let cache = try LocalTools.prepareTeXCache()
                result = try await LocalTools.run(
                    tool,
                    args: ["--only-cached", "--untrusted", "--keep-logs", "--synctex", "--outdir", run.path, source.path],
                    directory: source.deletingLastPathComponent(),
                    environment: ["TECTONIC_CACHE_DIR": cache.path],
                    timeout: 120
                )
            } else {
                guard let tool = LocalTools.executable(engine) else {
                    throw FileIssue.message("本机尚未安装 \(engine)。请选择内置 Tectonic 或在设置中配置 TeX Live。")
                }
                // 加入 -file-line-error 和 -synctex=1 保证诊断和双向定位能力
                result = try await LocalTools.run(
                    tool,
                    args: ["-file-line-error", "-synctex=1", "-no-shell-escape", "-interaction=nonstopmode", "-halt-on-error", "-output-directory=" + run.path, source.path],
                    directory: source.deletingLastPathComponent(),
                    timeout: 120
                )
            }

            guard self.generation == currentGen else { return }
            guard FileSafety.digest(try Data(contentsOf: source)) == inputDigest else {
                throw FileIssue.message("编译期间主文件发生变化，请重新编译以获得对应当前稿件的 PDF。")
            }

            output = result.output

            // 解析结构化诊断
            diagnostics = LaTeXDiagnosticParser.parse(log: result.output, workingDirectory: source.deletingLastPathComponent())

            let producedPDF = run.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".pdf")
            if result.code == 0, FileManager.default.fileExists(atPath: producedPDF.path) {
                pdfURL = producedPDF
                compiledEditorText = editorText
                output = "编译成功 · " + source.lastPathComponent + "\n\n" + result.output
                statusMessage = "编译成功"
            } else {
                // 如果有错误，自动切到诊断页签
                if !diagnostics.isEmpty {
                    sidebarTab = .diagnostics
                    showSidebar = true
                }
                let errorCount = diagnostics.filter { $0.severity == .error }.count
                statusMessage = errorCount > 0 ? "编译失败（发现 \(errorCount) 处错误）" : "编译未完成"
                throw FileIssue.message("编译未完成。请查看诊断面板与日志；离线缺失的宏包需通过本地工具包补充。\n" + result.output)
            }

            // 清理旧的编译临时构件
            let children = try FileManager.default.contentsOfDirectory(at: build, includingPropertiesForKeys: [.creationDateKey])
            for old in children where old.lastPathComponent != run.lastPathComponent {
                try? FileManager.default.removeItem(at: old)
            }
        } catch {
            output = error.localizedDescription
            if diagnostics.isEmpty {
                diagnostics.append(LaTeXDiagnostic(severity: .error, message: error.localizedDescription.components(separatedBy: "\n").first ?? "编译失败", detail: error.localizedDescription))
            }
            sidebarTab = .diagnostics
            showSidebar = true
        }
    }

    /// 正向定位：由源码行 -> PDF
    public func forwardSync(line: Int, sourceURL: URL?) {
        guard let pdfURL, let source = sourceURL else { return }
        Task {
            if let result = await SyncTeXService.forward(line: line, column: 1, source: source, pdf: pdfURL) {
                self.targetHighlightPage = result.page
                self.targetHighlightPoint = result.point
                self.highlightGeneration += 1
                self.statusMessage = "已定位到 PDF 第 \(result.page) 页"
            } else {
                self.statusMessage = "未找到对应 PDF 定位信息"
            }
        }
    }

    /// 反向定位：由 PDF 点击 -> 源码
    public func handlePDFCommandClick(page: Int, point: CGPoint) {
        guard let pdfURL else { return }
        Task {
            if let result = await SyncTeXService.inverse(page: page, point: point, pdf: pdfURL) {
                NotificationCenter.default.post(
                    name: Notification.Name("GaoWenJian.jumpToLaTeXLine"),
                    object: result.file.path,
                    userInfo: ["line": result.line, "column": result.column]
                )
                self.statusMessage = "已跳转至源码第 \(result.line) 行"
            }
        }
    }
}

// MARK: - 主工作区视图 (LaTeX Workspace)

public struct LaTeXWorkspace: View {
    @Binding public var text: String
    public let url: URL?
    public let save: () -> URL?
    public let onError: (String) -> Void

    @StateObject private var build = LaTeXBuildModel()
    @State private var pdfControls = LaTeXPDFControls()

    public init(text: Binding<String>, url: URL?, save: @escaping () -> URL?, onError: @escaping (String) -> Void) {
        self._text = text
        self.url = url
        self.save = save
        self.onError = onError
    }

    public var body: some View {
        VStack(spacing: 0) {
            topToolbar
            Divider()

            HSplitView {
                // 左侧大纲与诊断折叠面板
                if build.showSidebar {
                    sidebarPanel
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                }

                // 中间编辑器
                LaTeXSourceEditor(
                    text: $text,
                    fileURL: url,
                    projectLabels: build.labels,
                    projectCitations: build.citations,
                    onCursorLineChange: { _ in },
                    onForwardSync: { line in
                        if let url { build.forwardSync(line: line, sourceURL: url) }
                    }
                )
                .frame(minWidth: 320)

                // 右侧 PDF 预览
                pdfPreviewPanel
                    .frame(minWidth: 340)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 底部编译日志面板
            if build.showLog {
                Divider()
                logPanel
            }
        }
        .onAppear {
            build.refreshIndex(editorText: text, currentURL: url)
        }
        .onChange(of: text) { _, newText in
            build.refreshIndex(editorText: newText, currentURL: url)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoWenJian.compileActive"))) { note in
            if note.object as? String == url?.path { compile() }
        }
    }

    // MARK: - 顶栏工具条

    private var topToolbar: some View {
        HStack(spacing: 8) {
            // 侧栏大纲/诊断切换
            Button {
                build.showSidebar.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help(build.showSidebar ? "隐藏结构与诊断" : "显示结构与诊断")

            Divider().frame(height: 18)

            // 快捷模板与环境菜单
            Menu {
                Menu("数学公式") {
                    Button("行内公式 $...$") { insertSnippet("$ $", cursorBack: 1) }
                    Button("行间公式 $$...$$") { insertSnippet("$$\n\n$$", cursorBack: 3) }
                    Button("分式 \\frac{a}{b}") { insertSnippet("\\frac{}{}", cursorBack: 3) }
                    Button("根号 \\sqrt{x}") { insertSnippet("\\sqrt{}", cursorBack: 1) }
                    Button("求和 \\sum_{i=1}^{n}") { insertSnippet("\\sum_{i=1}^{n} ", cursorBack: 0) }
                    Button("积分 \\int_{a}^{b}") { insertSnippet("\\int_{a}^{b} ", cursorBack: 0) }
                    Divider()
                    Button("矩阵 (pmatrix)") { insertSnippet("\\begin{pmatrix}\n  a & b \\\\\n  c & d\n\\end{pmatrix}\n", cursorBack: 0) }
                    Button("方程组 (cases)") { insertSnippet("\\begin{cases}\n  x, & \\text{若 } y > 0 \\\\\n  -x, & \\text{其他}\n\\end{cases}\n", cursorBack: 0) }
                }

                Menu("常用环境") {
                    Button("行间编号公式 (equation)") { insertSnippet("\\begin{equation}\n  \n\\end{equation}\n", cursorBack: 16) }
                    Button("多行对齐公式 (align)") { insertSnippet("\\begin{align}\n  \n\\end{align}\n", cursorBack: 13) }
                    Button("项目符号 (itemize)") { insertSnippet("\\begin{itemize}\n  \\item \n\\end{itemize}\n", cursorBack: 15) }
                    Button("编号列表 (enumerate)") { insertSnippet("\\begin{enumerate}\n  \\item \n\\end{enumerate}\n", cursorBack: 17) }
                    Button("三线表 (table)") { insertSnippet("\\begin{table}[htbp]\n  \\centering\n  \\begin{tabular}{cc}\n    \\toprule\n    列1 & 列2 \\\\\n    \\midrule\n    数据1 & 数据2 \\\\\n    \\bottomrule\n  \\end{tabular}\n  \\caption{表格标题}\n  \\label{tab:table1}\n\\end{table}\n", cursorBack: 0) }
                    Button("插图 (figure)") { insertSnippet("\\begin{figure}[htbp]\n  \\centering\n  \\includegraphics[width=0.8\\linewidth]{image.png}\n  \\caption{插图描述}\n  \\label{fig:fig1}\n\\end{figure}\n", cursorBack: 0) }
                }

                Menu("文本样式") {
                    Button("加粗 \\textbf{...}") { insertSnippet("\\textbf{}", cursorBack: 1) }
                    Button("斜体 \\textit{...}") { insertSnippet("\\textit{}", cursorBack: 1) }
                    Button("等宽代码 \\texttt{...}") { insertSnippet("\\texttt{}", cursorBack: 1) }
                    Button("下划线 \\underline{...}") { insertSnippet("\\underline{}", cursorBack: 1) }
                    Button("强调 \\emph{...}") { insertSnippet("\\emph{}", cursorBack: 1) }
                }

                Menu("结构与引用") {
                    Button("一级节 \\section{...}") { insertSnippet("\n\\section{}\n", cursorBack: 2) }
                    Button("二级子节 \\subsection{...}") { insertSnippet("\n\\subsection{}\n", cursorBack: 2) }
                    Button("三级子子节 \\subsubsection{...}") { insertSnippet("\n\\subsubsection{}\n", cursorBack: 2) }
                    Divider()
                    Button("标签 \\label{...}") { insertSnippet("\\label{}", cursorBack: 1) }
                    Button("引用 \\ref{...}") { insertSnippet("\\ref{}", cursorBack: 1) }
                    Button("公式引用 \\eqref{...}") { insertSnippet("\\eqref{}", cursorBack: 1) }
                    Button("文献引用 \\cite{...}") { insertSnippet("\\cite{}", cursorBack: 1) }
                }
            } label: {
                Label("插入", systemImage: "plus.forwardslash.minus")
            }

            // 编译器引擎切换
            Picker("编译器", selection: $build.engine) {
                Text("Tectonic · 离线").tag("tectonic")
                ForEach(["xelatex", "pdflatex", "lualatex"], id: \.self) {
                    Text($0).tag($0)
                }
            }
            .labelsHidden()
            .frame(width: 140)

            // 主文件控制
            Menu {
                Button("选择主文件…") {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [.init(filenameExtension: "tex")!]
                    if p.runModal() == .OK, let u = p.url {
                        build.mainPath = u.path
                    }
                }
                if !build.mainPath.isEmpty {
                    Button("恢复使用当前文件") { build.mainPath = "" }
                }
                if let root = build.detectedRootPath {
                    Divider()
                    Text("注释自动识别根文件：\(URL(fileURLWithPath: root).lastPathComponent)")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text.fill")
                    Text(displayMainFileName)
                        .lineLimit(1)
                }
            }
            .help("当前编译主文件：" + (build.effectiveMainURL?.path ?? url?.path ?? "当前文件"))

            Spacer(minLength: 8)

            // 编译按钮 (⌘B)
            Button(action: compile) {
                HStack(spacing: 5) {
                    if build.busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(build.busy ? "编译中" : "编译")
                }
            }
            .keyboardShortcut("b", modifiers: [.command])
            .disabled(build.busy)

            // 正向定位
            Button {
                if let url {
                    NotificationCenter.default.post(name: Notification.Name("GaoWenJian.requestForwardSync"), object: url.path)
                }
            } label: {
                Image(systemName: "arrow.right.to.line")
            }
            .help("正向定位到 PDF (Forward SyncTeX)")
            .disabled(build.pdfURL == nil)

            // 导出 PDF
            Button {
                guard let pdf = build.pdfURL else { return }
                let p = NSSavePanel()
                p.nameFieldStringValue = pdf.lastPathComponent
                if p.runModal() == .OK, let out = p.url {
                    do { try FileSafety.write(Data(contentsOf: pdf), to: out) }
                    catch { onError(error.localizedDescription) }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("导出 PDF…")
            .disabled(build.pdfURL == nil)

            // 独立窗口阅读
            Button {
                if let pdf = build.pdfURL { PDFReaderWindow.open(pdf) }
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .help("独立窗口阅读")
            .disabled(build.pdfURL == nil)

            // 编译日志面板开关
            Button {
                build.showLog.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "terminal")
                    if !build.diagnostics.isEmpty {
                        let errors = build.diagnostics.filter { $0.severity == .error }.count
                        if errors > 0 {
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                        } else {
                            Circle().fill(Color.orange).frame(width: 6, height: 6)
                        }
                    }
                }
            }
            .help("切换编译日志与终端输出")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var displayMainFileName: String {
        if !build.mainPath.isEmpty {
            return URL(fileURLWithPath: build.mainPath).lastPathComponent
        }
        if let detected = build.detectedRootPath {
            return URL(fileURLWithPath: detected).lastPathComponent + " (自动识别)"
        }
        return url?.lastPathComponent ?? "当前文件"
    }

    private func insertSnippet(_ snippet: String, cursorBack: Int) {
        NotificationCenter.default.post(
            name: Notification.Name("GaoWenJian.insertLaTeXSnippet"),
            object: nil,
            userInfo: ["snippet": snippet, "cursorBack": cursorBack]
        )
    }

    private func compile() {
        guard let savedURL = save() else { return }
        let editorText = text
        Task {
            await build.compile(savedURL, editorText: editorText)
        }
    }

    // MARK: - 侧边栏面板 (大纲树与诊断问题)

    private var sidebarPanel: some View {
        VStack(spacing: 0) {
            Picker("面板切换", selection: $build.sidebarTab) {
                Text("结构大纲").tag(LaTeXSidebarTab.structure)
                HStack {
                    Text("编译诊断")
                    if !build.diagnostics.isEmpty {
                        let count = build.diagnostics.filter { $0.severity == .error }.count
                        Text("\(count > 0 ? count : build.diagnostics.count)")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 4)
                            .background(count > 0 ? Color.red : Color.orange, in: Capsule())
                            .foregroundColor(.white)
                    }
                }.tag(LaTeXSidebarTab.diagnostics)
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            if build.sidebarTab == .structure {
                structureView
            } else {
                diagnosticsView
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var structureView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if build.structureNodes.isEmpty {
                    Text("暂无大纲。可通过 \\section、\\figure、\\table 建立结构。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(14)
                } else {
                    ForEach(build.structureNodes) { node in
                        Button {
                            NotificationCenter.default.post(
                                name: Notification.Name("GaoWenJian.jumpToLaTeXLine"),
                                object: node.fileURL?.path ?? url?.path,
                                userInfo: ["line": node.line]
                            )
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: node.kind.iconName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                Text(node.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer()
                                Text("L\(node.line)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.leading, CGFloat(node.kind.indentLevel) * 12 + 6)
                            .padding(.trailing, 8)
                            .frame(height: 26)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var diagnosticsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if build.diagnostics.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("无编译报错或警告")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                } else {
                    ForEach(build.diagnostics) { diag in
                        Button {
                            if let line = diag.line {
                                NotificationCenter.default.post(
                                    name: Notification.Name("GaoWenJian.jumpToLaTeXLine"),
                                    object: diag.file?.path ?? url?.path,
                                    userInfo: ["line": line]
                                )
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    Image(systemName: diag.severity.systemImage)
                                        .foregroundStyle(diag.severity == .error ? Color.red : Color.orange)
                                        .font(.system(size: 12))
                                    Text(diag.severity.rawValue)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(diag.severity == .error ? Color.red : Color.orange)
                                    Spacer()
                                    if !diag.locationDescription.isEmpty {
                                        Text(diag.locationDescription)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(diag.message)
                                    .font(.system(size: 12))
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(8)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(diag.severity == .error ? Color.red.opacity(0.2) : Color.orange.opacity(0.2)))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - PDF 预览区

    private var pdfPreviewPanel: some View {
        VStack(spacing: 0) {
            // PDF 工具条（缩放、定位指示）
            HStack(spacing: 8) {
                if let status = build.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button { pdfControls.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }.help("缩小")
                Button { pdfControls.actualSize() } label: { Text("100%").font(.system(size: 11)) }.help("实际大小")
                Button { pdfControls.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }.help("放大")
                Divider().frame(height: 14)
                Button { pdfControls.fitWidth() } label: { Image(systemName: "arrow.left.and.right") }.help("适应宽度")
                Button { pdfControls.fitPage() } label: { Image(systemName: "arrow.up.and.down") }.help("适应页面")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            if let pdf = build.pdfURL {
                LaTeXPDFPreview(
                    url: pdf,
                    controls: pdfControls,
                    highlightPage: build.targetHighlightPage,
                    highlightPoint: build.targetHighlightPoint,
                    highlightGeneration: build.highlightGeneration,
                    onCommandClick: { page, point in
                        build.handlePDFCommandClick(page: page, point: point)
                    }
                )
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("编译后在这里预览 PDF")
                        .font(.headline)
                    Text("支持 ⌘-点击 PDF 反向定位源码\n内置编译器不联网获取宏包")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - 终端日志折叠面板

    private var logPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("编译终端日志", systemImage: "terminal")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("清空") { build.output = "" }
                    .font(.caption)
                Button("关闭") { build.showLog = false }
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                Text(build.output)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 160)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

// MARK: - PDF 控制器与视图

public final class LaTeXPDFControls: ObservableObject {
    weak var pdfView: PDFView?
    public init() {}

    public func zoomIn() {
        guard let v = pdfView, v.document != nil else { return }
        v.autoScales = false
        v.scaleFactor = min(v.maxScaleFactor, v.scaleFactor + 0.2)
    }

    public func zoomOut() {
        guard let v = pdfView, v.document != nil else { return }
        v.autoScales = false
        v.scaleFactor = max(v.minScaleFactor, v.scaleFactor - 0.2)
    }

    public func actualSize() {
        guard let v = pdfView, v.document != nil else { return }
        v.autoScales = false
        v.scaleFactor = 1.0
    }

    public func fitWidth() {
        guard let v = pdfView, let doc = v.document, let page = v.currentPage ?? doc.page(at: 0) else { return }
        v.autoScales = false
        let pageRect = page.bounds(for: v.displayBox)
        let visibleWidth = v.bounds.width - 24
        if pageRect.width > 0 && visibleWidth > 0 {
            v.scaleFactor = visibleWidth / pageRect.width
        }
    }

    public func fitPage() {
        guard let v = pdfView else { return }
        v.autoScales = true
    }
}

public struct LaTeXPDFPreview: NSViewRepresentable {
    public let url: URL
    public let controls: LaTeXPDFControls
    public let highlightPage: Int?
    public let highlightPoint: CGPoint?
    public let highlightGeneration: Int
    public let onCommandClick: (Int, CGPoint) -> Void

    public func makeNSView(context: Context) -> SyncPDFView {
        let view = SyncPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .windowBackgroundColor
        view.onCommandClick = onCommandClick
        controls.pdfView = view
        context.coordinator.load(url, into: view)
        return view
    }

    public func updateNSView(_ view: SyncPDFView, context: Context) {
        controls.pdfView = view
        view.onCommandClick = onCommandClick
        context.coordinator.load(url, into: view)

        if let p = highlightPage, let pt = highlightPoint {
            context.coordinator.applyHighlight(page: p, point: pt, generation: highlightGeneration, to: view)
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        private var currentURL: URL?
        private var currentHighlightGen = -1

        func load(_ url: URL, into view: SyncPDFView) {
            if currentURL != url {
                currentURL = url
                if let doc = PDFDocument(url: url) {
                    view.document = doc
                }
            } else if view.document == nil {
                view.document = PDFDocument(url: url)
            }
        }

        func applyHighlight(page: Int, point: CGPoint, generation: Int, to view: SyncPDFView) {
            guard generation != currentHighlightGen else { return }
            currentHighlightGen = generation
            view.reveal(pageIndex: page - 1, point: point)
        }
    }
}

public final class SyncPDFView: PDFView {
    public var onCommandClick: ((Int, CGPoint) -> Void)?

    public override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let pointInView = convert(event.locationInWindow, from: nil)
            if let page = page(for: pointInView, nearest: true), let doc = document {
                let pageIndex = doc.index(for: page) + 1
                let pointInPage = convert(pointInView, to: page)
                onCommandClick?(pageIndex, pointInPage)
                return
            }
        }
        super.mouseDown(with: event)
    }

    public func reveal(pageIndex: Int, point: CGPoint) {
        guard let doc = document, pageIndex >= 0 && pageIndex < doc.pageCount,
              let page = doc.page(at: pageIndex) else { return }
        go(to: page)
        let visibleRect = CGRect(x: point.x - 20, y: point.y - 20, width: 40, height: 40)
        go(to: visibleRect, on: page)
    }
}

// MARK: - 智能补全编辑器 (LaTeX Source Editor)

public struct LaTeXSourceEditor: NSViewRepresentable {
    @Binding public var text: String
    public let fileURL: URL?
    public let projectLabels: [String]
    public let projectCitations: [String]
    public let onCursorLineChange: (Int) -> Void
    public let onForwardSync: (Int) -> Void

    @AppStorage("editorFontSize") private var fontSize = 15.0
    @AppStorage("wrapLines") private var wrap = true

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = !wrap
        scroll.autohidesScrollers = true

        let textView = LaTeXTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 20, height: 18)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wrap
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = wrap

        textView.string = text
        scroll.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.highlight(textView)
        context.coordinator.setupObservers()

        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? LaTeXTextView else { return }
        if textView.string != text {
            let range = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(range.location, (text as NSString).length), length: 0))
            context.coordinator.highlight(textView)
        }
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainer?.widthTracksTextView = wrap
        textView.isHorizontallyResizable = !wrap
        scroll.hasHorizontalScroller = !wrap
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        public var parent: LaTeXSourceEditor
        public weak var textView: LaTeXTextView?
        private var completionWindow: NSWindow?
        private var candidates: [LaTeXCompletion.CompletionCandidate] = []
        private var currentReplaceRange = NSRange(location: 0, length: 0)
        private var observers: [NSObjectProtocol] = []

        public init(_ parent: LaTeXSourceEditor) {
            self.parent = parent
            super.init()
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            completionWindow?.orderOut(nil)
        }

        public func setupObservers() {
            // 监听跳转行通知
            let jumpObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("GaoWenJian.jumpToLaTeXLine"),
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self, let line = note.userInfo?["line"] as? Int else { return }
                self.jumpTo(line: line)
            }
            observers.append(jumpObserver)

            // 监听代码片段插入
            let snippetObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("GaoWenJian.insertLaTeXSnippet"),
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self,
                      let snippet = note.userInfo?["snippet"] as? String,
                      let back = note.userInfo?["cursorBack"] as? Int else { return }
                self.insertSnippet(snippet, cursorBack: back)
            }
            observers.append(snippetObserver)

            // 监听正向同步请求
            let forwardObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("GaoWenJian.requestForwardSync"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, let tv = self.textView else { return }
                let line = self.currentLineNumber(in: tv)
                self.parent.onForwardSync(line)
            }
            observers.append(forwardObserver)
        }

        public func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? LaTeXTextView else { return }
            parent.text = view.string
            highlight(view)
            checkCompletion(view)
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? LaTeXTextView else { return }
            let line = currentLineNumber(in: view)
            parent.onCursorLineChange(line)
            checkCompletion(view)
        }

        public func highlight(_ view: NSTextView) {
            guard let storage = view.textStorage, storage.length < 500_000 else { return }
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: storage.length))

            let patterns: [(String, NSColor)] = [
                // 章节命令
                (#"\\(part|chapter|section|subsection|subsubsection|paragraph)\*?"#, .systemPink),
                // 常用命令
                (#"\\\w+"#, .systemIndigo),
                // 行内与块级公式
                (#"(\$\$[\s\S]*?\$\$|\$[^\$]*?\$)"#, .systemTeal),
                // 环境
                (#"\\(begin|end)\{[^\}]+\}"#, .systemPurple),
                // 注释
                (#"%.*$"#, .secondaryLabelColor)
            ]

            for (pattern, color) in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) {
                    for match in regex.matches(in: view.string, range: NSRange(location: 0, length: storage.length)) {
                        storage.addAttribute(.foregroundColor, value: color, range: match.range)
                    }
                }
            }
            storage.endEditing()
        }

        private func currentLineNumber(in view: NSTextView) -> Int {
            let loc = view.selectedRange().location
            let ns = view.string as NSString
            let prefix = ns.substring(with: NSRange(location: 0, length: min(loc, ns.length)))
            return prefix.components(separatedBy: .newlines).count
        }

        public func jumpTo(line: Int) {
            guard let tv = textView, line > 0 else { return }
            let lines = tv.string.components(separatedBy: .newlines)
            guard line <= lines.count else { return }

            var loc = 0
            for i in 0..<(line - 1) {
                loc += (lines[i] as NSString).length + 1 // +1 换行符
            }
            let lineLength = (lines[line - 1] as NSString).length
            let targetRange = NSRange(location: loc, length: lineLength)

            tv.setSelectedRange(targetRange)
            tv.scrollRangeToVisible(targetRange)
            tv.window?.makeFirstResponder(tv)
        }

        public func insertSnippet(_ snippet: String, cursorBack: Int) {
            guard let tv = textView else { return }
            let sel = tv.selectedRange()
            tv.insertText(snippet, replacementRange: sel)
            let newLoc = max(0, tv.selectedRange().location - cursorBack)
            tv.setSelectedRange(NSRange(location: newLoc, length: 0))
        }

        // MARK: - 补全逻辑

        private func checkCompletion(_ view: LaTeXTextView) {
            let sel = view.selectedRange()
            guard sel.length == 0 else {
                dismissCompletion()
                return
            }

            guard let detected = LaTeXCompletion.detectContext(in: view.string, cursorLocation: sel.location) else {
                dismissCompletion()
                return
            }

            let cands = LaTeXCompletion.candidates(
                for: detected.context,
                projectLabels: parent.projectLabels,
                projectCitations: parent.projectCitations
            )

            guard !cands.isEmpty else {
                dismissCompletion()
                return
            }

            self.candidates = cands
            self.currentReplaceRange = detected.replaceRange
            showCompletionPopup(candidates: cands, at: view)
        }

        private func showCompletionPopup(candidates: [LaTeXCompletion.CompletionCandidate], at textView: LaTeXTextView) {
            let sel = textView.selectedRange()
            guard let window = textView.window else { return }
            guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }

            let glyphIndex = layoutManager.glyphIndexForCharacter(at: max(0, sel.location - 1))
            let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
            let rectInWindow = textView.convert(glyphRect, to: nil)
            let screenRect = window.convertToScreen(rectInWindow)

            if completionWindow == nil {
                let win = NSWindow(
                    contentRect: NSRect(x: screenRect.origin.x, y: screenRect.origin.y - 180, width: 220, height: 160),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                win.isOpaque = false
                win.backgroundColor = .clear
                win.hasShadow = true
                win.level = .floating
                self.completionWindow = win
            }

            let contentView = NSHostingView(rootView: LaTeXCompletionListView(candidates: candidates) { [weak self] cand in
                self?.applyCandidate(cand)
            })
            completionWindow?.contentView = contentView
            completionWindow?.setFrame(NSRect(x: screenRect.origin.x, y: screenRect.origin.y - 170, width: 230, height: 160), display: true)
            completionWindow?.orderFront(nil)
        }

        public func applyCandidate(_ cand: LaTeXCompletion.CompletionCandidate) {
            guard let tv = textView else { return }
            tv.insertText(cand.insertText, replacementRange: currentReplaceRange)
            let targetLoc = max(0, tv.selectedRange().location - cand.caretOffsetFromEnd)
            tv.setSelectedRange(NSRange(location: targetLoc, length: 0))
            dismissCompletion()
        }

        public func dismissCompletion() {
            completionWindow?.orderOut(nil)
            completionWindow = nil
        }
    }
}

public final class LaTeXTextView: NSTextView {
    // 基础 NSTextView，供事件拦截
}

public struct LaTeXCompletionListView: View {
    public let candidates: [LaTeXCompletion.CompletionCandidate]
    public let onSelect: (LaTeXCompletion.CompletionCandidate) -> Void

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(candidates) { cand in
                    Button {
                        onSelect(cand)
                    } label: {
                        HStack {
                            Text(cand.title)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.primary)
                            Spacer()
                            if let sub = cand.subtitle {
                                Text(sub)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
    }
}
