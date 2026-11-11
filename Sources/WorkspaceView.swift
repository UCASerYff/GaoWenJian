import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RootWorkspace: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var stickyNotes: StickyNotesStore
    let stickyWindows: StickyNotesWindowManager
    @State private var sidebar = true
    @State private var search = ""
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 0) {
            if sidebar { sidebarView.frame(width: 230); Divider() }
            VStack(spacing: 0) {
                if !store.tabs.isEmpty { tabStrip }
                ZStack {
                    // Keep every editor alive when navigating to another part of the app.
                    ForEach(store.tabs) { session in
                        TabWorkspace(session: session, store: store)
                            .opacity(isSelected(session) ? 1 : 0)
                            .allowsHitTesting(isSelected(session))
                            .accessibilityHidden(!isSelected(session))
                    }
                    if store.showingOrganizer {
                        OrganizerHostView(host: store.organizerHost, openDocument: { store.open($0) }, goHome: store.showHome)
                    } else if store.showingNotes {
                        StickyNotesWorkspace(store: stickyNotes, windows: stickyWindows, onGoHome: store.showHome, onOpenMarkdown: { store.newText(.markdown, text: $0) })
                    } else if store.active == nil { welcome }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                statusBar
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WorkspaceStyle.canvas)
        .tint(WorkspaceStyle.accent)
        .background(WindowCloseGuard(store: store, stickyNotes: stickyNotes))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { sidebar.toggle() } label: { Image(systemName: "sidebar.left") }.help("显示 / 隐藏侧边栏")
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 14) {
                    Menu {
                        Button("LaTeX 文档") { store.newText(.latex, text: Templates.latex) }
                        Button("Markdown 文档") { store.newText(.markdown) }
                        Divider()
                        Button("纯文本") { store.newText(.text) }
                        Button("CSV 表格") { store.newText(.csv, text: "名称,数值,备注\n项目,0,\n") }
                    } label: { Label("新建", systemImage: "plus") }
                    Button(action: store.openPanel) { Label("打开", systemImage: "folder") }.help("打开文件 ⌘O")
                    Divider().frame(height: 16)
                    Button {
                        if store.showingNotes { _ = AppHub.saveStickyNotes() }
                        else if let active = store.active { store.save(active) }
                    } label: { Label("保存", systemImage: "square.and.arrow.down") }
                    .help("保存 ⌘S")
                    .disabled(store.showingOrganizer || (store.active?.kind.canSave != true && !store.showingNotes))
                }
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoWenJian.moduleDirty"))) { note in
            if let path = note.object as? String, let dirty = note.userInfo?["dirty"] as? Bool,
               let session = store.tabs.first(where: { $0.url?.path == path }) {
                session.moduleDirty = dirty; store.objectWillChange.send()
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in store.open(url) } }
                }
            }
            return true
        }
    }

    private func isSelected(_ session: FileSession) -> Bool {
        !store.showingNotes && !store.showingOrganizer && store.selection == session.id
    }

    private var tabStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(store.tabs) { session in
                    TabButton(session: session, selected: isSelected(session), select: { store.select(session) }, close: { store.close(session) })
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .background(WorkspaceStyle.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(WorkspaceStyle.line).frame(height: 1) }
    }

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                if let image = NSImage(named: "AppIcon") { Image(nsImage: image).resizable().frame(width: 38, height: 38) }
                VStack(alignment: .leading, spacing: 3) {
                    Text("搞文件").font(.system(size: 18, weight: .semibold))
                    Text("你的本地写作台").font(.caption).foregroundStyle(WorkspaceStyle.muted)
                }
            }.padding(.horizontal, 19).padding(.top, 23).padding(.bottom, 24)
            VStack(alignment: .leading, spacing: 4) {
                sidebarShortcut("工作台", symbol: "square.grid.2x2", selected: !store.showingNotes && !store.showingOrganizer && store.active == nil, action: store.showHome)
                sidebarHeading("写作")
                sidebarShortcut("LaTeX", symbol: "function", color: WorkspaceStyle.latex) { store.openPanel(for: [.latex]) }
                sidebarShortcut("Markdown", symbol: "text.alignleft", color: WorkspaceStyle.markdown) { store.openPanel(for: [.markdown]) }
                sidebarHeading("文档工具")
                sidebarShortcut("PDF 编辑", symbol: "doc.richtext", color: WorkspaceStyle.pdf) { store.openPanel(for: [.pdf]) }
                sidebarShortcut("Office 查看", symbol: "doc.viewfinder") { store.openPanel(for: [.word, .spreadsheet, .presentation]) }
                sidebarShortcut("整理与查找", symbol: "folder.badge.gearshape", selected: store.showingOrganizer, action: store.showOrganizer)
            }.padding(.horizontal, 12)
            Rectangle().fill(WorkspaceStyle.line).frame(height: 1).padding(.horizontal, 20).padding(.vertical, 18)
            HStack {
                Text(store.folder?.lastPathComponent ?? "最近文件").font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                Button(action: store.openFolderPanel) { Image(systemName: "folder.badge.plus") }.buttonStyle(.plain).help("打开文件夹")
            }.foregroundStyle(WorkspaceStyle.muted).padding(.horizontal, 22)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.tertiary)
                TextField("筛选文件名", text: $search).textFieldStyle(.plain).font(.caption)
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).help("清除筛选") }
            }.padding(9).background(WorkspaceStyle.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 16).padding(.top, 9).padding(.bottom, 7)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if store.folder != nil {
                        ForEach(filteredEntries) { entry in
                            FileRow(url: entry.url, directory: entry.directory, depth: entry.depth, selected: !store.showingOrganizer && !store.showingNotes && store.active?.url == entry.url) { if !entry.directory { store.open(entry.url) } }
                        }
                    } else {
                        ForEach(filteredRecent, id: \.path) { url in
                            FileRow(url: url, directory: false, depth: 0, selected: !store.showingOrganizer && !store.showingNotes && store.active?.url == url) { store.open(url) }
                        }
                    }
                    if (store.folder != nil && filteredEntries.isEmpty) || (store.folder == nil && filteredRecent.isEmpty) {
                        Text(search.isEmpty ? "打开文件后，会显示在这里。" : "没有匹配的文件")
                            .font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                }.padding(.horizontal, 10)
            }
            if store.folder != nil {
                Button("返回最近文件") { store.folder = nil; store.entries = [] }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(WorkspaceStyle.accent).padding(.horizontal, 22).padding(.vertical, 9)
            }
            VStack(spacing: 5) {
                sidebarShortcut("便笺", symbol: "note.text", selected: store.showingNotes, action: showStickyNotes)
                HStack {
                    Label("本机处理", systemImage: "internaldrive").font(.caption2).foregroundStyle(WorkspaceStyle.muted)
                    Spacer()
                    Button { openSettings() } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).foregroundStyle(WorkspaceStyle.muted).help("设置 ⌘,")
                }.padding(.horizontal, 10).padding(.top, 6)
            }.padding(12).padding(.bottom, 5)
        }.background(WorkspaceStyle.sidebar)
    }

    private var filteredEntries: [BrowserEntry] { store.entries.filter { search.isEmpty || $0.url.lastPathComponent.localizedCaseInsensitiveContains(search) } }
    private var filteredRecent: [URL] { store.recent.filter { search.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(search) } }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(WorkspaceStyle.muted)
            .padding(.leading, 11).padding(.top, 13).padding(.bottom, 4)
    }
    private func sidebarShortcut(_ title: String, symbol: String, selected: Bool = false, color: Color = WorkspaceStyle.muted, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(selected ? WorkspaceStyle.accent : color).frame(width: 20)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
                if selected { Circle().fill(WorkspaceStyle.accent).frame(width: 5, height: 5) }
            }.padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .background(selected ? WorkspaceStyle.accent.opacity(0.11) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private var welcome: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 27) {
                    welcomeHeader
                    if store.restoredCount > 0 {
                        Label("已恢复 \(store.restoredCount) 个未保存草稿，请检查后保存。", systemImage: "arrow.counterclockwise")
                            .font(.callout).padding(13).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if geometry.size.width >= 1050 {
                        HStack(alignment: .top, spacing: 24) {
                            launchArea.frame(maxWidth: .infinity)
                            recentFiles.frame(width: 260)
                        }
                    } else {
                        launchArea
                        recentFiles
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc")
                        Text("将文件拖到窗口中，直接开始。")
                        Spacer()
                        Text("⌘N 新建  ·  ⌘O 打开").monospaced()
                    }.font(.caption).foregroundStyle(WorkspaceStyle.muted)
                }.padding(30).frame(maxWidth: 1240, alignment: .leading).frame(maxWidth: .infinity)
            }
        }.background(WorkspaceStyle.canvas)
    }

    private var welcomeHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("WORKSPACE").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(3).foregroundStyle(WorkspaceStyle.accent)
                Text("给想法，一张纸。") .font(.system(size: 30, weight: .medium, design: .serif))
                Text("从写作到成稿，让文件各就其位。").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: store.openPanel) { Label("打开文件", systemImage: "folder") }
                .buttonStyle(.bordered).controlSize(.large)
        }.padding(.top, 6).padding(.bottom, 5)
    }

    private var launchArea: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                homeHeading("开始写作", detail: "从空白到成稿")
                HStack(spacing: 14) {
                    WritingCard(title: "LaTeX", description: "让论文与公式井然有序", detail: "离线编译 · 大纲导航 · PDF 联动", symbol: "function", color: WorkspaceStyle.latex, create: { store.newText(.latex, text: Templates.latex) }, open: { store.openPanel(for: [.latex]) })
                    WritingCard(title: "Markdown", description: "让文字跟上你的想法", detail: "即时预览 · 公式图示 · 多格式导出", symbol: "text.alignleft", color: WorkspaceStyle.markdown, create: { store.newText(.markdown) }, open: { store.openPanel(for: [.markdown]) })
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                homeHeading("文档工具", detail: "阅读、编辑与整理")
                VStack(spacing: 0) {
                    toolRow(title: "PDF 编辑", detail: "文字与图片批注，表单与页面整理", symbol: "doc.richtext", color: WorkspaceStyle.pdf) {
                        Button("识别文字…") { OCRHandoffDispatcher.startOCR(store: store) }.buttonStyle(.borderless)
                        Button("打开 PDF") { store.openPanel(for: [.pdf]) }.buttonStyle(.bordered)
                    }
                    Divider().padding(.leading, 68)
                    toolRow(title: "Office 查看", detail: "Word · Excel · PowerPoint", symbol: "doc.viewfinder", color: WorkspaceStyle.markdown) {
                        Menu("打开文档") {
                            Button("Word") { store.openPanel(for: [.word]) }
                            Button("Excel") { store.openPanel(for: [.spreadsheet]) }
                            Button("PowerPoint") { store.openPanel(for: [.presentation]) }
                        }.menuStyle(.borderlessButton).fixedSize()
                    }
                    Divider().padding(.leading, 68)
                    toolRow(title: "整理与查找", detail: "授权目录索引，收藏与虚拟工作区", symbol: "folder.badge.gearshape", color: WorkspaceStyle.accent) {
                        Button("开始整理", action: store.showOrganizer).buttonStyle(.bordered)
                    }
                }.workspaceSurface()
            }
            HStack(spacing: 12) {
                Image(systemName: "note.text").font(.title3).foregroundStyle(WorkspaceStyle.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text("零散的灵感，也有去处。").font(.callout)
                    Text("便笺与桌面便条，随手记下来。") .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("打开便笺", action: showStickyNotes).buttonStyle(.borderless)
            }.padding(.horizontal, 4)
        }
    }

    private func toolRow<Actions: View>(title: String, detail: String, symbol: String, color: Color, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 21, weight: .regular)).foregroundStyle(color)
                .frame(width: 39, height: 42)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions().controlSize(.regular)
        }.padding(.horizontal, 17).padding(.vertical, 16)
    }

    private var recentFiles: some View {
        VStack(alignment: .leading, spacing: 12) {
            homeHeading("接着上次", detail: "最近打开")
            VStack(alignment: .leading, spacing: 0) {
                if store.recent.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "doc.text").font(.system(size: 28, weight: .light)).foregroundStyle(WorkspaceStyle.muted)
                        Text("这里等着你的第一份文档。") .font(.callout)
                        Text("打开的文件会在此显示，文档始终留在原来的位置。") .font(.caption).foregroundStyle(.secondary)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(store.recent.prefix(7)), id: \.path) { url in
                        RecentDocumentRow(url: url) { store.open(url) }
                        if url != store.recent.prefix(7).last { Divider().padding(.horizontal, 15) }
                    }
                }
                Divider().padding(.horizontal, 15)
                Button(action: store.openFolderPanel) {
                    Label("打开项目文件夹", systemImage: "folder.badge.plus").font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(WorkspaceStyle.accent)
            }.workspaceSurface()
        }
    }

    private func homeHeading(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(detail).font(.caption2).foregroundStyle(WorkspaceStyle.muted)
        }
    }
    private func showStickyNotes() { NSApp.keyWindow?.makeFirstResponder(nil); store.showingNotes = true; store.showingOrganizer = false }
    private var statusBar: some View {
        HStack(spacing: 9) {
            Circle().fill(WorkspaceStyle.accent).frame(width: 5, height: 5)
            Text(store.showingOrganizer ? "整理与查找 · 写作标签已保留" : store.showingNotes ? stickyNotes.saveStatus : store.status).lineLimit(1)
            Spacer(minLength: 8)
            if !store.showingOrganizer && !store.showingNotes, let active = store.active { SessionStatus(session: active) }
            Text("本地模式").foregroundStyle(WorkspaceStyle.muted)
        }.font(.system(size: 10)).padding(.horizontal, 15).frame(height: 27).background(WorkspaceStyle.canvas)
    }
}

