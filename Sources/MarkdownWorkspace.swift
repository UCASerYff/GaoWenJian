import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import PDFKit

/// A fully local Markdown work area. `text` is the original source, never reconstructed from HTML.
struct MarkdownWorkspace: View {
    @Binding var text: String
    let baseURL: URL?
    let onError: (String) -> Void
    @State private var mode = "live"
    @State private var showsOutline = false
    @StateObject private var bridge = MarkdownBridge()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Picker("编辑模式", selection: $mode) {
                    Text("即时编辑").tag("live")
                    Text("分屏").tag("split")
                    Text("源码").tag("source")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                Button { showsOutline.toggle() } label: { Image(systemName: "list.bullet.indent") }
                    .help("显示文档大纲")
                    .tint(showsOutline ? .accentColor : .secondary)
                Divider().frame(height: 18)
                Button { bridge.format("bold") } label: { Image(systemName: "bold") }.help("加粗（⌘B）")
                Button { bridge.format("italic") } label: { Image(systemName: "italic") }.help("斜体（⌘I）")
                Menu {
                    Button("一级标题") { bridge.insert("# 标题\n\n") }
                    Button("二级标题") { bridge.insert("## 标题\n\n") }
                    Button("无序列表") { bridge.insert("- 列表项目\n") }
                    Button("任务列表") { bridge.insert("- [ ] 待办事项\n") }
                    Button("引用") { bridge.insert("> 引用内容\n\n") }
                    Divider()
                    Button("表格") { bridge.insert("\n\n| 列一 | 列二 |\n| --- | --- |\n| 内容 | 内容 |\n\n") }
                    Button("代码块") { bridge.insert("\n\n```text\n代码内容\n```\n\n") }
                    Button("行内公式") { bridge.format("math") }
                    Button("公式块") { bridge.insert("\n\n$$\nE = mc^2\n$$\n\n") }
                    Button("Mermaid 图示") { bridge.insert("\n\n```mermaid\nflowchart LR\n    A[开始] --> B[完成]\n```\n\n") }
                    Button("脚注") { bridge.insert("[^1]\n\n[^1]: 脚注内容\n") }
                    Button("链接") { bridge.format("link") }
                } label: { Label("插入", systemImage: "plus") }
                Button { bridge.importImage() } label: { Image(systemName: "photo.badge.plus") }.help("插入本地图片（也支持粘贴与拖拽）")
                Spacer(minLength: 8)
                Menu {
                    Button("导出 HTML…") { bridge.export("html") }
                    Button("导出 PDF…") { bridge.export("pdf") }
                } label: { Label("导出", systemImage: "square.and.arrow.up") }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            MarkdownWebEditor(text: $text, baseURL: baseURL, mode: mode, showsOutline: showsOutline, bridge: bridge, onError: onError)
        }
    }
}

@MainActor
private final class MarkdownBridge: ObservableObject {
    weak var coordinator: MarkdownWebEditor.Coordinator?
    func insert(_ value: String) { coordinator?.run("window.gaoMarkdown.insertSnippet(\(MarkdownJSON.literal(value)))") }
    func format(_ kind: String) { coordinator?.run("window.gaoMarkdown.format(\(MarkdownJSON.literal(kind)))") }
    func importImage() { coordinator?.importImage() }
    func export(_ kind: String) { coordinator?.beginExport(kind) }
}

private enum MarkdownJSON {
    static func literal(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]), let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(encoded.dropFirst().dropLast())
    }
}

