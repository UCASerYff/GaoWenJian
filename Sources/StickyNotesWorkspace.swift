import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension StickyNoteColor {
    var displayName:String {
        switch self {case .yellow:return "黄色";case .blue:return "蓝色";case .green:return "绿色";case .pink:return "粉色";case .purple:return "紫色";case .gray:return "灰色"}
    }
    var paperColor:NSColor {
        let components:(CGFloat,CGFloat,CGFloat)
        switch self {
        case .yellow:components=(1,0.96,0.72)
        case .blue:components=(0.80,0.91,1)
        case .green:components=(0.84,0.95,0.79)
        case .pink:components=(1,0.85,0.88)
        case .purple:components=(0.91,0.86,0.99)
        case .gray:components=(0.91,0.91,0.89)
        }
        return NSColor(srgbRed:components.0,green:components.1,blue:components.2,alpha:1)
    }
    static var palette:[StickyNoteColor] {[.yellow,.blue,.green,.pink,.purple,.gray]}
}

struct StickyNotesWorkspace:View {
    @ObservedObject var store:StickyNotesStore
    var windows:StickyNotesWindowManager?
    var onOpenMarkdown:(String)->Void = {_ in}
    @State private var selected:UUID?
    @State private var search=""
    @State private var groupFilter=""
    @State private var colorFilter=""
    @State private var sort="updated"
    @State private var showTrash=false