struct SessionStatus: View {
    @ObservedObject var session: FileSession
    var body: some View {
        HStack(spacing: 12) {
            if session.kind.isText { Text("\(session.text.count) 字符 · \(session.text.components(separatedBy: "\n").count) 行") }
            Text(session.kind.isOfficeViewer ? "只读查看" : session.dirty || session.moduleDirty ? "有未保存修改" : "已保存")
                .foregroundStyle(session.dirty || session.moduleDirty ? Color.orange : WorkspaceStyle.muted)
        }
    }
}

struct TabButton: View {
    @ObservedObject var session: FileSession
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovered = false
    var body: some View {
        HStack(spacing: 9) {
            Button(action: select) {
                HStack(spacing: 8) {
                    Image(systemName: session.kind.symbol).foregroundStyle(WorkspaceStyle.color(for: session.kind))
                    Text(session.title).lineLimit(1).frame(maxWidth: 190)
                    if session.dirty || session.moduleDirty { Circle().fill(Color.orange).frame(width: 5, height: 5).accessibilityLabel("有未保存修改") }
                }.font(.system(size: 12, weight: selected ? .medium : .regular)).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 18) }
                .buttonStyle(.plain).foregroundStyle(.secondary).opacity(selected || hovered ? 1 : 0.35).help("关闭 \(session.title)")
        }
        .padding(.horizontal, 11).frame(height: 32)
        .background(selected ? WorkspaceStyle.surface : WorkspaceStyle.line.opacity(hovered ? 0.35 : 0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? WorkspaceStyle.accent.opacity(0.38) : Color.clear))
        .onHover { hovered = $0 }
    }
}

