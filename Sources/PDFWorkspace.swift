import AppKit
import SwiftUI
import PDFKit
import UniformTypeIdentifiers

final class GaoPDFView: PDFView {
    var placement: ((PDFPage, NSPoint) -> Void)?
    var onFormInteraction: (() -> Void)?
    var onAnnotationDoubleClick: ((PDFAnnotation) -> Void)?
    var formsEditable = true
    var onInitialLayout: ((CGFloat) -> Void)?
    private var completedInitialLayout = false
    private var initialLayoutScheduled = false

    override func layout() {
        super.layout()
        scheduleInitialFit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleInitialFit()
    }

    private func scheduleInitialFit() {
        guard !completedInitialLayout, !initialLayoutScheduled, window != nil,
              bounds.width > 100, bounds.height > 100, document?.pageCount ?? 0 > 0 else { return }
        initialLayoutScheduled = true
        // PDFKit first receives a zero-sized representable. Wait until AppKit has
        // finished assigning the workspace bounds before computing the initial fit.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.initialLayoutScheduled = false
            guard !self.completedInitialLayout, self.window != nil,
                  self.bounds.width > 100, self.bounds.height > 100,
                  let firstPage = self.document?.page(at: 0) else { return }
            self.completedInitialLayout = true
            if self.autoScales {
                self.layoutDocumentView()
                let fit = self.scaleFactorForSizeToFit
                if fit.isFinite && fit > 0 {
                    self.scaleFactor = min(self.maxScaleFactor, max(self.minScaleFactor, fit))
                }
                self.autoScales = true
            }
            self.go(to: firstPage)
            self.onInitialLayout?(self.scaleFactor)
        }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let placement, let page = page(for: point, nearest: false) {
            placement(page, convert(point, to: page))
            return
        }
        if event.clickCount == 2, let page = page(for: point, nearest: false),
           let annotation = page.annotation(at: convert(point, to: page)),
           annotation.type == "FreeText" || annotation.type == "Text" || PDFAnnotationEntry(annotation: annotation, pageIndex: 0).isImage {
            onAnnotationDoubleClick?(annotation)
            return
        }
        if let page = page(for: point, nearest: false),
           page.annotation(at: convert(point, to: page))?.type == "Widget" {
            guard formsEditable else { return }
            onFormInteraction?()
        }
        super.mouseDown(with: event)
    }
}