    private var groups:[String] {Array(Set(store.notes.filter{$0.deletedAt == nil}.map(\.group).filter{!$0.isEmpty})).sorted()}
    private var filtered:[StickyNote] {
        let result=store.notes.filter {note in
            (showTrash ? note.deletedAt != nil : note.deletedAt == nil) &&
            (groupFilter.isEmpty || note.group == groupFilter) &&
            (colorFilter.isEmpty || note.color.rawValue == colorFilter) &&
            (search.isEmpty || note.title.localizedCaseInsensitiveContains(search) || note.plainText.localizedCaseInsensitiveContains(search) || note.group.localizedCaseInsensitiveContains(search))
        }
        return result.sorted {a,b in
            if sort == "title" {return a.title.localizedStandardCompare(b.title) == .orderedAscending}
            if sort == "created" {return a.createdAt>b.createdAt}
            return a.updatedAt>b.updatedAt
        }
    }
    var body:some View {
        VStack(spacing:0) {
            header
            if let error=store.error{StickySaveErrorBanner(message:error,retry:{NSApp.keyWindow?.makeFirstResponder(nil);_ = store.flush()},dismiss:{store.error=nil})}
            Divider()
            HSplitView {
                browser.frame(minWidth:230,idealWidth:270,maxWidth:360)
                detail.frame(minWidth:430,maxWidth:.infinity,maxHeight:.infinity)
            }
        }
        .onAppear{ensureSelection()}
        .onReceive(store.$notes){_ in DispatchQueue.main.async{ensureSelection()}}
        .onChange(of:showTrash){_,_ in selected=nil;ensureSelection()}
        .onChange(of:search){_,_ in ensureSelection()}
        .onChange(of:groupFilter){_,_ in ensureSelection()}
        .onChange(of:colorFilter){_,_ in ensureSelection()}
    }
    private var header:some View {
        HStack(spacing:12) {
            Label("便笺",systemImage:"note.text").font(.headline)
            Text("随手记下，留在桌面").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button{windows?.arrangeDesktopWindows()}label:{Label("排列桌面",systemImage:"square.grid.2x2")}.disabled(!store.notes.contains{$0.isOnDesktop && $0.deletedAt == nil})
            Button{importNotes()}label:{Label("导入",systemImage:"square.and.arrow.down")}
            Button{newNote()}label:{Label("新建便笺",systemImage:"plus")}.buttonStyle(.borderedProminent).tint(Color(nsColor:.darkGray))
        }.padding(.horizontal,18).padding(.vertical,12).background(.bar)
    }
    private var browser:some View {
        VStack(alignment:.leading,spacing:12) {
            TextField("搜索内容、标题或分组",text:$search).textFieldStyle(.roundedBorder)
            HStack {
                Picker("分组",selection:$groupFilter){Text("全部分组").tag("");ForEach(groups,id:\.self){Text($0).tag($0)}}.labelsHidden()
                Picker("颜色",selection:$colorFilter){Text("全部颜色").tag("");ForEach(StickyNoteColor.palette,id:\.rawValue){Text($0.displayName).tag($0.rawValue)}}.labelsHidden()
            }
            HStack {
                Picker("排序",selection:$sort){Text("最近编辑").tag("updated");Text("新建时间").tag("created");Text("标题").tag("title")}.labelsHidden()
                Spacer()
                Text("\(filtered.count) 条").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing:8) {
                    ForEach(filtered) {note in StickyNoteListCard(note:note,selected:selected == note.id){NSApp.keyWindow?.makeFirstResponder(nil);selected=note.id}}
                    if filtered.isEmpty {Text(showTrash ? "回收站为空" : "没有找到便笺").font(.callout).foregroundStyle(.secondary).padding(.vertical,32)}
                }
            }
            Divider()
            Button{showTrash.toggle()}label:{HStack{Label(showTrash ? "返回全部便笺" : "回收站",systemImage:showTrash ? "note.text" : "trash");Spacer();if !showTrash{Text("\(store.notes.filter{$0.deletedAt != nil}.count)").foregroundStyle(.secondary)}}}.buttonStyle(.plain).font(.callout)
            Label("自动保存到本机",systemImage:"internaldrive").font(.caption).foregroundStyle(.secondary)
        }.padding(16).background(Color(nsColor:.windowBackgroundColor))
    }
    @ViewBuilder private var detail:some View {
        if let id=selected,let note=store.notes.first(where:{$0.id==id}) {
            StickyNoteDetail(store:store,noteID:id,desktop:false,onDesktop:{windows?.show(noteID:id)},onOpenMarkdown:onOpenMarkdown)
                .id(id)
                .overlay(alignment:.topTrailing){if note.deletedAt != nil{EmptyView()}}
        } else {
            VStack(spacing:16) {
                Image(systemName:"note.text").font(.system(size:46,weight:.light)).foregroundStyle(.tertiary)
                Text("用便笺留住片刻的想法").font(.title3)
                Text("富文本、图片和附件一起保存。\n可以置顶、透明显示，或收成一条标题。").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
                Button("新建便笺",action:newNote)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
    private func ensureSelection(){if selected == nil || !filtered.contains(where:{$0.id == selected}){NSApp.keyWindow?.makeFirstResponder(nil);selected=filtered.first?.id}}
    private func newNote(){NSApp.keyWindow?.makeFirstResponder(nil);showTrash=false;search="";groupFilter="";colorFilter="";if let id=store.create(){selected=id}}
    private func importNotes(){
        NSApp.keyWindow?.makeFirstResponder(nil)
        let panel=NSOpenPanel();panel.title="导入文本或富文本便笺";panel.allowedContentTypes=[.plainText,.rtf,.rtfd];panel.allowsMultipleSelection=true;panel.canChooseDirectories=false;panel.treatsFilePackagesAsDirectories=false
        guard panel.runModal() == .OK else{return}
        for url in panel.urls {do{selected=try store.importNote(from:url);showTrash=false;search="";groupFilter="";colorFilter=""}catch{store.error="导入未完成："+error.localizedDescription;break}}
    }
}

private struct StickyNoteListCard:View {
    let note:StickyNote;let selected:Bool;let action:()->Void
    var body:some View {
        Button(action:action) {
            HStack(alignment:.top,spacing:10) {
                RoundedRectangle(cornerRadius:3).fill(Color(nsColor:note.color.paperColor)).frame(width:5)
                VStack(alignment:.leading,spacing:6) {
                    HStack{Text(note.title.isEmpty ? "未命名便笺" : note.title).font(.callout.weight(.semibold)).lineLimit(1);Spacer();if note.isOnDesktop{Image(systemName:"macwindow").font(.caption)};if note.isPinned{Image(systemName:"pin.fill").font(.caption)}}
                    Text(note.plainText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "空白便笺" : note.plainText.replacingOccurrences(of:"\u{fffc}",with:"[附件]")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack{if !note.group.isEmpty{Text(note.group).lineLimit(1)};Spacer();Text(note.updatedAt,style:.date)}.font(.system(size:10)).foregroundStyle(.tertiary)
                }
            }.padding(12).frame(maxWidth:.infinity,minHeight:91,alignment:.leading)
                .background(selected ? Color.primary.opacity(0.08):Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:10))
                .overlay(RoundedRectangle(cornerRadius:10).stroke(Color.primary.opacity(selected ? 0.2:0.06)))
                .contentShape(RoundedRectangle(cornerRadius:10))
        }.buttonStyle(.plain)
    }
}

struct StickyNoteDetail:View {
    @ObservedObject var store:StickyNotesStore
    let noteID:UUID
    let desktop:Bool
    var onDesktop:()->Void = {}
    var onOpenMarkdown:(String)->Void = {_ in}
    var onCollapse:()->Void = {}
    @StateObject private var editor=StickyRichEditorSession()
    private var note:StickyNote? {store.notes.first{$0.id==noteID}}
    var body:some View {
        Group {
            if let note {
                VStack(spacing:0) {
                    if !desktop {metadata(note);Divider()}
                    if desktop,let error=store.error{StickySaveErrorBanner(message:error,retry:{commitEditor();_ = store.flush()},dismiss:{store.error=nil})}
                    if note.deletedAt != nil {trashBanner}
                    if !note.isCollapsed || !desktop {
                        formatting(note)
                        StickyRichTextEditor(store:store,noteID:noteID,session:editor,editable:note.deletedAt == nil)
                            .frame(maxWidth:.infinity,maxHeight:.infinity)
                        footer(note)
                    }
                }.background(Color(nsColor:note.color.paperColor))
            } else {Text("这条便笺无法读取").foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)}
        }
    }
    private func metadata(_ note:StickyNote)->some View {
        VStack(alignment:.leading,spacing:11) {
            HStack {
                TextField("便笺标题",text:Binding(get:{self.note?.title ?? ""},set:{title in _ = store.updateMetadata(id:noteID){$0.title=title}})).font(.system(size:19,weight:.semibold)).textFieldStyle(.plain).disabled(note.deletedAt != nil)
                Spacer()
                if note.deletedAt == nil {Button(action:onDesktop){Label("放到桌面",systemImage:"macwindow")}}
                Menu {
                    Button("导出纯文本…"){export(.txt)}
                    Button("导出 RTF…"){export(.rtf)}
                    Button("导出 RTFD（含附件）…"){export(.rtfd)}
                    Divider()
                    Button("复制为 Markdown（附件仅标注）"){copyMarkdown()}
                    Button("送入 Markdown 工作台（附件仅标注）"){onOpenMarkdown(markdown())}
                    if note.deletedAt == nil {Divider();Button("设为新便笺默认样式"){_ = store.setDefaults(from:noteID)};Button("移到回收站…",role:.destructive){trash()}}
                }label:{Image(systemName:"ellipsis.circle")}.menuStyle(.borderlessButton).fixedSize()
            }
            HStack(spacing:12) {
                HStack(spacing:6){ForEach(StickyNoteColor.palette,id:\.rawValue){color in colorButton(color,selected:note.color==color)}}
                TextField("分组（可选）",text:Binding(get:{self.note?.group ?? ""},set:{group in _ = store.updateMetadata(id:noteID){$0.group=group}})).textFieldStyle(.plain).font(.caption).frame(maxWidth:180).disabled(note.deletedAt != nil)
                Spacer()
                Toggle("置顶",isOn:metadataBinding(\.isPinned)).toggleStyle(.button).help("桌面便笺显示在其他窗口上方").disabled(note.deletedAt != nil)
                Toggle("透明",isOn:metadataBinding(\.isTranslucent)).toggleStyle(.button).help("桌面便笺半透明显示").disabled(note.deletedAt != nil)
            }
        }.padding(.horizontal,20).padding(.vertical,16).foregroundStyle(Color(nsColor:.black))
    }
    private var trashBanner:some View {
        HStack{Label("便笺在回收站中，内容保留",systemImage:"trash");Spacer();Button("恢复便笺"){_ = store.restore(id:noteID)}}.font(.callout).padding(12).background(Color.black.opacity(0.06)).foregroundStyle(Color(nsColor:.black))
    }
    private func formatting(_ note:StickyNote)->some View {
        HStack(spacing:10) {
            Button{editor.fontPanel()}label:{Image(systemName:"textformat")}.help("字体与字号")
            Button{editor.format("bold")}label:{Image(systemName:"bold")}.help("加粗")
            Button{editor.format("italic")}label:{Image(systemName:"italic")}.help("斜体")
            Button{editor.format("underline")}label:{Image(systemName:"underline")}.help("下划线")
            Button{editor.format("strike")}label:{Image(systemName:"strikethrough")}.help("删除线")
            Button{editor.bullet()}label:{Image(systemName:"list.bullet")}.help("项目符号")
            Button{editor.insertAttachment()}label:{Image(systemName:"paperclip")}.help("插入图片或文件附件")
            Button{editor.find()}label:{Image(systemName:"magnifyingglass")}.help("查找与替换当前便笺")
            Spacer(minLength:0)
            if desktop {
                Menu {
                    ForEach(StickyNoteColor.palette,id:\.rawValue){color in Button(color.displayName){_ = store.updateMetadata(id:noteID){$0.color=color}}}
                    Divider()
                    Button(note.isPinned ? "取消置顶" : "置顶显示"){_ = store.updateMetadata(id:noteID){$0.isPinned.toggle()}}
                    Button(note.isTranslucent ? "取消透明" : "透明显示"){_ = store.updateMetadata(id:noteID){$0.isTranslucent.toggle()}}
                    Button("收起为标题",action:onCollapse)
                    Button("设为新便笺默认样式"){_ = store.setDefaults(from:noteID)}
                    Divider()
                    Button("导出 RTFD…"){export(.rtfd)}
                    Button("复制为 Markdown（附件仅标注）"){copyMarkdown()}
                    Divider();Button("移到回收站…",role:.destructive){trash()}
                }label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).fixedSize()
            }
        }.buttonStyle(.plain).font(.system(size:12)).padding(.horizontal,desktop ? 12:20).frame(height:36).foregroundStyle(Color(nsColor:.black)).background(Color.black.opacity(0.025)).disabled(note.deletedAt != nil)
    }
    private func footer(_ note:StickyNote)->some View {
        HStack(spacing:8) {
            Text("\(note.plainText.replacingOccurrences(of:"\u{fffc}",with:"").count) 字")
            Spacer()
            if store.isDirty {Button(store.error == nil ? "立即保存":"重试保存"){commitEditor();_ = store.flush()}.buttonStyle(.plain).underline().help("立即保存尚未落盘的便笺")}
            Label(store.saveStatus,systemImage:store.isDirty ? "clock" : "checkmark.circle").lineLimit(1)
        }.font(.system(size:10)).padding(.horizontal,desktop ? 12:20).frame(height:27).foregroundStyle(Color(nsColor:.black).opacity(0.6)).background(Color.black.opacity(0.025))
    }
    private func metadataBinding(_ path:WritableKeyPath<StickyNote,Bool>)->Binding<Bool>{Binding(get:{note?[keyPath:path] ?? false},set:{value in _ = store.updateMetadata(id:noteID){$0[keyPath:path]=value}})}
    private func colorButton(_ color:StickyNoteColor,selected:Bool)->some View {
        Button{_ = store.updateMetadata(id:noteID){$0.color=color}}label:{
            Circle().fill(Color(nsColor:color.paperColor)).frame(width:19,height:19)
                .overlay(Circle().stroke(Color.black.opacity(selected ? 0.8:0.2),lineWidth:selected ? 2:1))
                .overlay{if selected{Image(systemName:"checkmark").font(.system(size:9,weight:.bold)).foregroundStyle(.black)}}
        }.buttonStyle(.plain).help(color.displayName+"便笺").accessibilityLabel(color.displayName+"便笺").disabled(note?.deletedAt != nil)
    }
    private func trash(){
        commitEditor()
        let alert=NSAlert();alert.messageText="将便笺移到回收站？";alert.informativeText="内容和附件会保留，可以在便笺回收站恢复。桌面窗口会同时隐藏。";alert.addButton(withTitle:"移到回收站");alert.addButton(withTitle:"取消")
        if alert.runModal() == .alertFirstButtonReturn{_ = store.trash(id:noteID)}
    }
    private func export(_ format:StickyNoteExportFormat){
        commitEditor()
        let panel=NSSavePanel();let ext:String
        switch format {case .txt:ext="txt";case .rtf:ext="rtf";case .rtfd:ext="rtfd"}
        panel.title="导出便笺";panel.nameFieldStringValue=(note?.title.isEmpty == false ? note!.title:"便笺")+"."+ext;panel.allowedContentTypes=[UTType(filenameExtension:ext) ?? .data];panel.canCreateDirectories=true
        if format == .txt{panel.message="导出文字副本，不包含富文本格式与附件。原便笺和附件完整保留。"}
        if format == .rtfd{panel.message="保存完整富文本与嵌入附件。"}
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {
            let expected=try StickyNotesStore.destinationDigest(at:url)
            try store.exportNote(id:noteID,to:url,format:format,expectedDigest:expected)
        } catch {store.error="导出未完成："+error.localizedDescription}
    }
    private func commitEditor(){guard note?.deletedAt == nil,let view=editor.textView else{return};if view.hasMarkedText(){view.unmarkText()};_ = store.updateContent(id:noteID,content:view.attributedString());view.window?.makeFirstResponder(nil)}
    private func markdown()->String{commitEditor();guard let content=store.content(for:noteID)else{return ""};return StickyMarkdown.text(content,title:note?.title ?? "")}
    private func copyMarkdown(){NSPasteboard.general.clearContents();NSPasteboard.general.setString(markdown(),forType:.string)}
}