struct FileRow: View {
    let url: URL
    let directory: Bool
    let depth: Int
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: directory ? "folder" : FileKind(url: url).symbol).frame(width: 18).foregroundStyle(selected ? WorkspaceStyle.accent : WorkspaceStyle.muted)
                Text(url.lastPathComponent).lineLimit(1)
                Spacer(minLength: 0)
            }.font(.system(size: 12)).padding(.leading, 10 + CGFloat(depth) * 10).padding(.trailing, 8).frame(height: 30)
                .background(selected ? WorkspaceStyle.accent.opacity(0.11) : WorkspaceStyle.line.opacity(hover ? 0.4 : 0), in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover = $0 }.help(url.path)
    }
}

struct WritingCard: View {
    let title: String
    let description: String
    let detail: String
    let symbol: String
    let color: Color
    let create: () -> Void
    let open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                Image(systemName: symbol).font(.system(size: 25, weight: .medium)).foregroundStyle(color)
                    .frame(width: 42, height: 42).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                Spacer()
                Text(title == "LaTeX" ? ".tex" : ".md").font(.system(size: 12, design: .monospaced)).foregroundStyle(color.opacity(0.8)).padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 24, weight: .semibold, design: .serif))
                Text(description).font(.callout).foregroundStyle(.secondary)
            }
            Text(detail).font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted).fixedSize(horizontal: false, vertical: true).frame(minHeight: 25, alignment: .top)
            HStack(spacing: 10) {
                Button("新建文档", action: create).buttonStyle(.borderedProminent).tint(color).foregroundStyle(WorkspaceStyle.onAccent)
                Spacer(minLength: 0)
                Button("打开…", action: open).buttonStyle(.borderless).foregroundStyle(color)
            }.controlSize(.large)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).workspaceSurface()
    }
}

