import AppKit
import WebKit
import Foundation
import PDFKit

@MainActor
final class MarkdownWebSmoke: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var window: NSWindow!
    var view: WKWebView!
    var printView: WKWebView?
    var printWindow: NSWindow?
    var localScheme: MarkdownSchemeHandler!
    var pdfTarget: URL?
    var printOperation: NSPrintOperation?
    var errors: [String] = []
    var finished = false
    let source = "---\r\ntitle: 本地测试\r\nunknown: must-survive\r\n---\r\n\r\n# 标题\r\n\r\n正文 **粗体** $x^2$ 与脚注[^a]\r\n\r\n- [ ] 未完成\r\n- [x] 已完成\r\n\r\n| A | B |\r\n|---|---|\r\n|1|2|\r\n\r\n```mermaid\r\nflowchart LR\r\n A[开始] --> B[完成]\r\n```\r\n\r\n![本地图片](pixel.png)\r\n\r\n![远程图片](https://invalid.example/image.png)\r\n\r\n<custom-widget data-private=\"keep\">未知对象</custom-widget>\r\n\r\n<script>window.UNSAFE=true</script>\r\n\r\n[^a]: 脚注内容\r\n"
    func start() {
        let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Web", isDirectory: true)
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gao-md-smoke-" + UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try! Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jdykAAAAASUVORK5CYII=")!.write(to: temp.appendingPathComponent("pixel.png"))
        let scheme = MarkdownSchemeHandler(resourceRoot: resources, attachmentRoot: temp); localScheme = scheme
        do { _ = try scheme.localURL(for: URL(string: "gaomd://attachment/../../etc/passwd")!); fail("path traversal accepted") } catch {}
        let configuration = WKWebViewConfiguration(); configuration.setURLSchemeHandler(scheme, forURLScheme: "gaomd"); configuration.userContentController.add(self, name: "gaoMD")
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: configuration); view.navigationDelegate = self
        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false); window.title = "Markdown 本地验证"; window.contentView = view; window.makeKeyAndOrderFront(nil)
        view.load(URLRequest(url: URL(string: "gaomd://bundle/index.html")!))
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in if self?.finished == false { self?.fail("editor timeout") } }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any], let kind = payload["kind"] as? String else { return }
        if kind == "error" { errors.append(payload["message"] as? String ?? "unknown browser error") }
        if kind == "ready" {
            let data = try! JSONSerialization.data(withJSONObject: [source]); let literal = String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
            view.evaluateJavaScript("window.gaoMarkdown.setDocument(\(literal),'live',true)") { [weak self] _, error in if let error { self?.fail(error.localizedDescription) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.check() }
        }
        if kind == "exportReady" {
            let html = payload["html"] as? String ?? ""
            guard html.contains("katex"), html.contains("<svg"), html.contains("footnote"), !html.contains("<script>"), errors.isEmpty else { fail("export/console failure: " + errors.joined(separator: "; ")); return }
            let config = WKWebViewConfiguration(); config.setURLSchemeHandler(localScheme, forURLScheme: "gaomd")
            let printer = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000), configuration: config)
            printView = printer; printer.navigationDelegate = self
            let holder = NSWindow(contentRect: printer.frame, styleMask: .borderless, backing: .buffered, defer: false)
            holder.isReleasedWhenClosed = false; holder.contentView = printer; holder.alphaValue = 0; holder.orderBack(nil); printWindow = holder
            printer.loadHTMLString("<!doctype html><html><head><meta charset=\"utf-8\"><link rel=\"stylesheet\" href=\"gaomd://bundle/vendor/katex.min.css\"><link rel=\"stylesheet\" href=\"gaomd://bundle/markdown.css\"></head><body>" + html + "</body></html>", baseURL: nil)
        }
    }
    func check() {
        let script = """
        (() => {
          const before=window.gaoMarkdown.getDocument();
          const initialMermaid=!!document.querySelector('.mermaid svg');
          const initialImage=document.querySelector('img')?.naturalWidth>0;
          const mermaidError=document.querySelector('.mermaid-error')?.title||'';
          window.gaoMarkdown.setMode('split');window.gaoMarkdown.setMode('source');window.gaoMarkdown.setMode('live');
          const after=window.gaoMarkdown.getDocument();
          const image=document.querySelector('img');
          const result={same:before===after,math:!!document.querySelector('.katex'),mermaid:initialMermaid,mermaidError,table:!!document.querySelector('table'),footnote:!!document.querySelector('.footnote'),outline:document.querySelectorAll('#outline-items button').length,image:initialImage,remote:!!document.querySelector('.image-placeholder'),unsafe:!!window.UNSAFE};
          const blocks=window.GaoMDCore.blocks(after), heading=blocks.findIndex(b=>b.type==='heading');
          const edited=window.gaoMarkdown.testEditBlock(heading,'# 已编辑\\r\\n\\r\\n');
          result.edited=edited.includes('# 已编辑\\r\\n')&&edited.includes('unknown: must-survive')&&edited.includes('<custom-widget data-private="keep">未知对象</custom-widget>');
          return result;
        })()
        """
        view.evaluateJavaScript(script) { [weak self] value, error in
            guard let self else { return }
            guard error == nil, let result = value as? [String: Any] else { self.fail("JS result: " + (error?.localizedDescription ?? "nil")); return }
            print(result)
            for key in ["same", "math", "mermaid", "table", "footnote", "image", "remote", "edited"] { if result[key] as? Bool != true { self.fail("failed " + key); return } }
            guard result["unsafe"] as? Bool == false, result["outline"] as? Int == 1 else { self.fail("sanitization or outline failed"); return }
            self.view.evaluateJavaScript("window.gaoMarkdown.requestExport('html')") { _, error in if let error { self.fail(error.localizedDescription) } }
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error.localizedDescription) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === printView else { return }
        webView.callAsyncJavaScript("await document.fonts.ready; return true;", arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            let target = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gao-md-pdf-" + UUID().uuidString + ".pdf")
            let info = NSPrintInfo(); info.paperSize = NSSize(width: 595.28, height: 841.89); info.topMargin = 42; info.bottomMargin = 42; info.leftMargin = 38; info.rightMargin = 38; info.horizontalPagination = .fit; info.verticalPagination = .automatic; info.jobDisposition = .save; info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = target
            let operation = webView.printOperation(with: info); operation.showsPrintPanel = false; operation.showsProgressPanel = false; operation.canSpawnSeparateThread = true
            self.pdfTarget = target; self.printOperation = operation
            operation.runModal(for: self.printWindow!, delegate: self, didRun: #selector(self.pdfDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
    }
    @objc func pdfDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard success, let target = pdfTarget, let pdf = PDFDocument(url: target), pdf.pageCount >= 1, pdf.pageCount < 20, let page = pdf.page(at: 0), page.bounds(for: .mediaBox).height > 800 else { fail("native paginated PDF export failed"); return }
        finished = true
        print("PASS: real WKWebView offline load, local images, blocked remote resources, math, Mermaid, sanitization, exact source/mode roundtrip, block editing, HTML export, and native A4 PDF export (\(pdf.pageCount) pages).")
        NSApplication.shared.terminate(nil)
    }
    func fail(_ message: String) { finished = true; fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
struct MarkdownSmokeMain {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let test = MarkdownWebSmoke(); test.start(); app.run()
    }
}
