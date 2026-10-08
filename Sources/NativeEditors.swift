import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SourceEditor:NSViewRepresentable {
    @Binding var text:String
    var language:String="text"
    @AppStorage("editorFontSize") private var size=15.0
    @AppStorage("wrapLines") private var wrap=true
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeNSView(context:Context)->NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller = !wrap;scroll.autohidesScrollers=true
        let view=NSTextView(frame:.zero);view.delegate=context.coordinator;view.isRichText=false;view.isAutomaticQuoteSubstitutionEnabled=false
        view.isAutomaticDashSubstitutionEnabled=false;view.isAutomaticTextReplacementEnabled=false;view.isAutomaticSpellingCorrectionEnabled=false
        view.isContinuousSpellCheckingEnabled=false;view.allowsUndo=true;view.usesFindBar=true;view.isIncrementalSearchingEnabled=true
        view.font = .monospacedSystemFont(ofSize:size,weight:.regular);view.textColor = .labelColor;view.backgroundColor = .textBackgroundColor
        view.textContainerInset=NSSize(width:20,height:18);view.minSize=NSSize(width:0,height:0);view.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable=true;view.isHorizontallyResizable = !wrap;view.autoresizingMask=[.width]
        view.textContainer?.widthTracksTextView=wrap;view.textContainer?.containerSize=NSSize(width:wrap ? scroll.contentSize.width : CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        view.string=text;scroll.documentView=view;context.coordinator.highlight(view);return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context){
        context.coordinator.parent=self
        guard let view=scroll.documentView as? NSTextView else{return}
        if view.string != text {let range=view.selectedRange();view.string=text;view.setSelectedRange(NSRange(location:min(range.location,(text as NSString).length),length:0));context.coordinator.highlight(view)}
        view.font = .monospacedSystemFont(ofSize:size,weight:.regular);view.textContainer?.widthTracksTextView=wrap;view.isHorizontallyResizable = !wrap;scroll.hasHorizontalScroller = !wrap
    }
    final class Coordinator:NSObject,NSTextViewDelegate {
        var parent:SourceEditor
        init(_ parent:SourceEditor){self.parent=parent}
        func textDidChange(_ notification:Notification){guard let view=notification.object as? NSTextView else{return};parent.text=view.string;highlight(view)}
        func highlight(_ view:NSTextView){
            guard let storage=view.textStorage,storage.length < 500_000 else{return}
            storage.beginEditing();storage.addAttribute(.foregroundColor,value:NSColor.labelColor,range:NSRange(location:0,length:storage.length))
            let patterns:[(String,NSColor)] = parent.language == "tex" ? [("\\\\[a-zA-Z@]+",.systemIndigo),("%[^\\n]*",.secondaryLabelColor),("\\$[^$]*\\$",.systemTeal)] : [("^#{1,6} .*$",.systemIndigo),("\\\"[^\\\"]*\\\"",.systemTeal)]
            for (pattern,color) in patterns {if let regex=try? NSRegularExpression(pattern:pattern,options:[.anchorsMatchLines]){for match in regex.matches(in:view.string,range:NSRange(location:0,length:storage.length)){storage.addAttribute(.foregroundColor,value:color,range:match.range)}}}
            storage.endEditing()
        }
    }
}