private struct RecentDocumentRow: View {
    let url: URL
    let open: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: FileKind(url: url).symbol).foregroundStyle(WorkspaceStyle.color(for: FileKind(url: url))).font(.system(size: 15)).frame(width: 19).padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(url.deletingLastPathComponent().lastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(.tertiary).opacity(hover ? 1 : 0)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(WorkspaceStyle.accent.opacity(hover ? 0.05 : 0)).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover = $0 }.help(url.path)
    }
}
struct TabWorkspace:View{
    @ObservedObject var session:FileSession
    @ObservedObject var store:WorkspaceStore
    private var binding:Binding<String>{Binding(get:{session.text},set:{session.edited($0)})}
    var body:some View{
        VStack(spacing:0){
        if let incoming=session.incoming{IncomingDocumentBanner(incoming:incoming)}
        Group{switch session.kind{
        case .markdown:MarkdownWorkspace(text:binding,baseURL:session.url,onError:{store.error=$0})
        case .latex:LaTeXWorkspace(text:binding,url:session.url,save:{store.save(session) ? session.url : nil},onError:{store.error=$0})
        case .csv:CSVWorkspace(text:binding,delimiter:session.url?.pathExtension.lowercased()=="tsv" ? "\t" : ",")
        case .text:SourceEditor(text:binding)
        case .pdf:if let url=session.url{PDFWorkspace(url:url,onSaved:{store.moduleDidSave(url)},onError:{store.error=$0})}
        case .word,.spreadsheet,.presentation:if let url=session.url{OfficeViewer(url:url,onError:{store.error=$0})}
        case .richText:if let url=session.url{RichTextWorkspace(url:url,onSaved:{store.moduleDidSave(url)},onError:{store.error=$0})}
        case .image:if let url=session.url{ImageWorkspace(url:url)}
        case .other:if let url=session.url{UnsupportedWorkspace(url:url,store:store)}
        }}.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
}
struct ImageWorkspace:View{let url:URL;@State private var scale=1.0;var body:some View{VStack(spacing:0){HStack{Text(url.lastPathComponent).font(.subheadline);Spacer();Slider(value:$scale,in:0.1...3).frame(width:160);Text("\(Int(scale*100))%").font(.caption.monospacedDigit());Button("识别图片文字 (OCR)"){if let s=AppHub.store{OCRHandoffDispatcher.startOCR(for:url,store:s)}};Button("在 Finder 显示"){NSWorkspace.shared.activateFileViewerSelecting([url])}}.padding(12).background(.bar);ScrollView([.horizontal,.vertical]){if let image=NSImage(contentsOf:url){Image(nsImage:image).resizable().scaledToFit().frame(width:min(image.size.width,1200)*scale).padding(24)}else{Text("无法解码这张图片").padding()}}.frame(maxWidth:.infinity,maxHeight:.infinity)}}}
struct UnsupportedWorkspace:View{let url:URL;@ObservedObject var store:WorkspaceStore
    var body:some View{VStack(spacing:16){Image(systemName:"doc").font(.system(size:48,weight:.light)).foregroundStyle(.secondary);Text(url.lastPathComponent).font(.title2);Text("此格式可通过本机其他应用打开。").font(.callout).foregroundStyle(.secondary);Button("使用系统应用打开"){NSWorkspace.shared.open(url)}}.frame(maxWidth:.infinity,maxHeight:.infinity)}
}