@MainActor final class StickyRichEditorSession:ObservableObject {
    weak var textView:NSTextView?
    func focus(){if let view=textView{view.window?.makeFirstResponder(view)}}
    func fontPanel(){guard let view=textView else{return};focus();NSFontManager.shared.setSelectedFont(view.font ?? NSFont.systemFont(ofSize:15),isMultiple:false);NSFontManager.shared.orderFrontFontPanel(nil)}
    func find(){guard let view=textView else{return};focus();view.performFindPanelAction(StickyFindSender())}
    func format(_ kind:String){
        guard let view=textView,let storage=view.textStorage else{return};focus()
        let range=view.selectedRange()
        if range.length == 0 {
            var attrs=view.typingAttributes;let font=attrs[.font] as? NSFont ?? .systemFont(ofSize:15)
            if kind == "bold" || kind == "italic" {let trait:NSFontTraitMask=kind == "bold" ? .boldFontMask:.italicFontMask;let has=NSFontManager.shared.traits(of:font).contains(trait);attrs[.font]=has ? NSFontManager.shared.convert(font,toNotHaveTrait:trait):NSFontManager.shared.convert(font,toHaveTrait:trait)}
            else {let key:NSAttributedString.Key=kind == "strike" ? .strikethroughStyle:.underlineStyle;attrs[key]=(attrs[key] as? Int ?? 0)==0 ? NSUnderlineStyle.single.rawValue:0}
            view.typingAttributes=attrs;return
        }
        let before=storage.attributedSubstring(from:range)
        let replacement=NSMutableAttributedString(attributedString:before)
        if kind == "bold" || kind == "italic" {
            let trait:NSFontTraitMask=kind == "bold" ? .boldFontMask:.italicFontMask
            let font=storage.attribute(.font,at:range.location,effectiveRange:nil) as? NSFont ?? .systemFont(ofSize:15)
            let removing=NSFontManager.shared.traits(of:font).contains(trait)
            before.enumerateAttribute(.font,in:NSRange(location:0,length:before.length)){value,part,_ in let current=value as? NSFont ?? .systemFont(ofSize:15);let converted=removing ? NSFontManager.shared.convert(current,toNotHaveTrait:trait):NSFontManager.shared.convert(current,toHaveTrait:trait);replacement.addAttribute(.font,value:converted,range:part)}
        } else {
            let key:NSAttributedString.Key=kind == "strike" ? .strikethroughStyle:.underlineStyle
            let removing=(storage.attribute(key,at:range.location,effectiveRange:nil) as? Int ?? 0) != 0
            replacement.addAttribute(key,value:removing ? 0:NSUnderlineStyle.single.rawValue,range:NSRange(location:0,length:replacement.length))
        }
        Self.replace(view,range:range,with:replacement)
    }
    func bullet(){
        guard let view=textView,let storage=view.textStorage else{return};focus()
        let range=(view.string as NSString).paragraphRange(for:view.selectedRange());let before=storage.attributedSubstring(from:range)
        let replacement=NSMutableAttributedString(attributedString:before);let text=before.string as NSString
        var offsets:[Int]=[0];if text.length>0{for index in 0..<text.length where text.character(at:index)==10 && index+1<text.length{offsets.append(index+1)}}
        for offset in offsets.reversed(){if offset+2<=replacement.length && (replacement.string as NSString).substring(with:NSRange(location:offset,length:2)) == "• "{replacement.deleteCharacters(in:NSRange(location:offset,length:2))}else{replacement.insert(NSAttributedString(string:"• ",attributes:view.typingAttributes),at:offset)}}
        Self.replace(view,range:range,with:replacement)
    }
    private static func replace(_ view:NSTextView,range:NSRange,with replacement:NSAttributedString){
        guard let storage=view.textStorage,NSMaxRange(range)<=storage.length else{return}
        // NSTextView registers the changed range and its attributed contents for native undo/redo.
        // An extra manual undo entry would duplicate AppKit's entry and corrupt length-changing edits.
        view.insertText(replacement,replacementRange:range)
        view.setSelectedRange(NSRange(location:range.location,length:replacement.length))
    }
    func insertAttachment(){
        guard let view=textView else{return};let panel=NSOpenPanel();panel.title="插入图片或文件附件";panel.allowsMultipleSelection=true;panel.canChooseDirectories=false
        guard panel.runModal() == .OK else{return};focus()
        for url in panel.urls {
            do{let wrapper=try FileWrapper(url:url,options:.immediate);let attachment=NSTextAttachment(fileWrapper:wrapper);view.insertText(NSAttributedString(attachment:attachment),replacementRange:view.selectedRange())}
            catch{let alert=NSAlert(error:error);alert.runModal()}
        }
    }
}