struct PDFCanvas: NSViewRepresentable {
    @ObservedObject var model: PDFWorkspaceModel
    let twoUp: Bool
    let placement: ((PDFPage, NSPoint) -> Void)?
    let onAnnotationDoubleClick: (PDFAnnotation) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> GaoPDFView {
        let view = GaoPDFView()
        view.document = model.document
        view.backgroundColor = NSColor.windowBackgroundColor
        view.displayDirection = .vertical
        view.displayMode = twoUp ? .twoUpContinuous : .singlePageContinuous
        view.displaysPageBreaks = true
        view.minScaleFactor = 0.15
        view.maxScaleFactor = 5
        // Setting either scale limit disables PDFKit's autoScales.
        view.autoScales = true
        view.enableDataDetectors = false
        model.pdfView = view
        view.placement = placement
        view.onAnnotationDoubleClick = onAnnotationDoubleClick
        view.onFormInteraction = { [weak model] in model?.formInteractionWillBegin() }
        view.formsEditable = model.permitsForms
        view.onInitialLayout = { [weak model] scale in
            model?.zoom = scale
            model?.currentPage = 1
        }
        context.coordinator.observe(view)
        return view
    }
    func updateNSView(_ view: GaoPDFView, context: Context) {
        if view.document !== model.document { view.document = model.document }
        let desired: PDFDisplayMode = twoUp ? .twoUpContinuous : .singlePageContinuous
        if view.displayMode != desired {
            let wasAutomatic = view.autoScales
            let previousScale = view.scaleFactor
            view.displayMode = desired
            view.autoScales = wasAutomatic
            if !wasAutomatic { view.scaleFactor = previousScale }
        }
        view.placement = placement
        view.onAnnotationDoubleClick = onAnnotationDoubleClick
        view.onFormInteraction = { [weak model] in model?.formInteractionWillBegin() }
        view.formsEditable = model.permitsForms
        model.pdfView = view
    }
    static func dismantleNSView(_ view: GaoPDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
        view.placement = nil
        view.onFormInteraction = nil
        view.onAnnotationDoubleClick = nil
        view.onInitialLayout = nil
    }
    @MainActor final class Coordinator {
        let model: PDFWorkspaceModel
        var tokens: [NSObjectProtocol] = []
        private var formTimer: Timer?
        init(model: PDFWorkspaceModel) { self.model = model }
        func observe(_ view: PDFView) {
            // PDFKit exposes hit notifications, not widget-value-change events.
            // Observe real values without interrupting the active field editor.
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.model.formMayHaveChanged() }
            }
            formTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            for name in [NSText.didChangeNotification, NSText.didEndEditingNotification,
                         NSControl.textDidChangeNotification, NSControl.textDidEndEditingNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak view] note in
                    // NSWindow's shared field editor may sit outside the PDF's
                    // view subtree. Its public delegate identifies the owning
                    // control; do not observe another editor in the same window.
                    guard let view else { return }
                    let objectView = note.object as? NSView
                    let editor = note.object as? NSTextView
                    let owner = editor?.delegate as? NSView
                    let belongs = objectView?.isDescendant(of: view) == true ||
                        (editor?.window === view.window && owner?.isDescendant(of: view) == true)
                    guard belongs else { return }
                    let ended = name == NSText.didEndEditingNotification || name == NSControl.textDidEndEditingNotification
                    Task { @MainActor in self?.model.formMayHaveChanged(endingEditing: ended) }
                })
            }
            tokens.append(NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
                Task { @MainActor in
                    guard let self, let page = view?.currentPage, let document = self.model.document else { return }
                    self.model.currentPage = document.index(for: page) + 1
                }
            })
            tokens.append(NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self, weak view] _ in
                Task { @MainActor in guard let view else { return }; self?.model.zoom = view.scaleFactor }
            })
            tokens.append(NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self, weak view] _ in
                Task { @MainActor in self?.model.hasSelection = !(view?.currentSelection?.string ?? "").isEmpty }
            })
        }
        func stopObserving() {
            formTimer?.invalidate(); formTimer = nil
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens.removeAll()
        }
    }
}

struct PDFThumbnails: NSViewRepresentable {
    @ObservedObject var model: PDFWorkspaceModel
    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.thumbnailSize = NSSize(width: 110, height: 146)
        view.backgroundColor = .controlBackgroundColor
        view.pdfView = model.pdfView
        return view
    }
    func updateNSView(_ view: PDFThumbnailView, context: Context) {
        if view.pdfView !== model.pdfView { view.pdfView = model.pdfView }
        view.needsDisplay = true
    }
}

struct PDFWorkspace: View {
    let url: URL
    let onSaved: () -> Void
    let onError: (String) -> Void
    @StateObject private var model: PDFWorkspaceModel
    @State private var showThumbnails = true
    @State private var showInspector = false
    @State private var inspectorTab = 0
    @State private var twoUp = false
    @State private var search = ""
    @State private var pageInput = "1"
    @State private var password = ""
    @State private var textFontSize: Double = 14
    @State private var textColor = Color.black
    @State private var objectSheet: PDFObjectSheetDraft?
    @State private var placementText: String?
    @State private var pendingNote = true
    @State private var imageToAdd: PDFImageAsset?
    @State private var imageWidth: Double = 180
    @State private var placingImage = false
    @State private var movingAnnotation: PDFAnnotationEntry?
    @State private var showExtractSheet = false
    @State private var showCropSheet = false
    @State private var cropTop = "0"
    @State private var cropLeft = "0"
    @State private var cropBottom = "0"
    @State private var cropRight = "0"
    @State private var pageRange = ""
    @State private var showDeleteConfirmation = false
    @State private var showSignatureConfirmation = false

    static let saveRequested = Notification.Name("GaoWenJian.saveActive")

