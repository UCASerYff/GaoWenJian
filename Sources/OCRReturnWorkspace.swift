import AppKit
import SwiftUI
import UniformTypeIdentifiers

private actor OCRReturnScanWorker {
    private let cache = OCRReturnMailbox.Cache()

    func scan(exchangeRoot: URL, mailboxRoot: URL) throws -> OCRReturnScan {
        try OCRReturnMailbox.scan(exchangeRoot: exchangeRoot, mailboxRoot: mailboxRoot, cache: cache)
    }
}

@MainActor final class OCRReturnCenter: ObservableObject {
    static let mailboxChanged = Notification.Name("GaoWenJian.ocrMailboxChanged")
    @Published private(set) var results: [OCRReturnCandidate] = []
    @Published private(set) var waiting = false
    @Published private(set) var hasIssues = false

    private let worker = OCRReturnScanWorker()
    private var monitor: Task<Void, Never>?
    private(set) var visible = false

    static func mailboxDidChange() {
        NotificationCenter.default.post(name: mailboxChanged, object: nil)
    }

    func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        if visible { refresh() }
        else { monitor?.cancel(); monitor = nil }
    }

    func refresh() {
        guard visible else { return }
        monitor?.cancel()
        let exchange = GaoHandoffService.exchangeRoot, mailbox = GaoHandoffService.ocrMailboxRoot
        let worker = self.worker
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let scan = try await worker.scan(exchangeRoot: exchange, mailboxRoot: mailbox)
                    guard !Task.isCancelled, let self, self.visible else { return }
                    self.results = scan.results
                    self.waiting = scan.pending
                    self.hasIssues = !scan.issues.isEmpty
                    guard scan.pending else { return }
                } catch {
                    guard !Task.isCancelled, let self, self.visible else { return }
                    self.results = []
                    self.waiting = false
                    self.hasIssues = true
                    return
                }
                do { try await Task.sleep(nanoseconds: 4_000_000_000) }
                catch { return }
            }
        }
    }

    var current: [OCRReturnCandidate] { results.filter { $0.expiresAt > Date() } }

    func matching(_ url: URL?) -> [OCRReturnCandidate] {
        guard let original = url?.standardizedFileURL else { return [] }
        return current.filter { result in
            result.sources.contains { $0.originalURL?.standardizedFileURL == original }
        }
    }
}

@MainActor struct OCRReturnWindowProbe: NSViewRepresentable {
    let visibility: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> Probe { Probe(visibility: visibility) }
    func updateNSView(_ view: Probe, context: Context) { view.visibility = visibility }

    final class Probe: NSView {
        var visibility: @MainActor (Bool) -> Void
        private var closing = false

        init(visibility: @escaping @MainActor (Bool) -> Void) {
            self.visibility = visibility
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { return nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let notifications = NotificationCenter.default
            notifications.removeObserver(self)
            closing = false
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification,
                             NSWindow.willCloseNotification] {
                    notifications.addObserver(self, selector: #selector(visibilityChanged(_:)), name: name, object: window)
                }
                for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                             NSApplication.didBecomeActiveNotification] {
                    notifications.addObserver(self, selector: #selector(visibilityChanged(_:)), name: name, object: NSApp)
                }
            }
            reportVisibility()
        }

        @objc private func visibilityChanged(_ notification: Notification) {
            if notification.name == NSWindow.willCloseNotification { closing = true }
            reportVisibility()
        }

        private func reportVisibility() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let visible = self.window.map {
                    $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
                } ?? false
                self.visibility(visible && !self.closing && NSApp?.isHidden != true)
            }
        }
    }
}

struct OCRReturnDocumentNotice: View {
    let count: Int
    let review: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("此文档有 \(count) 项 OCR 结果待审核", systemImage: "text.viewfinder")
                .font(.callout)
            Spacer()
            Button(count == 1 ? "审核结果" : "查看待审核", action: review)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(WorkspaceStyle.accent.opacity(0.11))
    }
}

@MainActor struct OCRReturnInbox: View {
    @ObservedObject var center: OCRReturnCenter
    @ObservedObject var store: WorkspaceStore
    @Binding var review: OCRReturnCandidate?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(review == nil ? "OCR 与交接" : "审核 OCR 回传").font(.title2.weight(.semibold))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let review { detail(review) }
            else { inbox }
        }
        .padding(22)
        .frame(minWidth: 540, idealWidth: 580, minHeight: 340, idealHeight: 440)
        .onAppear { center.refresh() }
    }

    private var inbox: some View {
        VStack(alignment: .leading, spacing: 12) {
            if center.waiting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("等待搞操作回传").foregroundStyle(.secondary)
                }
            }
            if center.hasIssues {
                Text("部分回传无法核验，可从搞操作手工导出后接收。")
                    .font(.callout).foregroundStyle(.orange)
            }
            if center.current.isEmpty {
                ContentUnavailableView("没有待审核的 OCR 回传", systemImage: "text.viewfinder",
                    description: Text("结果匹配本机请求后会显示在这里。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(center.current) { candidate in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(candidate.sources.map { HandoffNames.display($0.displayName) }.joined(separator: "、"))
                                        .font(.headline).lineLimit(2)
                                    Text("\(candidate.sources.reduce(0) { $0 + $1.pages.count }) 页 · \(status(candidate.status))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("审核…") { review = candidate }
                            }
                            .padding(10)
                            .background(WorkspaceStyle.line.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("选择交接包…") { choosePackage() }
                Spacer()
                Button("重新检查") { center.refresh() }
            }
        }
    }

    private func detail(_ candidate: OCRReturnCandidate) -> some View {
        let stillCurrent = center.current.contains { $0.id == candidate.id && $0.manifestSHA256 == candidate.manifestSHA256 }
        return VStack(alignment: .leading, spacing: 12) {
            Text("搞操作 · \(status(candidate.status))").foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(candidate.sources, id: \.itemID) { source in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(HandoffNames.display(source.displayName)).font(.headline)
                            Text("原件 SHA-256 \(source.sha256)").font(.caption.monospaced()).textSelection(.enabled)
                            ForEach(source.pages, id: \.pageNumber) { page in
                                Text("第 \(page.pageNumber) 页 · \(status(page.status))").font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Text(stillCurrent ? "接收后会打开独立副本。已有文档和草稿保留。" : "回传已变更或过期，请重新检查或手工接收结果包。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("返回待审核") { review = nil }
                Spacer()
                Button("接收结果副本") {
                    guard stillCurrent, !store.handoffBusy else { return }
                    dismiss()
                    GaoHandoffService.acceptOCRReturn(candidate, store: store)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!stillCurrent || store.handoffBusy)
            }
        }
    }

    private func status(_ status: String?) -> String {
        switch status {
        case "completed": return "已完成"
        case "partial": return "部分完成"
        case "failed": return "失败"
        case "pending": return "待处理"
        case "cancelled": return "已取消"
        default: return "未声明"
        }
    }

    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.title = "选择交接包"
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        if let type = UTType(filenameExtension: "gaoaction") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if OCRReturnMailbox.isMailboxURL(url, mailboxRoot: GaoHandoffService.ocrMailboxRoot) {
            center.refresh()
        } else {
            dismiss()
            _ = GaoHandoffService.handleIncoming(url: url, store: store)
        }
    }
}