private final class StickyFindSender:NSObject {@objc var tag:Int {NSTextFinder.Action.showReplaceInterface.rawValue}}

private struct StickySaveErrorBanner:View {
    let message:String;let retry:()->Void;let dismiss:()->Void
    var body:some View {
        HStack(alignment:.top,spacing:10){Image(systemName:"exclamationmark.triangle");Text(message).font(.caption).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading);Button("重试保存",action:retry);Button(action:dismiss){Image(systemName:"xmark")}.buttonStyle(.plain)}.font(.caption).padding(12).foregroundStyle(Color(nsColor:.black)).background(Color.orange.opacity(0.18))
    }
}

@MainActor class StickyNativeTextView:NSTextView {
    private(set) var isUpdatingMarkedText=false
    private var undoObservers:[NSObjectProtocol]=[]
    private weak var observedUndoManager:UndoManager?
    override func viewDidMoveToWindow(){
        super.viewDidMoveToWindow()
        observeUndoIfNeeded()
    }
    func observeUndoIfNeeded(){
        let manager=window == nil ? nil:undoManager
        if let manager,manager === observedUndoManager{return}
        for observer in undoObservers{NotificationCenter.default.removeObserver(observer)}
        undoObservers=[];observedUndoManager=manager
        guard let manager else{return}
        for name in [Notification.Name.NSUndoManagerDidUndoChange,Notification.Name.NSUndoManagerDidRedoChange] {
            undoObservers.append(NotificationCenter.default.addObserver(forName:name,object:manager,queue:.main){[weak self] _ in
                MainActor.assumeIsolated{guard let self else{return};self.delegate?.textDidChange?(Notification(name:NSText.didChangeNotification,object:self))}
            })
        }
    }
    deinit{for observer in undoObservers{NotificationCenter.default.removeObserver(observer)}}
    override func setMarkedText(_ string:Any,selectedRange:NSRange,replacementRange:NSRange){
        // AppKit can send textDidChange before it publishes the first marked range.
        isUpdatingMarkedText=true
        defer{isUpdatingMarkedText=false}
        super.setMarkedText(string,selectedRange:selectedRange,replacementRange:replacementRange)
    }
}