    init(url: URL, onSaved: @escaping () -> Void, onError: @escaping (String) -> Void) {
        self.url = url
        self.onSaved = onSaved
        self.onError = onError
        _model = StateObject(wrappedValue: PDFWorkspaceModel(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.loadError {
                ContentUnavailableView("无法打开 PDF", systemImage: "exclamationmark.document", description: Text(error))
            } else if model.document?.isLocked == true {
                lockedView
            } else {
                readingToolbar
                Divider()
                editingToolbar
                Divider()
                HSplitView {
                    if showThumbnails {
                        VStack(spacing: 0) {
                            Text("页面").font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(8)
                            PDFThumbnails(model: model)
                        }.frame(minWidth: 100, idealWidth: 140, maxWidth: 220)
                    }
                    PDFCanvas(model: model, twoUp: twoUp, placement: placementHandler, onAnnotationDoubleClick: editAnnotation)
                        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                    if showInspector { inspector.frame(minWidth: 230, idealWidth: 270, maxWidth: 350) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                Divider()
                statusBar
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.currentPage) { _, page in pageInput = String(page) }
        .onReceive(NotificationCenter.default.publisher(for: Self.saveRequested)) { notification in
            if notification.object as? String == url.path { requestSave(asNew: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoWenJian.discardDraft"))) { notification in
            if notification.object as? String == url.path { model.discardDraft() }
        }
        .onAppear {
            CurrentDocumentHandoffRegistry.shared.register(model)
            model.publishDirty()
        }
        .onDisappear { CurrentDocumentHandoffRegistry.shared.unregister(model) }
        .sheet(item: $objectSheet) { draft in
            PDFObjectSheet(draft: draft, onCancel: { objectSheet = nil }, onApply: { applyObjectSheet(draft) })
        }
        .sheet(isPresented: $showExtractSheet) { extractSheet }
        .sheet(isPresented: $showCropSheet) { cropSheet }
        .onExitCommand { clearPlacement() }
        .confirmationDialog("删除第 \(model.currentPage) 页？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("删除页面", role: .destructive) { perform { try model.deleteCurrentPage() } }
            Button("取消", role: .cancel) { }
        } message: { Text("可通过 PDF 工具栏撤销。保存时会先保留原文件快照。") }
        .alert("修改将影响已有数字签名", isPresented: $showSignatureConfirmation) {
            Button("另存副本") { performSave(asNew: true) }
            Button("取消", role: .cancel) { }
        } message: { Text("此 PDF 含签名字段。编辑后已有数字签名可能失效，请另存副本保留原件。") }
    }

    private var lockedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.doc").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("输入 PDF 密码").font(.title2.weight(.semibold))
            SecureField("密码", text: $password).textFieldStyle(.roundedBorder).frame(width: 260)
                .onSubmit { perform { try model.unlock(password: password) }; password = "" }
            Button("解锁阅读") { perform { try model.unlock(password: password) }; password = "" }.buttonStyle(.borderedProminent)
            Text("加密文件在此版本中只读，以保留原有加密设置。").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readingToolbar: some View {
        HStack(spacing: 10) {
            Button { showThumbnails.toggle() } label: { Image(systemName: "sidebar.left") }.help("显示或隐藏缩略图")
            Button { model.go(to: model.currentPage - 1) } label: { Image(systemName: "chevron.left") }.disabled(model.currentPage <= 1)
            HStack(spacing: 3) {
                TextField("页", text: $pageInput).textFieldStyle(.roundedBorder).frame(width: 44)
                    .multilineTextAlignment(.center).onSubmit {
                        if let page = Int(pageInput), page >= 1, page <= model.pageCount { model.go(to: page) }
                        else { pageInput = String(model.currentPage) }
                    }
                Text("/ \(model.pageCount)").foregroundStyle(.secondary).monospacedDigit()
            }
            Button { model.go(to: model.currentPage + 1) } label: { Image(systemName: "chevron.right") }.disabled(model.currentPage >= model.pageCount)
            Divider().frame(height: 18)
            Button { changeZoom(by: 1 / 1.2) } label: { Image(systemName: "minus.magnifyingglass") }.help("缩小")
            Text("\(Int(model.zoom * 100))%").font(.caption).monospacedDigit().frame(width: 42)
            Button { changeZoom(by: 1.2) } label: { Image(systemName: "plus.magnifyingglass") }.help("放大")
            Button("适合") { model.pdfView?.autoScales = true }.help("适合窗口")
            Toggle(isOn: $twoUp) { Image(systemName: "book.pages") }.toggleStyle(.button).help("双页阅读")
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索 PDF 文字", text: $search).textFieldStyle(.plain).onSubmit { model.find(search) }
                if !search.isEmpty { Button { search = ""; model.find("") } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }.padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 6)).frame(minWidth: 130, idealWidth: 190, maxWidth: 240)
            if !model.searchResults.isEmpty {
                Button { model.showSearchResult(model.searchResultIndex - 1) } label: { Image(systemName: "chevron.up") }.help("上一个搜索结果")
                Button { model.showSearchResult(model.searchResultIndex + 1) } label: { Image(systemName: "chevron.down") }.help("下一个搜索结果")
            }
            Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("批注、表单与目录")
            Button { if let s = AppHub.store { OCRHandoffDispatcher.startOCR(for: url, store: s) } } label: { Label("识别扫描件", systemImage: "doc.text.viewfinder") }.help("使用搞截图识别文档文字 (OCR)")
        }.buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var editingToolbar: some View {
        HStack(spacing: 12) {
            Button { openTextSheet(note: false) } label: { Label("插入文字", systemImage: "textformat") }.disabled(!model.permitsAnnotations)
            Button { chooseImage() } label: { Label("插入图片", systemImage: "photo.badge.plus") }.disabled(!model.permitsAnnotations)
            Menu {
                Button("高亮选中文字") { perform { try model.markupSelection(type: .highlight) } }.disabled(!model.hasSelection)
                Button("下划线") { perform { try model.markupSelection(type: .underline) } }.disabled(!model.hasSelection)
                Button("删除线") { perform { try model.markupSelection(type: .strikeOut) } }.disabled(!model.hasSelection)
                Divider()
                Button("添加便签…") { openTextSheet(note: true) }
                Button("对象与批注") { showInspector = true; inspectorTab = 0 }
            } label: { Label("批注", systemImage: "highlighter") }.disabled(!model.permitsAnnotations)
            Menu {
                Button("顺时针旋转当前页") { perform { try model.rotateCurrentPage() } }
                Button("裁剪当前页可见区域…") { cropTop = "0"; cropLeft = "0"; cropBottom = "0"; cropRight = "0"; showCropSheet = true }
                Button("当前页前移") { perform { try model.moveCurrentPage(by: -1) } }.disabled(model.currentPage <= 1)
                Button("当前页后移") { perform { try model.moveCurrentPage(by: 1) } }.disabled(model.currentPage >= model.pageCount)
                Divider()
                Button("删除当前页…", role: .destructive) { showDeleteConfirmation = true }.disabled(model.pageCount <= 1)
                Button("追加 PDF 合并…") { merge() }
                Divider()
                Button("提取指定页面…") { pageRange = String(model.currentPage); showExtractSheet = true }
                Button("每页拆分为独立 PDF…") { split() }
            } label: { Label("页面", systemImage: "square.3.layers.3d") }.disabled(!model.permitsAssembly)
            Button { clearPlacement(); perform { try model.undo() } } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo).help("撤销 PDF 修改")
            Button { clearPlacement(); perform { try model.redo() } } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.canRedo).help("重做 PDF 修改")
            if placementText != nil || placingImage || movingAnnotation != nil {
                Text(movingAnnotation != nil ? "点击本页新位置" : "点击页面放置\(placingImage ? "图片" : (pendingNote ? "便签" : "文字"))").font(.caption).foregroundStyle(.orange).lineLimit(1)
                Button("取消") { clearPlacement() }
            } else {
                Text(model.document?.isEncrypted == true ? "加密 PDF · 只读" : "双击插入的文字或图片可编辑").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if model.recoveryConflict { Button("另存恢复副本…") { exportRecovery() } }
            Spacer(minLength: 0)
            Button("另存为…") { requestSave(asNew: true) }.disabled(model.document?.isEncrypted == true)
            Button { requestSave(asNew: false) } label: { Label(model.dirty ? "保存 PDF •" : "保存 PDF", systemImage: "square.and.arrow.down") }
                .disabled(model.document?.isEncrypted == true)
        }.buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle().fill(model.dirty ? Color.orange : Color.green).frame(width: 6, height: 6)
            Text(model.status).lineLimit(1)
            Spacer()
            Text("原文重排与扫描文字识别暂不提供").foregroundStyle(.secondary).lineLimit(1)
        }.font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("信息", selection: $inspectorTab) {
                Text("对象").tag(0)
                Text("表单").tag(1)
                Text("目录").tag(2)
            }.pickerStyle(.segmented).padding(10)
            Divider()
            if inspectorTab == 0 { annotationList }
            else if inspectorTab == 1 { formList }
            else { outlineList }
        }.background(Color(nsColor: .controlBackgroundColor))
    }

    private var annotationList: some View {
        Group {
            if model.annotationEntries.isEmpty {
                ContentUnavailableView("暂无对象与批注", systemImage: "square.on.square", description: Text("插入文字、图片，或选中文字后添加高亮。"))
            } else {
                List(model.annotationEntries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.title).font(.caption.weight(.semibold))
                            Spacer()
                            Text("第 \(entry.pageIndex + 1) 页").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(entry.annotation.contents ?? "无文字内容").font(.caption).lineLimit(4).foregroundStyle(.secondary)
                        HStack {
                            Button("定位") { model.go(to: entry.pageIndex + 1) }
                            if entry.annotation.type == "Text" || entry.annotation.type == "FreeText" {
                                Button("编辑") { editAnnotation(entry.annotation) }.disabled(!model.permitsAnnotations)
                            }
                            if entry.canPosition {
                                Button("移动") { clearPlacement(); movingAnnotation = entry; model.go(to: entry.pageIndex + 1) }.disabled(!model.permitsAnnotations)
                                Button("尺寸") { openGeometry(entry) }.disabled(!model.permitsAnnotations)
                            }
                            Spacer()
                            Button { clearPlacement(); perform { try model.removeAnnotation(entry) } } label: { Image(systemName: "trash") }.disabled(!model.permitsAnnotations).help("删除对象或批注")
                        }.font(.caption).buttonStyle(.borderless)
                    }.padding(.vertical, 5)
                }.listStyle(.plain)
            }
        }
    }

