import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RootWorkspace:View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var stickyNotes:StickyNotesStore
    let stickyWindows:StickyNotesWindowManager
    @State private var sidebar=true
    @State private var search=""
    @State private var history=false
    @Environment(\.openSettings) private var openSettings
    var body:some View{
        HStack(spacing:0){
            if sidebar{sidebarView.frame(width:236);Divider()}
            VStack(spacing:0){
                if !store.tabs.isEmpty{
                    ScrollView(.horizontal){HStack(spacing:4){ForEach(store.tabs){session in TabButton(session:session,selected:!store.showingNotes && store.selection==session.id,select:{store.select(session)},close:{store.close(session)})}}.padding(.horizontal,8).padding(.vertical,6)}.scrollIndicators(.hidden).background(.bar)
                    Divider()
                }
                ZStack {
                    if !store.tabs.isEmpty {
                        ForEach(store.tabs) { session in
                            TabWorkspace(session:session,store:store)
                                .opacity(!store.showingNotes && store.selection == session.id ? 1 : 0)
                                .allowsHitTesting(!store.showingNotes && store.selection == session.id)
                                .accessibilityHidden(store.showingNotes || store.selection != session.id)
                        }
                    }
                    if store.showingNotes {
                        StickyNotesWorkspace(store:stickyNotes,windows:stickyWindows,onGoHome:store.showHome,onOpenMarkdown:{text in store.newText(.markdown,text:text)})
                    } else if store.active == nil {welcome}
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                Divider()
                statusBar
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
        .background(Color(nsColor:.windowBackgroundColor))
        .background(WindowCloseGuard(store:store,stickyNotes:stickyNotes))
        .toolbar{
            ToolbarItem(placement:.navigation){Button{sidebar.toggle()}label:{Image(systemName:"sidebar.left")}.help("显示 / 隐藏侧边栏")}
            ToolbarItem(placement:.primaryAction){HStack(spacing:12){
                Button(action:store.showHome){Label("首页",systemImage:"house")}.help("返回首页 ⌘1")
                Menu{Button("LaTeX"){store.newText(.latex,text:Templates.latex)};Button("Markdown"){store.newText(.markdown)};Divider();Button("文本"){store.newText(.text)}}label:{Label("新建",systemImage:"plus")}
                Button(action:store.openPanel){Label("打开",systemImage:"folder")}
                Button(action:{OCRHandoffDispatcher.startOCR(store:store)}){Label("识别文字",systemImage:"doc.text.viewfinder")}.help("识别扫描件或图片文字 (OCR)")
                Button{if store.showingNotes{_=AppHub.saveStickyNotes()}else if let active=store.active{store.save(active)}}label:{Image(systemName:"square.and.arrow.down")}.help("保存 ⌘S").disabled(store.active?.kind.canSave != true && !store.showingNotes)
                Button{history=true}label:{Image(systemName:"clock.arrow.circlepath")}.help("本地历史").disabled(store.showingNotes || store.active?.url==nil)
                Button{openSettings()}label:{Image(systemName:"gearshape")}.help("设置")
            }}
        }
        .alert("操作未完成",isPresented:Binding(get:{store.error != nil},set:{if !$0{store.error=nil}})){Button("好"){store.error=nil}}message:{Text(store.error ?? "")}
        .sheet(isPresented:$history){if let url=store.active?.url{HistoryView(url:url,onError:{store.error=$0}).frame(width:700,height:500)}}
        .onReceive(NotificationCenter.default.publisher(for:Notification.Name("GaoWenJian.moduleDirty"))){note in
            if let path=note.object as? String,let dirty=note.userInfo?["dirty"] as? Bool,let session=store.tabs.first(where:{$0.url?.path==path}){session.moduleDirty=dirty;store.objectWillChange.send()}
        }
        .onDrop(of:[UTType.fileURL],isTargeted:nil){providers in
            for provider in providers{_ = provider.loadObject(ofClass:URL.self){url,_ in if let url{Task{@MainActor in store.open(url)}}}};return true
        }
    }
    private var sidebarView:some View{
        VStack(alignment:.leading,spacing:0){
            HStack(spacing:11){if let image=NSImage(named:"AppIcon"){Image(nsImage:image).resizable().frame(width:38,height:38)}else{Image(systemName:"doc.on.doc.fill").font(.title)};VStack(alignment:.leading,spacing:3){Text("搞文件").font(.headline);Text("写作 · 编译 · PDF").font(.caption).foregroundStyle(.secondary)}}.padding(18)
            VStack(alignment:.leading,spacing:5){
                sidebarShortcut("首页",symbol:"house",selected:!store.showingNotes && store.active==nil,action:store.showHome)
                Text("核心写作").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.leading,10).padding(.top,10)
                sidebarShortcut("LaTeX",symbol:"function"){store.openPanel(for:[.latex])}
                sidebarShortcut("Markdown",symbol:"text.badge.checkmark"){store.openPanel(for:[.markdown])}
                Divider().padding(.vertical,6)
                sidebarShortcut("PDF 编辑器",symbol:"doc.richtext"){store.openPanel(for:[.pdf])}
                sidebarShortcut("Office 查看器",symbol:"doc.viewfinder"){store.openPanel(for:[.word,.spreadsheet,.presentation])}
            }.padding(.horizontal,14).padding(.bottom,16)
            TextField("搜索文件名",text:$search).textFieldStyle(.roundedBorder).padding(.horizontal,14).padding(.bottom,12)
            HStack{Text(store.folder?.lastPathComponent ?? "最近打开").font(.caption.weight(.semibold)).foregroundStyle(.secondary);Spacer();Button(action:store.openFolderPanel){Image(systemName:"folder.badge.plus")}.buttonStyle(.plain).help("打开文件夹")}.padding(.horizontal,18).padding(.bottom,8)
            ScrollView{
                LazyVStack(alignment:.leading,spacing:3){
                    if store.folder != nil{
                        ForEach(store.entries.filter{search.isEmpty || $0.url.lastPathComponent.localizedCaseInsensitiveContains(search)}){entry in
                            FileRow(url:entry.url,directory:entry.directory,depth:entry.depth,selected:store.active?.url==entry.url){if !entry.directory{store.open(entry.url)}}
                        }
                    }else{
                        ForEach(store.recent.filter{search.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(search)},id:\.path){url in FileRow(url:url,directory:false,depth:0,selected:store.active?.url==url){store.open(url)}}
                    }
                    if store.entries.isEmpty && store.recent.isEmpty{Text("打开文件或文件夹开始工作").font(.caption).foregroundStyle(.tertiary).padding(16)}
                }.padding(.horizontal,10)
            }
            Spacer(minLength:0)
            if store.folder != nil{Button("切换到最近打开"){store.folder=nil;store.entries=[]}.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(.horizontal,18).padding(.bottom,10)}
            Divider().padding(.horizontal,14)
            VStack(alignment:.leading,spacing:5){
                Text("附加工具").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.leading,10)
                sidebarShortcut("便笺",symbol:"note.text",selected:store.showingNotes,action:showStickyNotes)
            }.padding(14)
            Label("全部在本机处理",systemImage:"internaldrive").font(.caption).foregroundStyle(.secondary).padding(.horizontal,24).padding(.bottom,16)

        }.background(.regularMaterial)
    }
    private func sidebarShortcut(_ title:String,symbol:String,selected:Bool=false,action:@escaping ()->Void)->some View {
        Button(action:action){Label(title,systemImage:symbol).font(.callout).frame(maxWidth:.infinity,alignment:.leading).padding(9).contentShape(Rectangle())}
            .buttonStyle(.plain).background(selected ? Color.primary.opacity(0.09):.clear,in:RoundedRectangle(cornerRadius:7))
    }
    private var welcome:some View{
        ScrollView{
            VStack(alignment:.leading,spacing:24){
                HStack(alignment:.center){
                    VStack(alignment:.leading,spacing:8){
                        Text("专注写作，从这里开始。").font(.system(size:29,weight:.semibold))
                        Text("LaTeX 与 Markdown 写作、编译，配合本地 PDF 编辑。").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength:12)
                    Button(action:store.openFolderPanel){Label("打开文件夹",systemImage:"folder.badge.plus")}.controlSize(.large)
                }
                if store.restoredCount>0{Label("已恢复 \(store.restoredCount) 个未保存文本草稿，请检查后保存。",systemImage:"arrow.counterclockwise").font(.callout).padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Color.orange.opacity(0.1),in:RoundedRectangle(cornerRadius:10))}
                VStack(alignment:.leading,spacing:12){
                    homeHeading("写作与编译",detail:"核心工作区")
                    HStack(spacing:16){
                        WritingCard(title:"LaTeX",description:"论文与公式排版",detail:"本地编译 · 大纲导航 · 源码与 PDF 联动",symbol:"function",color:.teal,create:{store.newText(.latex,text:Templates.latex)},open:{store.openPanel(for:[.latex])})
                        WritingCard(title:"Markdown",description:"轻量写作与即时预览",detail:"即时渲染 · 公式与图示 · HTML / PDF 导出",symbol:"text.badge.checkmark",color:.indigo,create:{store.newText(.markdown,text:Templates.markdown)},open:{store.openPanel(for:[.markdown])})
                    }
                }
                HStack(spacing:16){
                    Image(systemName:"doc.richtext").font(.system(size:27)).foregroundStyle(.red).frame(width:50,height:50).background(Color.red.opacity(0.08),in:RoundedRectangle(cornerRadius:11))
                    VStack(alignment:.leading,spacing:5){Text("PDF 编辑器").font(.headline);Text("插入文字与图片、批注、填写表单，整理与合并页面。").font(.callout).foregroundStyle(.secondary)}
                    Spacer(minLength:8)
                    Button("识别扫描件/图片…"){OCRHandoffDispatcher.startOCR(store:store)}.controlSize(.large)
                    Button("打开 PDF…"){store.openPanel(for:[.pdf])}.controlSize(.large)
                }.padding(18).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(Color.primary.opacity(0.08)))
                VStack(alignment:.leading,spacing:10){
                    homeHeading("Office 查看",detail:"阅读文档、表格与演示")
                    HStack(spacing:12){
                        OfficeLaunchCard(title:"Word",symbol:"doc.text",color:.blue){store.openPanel(for:[.word])}
                        OfficeLaunchCard(title:"Excel",symbol:"tablecells",color:.green){store.openPanel(for:[.spreadsheet])}
                        OfficeLaunchCard(title:"PowerPoint",symbol:"rectangle.on.rectangle",color:.orange){store.openPanel(for:[.presentation])}
                    }
                }
                HStack(spacing:12){
                    Text("附加工具").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Button(action:showStickyNotes){Label("便笺",systemImage:"note.text")}.buttonStyle(.borderless)
                    Text("随手记录与桌面便条").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(action:store.openPanel){Label("打开其他文件…",systemImage:"folder")}.buttonStyle(.borderless).font(.caption)
                }
                Divider()
                VStack(alignment:.leading,spacing:10){
                    homeHeading("最近打开",detail:"保留文件原来的位置")
                    if store.recent.isEmpty{Text("拖入文件，或从上方开始新的写作。").font(.callout).foregroundStyle(.secondary).padding(.vertical,6)}
                    else{VStack(spacing:0){ForEach(Array(store.recent.prefix(6)),id:\.path){url in Button{store.open(url)}label:{HStack(spacing:12){Image(systemName:FileKind(url:url).symbol).foregroundStyle(.secondary).frame(width:22);VStack(alignment:.leading,spacing:4){Text(url.lastPathComponent).font(.callout.weight(.medium));Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1)};Spacer();Image(systemName:"arrow.up.right").font(.caption).foregroundStyle(.tertiary)}.padding(10).contentShape(Rectangle())}.buttonStyle(.plain);Divider()}}}
                }
            }.padding(32).frame(maxWidth:1120,alignment:.leading).frame(maxWidth:.infinity)
        }
    }
    private func homeHeading(_ title:String,detail:String)->some View {
        HStack{Text(title).font(.headline);Spacer();Text(detail).font(.caption).foregroundStyle(.secondary)}
    }
    private func showStickyNotes(){NSApp.keyWindow?.makeFirstResponder(nil);store.showingNotes=true}
    private var statusBar:some View{HStack(spacing:14){Image(systemName:"internaldrive").font(.caption);Text(store.showingNotes ? stickyNotes.saveStatus : store.status).font(.caption).lineLimit(1);Spacer();if !store.showingNotes,let active=store.active{SessionStatus(session:active)};Text("本地模式").font(.caption).foregroundStyle(.secondary)}.padding(.horizontal,14).frame(height:30).background(.bar)}
}
struct SessionStatus:View{@ObservedObject var session:FileSession;var body:some View{HStack(spacing:12){if session.kind.isText{Text("\(session.text.count) 字符 · \(session.text.components(separatedBy:"\n").count) 行")};Text(session.kind.isOfficeViewer ? "只读查看" : session.dirty || session.moduleDirty ? "有未保存修改" : "已保存").foregroundStyle(session.dirty || session.moduleDirty ? Color.orange : .secondary)}.font(.caption)}}
struct TabButton:View{
    @ObservedObject var session:FileSession
    let selected:Bool;let select:()->Void;let close:()->Void
    var body:some View{HStack(spacing:8){Button(action:select){HStack(spacing:7){Image(systemName:session.kind.symbol);Text(session.title).lineLimit(1);if session.dirty || session.moduleDirty{Circle().fill(Color.orange).frame(width:5,height:5)}}.font(.system(size:12)).contentShape(Rectangle())}.buttonStyle(.plain);Button(action:close){Image(systemName:"xmark").font(.system(size:9,weight:.semibold)).foregroundStyle(.secondary)}.buttonStyle(.plain)}.padding(.horizontal,12).frame(height:31).background(selected ? Color(nsColor:.controlBackgroundColor):Color.clear,in:RoundedRectangle(cornerRadius:7)).overlay(RoundedRectangle(cornerRadius:7).stroke(selected ? Color.primary.opacity(0.1):.clear))}
}
struct FileRow:View{let url:URL;let directory:Bool;let depth:Int;let selected:Bool;let action:()->Void;@State private var hover=false
    var body:some View{Button(action:action){HStack(spacing:8){Image(systemName:directory ? "folder" : FileKind(url:url).symbol).frame(width:18).foregroundStyle(selected ? Color.white : .secondary);Text(url.lastPathComponent).lineLimit(1);Spacer(minLength:0)}.font(.system(size:12)).padding(.leading,10+CGFloat(depth)*10).padding(.trailing,8).frame(height:30).foregroundStyle(selected ? Color.white : .primary).background(selected ? Color(nsColor:.darkGray):Color.primary.opacity(hover ? 0.06:0),in:RoundedRectangle(cornerRadius:7)).contentShape(Rectangle())}.buttonStyle(.plain).onHover{hover=$0}.help(url.path)}
}
struct WritingCard:View {
    let title:String;let description:String;let detail:String;let symbol:String;let color:Color
    let create:()->Void;let open:()->Void
    var body:some View{
        VStack(alignment:.leading,spacing:13){
            HStack(spacing:12){
                Image(systemName:symbol).font(.system(size:27,weight:.medium)).foregroundStyle(color).frame(width:48,height:48).background(color.opacity(0.12),in:RoundedRectangle(cornerRadius:12))
                VStack(alignment:.leading,spacing:3){Text(title).font(.system(size:22,weight:.semibold));Text(description).font(.callout).foregroundStyle(.secondary)}
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(minHeight:28,alignment:.top)
            HStack(spacing:12){Button("新建 \(title)",action:create).buttonStyle(.borderedProminent).tint(color);Button("打开…",action:open).buttonStyle(.bordered)}.controlSize(.large)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(22)
            .background(color.opacity(0.045),in:RoundedRectangle(cornerRadius:15)).overlay(RoundedRectangle(cornerRadius:15).stroke(color.opacity(0.22)))
    }
}
struct OfficeLaunchCard:View {
    let title:String;let symbol:String;let color:Color;let action:()->Void
    var body:some View{
        Button(action:action){HStack(spacing:10){Image(systemName:symbol).font(.title3).foregroundStyle(color);Text(title).font(.callout.weight(.medium));Spacer(minLength:0);Image(systemName:"arrow.up.right").font(.caption).foregroundStyle(.tertiary)}.padding(14).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:9)).contentShape(Rectangle())}.buttonStyle(.plain).help("打开 \(title) 文件，只读查看")
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
struct HistoryView: View {
    let url: URL
    let onError: (String) -> Void
    @State private var items: [URL] = []
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("本地历史").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }
            }
            Text(url.lastPathComponent + " · 每次覆盖保存前保留原件。恢复时生成副本，便于核对。")
                .font(.callout).foregroundStyle(.secondary)
            List(items, id: \.path) { item in
                HStack {
                    Text(item.lastPathComponent).font(.caption.monospaced()).lineLimit(1)
                    Spacer()
                    Button("恢复副本…") { restore(item) }
                }
            }
            if items.isEmpty { Text("第一次覆盖保存后会出现历史快照。").foregroundStyle(.secondary) }
        }
        .padding(24)
        .onAppear {
            do { items = try FileSafety.snapshots(for: url) }
            catch { onError(error.localizedDescription) }
        }
    }
    private func restore(_ item: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "恢复-" + url.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try FileSafety.write(Data(contentsOf: item), to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { onError(error.localizedDescription) }
    }
}