struct CSVWorkspace:View {
    @Binding var text:String
    let delimiter:Character
    @State private var rows:[[String]]=[]
    @State private var source=false
    @State private var filter=""
    @State private var selectedColumn=0
    @State private var internalUpdate=false
    var body:some View {
        VStack(spacing:0){
            HStack{
                Label("\(rows.count) 行 · \(rows.first?.count ?? 0) 列",systemImage:"tablecells").font(.subheadline)
                Spacer();TextField("筛选行",text:$filter).frame(width:170)
                Button("新增行"){rows.append(Array(repeating:"",count:rows.first?.count ?? 1));sync()}
                Button("新增列"){for i in rows.indices{rows[i].append("")};sync()}
                Button("复制 Markdown"){NSPasteboard.general.clearContents();NSPasteboard.general.setString(DelimitedText.markdown(rows),forType:.string)}
                Toggle("源码",isOn:$source).toggleStyle(.button)
            }.padding(12).background(.bar)
            if source {SourceEditor(text:$text)}
            else {ScrollView([.horizontal,.vertical]){
                LazyVStack(spacing:0){
                    HStack(spacing:0){Text("#").frame(width:46,height:30).background(Color.primary.opacity(0.06));ForEach(0..<(rows.first?.count ?? 0),id:\.self){column in
                        Button(columnName(column)){selectedColumn=column;sort(column)}.buttonStyle(.plain).frame(width:145,height:30).background(Color.primary.opacity(0.06)).help("按此列排序（保留首行）")
                    }}
                    ForEach(Array(rows.indices.prefix(1000)),id:\.self){r in
                        if filter.isEmpty || rows[r].contains(where:{$0.localizedCaseInsensitiveContains(filter)}) {
                            HStack(spacing:0){Text(String(r+1)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width:46,height:34)
                                ForEach(rows[r].indices,id:\.self){c in
                                    TextField("",text:Binding(get:{rows[r][c]},set:{rows[r][c]=$0;sync()})).textFieldStyle(.plain).padding(.horizontal,8).frame(width:145,height:34).background(r==0 ? Color.primary.opacity(0.035):Color.clear).overlay(Rectangle().stroke(Color.primary.opacity(0.09),lineWidth:0.5))
                                }
                            }
                        }
                    }
                    if rows.count>1000{Text("表格视图显示前 1000 行；源码模式保留并编辑全部数据。").font(.caption).padding()}
                }
            }.background(Color(nsColor:.textBackgroundColor))}
        }.onAppear{rows=DelimitedText.parse(text,delimiter:delimiter)}.onChange(of:text){_,value in if !internalUpdate{rows=DelimitedText.parse(value,delimiter:delimiter)}}
    }
    private func sync(){internalUpdate=true;text=DelimitedText.encode(rows,delimiter:delimiter);DispatchQueue.main.async{internalUpdate=false}}
    private func sort(_ column:Int){guard rows.count>2 else{return};let header=rows.removeFirst();rows.sort{($0[column]).localizedStandardCompare($1[column]) == .orderedAscending};rows.insert(header,at:0);sync()}
    private func columnName(_ index:Int)->String{var n=index+1;var s="";while n>0{n-=1;s=String(UnicodeScalar(65+n%26)!)+s;n/=26};return s}
}