    private var formList: some View {
        Group {
            if model.formEntries.isEmpty {
                ContentUnavailableView("无交互表单", systemImage: "rectangle.and.pencil.and.ellipsis", description: Text("普通扫描表格可使用“添加文字”填写。"))
            } else {
                List(model.formEntries) { entry in
                    PDFFormRow(entry: entry, model: model, onError: onError)
                }.listStyle(.plain)
            }
        }
    }

    private var outlineList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let root = model.document?.outlineRoot, root.numberOfChildren > 0 {
                    ForEach(0..<root.numberOfChildren, id: \.self) { index in
                        if let child = root.child(at: index) { PDFOutlineRow(outline: child, model: model, depth: 0) }
                    }
                } else {
                    ContentUnavailableView("没有目录", systemImage: "list.bullet.indent", description: Text("此 PDF 未包含目录书签。"))
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private var extractSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("提取页面").font(.title3.weight(.semibold))
            Text("填写页码或范围，例如 1,3-5。共 \(model.pageCount) 页。").font(.caption).foregroundStyle(.secondary)
            TextField("页码", text: $pageRange).textFieldStyle(.roundedBorder).frame(width: 340)
            HStack {
                Button("取消") { showExtractSheet = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("导出 PDF…") {
                    perform {
                        let pages = try PDFWorkspaceModel.parsePages(pageRange, count: model.pageCount)
                        let output = try model.extractedDocument(pages: pages)
                        showExtractSheet = false
                        if let target = saveURL(name: "\(url.deletingPathExtension().lastPathComponent)-提取.pdf") {
                            if target.standardizedFileURL == url.standardizedFileURL { throw PDFWorkspaceError.message("提取结果请另存到新文件，避免覆盖正在编辑的原件。") }
                            try model.export(output, to: target)
                            onSaved()
                        }
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(22)
    }

    private var cropSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("裁剪第 \(model.currentPage) 页").font(.title3.weight(.semibold))
            Text("输入各边缩进距离，单位为点（1 点 = 1/72 英寸）。").font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow { Text("上"); TextField("0", text: $cropTop); Text("下"); TextField("0", text: $cropBottom) }
                GridRow { Text("左"); TextField("0", text: $cropLeft); Text("右"); TextField("0", text: $cropRight) }
            }.textFieldStyle(.roundedBorder).frame(width: 340)
            Text("裁剪只改变可见区域，页面区域外的原内容仍保留。此操作不用于删除敏感内容。").font(.caption).foregroundStyle(.secondary).frame(width: 340, alignment: .leading)
            HStack {
                Button("取消") { showCropSheet = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("应用裁剪") {
                    perform {
                        guard let top = Double(cropTop), let left = Double(cropLeft), let bottom = Double(cropBottom), let right = Double(cropRight),
                              top.isFinite, left.isFinite, bottom.isFinite, right.isFinite else {
                            throw PDFWorkspaceError.message("请填写有效的裁剪距离。")
                        }
                        try model.cropCurrentPage(top: top, left: left, bottom: bottom, right: right)
                        showCropSheet = false
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(22)
    }

    private var placementHandler: ((PDFPage, NSPoint) -> Void)? {
        if let entry = movingAnnotation {
            return { page, point in perform { try model.repositionAnnotation(entry, page: page, at: point); clearPlacement() } }
        }
        if placingImage, let asset = imageToAdd {
            return { page, point in
                perform { try model.addImage(asset, page: page, at: point, width: imageWidth); clearPlacement(); showInspector = true; inspectorTab = 0 }
            }
        }
        if let text = placementText {
            return { page, point in
                perform { try model.addText(text, note: pendingNote, page: page, at: point, fontSize: CGFloat(textFontSize), color: NSColor(textColor)); clearPlacement() }
            }
        }
        return nil
    }

    private func clearPlacement() { placementText = nil; placingImage = false; imageToAdd = nil; movingAnnotation = nil }
    private func openTextSheet(note: Bool) {
        clearPlacement()
        objectSheet = PDFObjectSheetDraft(kind: .text, note: note, fontSize: textFontSize, color: textColor)
    }
    private func chooseImage() {
        clearPlacement()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要嵌入当前 PDF 的图片。"
        if panel.runModal() == .OK, let selected = panel.url {
            perform {
                let asset = try PDFImageAsset(url: selected)
                objectSheet = PDFObjectSheetDraft(kind: .image, asset: asset)
            }
        }
    }
    private func editAnnotation(_ annotation: PDFAnnotation) {
        guard model.permitsAnnotations, let entry = model.annotationEntries.first(where: { $0.annotation === annotation }) else { return }
        clearPlacement()
        if entry.isImage { openGeometry(entry); return }
        objectSheet = PDFObjectSheetDraft(kind: .annotation, entry: entry,
            fontSize: Double(annotation.font?.pointSize ?? 14), color: Color(nsColor: annotation.fontColor ?? .black))
    }
    private func openGeometry(_ entry: PDFAnnotationEntry) {
        guard entry.annotation.page != nil else { return }
        clearPlacement()
        objectSheet = PDFObjectSheetDraft(kind: .geometry, entry: entry)
    }
    private func applyObjectSheet(_ draft: PDFObjectSheetDraft) {
        perform {
            switch draft.kind {
            case .text:
                placementText = draft.text
                pendingNote = draft.note
                textFontSize = draft.fontSize
                textColor = draft.color
            case .image:
                guard let asset = draft.asset else { throw PDFWorkspaceError.message("图片未载入，请重新选择。") }
                imageToAdd = asset
                imageWidth = draft.imageWidth
                placingImage = true
            case .annotation:
                guard let entry = draft.entry else { return }
                try model.updateAnnotation(entry, contents: draft.text, fontSize: draft.fontSize, color: NSColor(draft.color))
            case .geometry:
                guard let entry = draft.entry, let width = Double(draft.width),
                      let height = entry.isImage ? Double(draft.width).map({ $0 * draft.aspect }) : Double(draft.height) else {
                    throw PDFWorkspaceError.message("请输入有效的宽度和高度。")
                }
                try model.resizeAnnotation(entry, displayWidth: width, displayHeight: height)
            }
            objectSheet = nil
        }
    }
    private func changeZoom(by factor: CGFloat) {
        guard let view = model.pdfView else { return }
        view.autoScales = false
        view.scaleFactor = min(view.maxScaleFactor, max(view.minScaleFactor, view.scaleFactor * factor))
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { onError(error.localizedDescription) }
    }
    private func requestSave(asNew: Bool) {
        if model.containsSignatures { showSignatureConfirmation = true }
        else { performSave(asNew: asNew) }
    }
    private func performSave(asNew: Bool) {
        perform {
            if asNew {
                guard let target = saveURL(name: "\(url.deletingPathExtension().lastPathComponent)-副本.pdf") else { return }
                _ = try model.save(to: target)
            } else { _ = try model.save() }
            onSaved()
        }
    }
    private func saveURL(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = name
        panel.directoryURL = url.deletingLastPathComponent()
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func merge() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "所选 PDF 的页面将追加到当前文档末尾。原有书签保留在各自原件中。"
        if panel.runModal() == .OK { perform { try model.appendPDFs(panel.urls) } }
    }
    private func exportRecovery() {
        perform {
            let recovered = try model.recoveredDocumentForExport()
            guard let target = saveURL(name: "\(url.deletingPathExtension().lastPathComponent)-恢复副本.pdf") else { return }
            guard target.standardizedFileURL != url.standardizedFileURL else {
                throw PDFWorkspaceError.message("恢复副本请另存新文件，以保留原文件的外部修改。")
            }
            try model.export(recovered, to: target)
            onSaved()
        }
    }
    private func split() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "选择拆分文件的保存位置。会新建独立文件夹保留现有文件。"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        perform {
            let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
            let outputFolder = folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-拆分-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4))", isDirectory: true)
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: false)
            for index in 0..<model.pageCount {
                let single = try model.extractedDocument(pages: [index])
                try model.export(single, to: outputFolder.appendingPathComponent(String(format: "第%03d页.pdf", index + 1)))
            }
            model.status = "已拆分 \(model.pageCount) 页到 \(outputFolder.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([outputFolder])
            onSaved()
        }
    }
}

/// The sheet item carries both its purpose and initial data. Keeping editable
/// fields in an observed draft avoids capturing a previous parent-view value on
/// the first presentation (for example nil image or the previous note mode).
@MainActor private final class PDFObjectSheetDraft: ObservableObject, Identifiable {
    enum Kind { case text, image, annotation, geometry }
    let id = UUID()
    let kind: Kind
    let note: Bool
    let asset: PDFImageAsset?
    let entry: PDFAnnotationEntry?
    let aspect: Double
    @Published var text: String
    @Published var fontSize: Double
    @Published var color: Color
    @Published var imageWidth: Double
    @Published var width: String
    @Published var height: String

    init(kind: Kind, note: Bool = false, asset: PDFImageAsset? = nil, entry: PDFAnnotationEntry? = nil,
         fontSize: Double = 14, color: Color = .black) {
        self.kind = kind; self.note = note; self.asset = asset; self.entry = entry
        self.fontSize = fontSize; self.color = color
        text = entry?.annotation.contents ?? ""
        imageWidth = min(240, asset?.image.size.width ?? 180)
        let size: NSSize
        if let entry, let page = entry.annotation.page {
            size = PDFWorkspaceModel.displaySize(of: entry.annotation.bounds, on: page)
        } else { size = .zero }
        width = String(format: "%.1f", size.width)
        height = String(format: "%.1f", size.height)
        aspect = size.height / max(1, size.width)
    }

    var title: String {
        switch kind {
        case .text: return note ? "添加便签" : "插入文字"
        case .image: return "插入图片"
        case .annotation: return "编辑批注"
        case .geometry: return "调整对象尺寸"
        }
    }
    var canApply: Bool {
        let validFont = fontSize.isFinite && fontSize >= 6 && fontSize <= 144
        switch kind {
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (note || validFont)
        case .image: return asset != nil && imageWidth.isFinite && imageWidth >= 4 && imageWidth <= 10_000
        case .annotation: return entry != nil && (entry?.annotation.type != "FreeText" || validFont)
        case .geometry: return entry != nil
        }
    }
}

@MainActor private struct PDFObjectSheet: View {
    @ObservedObject var draft: PDFObjectSheetDraft
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.title).font(.title3.weight(.semibold))
            switch draft.kind {
            case .text, .annotation: textFields
            case .image: imageFields
            case .geometry: geometryFields
            }
            HStack {
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(draft.kind == .text || draft.kind == .image ? "选择位置" : "应用", action: onApply)
                    .keyboardShortcut(.defaultAction).disabled(!draft.canApply)
            }
        }.padding(22)
    }

    private var textFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            if draft.kind == .text {
                Text("输入内容后，点击 PDF 页面选择位置。").font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $draft.text).font(.system(size: 14)).frame(width: 400, height: 140).border(Color.secondary.opacity(0.25))
            if (draft.kind == .text && !draft.note) || draft.entry?.annotation.type == "FreeText" {
                HStack {
                    Text("字号")
                    if draft.kind == .text { Slider(value: $draft.fontSize, in: 8...36, step: 1) }
                    TextField("点", value: $draft.fontSize, format: .number).textFieldStyle(.roundedBorder).frame(width: 60)
                    Text("pt")
                }
                ColorPicker("文字颜色", selection: $draft.color, supportsOpacity: false)
                if draft.kind == .annotation {
                    Text("较长内容可通过对象列表的“尺寸”加大文字框。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var imageFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let asset = draft.asset {
                Image(nsImage: asset.image).resizable().scaledToFit().frame(width: 400, height: 190)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                Text(asset.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Text("宽度")
                    TextField("点", value: $draft.imageWidth, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                    Text("点 · 高 \(String(format: "%.1f", draft.imageWidth * asset.aspectRatio)) 点（等比）").font(.caption).foregroundStyle(.secondary)
                }
                Text("下一步点击页面放置。图片会嵌入 PDF，可在右侧对象列表中移动、调整尺寸或删除。超出页面的图片会等比缩小。").font(.caption).foregroundStyle(.secondary).frame(width: 400, alignment: .leading)
            }
        }
    }

    private var geometryFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("以当前页面显示方向为准，单位为点（1 点 = 1/72 英寸）。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("宽")
                TextField("宽度", text: $draft.width).textFieldStyle(.roundedBorder)
                Text("高")
                if draft.entry?.isImage == true {
                    Text(String(format: "%.1f", (Double(draft.width) ?? 0) * draft.aspect)).frame(width: 90, alignment: .leading)
                } else { TextField("高度", text: $draft.height).textFieldStyle(.roundedBorder) }
            }.frame(width: 360)
            if draft.entry?.isImage == true { Text("图片保持原有宽高比例。").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct PDFFormRow: View {
    let entry: PDFFormEntry
    @ObservedObject var model: PDFWorkspaceModel
    let onError: (String) -> Void
    @State private var value = ""
    @State private var checked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(entry.title).font(.caption.weight(.semibold)).lineLimit(2)
                Spacer()
                Button("定位") { model.go(to: entry.pageIndex + 1) }.font(.caption).buttonStyle(.borderless)
            }
            if entry.isSignature {
                Text("数字签名字段 · 只读").font(.caption).foregroundStyle(.secondary)
            } else if entry.isButton {
                if entry.annotation.widgetControlType == .pushButtonControl {
                    Text("PDF 操作按钮").font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle("选中", isOn: $checked).font(.caption).onChange(of: checked) { _, state in
                        if state != (entry.annotation.buttonWidgetState == .onState) {
                            do { try model.setForm(entry, checked: state) } catch { onError(error.localizedDescription) }
                        }
                    }
                }
            } else {
                TextField("填写内容", text: $value).textFieldStyle(.roundedBorder).font(.caption)
                HStack {
                    if entry.annotation.widgetFieldType == .choice { Text("选项：\((entry.annotation.choices ?? []).joined(separator: " / "))").font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer()
                    Button("应用") {
                        do { try model.setForm(entry, text: value) } catch { onError(error.localizedDescription) }
                    }.font(.caption).buttonStyle(.borderless)
                }
            }
        }.padding(.vertical, 4)
        .disabled(!model.permitsForms || entry.annotation.isReadOnly)
        .onAppear { value = entry.annotation.widgetStringValue ?? ""; checked = entry.annotation.buttonWidgetState == .onState }
    }
}

private struct PDFOutlineRow: View {
    let outline: PDFOutline
    @ObservedObject var model: PDFWorkspaceModel
    let depth: Int
    @State private var expanded = true
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if outline.numberOfChildren > 0 {
                    Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2) }.buttonStyle(.plain).frame(width: 14)
                } else { Color.clear.frame(width: 14, height: 1) }
                Button(outline.label ?? "未命名书签") {
                    if let destination = outline.destination { model.pdfView?.go(to: destination) }
                    else if let action = outline.action as? PDFActionGoTo { model.pdfView?.go(to: action.destination) }
                }.buttonStyle(.plain).font(.caption).lineLimit(2)
                Spacer(minLength: 0)
            }.padding(.vertical, 5).padding(.leading, CGFloat(depth) * 12)
            if expanded && depth < 20 {
                ForEach(0..<outline.numberOfChildren, id: \.self) { index in
                    if let child = outline.child(at: index) { AnyView(PDFOutlineRow(outline: child, model: model, depth: depth + 1)) }
                }
            }
        }
    }
}