/// The only browser URL scheme used by the editor. It serves bundled assets and files inside the document's directory.
final class MarkdownSchemeHandler: NSObject, WKURLSchemeHandler {
    let resourceRoot: URL
    var attachmentRoot: URL?
    init(resourceRoot: URL, attachmentRoot: URL?) {
        self.resourceRoot = resourceRoot.resolvingSymlinksInPath().standardizedFileURL
        self.attachmentRoot = attachmentRoot?.resolvingSymlinksInPath().standardizedFileURL
    }
    static func documentDirectory(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else { return nil }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { return url }
        return url.hasDirectoryPath ? url : url.deletingLastPathComponent()
    }
    func localURL(for url: URL) throws -> URL {
        guard url.scheme == "gaomd", url.host == "bundle" || url.host == "attachment" else { throw FileIssue.message("已阻止外部资源访问。") }
        guard let root = url.host == "bundle" ? resourceRoot : attachmentRoot else { throw FileIssue.message("请先保存文档，再使用本地图片。") }
        let relative = String(url.path.drop(while: { $0 == "/" }))
        let resolved = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path.hasPrefix(prefix) else { throw FileIssue.message("图片位于文档目录之外，请使用“插入图片”复制到附件目录。") }
        return resolved
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            guard let url = urlSchemeTask.request.url else { throw FileIssue.message("无效的本地资源。") }
            let file = try localURL(for: url)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 100 * 1024 * 1024 else { throw FileIssue.message("本地资源不是常规文件，或超过 100 MB。") }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"])!
            urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

@MainActor
private struct MarkdownWebEditor: NSViewRepresentable {
    @Binding var text: String
    let baseURL: URL?
    let mode: String
    let showsOutline: Bool
    let bridge: MarkdownBridge
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(coordinator.schemeHandler, forURLScheme: "gaomd")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(coordinator, name: "gaoMD")
        let errorScript = "window.addEventListener('error', function(e) { try { window.webkit.messageHandlers.gaoMD.postMessage({kind:'error',message:'Markdown 编辑器：'+e.message}); } catch(_){} });"
        configuration.userContentController.addUserScript(WKUserScript(source: errorScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.setValue(false, forKey: "drawsBackground")
        coordinator.webView = view; bridge.coordinator = coordinator
        view.load(URLRequest(url: URL(string: "gaomd://bundle/index.html")!))
        return view
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self; bridge.coordinator = coordinator
        coordinator.schemeHandler.attachmentRoot = MarkdownSchemeHandler.documentDirectory(baseURL)?.resolvingSymlinksInPath().standardizedFileURL
        coordinator.synchronize()
    }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "gaoMD")
        nsView.navigationDelegate = nil
        coordinator.exportView?.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MarkdownWebEditor
        weak var webView: WKWebView?
        let schemeHandler: MarkdownSchemeHandler
        var ready = false
        var latestText: String?
        var latestMode: String?
        var latestOutline: Bool?
        var latestRoot: URL?
        var pendingExport: (kind: String, url: URL)?
        var exportView: WKWebView?
        var exportWindow: NSWindow?
        var pdfPrintOperation: NSPrintOperation?
        var retainedForPrint: Coordinator?

        init(_ parent: MarkdownWebEditor) {
            self.parent = parent
            let resources = Bundle.main.resourceURL?.appendingPathComponent("Web", isDirectory: true) ?? URL(fileURLWithPath: "/nonexistent/Web")
            schemeHandler = MarkdownSchemeHandler(resourceRoot: resources, attachmentRoot: MarkdownSchemeHandler.documentDirectory(parent.baseURL))
        }
        func run(_ javascript: String) {
            guard ready else { return }
            webView?.evaluateJavaScript(javascript) { [weak self] _, error in
                if let error { self?.parent.onError("Markdown 操作失败：" + error.localizedDescription) }
            }
        }
        func synchronize() {
            guard ready else { return }
            let root = schemeHandler.attachmentRoot
            if latestText != parent.text || latestRoot != root {
                let rootChanged = latestRoot != root
                latestText = parent.text; latestRoot = root; latestMode = parent.mode; latestOutline = parent.showsOutline
                run("window.gaoMarkdown.setDocument(\(MarkdownJSON.literal(parent.text)),\(MarkdownJSON.literal(parent.mode)),\(parent.showsOutline),\(rootChanged))")
            } else {
                if latestMode != parent.mode { latestMode = parent.mode; run("window.gaoMarkdown.setMode(\(MarkdownJSON.literal(parent.mode)))") }
                if latestOutline != parent.showsOutline { latestOutline = parent.showsOutline; run("window.gaoMarkdown.setOutline(\(parent.showsOutline))") }
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let payload = message.body as? [String: Any], let kind = payload["kind"] as? String else { return }
            switch kind {
            case "ready": ready = true; synchronize()
            case "change":
                if let value = payload["text"] as? String { latestText = value; parent.text = value }
            case "error": if let error = payload["message"] as? String { parent.onError(error) }
            case "link":
                guard let href = payload["href"] as? String else { return }
                if href.hasPrefix("#") { return }
                parent.onError("当前版本在本机工作。链接地址：" + href)
            case "pasteImage":
                do {
                    guard let value = payload["data"] as? String, value.hasPrefix("data:image/"), let comma = value.firstIndex(of: ","), let data = Data(base64Encoded: String(value[value.index(after: comma)...])), data.count <= 25 * 1024 * 1024 else { throw FileIssue.message("无法读取粘贴的图片。") }
                    try storeImage(data: data, name: payload["name"] as? String ?? "粘贴图片.png")
                } catch { parent.onError(error.localizedDescription) }
            case "exportReady":
                guard let html = payload["html"] as? String, let pending = pendingExport, pending.kind == payload["format"] as? String else { return }
                pendingExport = nil
                do {
                    let document = try exportDocument(body: html)
                    if pending.kind == "html" { try FileSafety.write(Data(document.utf8), to: pending.url) }
                    else { try printPDF(document: document, destination: pending.url) }
                } catch { parent.onError(error.localizedDescription) }
            default: break
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if webView === exportView {
                webView.callAsyncJavaScript("await document.fonts.ready; return true;", arguments: [:], in: nil, in: .page) { [weak self] _ in self?.finishPDF() }
            } else if !ready {
                webView.evaluateJavaScript("typeof window.gaoMarkdown === 'object'") { [weak self] value, _ in
                    guard let self else { return }
                    if value as? Bool == true { self.ready = true; self.synchronize() }
                    else { self.parent.onError("Markdown 编辑器资源未能加载，请重新打开文档。") }
                }
            }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { parent.onError("Markdown 页面加载失败：" + error.localizedDescription) }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if webView === exportView, url.scheme == "about" { decisionHandler(.allow); return }
            decisionHandler(url.scheme == "gaomd" && url.host == "bundle" ? .allow : .cancel)
        }
        func importImage() {
            guard MarkdownSchemeHandler.documentDirectory(parent.baseURL) != nil else { parent.onError("请先保存 Markdown 文档，再插入图片。"); return }
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.message = "图片将复制到文档旁的 .assets 目录，原图片保持不变。"
            panel.begin { [weak self] response in
                guard response == .OK, let self else { return }
                do { for url in panel.urls { try self.storeImage(data: Data(contentsOf: url), name: url.lastPathComponent) } }
                catch { self.parent.onError("插入图片失败：" + error.localizedDescription) }
            }
        }
        func storeImage(data: Data, name: String) throws {
            guard let rawRoot = MarkdownSchemeHandler.documentDirectory(parent.baseURL) else { throw FileIssue.message("请先保存 Markdown 文档，再插入图片。") }
            let root = rawRoot.resolvingSymlinksInPath().standardizedFileURL
            let folder = root.appendingPathComponent(".assets", isDirectory: true)
            let existing = folder.resolvingSymlinksInPath().standardizedFileURL
            guard existing.path.hasPrefix(root.path + "/") else { throw FileIssue.message("附件目录指向文档目录外，已停止写入。") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let original = URL(fileURLWithPath: name).lastPathComponent
            let stem = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "[^\\p{L}\\p{N}_-]", with: "-", options: .regularExpression)
            let ext = URL(fileURLWithPath: original).pathExtension.isEmpty ? "png" : URL(fileURLWithPath: original).pathExtension.lowercased()
            let safeStem = stem.isEmpty ? "图片" : String(stem.prefix(60))
            var target = folder.appendingPathComponent(safeStem + "." + ext); var count = 1
            while FileManager.default.fileExists(atPath: target.path) { target = folder.appendingPathComponent(safeStem + "-\(count)." + ext); count += 1 }
            try data.write(to: target, options: .atomic)
            guard try Data(contentsOf: target) == data else { throw FileIssue.message("附件保存校验失败。") }
            let relative = ".assets/" + target.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
            run("window.gaoMarkdown.insertSnippet(\(MarkdownJSON.literal("![" + safeStem + "](" + relative + ")\n")))")
        }
        func beginExport(_ kind: String) {
            guard ready else { parent.onError("编辑器正在加载，请稍后导出。"); return }
            guard exportView == nil else { parent.onError("PDF 正在导出，请等待完成后再导出。"); return }
            let panel = NSSavePanel(); panel.allowedContentTypes = kind == "pdf" ? [.pdf] : [.html]
            let name = parent.baseURL?.deletingPathExtension().lastPathComponent ?? "文档"
            panel.nameFieldStringValue = name + "." + kind
            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url, let self else { return }
                self.pendingExport = (kind, url)
                self.run("window.gaoMarkdown.requestExport(\(MarkdownJSON.literal(kind)))")
            }
        }
        func exportDocument(body: String) throws -> String {
            var html = body
            let regex = try NSRegularExpression(pattern: "gaomd://attachment/[^\\\"\\s<>]*")
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
                guard let range = Range(match.range, in: html), let url = URL(string: String(html[range])) else { continue }
                let file = try schemeHandler.localURL(for: url)
                let data = try Data(contentsOf: file)
                let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                html.replaceSubrange(range, with: "data:\(mime);base64," + data.base64EncodedString())
            }
            var katexCSS = try String(contentsOf: schemeHandler.resourceRoot.appendingPathComponent("vendor/katex.min.css"), encoding: .utf8)
            let fontRegex = try NSRegularExpression(pattern: "url\\(fonts/([^)]*\\.woff2)\\)")
            for match in fontRegex.matches(in: katexCSS, range: NSRange(katexCSS.startIndex..., in: katexCSS)).reversed() {
                guard let entire = Range(match.range, in: katexCSS), let filename = Range(match.range(at: 1), in: katexCSS) else { continue }
                let data = try Data(contentsOf: schemeHandler.resourceRoot.appendingPathComponent("vendor/fonts/" + String(katexCSS[filename])))
                katexCSS.replaceSubrange(entire, with: "url(data:font/woff2;base64," + data.base64EncodedString() + ")")
            }
            // Only the inlined WOFF2 source is needed by the exported document.
            katexCSS = katexCSS.replacingOccurrences(of: ",url\\(fonts/[^)]*\\)[^,;}]*", with: "", options: .regularExpression)
            let css = try String(contentsOf: schemeHandler.resourceRoot.appendingPathComponent("markdown.css"), encoding: .utf8)
            let title = (parent.baseURL?.deletingPathExtension().lastPathComponent ?? "文档").replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            let layout = "html,body{height:auto;overflow:visible;display:block;padding:0}body{background:var(--paper)}.markdown-body{padding:32px 42px}"
            return "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; script-src 'none'\"><title>\(title)</title><style>\(katexCSS)\n\(css)\n\(layout)</style></head><body>\(html)</body></html>"
        }
        var pdfDestination: URL?
        var pdfTemporaryURL: URL?
        var pdfExpectedDigest: String?
        var pdfDestinationExisted = false
        func printPDF(document: String, destination: URL) throws {
            pdfDestinationExisted = FileManager.default.fileExists(atPath: destination.path)
            pdfExpectedDigest = pdfDestinationExisted ? FileSafety.digest(try Data(contentsOf: destination)) : nil
            pdfTemporaryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("gao-md-export-" + UUID().uuidString + ".pdf")
            retainedForPrint = self
            pdfDestination = destination
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
            exportView = view; view.navigationDelegate = self
            // WebKit needs an attached window to complete layout and font loading before printing.
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true; window.hasShadow = false
            window.contentView = view; exportWindow = window; window.orderBack(nil)
            view.loadHTMLString(document, baseURL: nil)
        }
        func finishPDF() {
            guard let view = exportView, pdfDestination != nil else { return }
            let printInfo = NSPrintInfo()
            printInfo.paperSize = NSSize(width: 595.28, height: 841.89)
            printInfo.topMargin = 42; printInfo.bottomMargin = 42; printInfo.leftMargin = 38; printInfo.rightMargin = 38
            printInfo.horizontalPagination = .fit; printInfo.verticalPagination = .automatic; printInfo.isHorizontallyCentered = false
            printInfo.jobDisposition = .save
            guard let temporary = pdfTemporaryURL else { parent.onError("无法创建 PDF 导出临时文件。"); cleanUpPDF(); return }
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = temporary
            let operation = view.printOperation(with: printInfo)
            operation.showsPrintPanel = false; operation.showsProgressPanel = false; operation.canSpawnSeparateThread = true
            pdfPrintOperation = operation
            guard let window = exportWindow else { parent.onError("无法创建 PDF 导出工作区。"); cleanUpPDF(); return }
            // WebKit computes pagination through asynchronous IPC; running synchronously on the main thread yields an unresolved page range.
            operation.runModal(for: window, delegate: self, didRun: #selector(pdfDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        @objc func pdfDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            defer { cleanUpPDF() }
            do {
                guard success, let temporary = pdfTemporaryURL, let destination = pdfDestination else { throw FileIssue.message("PDF 导出失败，目标文件保持原样。") }
                let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
                guard data.starts(with: Data("%PDF".utf8)), let pdf = PDFDocument(data: data), pdf.pageCount > 0 else { throw FileIssue.message("PDF 导出结果校验失败，目标文件保持原样。") }
                guard pdfDestinationExisted || !FileManager.default.fileExists(atPath: destination.path) else { throw FileIssue.message("导出期间目标文件已被其他程序创建，请重新导出或另存。") }
                try FileSafety.write(data, to: destination, expectedDigest: pdfExpectedDigest)
            } catch { parent.onError(error.localizedDescription) }
        }
        func cleanUpPDF() {
            if let temporary = pdfTemporaryURL { try? FileManager.default.removeItem(at: temporary) }
            exportWindow?.close(); exportWindow = nil; exportView = nil; pdfDestination = nil
            pdfTemporaryURL = nil; pdfExpectedDigest = nil; pdfDestinationExisted = false; pdfPrintOperation = nil; retainedForPrint = nil
        }
    }
}