struct StickyRichTextEditor:NSViewRepresentable {
    @ObservedObject var store:StickyNotesStore
    let noteID:UUID
    @ObservedObject var session:StickyRichEditorSession
    var editable=true
    func makeCoordinator()->Coordinator{Coordinator(self)}
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.drawsBackground=false
        let view=StickyNativeTextView(frame:.zero);view.isRichText=true;view.importsGraphics=true;view.allowsUndo=true;view.usesFindBar=true;view.isIncrementalSearchingEnabled=true;view.isAutomaticSpellingCorrectionEnabled=false;view.isContinuousSpellCheckingEnabled=true;view.drawsBackground=false;view.font = .systemFont(ofSize:15);view.textColor = .black;view.typingAttributes=[.font:NSFont.systemFont(ofSize:15),.foregroundColor:NSColor.black]
        if let font=NSFont(name:store.defaults.fontName,size:store.defaults.fontSize){view.font=font;view.typingAttributes=[.font:font,.foregroundColor:NSColor.black]}
        view.textContainerInset=NSSize(width:20,height:16);view.minSize = .zero;view.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude);view.isVerticallyResizable=true;view.isHorizontallyResizable=false;view.autoresizingMask=[.width];view.textContainer?.widthTracksTextView=true;view.textContainer?.containerSize=NSSize(width:scroll.contentSize.width,height:CGFloat.greatestFiniteMagnitude)
        view.textStorage?.setAttributedString(store.content(for:noteID) ?? NSAttributedString(string:""));view.isEditable=editable;view.delegate=context.coordinator;session.textView=view;scroll.documentView=view;return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context){
        context.coordinator.parent=self
        guard let view=scroll.documentView as? NSTextView else{return};session.textView=view;view.isEditable=editable
        if !view.hasMarkedText(),(view as? StickyNativeTextView)?.isUpdatingMarkedText != true,let content=store.content(for:noteID),!view.attributedString().isEqual(to:content){let selection=view.selectedRange();view.undoManager?.disableUndoRegistration();view.textStorage?.setAttributedString(content);view.undoManager?.enableUndoRegistration();view.undoManager?.removeAllActions();view.setSelectedRange(NSRange(location:min(selection.location,content.length),length:0))}
    }
    @MainActor final class Coordinator:NSObject,NSTextViewDelegate {
        var parent:StickyRichTextEditor
        init(_ parent:StickyRichTextEditor){self.parent=parent}
        private var canSave:Bool {parent.editable && parent.store.notes.contains{$0.id==parent.noteID && $0.deletedAt == nil}}
        func textDidChange(_ notification:Notification){guard let view=notification.object as? NSTextView else{return};(view as? StickyNativeTextView)?.observeUndoIfNeeded();guard canSave,!view.hasMarkedText(),(view as? StickyNativeTextView)?.isUpdatingMarkedText != true else{return};_ = parent.store.updateContent(id:parent.noteID,content:view.attributedString())}
        func textDidEndEditing(_ notification:Notification){guard canSave,let view=notification.object as? NSTextView,(view as? StickyNativeTextView)?.isUpdatingMarkedText != true else{return};if view.hasMarkedText(){view.unmarkText()};_ = parent.store.updateContent(id:parent.noteID,content:view.attributedString())}
    }
}

enum StickyMarkdown {
    static func text(_ content:NSAttributedString,title:String)->String {
        var output=""
        content.enumerateAttributes(in:NSRange(location:0,length:content.length)) {attrs,range,_ in
            let text=(content.string as NSString).substring(with:range)
            if let attachment=attrs[.attachment] as? NSTextAttachment {output += "[附件："+(attachment.fileWrapper?.preferredFilename ?? attachment.fileWrapper?.filename ?? "附件")+"]";return}
            var part=text
            if let url=attrs[.link] {part="["+part+"]("+String(describing:url)+")"}
            if let font=attrs[.font] as? NSFont {let traits=NSFontManager.shared.traits(of:font);if traits.contains(.boldFontMask){part="**"+part+"**"};if traits.contains(.italicFontMask){part="*"+part+"*"}}
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 {part="~~"+part+"~~"}
            output += part
        }
        output=output.replacingOccurrences(of:"• ",with:"- ")
        let heading=title.trimmingCharacters(in:.whitespacesAndNewlines)
        return (heading.isEmpty ? "":"# "+heading+"\n\n")+output
    }
}
