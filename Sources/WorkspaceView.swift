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
                Button(action:showStickyNotes){Label("便笺",systemImage:"note.text")}.help("便笺中心 ⌘2")
                Menu{Button("Markdown"){store.newText(.markdown)};Button("LaTeX"){store.newText(.latex,text:Templates.latex)};Button("Word"){store.createOffice("docx")};Button("Excel"){store.createOffice("xlsx")};Button("PPT"){store.createOffice("pptx")};Button("文本"){store.newText(.text)}}label:{Label("新建",systemImage:"plus")}
                Button(action:store.openPanel){Label("打开",systemImage:"folder")}
                Button{if store.showingNotes{_=AppHub.saveStickyNotes()}else if let active=store.active{store.save(active)}}label:{Image(systemName:"square.and.arrow.down")}.help("保存 ⌘S").disabled(store.active==nil && !store.showingNotes)
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
            HStack(spacing:11){if let image=NSImage(named:"AppIcon"){Image(nsImage:image).resizable().frame(width:38,height:38)}else{Image(systemName:"doc.on.doc.fill").font(.title)};VStack(alignment:.leading,spacing:3){Text("搞文件").font(.headline);Text("本地文件工作台").font(.caption).foregroundStyle(.secondary)}}.padding(18)
            Button(action:showStickyNotes){HStack{Label("便笺中心",systemImage:"note.text");Spacer();Text("\(stickyNotes.notes.filter{$0.deletedAt==nil}.count)").font(.caption.monospacedDigit())}.font(.callout).padding(10).contentShape(Rectangle())}.buttonStyle(.plain).background(store.showingNotes ? Color.primary.opacity(0.09):Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:8)).padding(.horizontal,14).padding(.bottom,12)
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
            VStack(alignment:.leading,spacing:7){Label("全部在本机处理",systemImage:"internaldrive").font(.caption.weight(.medium));Text("已打开 \(store.tabs.count) 个文件").font(.caption).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,alignment:.leading).padding(12).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10)).padding(12)
        }.background(.regularMaterial)
    }
    private var welcome:some View{
        ScrollView{
            VStack(alignment:.leading,spacing:26){
                HStack(alignment:.top){VStack(alignment:.leading,spacing:10){Text("让文件，各就其位。").font(.system(size:32,weight:.semibold));Text("写笔记、排论文、批注 PDF，整理文档、表格和演示。\n打开本地文件，继续你的工作。").font(.system(size:15)).foregroundStyle(.secondary).lineSpacing(6)};Spacer();Image(systemName:"doc.on.doc").font(.system(size:58,weight:.ultraLight)).foregroundStyle(.quaternary)}
                HStack(spacing:10){Button(action:store.openPanel){Label("打开文件",systemImage:"folder")}.buttonStyle(.borderedProminent).tint(Color(nsColor:.darkGray));Button(action:store.openFolderPanel){Label("打开文件夹",systemImage:"folder.badge.plus")}.buttonStyle(.bordered)}
                if store.restoredCount>0{Label("已恢复 \(store.restoredCount) 个未保存文本草稿，请检查后保存。",systemImage:"arrow.counterclockwise").font(.callout).padding(12).frame(maxWidth:.infinity,alignment:.leading).background(Color.orange.opacity(0.1),in:RoundedRectangle(cornerRadius:10))}
                LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible()),GridItem(.flexible())],spacing:16){
                    NewFileCard(title:"便笺",description:"随手记录 · 桌面置顶 · 本地保存",symbol:"note.text",color:.yellow){showStickyNotes()}
                    NewFileCard(title:"Markdown",description:"即时渲染 · 公式 · 图示",symbol:"text.badge.checkmark",color:.indigo){store.newText(.markdown,text:Templates.markdown)}
                    NewFileCard(title:"LaTeX",description:"源码编辑 · 本地编译",symbol:"function",color:.teal){store.newText(.latex,text:Templates.latex)}
                    NewFileCard(title:"PDF",description:"批注 · 页面整理 · 表单",symbol:"doc.richtext",color:.red){store.openPanel()}
                    NewFileCard(title:"Word",description:"段落编辑 · 样式 · 原格式保存",symbol:"doc.text",color:.blue){store.createOffice("docx")}
                    NewFileCard(title:"Excel",description:"工作表 · 单元格 · 常用公式",symbol:"tablecells",color:.green){store.createOffice("xlsx")}
                    NewFileCard(title:"PPT",description:"幻灯片 · 文字 · 布局",symbol:"rectangle.on.rectangle",color:.orange){store.createOffice("pptx")}
                }
                HStack{Text("最近打开").font(.headline);Spacer();Text("保留文件原来的位置").font(.caption).foregroundStyle(.secondary)}
                if store.recent.isEmpty{Text("还没有打开过文件。拖入文件，也可以从上面的按钮新建。").font(.callout).foregroundStyle(.secondary).padding(.vertical,8)}
                else{VStack(spacing:0){ForEach(Array(store.recent.prefix(8)),id:\.path){url in Button{store.open(url)}label:{HStack(spacing:12){Image(systemName:FileKind(url:url).symbol).foregroundStyle(.secondary).frame(width:22);VStack(alignment:.leading,spacing:4){Text(url.lastPathComponent).font(.callout.weight(.medium));Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1)};Spacer();Image(systemName:"arrow.up.right").font(.caption).foregroundStyle(.tertiary)}.padding(12).contentShape(Rectangle())}.buttonStyle(.plain);Divider()}}}
            }.padding(42).frame(maxWidth:1000,alignment:.leading).frame(maxWidth:.infinity)
        }
    }
    private func showStickyNotes(){NSApp.keyWindow?.makeFirstResponder(nil);store.showingNotes=true}
    private var statusBar:some View{HStack(spacing:14){Image(systemName:"internaldrive").font(.caption);Text(store.showingNotes ? stickyNotes.saveStatus : store.status).font(.caption).lineLimit(1);Spacer();if !store.showingNotes,let active=store.active{SessionStatus(session:active)};Text("本地模式").font(.caption).foregroundStyle(.secondary)}.padding(.horizontal,14).frame(height:30).background(.bar)}
}
struct SessionStatus:View{@ObservedObject var session:FileSession;var body:some View{HStack(spacing:12){if session.kind.isText{Text("\(session.text.count) 字符 · \(session.text.components(separatedBy:"\n").count) 行")};Text(session.dirty || session.moduleDirty ? "有未保存修改" : "已保存").foregroundStyle(session.dirty || session.moduleDirty ? Color.orange : .secondary)}.font(.caption)}}
struct TabButton:View{
    @ObservedObject var session:FileSession
    let selected:Bool;let select:()->Void;let close:()->Void
    var body:some View{HStack(spacing:8){Button(action:select){HStack(spacing:7){Image(systemName:session.kind.symbol);Text(session.title).lineLimit(1);if session.dirty || session.moduleDirty{Circle().fill(Color.orange).frame(width:5,height:5)}}.font(.system(size:12)).contentShape(Rectangle())}.buttonStyle(.plain);Button(action:close){Image(systemName:"xmark").font(.system(size:9,weight:.semibold)).foregroundStyle(.secondary)}.buttonStyle(.plain)}.padding(.horizontal,12).frame(height:31).background(selected ? Color(nsColor:.controlBackgroundColor):Color.clear,in:RoundedRectangle(cornerRadius:7)).overlay(RoundedRectangle(cornerRadius:7).stroke(selected ? Color.primary.opacity(0.1):.clear))}
}
struct FileRow:View{let url:URL;let directory:Bool;let depth:Int;let selected:Bool;let action:()->Void;@State private var hover=false
    var body:some View{Button(action:action){HStack(spacing:8){Image(systemName:directory ? "folder" : FileKind(url:url).symbol).frame(width:18).foregroundStyle(selected ? Color.white : .secondary);Text(url.lastPathComponent).lineLimit(1);Spacer(minLength:0)}.font(.system(size:12)).padding(.leading,10+CGFloat(depth)*10).padding(.trailing,8).frame(height:30).foregroundStyle(selected ? Color.white : .primary).background(selected ? Color(nsColor:.darkGray):Color.primary.opacity(hover ? 0.06:0),in:RoundedRectangle(cornerRadius:7)).contentShape(Rectangle())}.buttonStyle(.plain).onHover{hover=$0}.help(url.path)}
}
struct NewFileCard:View{let title:String;let description:String;let symbol:String;let color:Color;let action:()->Void;@State private var hover=false
    var body:some View{Button(action:action){VStack(alignment:.leading,spacing:13){Image(systemName:symbol).font(.system(size:23,weight:.medium)).foregroundStyle(color).frame(width:44,height:44).background(color.opacity(0.09),in:RoundedRectangle(cornerRadius:11));Text(title).font(.system(size:17,weight:.semibold));Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)}.frame(maxWidth:.infinity,minHeight:135,alignment:.leading).padding(19).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:14)).overlay(RoundedRectangle(cornerRadius:14).stroke(Color.primary.opacity(hover ? 0.22:0.075))).contentShape(RoundedRectangle(cornerRadius:14))}.buttonStyle(.plain).onHover{hover=$0}}
}
struct TabWorkspace:View{
    @ObservedObject var session:FileSession
    @ObservedObject var store:WorkspaceStore
    private var binding:Binding<String>{Binding(get:{session.text},set:{session.edited($0)})}
    var body:some View{
        Group{switch session.kind{
        case .markdown:MarkdownWorkspace(text:binding,baseURL:session.url,onError:{store.error=$0})
        case .latex:LaTeXWorkspace(text:binding,url:session.url,save:{store.save(session) ? session.url : nil},onError:{store.error=$0})
        case .csv:CSVWorkspace(text:binding,delimiter:session.url?.pathExtension.lowercased()=="tsv" ? "\t" : ",")
        case .text:SourceEditor(text:binding)
        case .pdf:if let url=session.url{PDFWorkspace(url:url,onSaved:{store.moduleDidSave(url)},onError:{store.error=$0})}
        case .word,.spreadsheet,.presentation:if let url=session.url{OfficeWorkspace(url:url,onSaved:{store.moduleDidSave(url)},onError:{store.error=$0})}
        case .richText:if let url=session.url{RichTextWorkspace(url:url,onSaved:{store.moduleDidSave(url)},onError:{store.error=$0})}
        case .image:if let url=session.url{ImageWorkspace(url:url)}
        case .other:if let url=session.url{UnsupportedWorkspace(url:url,store:store)}
        }}.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}
struct ImageWorkspace:View{let url:URL;@State private var scale=1.0;var body:some View{VStack(spacing:0){HStack{Text(url.lastPathComponent).font(.subheadline);Spacer();Slider(value:$scale,in:0.1...3).frame(width:160);Text("\(Int(scale*100))%").font(.caption.monospacedDigit());Button("在 Finder 显示"){NSWorkspace.shared.activateFileViewerSelecting([url])}}.padding(12).background(.bar);ScrollView([.horizontal,.vertical]){if let image=NSImage(contentsOf:url){Image(nsImage:image).resizable().scaledToFit().frame(width:min(image.size.width,1200)*scale).padding(24)}else{Text("无法解码这张图片").padding()}}.frame(maxWidth:.infinity,maxHeight:.infinity)}}}
struct UnsupportedWorkspace:View{let url:URL;@ObservedObject var store:WorkspaceStore;@State private var busy=false
    var body:some View{VStack(spacing:16){Image(systemName:"doc").font(.system(size:48,weight:.light)).foregroundStyle(.secondary);Text(url.lastPathComponent).font(.title2);Text("此格式可通过本机应用打开。旧版 Office 文件可转换为现代格式后编辑。原件保持在原位置。").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth:470);Button("使用系统应用打开"){NSWorkspace.shared.open(url)};if ["doc","xls","ppt","odt","ods","odp"].contains(url.pathExtension.lowercased()){Button(busy ? "正在转换…" : "转换并打开…",action:convert).disabled(busy)}}.frame(maxWidth:.infinity,maxHeight:.infinity)}
    private func convert(){let kind:[String:String]=["doc":"docx","odt":"docx","xls":"xlsx","ods":"xlsx","ppt":"pptx","odp":"pptx"];guard let format=kind[url.pathExtension.lowercased()]else{return};let p=NSSavePanel();p.nameFieldStringValue=url.deletingPathExtension().lastPathComponent+"."+format;guard p.runModal() == .OK,let out=p.url else{return};busy=true;Task{do{let converted=try await LocalTools.officeConvert(url,format:format,destination:out);store.open(converted)}catch{store.error=error.localizedDescription};busy=false}}
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