@MainActor final class RichTextModel:ObservableObject {
    @Published var content=NSAttributedString(string:"")
    @Published var dirty=false
    @Published var loaded=false
    @Published var recoveryMessage:String?
    @Published var recoveryError:String?
    var digest:String?
    var textView:NSTextView?
    var sourceURL:URL?
    private var recoveryBlocked=false
    private var lastDraftDigest:String?
    private var discardObserver:NSObjectProtocol?
    init(){
        discardObserver=NotificationCenter.default.addObserver(forName:Notification.Name("GaoWenJian.discardDraft"),object:nil,queue:.main){[weak self] notification in
            Task{@MainActor [weak self] in
                guard let self,let path=notification.object as? String,self.sourceURL?.path==path else{return}
                do{try self.discardDraft()}catch{self.recoveryError="无法删除恢复草稿："+error.localizedDescription}
            }
        }
    }
    deinit{if let observer=discardObserver{NotificationCenter.default.removeObserver(observer)}}
    func load(_ url:URL)throws{
        if loaded && sourceURL==url{return}
        let data=try Data(contentsOf:url)
        let original=try NSAttributedString(data:data,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil)
        sourceURL=url;digest=FileSafety.digest(data);content=original;dirty=false;loaded=true
        recoveryBlocked=false;recoveryMessage=nil;recoveryError=nil;lastDraftDigest=nil
        do{
            if let recovery=try RTFRecovery.read(for:url){
                lastDraftDigest=FileSafety.digest(recovery.data)
                guard recovery.draft.baseDigest==digest else{
                    recoveryBlocked=true
                    recoveryError="原件在草稿生成后已变化，已打开当前原件并保留旧恢复草稿，未自动恢复。草稿位置："+RTFRecovery.url(for:url).path
                    return
                }
                content=recovery.content;dirty=true
                recoveryMessage="已恢复上次未保存的富文本修改，请检查后保存；原件保持原样。"
                NotificationCenter.default.post(name:Notification.Name("GaoWenJian.moduleDirty"),object:url.path,userInfo:["dirty":true])
            }
        }catch{
            recoveryBlocked=true
            recoveryError="恢复草稿无法读取，已保留并禁止覆盖该草稿。"+error.localizedDescription+" 草稿位置："+RTFRecovery.url(for:url).path
        }
    }
    func markDirty(){
        guard loaded else{return}
        dirty=true
        if let url=sourceURL{NotificationCenter.default.post(name:Notification.Name("GaoWenJian.moduleDirty"),object:url.path,userInfo:["dirty":true])}
        do{try persistDraft()}catch{recoveryBlocked=true;recoveryError="恢复草稿写入失败，已有草稿保持原样。"+error.localizedDescription}
    }
    func persistDraft()throws{
        guard loaded,!recoveryBlocked,let url=sourceURL,let digest else{return}
        let target=RTFRecovery.url(for:url)
        if FileManager.default.fileExists(atPath:target.path){
            let existing=try Data(contentsOf:target)
            guard let lastDraftDigest,FileSafety.digest(existing)==lastDraftDigest else{throw FileIssue.message("恢复草稿已被外部修改，请保留并核对。")}
            _ = try RTFRecovery.decode(existing,for:url)
        }else if lastDraftDigest != nil{throw FileIssue.message("恢复草稿已被外部删除，已停止自动覆盖。")}
        let rtf=try content.data(from:NSRange(location:0,length:content.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
        let draft=RTFRecovery.Draft(version:1,sourcePath:url.standardizedFileURL.path,baseDigest:digest,rtfDigest:FileSafety.digest(rtf),rtf:rtf,writtenAt:Date())
        let package=try JSONEncoder().encode(draft)
        try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
        try package.write(to:target,options:.atomic)
        guard try Data(contentsOf:target)==package else{throw FileIssue.message("恢复草稿校验失败。")}
        lastDraftDigest=FileSafety.digest(package)
    }
    func discardDraft()throws{
        guard let url=sourceURL else{return}
        let target=RTFRecovery.url(for:url)
        if FileManager.default.fileExists(atPath:target.path){try FileManager.default.removeItem(at:target)}
        lastDraftDigest=nil;recoveryBlocked=false;recoveryMessage=nil;recoveryError=nil
    }
    func save(_ url:URL)throws{
        guard loaded,let digest else{throw FileIssue.message("原始富文本未成功读取，已停止保存，避免覆盖真实资料。")}
        let data=try content.data(from:NSRange(location:0,length:content.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
        try FileSafety.write(data,to:url,expectedDigest:digest)
        if !recoveryBlocked{do{try discardDraft()}catch{recoveryError="文档已保存，但恢复草稿未能清理："+error.localizedDescription}}
        sourceURL=url;self.digest=FileSafety.digest(data);dirty=false;recoveryMessage=nil
        NotificationCenter.default.post(name:Notification.Name("GaoWenJian.moduleDirty"),object:url.path,userInfo:["dirty":false])
    }
    func format(_ kind:String){
        guard let view=textView,let storage=view.textStorage else{return}
        let range=view.selectedRange();guard range.length>0 else{return}
        guard view.shouldChangeText(in:range,replacementString:nil) else{return}
        let before=storage.attributedSubstring(from:range)
        view.undoManager?.registerUndo(withTarget:view){target in target.textStorage?.replaceCharacters(in:range,with:before);target.didChangeText()}
        storage.beginEditing()
        if kind=="underline" {
            let old=(storage.attribute(.underlineStyle,at:range.location,effectiveRange:nil) as? Int) ?? 0
            storage.addAttribute(.underlineStyle,value:old==0 ? NSUnderlineStyle.single.rawValue : 0,range:range)
        }else{
            let trait:NSFontTraitMask=kind=="bold" ? .boldFontMask:.italicFontMask
            storage.enumerateAttribute(.font,in:range){value,subrange,_ in
                let font=(value as? NSFont) ?? NSFont.systemFont(ofSize:15)
                let active=NSFontManager.shared.traits(of:font).contains(trait)
                let converted=active ? NSFontManager.shared.convert(font,toNotHaveTrait:trait):NSFontManager.shared.convert(font,toHaveTrait:trait)
                storage.addAttribute(.font,value:converted,range:subrange)
            }
        }
        storage.endEditing();view.didChangeText()
    }
}

enum RTFRecovery {
    struct Draft:Codable {
        let version:Int
        let sourcePath:String
        let baseDigest:String
        let rtfDigest:String
        let rtf:Data
        let writtenAt:Date
    }
    struct Recovered {let draft:Draft;let content:NSAttributedString;let data:Data}
    static func url(for original:URL)->URL{
        let key=FileSafety.digest(Data(original.standardizedFileURL.path.utf8)).prefix(24)
        return FileSafety.root.appendingPathComponent("Recovery/RTF",isDirectory:true).appendingPathComponent(key+".json")
    }
    static func read(for original:URL)throws->Recovered?{
        let path=url(for:original)
        guard FileManager.default.fileExists(atPath:path.path)else{return nil}
        return try decode(Data(contentsOf:path),for:original)
    }
    static func decode(_ data:Data,for original:URL)throws->Recovered{
        let draft=try JSONDecoder().decode(Draft.self,from:data)
        guard draft.version==1,draft.sourcePath==original.standardizedFileURL.path,draft.baseDigest.count==64,draft.rtfDigest==FileSafety.digest(draft.rtf),draft.rtf.starts(with:Data("{\\rtf".utf8))else{throw FileIssue.message("草稿版本、原件路径或校验摘要不一致。")}
        let content=try NSAttributedString(data:draft.rtf,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil)
        return Recovered(draft:draft,content:content,data:data)
    }
}
struct RichTextWorkspace:View {
    let url:URL
    let onSaved:()->Void
    let onError:(String)->Void
    @StateObject private var model=RichTextModel()
    var body:some View{VStack(spacing:0){
        HStack{Label("RTF 富文本",systemImage:"doc.text");Spacer();Button("字体"){NSFontManager.shared.orderFrontFontPanel(nil)};Button("加粗"){model.format("bold")};Button("斜体"){model.format("italic")};Button("下划线"){model.format("underline")};Button("保存",action:save).disabled(!model.loaded)}.padding(12).background(.bar)
        if let message=model.recoveryMessage{Label(message,systemImage:"arrow.counterclockwise").font(.caption).padding(10).frame(maxWidth:.infinity,alignment:.leading).background(Color.orange.opacity(0.1))}
        if let error=model.recoveryError{Label(error,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(10).frame(maxWidth:.infinity,alignment:.leading)}
        RichEditor(model:model).disabled(!model.loaded)
    }.onAppear{do{try model.load(url)}catch{onError(error.localizedDescription)}}.onChange(of:model.recoveryError){_,error in if let error{onError(error)}}.onChange(of:model.dirty){_,dirty in NotificationCenter.default.post(name:Notification.Name("GaoWenJian.moduleDirty"),object:url.path,userInfo:["dirty":dirty])}.onReceive(NotificationCenter.default.publisher(for:Notification.Name("GaoWenJian.saveActive"))){if $0.object as? String==url.path{save()}}}
    func save(){do{try model.save(url);onSaved()}catch{onError(error.localizedDescription)}}
}
struct RichEditor:NSViewRepresentable {
    @ObservedObject var model:RichTextModel
    func makeCoordinator()->Coordinator{Coordinator(model)}
    func makeNSView(context:Context)->NSScrollView{let s=NSScrollView();s.hasVerticalScroller=true;let v=NSTextView();v.isRichText=true;v.allowsUndo=true;v.usesFindBar=true;v.textContainerInset=NSSize(width:36,height:24);v.autoresizingMask=[.width];v.isVerticallyResizable=true;v.textContainer?.widthTracksTextView=true;v.delegate=context.coordinator;v.textStorage?.setAttributedString(model.content);model.textView=v;s.documentView=v;return s}
    func updateNSView(_ s:NSScrollView,context:Context){guard let v=s.documentView as? NSTextView else{return};if !v.attributedString().isEqual(to:model.content){v.textStorage?.setAttributedString(model.content)}}
    final class Coordinator:NSObject,NSTextViewDelegate{let model:RichTextModel;init(_ m:RichTextModel){model=m};func textDidChange(_ n:Notification){guard let v=n.object as? NSTextView else{return};model.content=v.attributedString();model.markDirty()}}
}
