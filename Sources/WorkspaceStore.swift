import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum FileKind: String, CaseIterable {
    case markdown, latex, pdf, word, spreadsheet, presentation, csv, text, image, richText, other
    init(url:URL) {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": self = .markdown
        case "tex", "bib", "sty", "cls": self = .latex
        case "pdf": self = .pdf
        case "docx": self = .word
        case "xlsx": self = .spreadsheet
        case "pptx": self = .presentation
        case "csv", "tsv": self = .csv
        case "rtf": self = .richText
        case "txt", "json", "xml", "yaml", "yml", "html", "css", "js", "swift", "py", "r", "log", "sh": self = .text
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "svg": self = .image
        default: self = .other
        }
    }
    var title:String { switch self {
        case .markdown:return "Markdown"; case .latex:return "LaTeX"; case .pdf:return "PDF"; case .word:return "Word"
        case .spreadsheet:return "Excel"; case .presentation:return "PPT"; case .csv:return "CSV / TSV";case .text:return "文本"
        case .image:return "图片";case .richText:return "富文本";case .other:return "其他文件"
    }}
    var symbol:String { switch self {
        case .markdown:return "text.badge.checkmark"; case .latex:return "function"; case .pdf:return "doc.richtext"
        case .word,.richText:return "doc.text";case .spreadsheet,.csv:return "tablecells";case .presentation:return "rectangle.on.rectangle"
        case .text:return "curlybraces";case .image:return "photo";case .other:return "doc"
    }}
    var isText:Bool { [.markdown,.latex,.csv,.text].contains(self) }
}

@MainActor final class FileSession:ObservableObject,Identifiable {
    let id:UUID
    @Published var url:URL?
    @Published var text:String
    @Published var dirty:Bool
    @Published var moduleDirty = false
    var kind:FileKind
    var originalDigest:String?
    var encoding:String.Encoding = .utf8
    var savedText:String
    var restoredDraft=false
    var title:String { url?.lastPathComponent ?? "未命名." + suggestedExtension }
    var suggestedExtension:String { switch kind {case .markdown:return "md";case .latex:return "tex";case .csv:return "csv";default:return "txt"} }
    init(id:UUID=UUID(),url:URL?=nil,text:String="",kind:FileKind = .markdown,dirty:Bool=false) {
        self.id=id;self.url=url;self.text=text;self.kind=kind;self.dirty=dirty;self.savedText=text
    }
    func edited(_ value:String) { text=value;dirty = restoredDraft || value != savedText }
}
struct BrowserEntry:Identifiable { var url:URL;var directory:Bool;var depth:Int;var id:String {url.path} }
private struct WorkspaceState:Codable { var recent:[String] = [];var folder:String? }
private struct RecoveryItem:Codable { var id:UUID;var path:String?;var kind:String;var text:String;var digest:String?;var encoding:UInt }

@MainActor final class WorkspaceStore:ObservableObject {
    @Published var tabs:[FileSession] = []
    @Published var selection:UUID?
    @Published var folder:URL?
    @Published var entries:[BrowserEntry] = []
    @Published var recent:[URL] = []
    @Published var error:String?
    @Published var status = "文件仅保存在本机"
    @Published var restoredCount = 0
    @Published var showingNotes = false
    private var stateReadable = true
    private var recoveryReadable = true
    private var timer:Timer?
    var active:FileSession? { tabs.first {$0.id == selection} }
    init() {
        do {
            try FileManager.default.createDirectory(at:FileSafety.root,withIntermediateDirectories:true)
            let stateURL=FileSafety.root.appendingPathComponent("workspace.json")
            if FileManager.default.fileExists(atPath:stateURL.path) {
                do {
                    let state=try JSONDecoder().decode(WorkspaceState.self,from:Data(contentsOf:stateURL));recent=state.recent.map{URL(fileURLWithPath:$0)}
                    if let path=state.folder, FileManager.default.fileExists(atPath:path) {folder=URL(fileURLWithPath:path); refreshFolder()}
                } catch {stateReadable=false;self.error="工作区记录无法读取，已保留原文件：\(error.localizedDescription)"}
            }
            let recoveryURL=FileSafety.root.appendingPathComponent("recovery.json")
            if FileManager.default.fileExists(atPath:recoveryURL.path) {
                do {
                    let recovered=try JSONDecoder().decode([RecoveryItem].self,from:Data(contentsOf:recoveryURL))
                    for item in recovered {
                        let session=FileSession(id:item.id,url:item.path.map{URL(fileURLWithPath:$0)},text:item.text,kind:FileKind(rawValue:item.kind) ?? .text,dirty:true)
                        session.originalDigest=item.digest;session.encoding=String.Encoding(rawValue:item.encoding);session.savedText="";session.restoredDraft=true;tabs.append(session)
                    }
                    restoredCount=tabs.count;selection=tabs.first?.id
                } catch {recoveryReadable=false;self.error="恢复草稿无法读取，已保留原文件：\(error.localizedDescription)"}
            }
        } catch {self.error=error.localizedDescription}
        timer=Timer.scheduledTimer(withTimeInterval:4,repeats:true){[weak self] _ in Task{@MainActor in self?.checkpoint()}}
    }
    func checkpoint() {
        guard recoveryReadable else {return}
        do {
            let items=tabs.filter{$0.kind.isText && $0.dirty}.map{RecoveryItem(id:$0.id,path:$0.url?.path,kind:$0.kind.rawValue,text:$0.text,digest:$0.originalDigest,encoding:$0.encoding.rawValue)}
            try JSONEncoder().encode(items).write(to:FileSafety.root.appendingPathComponent("recovery.json"),options:.atomic)
        } catch {self.error="草稿恢复文件保存失败：\(error.localizedDescription)"}
    }
    private func persistState() {
        guard stateReadable else {return}
        do {try JSONEncoder().encode(WorkspaceState(recent:recent.map(\.path),folder:folder?.path)).write(to:FileSafety.root.appendingPathComponent("workspace.json"),options:.atomic)}
        catch{self.error=error.localizedDescription}
    }
    func select(_ session:FileSession){NSApp.keyWindow?.makeFirstResponder(nil);showingNotes=false;selection=session.id}
    func openPanel(){let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=true;panel.title="打开文件";if panel.runModal() == .OK {panel.urls.forEach(open)}}
    func openFolderPanel(){let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.title="打开工作文件夹";if panel.runModal() == .OK, let url=panel.url {folder=url;refreshFolder();persistState()}}
    func open(_ url:URL) {
        var directory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:url.path,isDirectory:&directory) else {error="文件不存在：\(url.lastPathComponent)";return}
        if directory.boolValue {folder=url;refreshFolder();persistState();return}
        showingNotes=false
        if let existing=tabs.first(where:{$0.url?.standardizedFileURL == url.standardizedFileURL}) {selection=existing.id;return}
        do {
            let kind=FileKind(url:url)
            let session=FileSession(url:url,kind:kind)
            if kind.isText {
                let data=try Data(contentsOf:url)
                guard data.count <= 20_000_000 else {throw FileIssue.message("文本超过 20 MB，请使用专用大文件工具打开。")}
                var actual:UInt=String.Encoding.utf8.rawValue
                session.text=try NSString(contentsOf:url,usedEncoding:&actual) as String;session.encoding=String.Encoding(rawValue:actual)
                session.savedText=session.text;session.originalDigest=FileSafety.digest(data)
            }
            tabs.append(session);selection=session.id
            recent.removeAll{$0.standardizedFileURL == url.standardizedFileURL};recent.insert(url,at:0);recent=Array(recent.prefix(40));persistState()
            status="已打开 \(url.lastPathComponent)"
        } catch {self.error="无法打开文件：\(error.localizedDescription)"}
    }
    func newText(_ kind:FileKind,text:String="") {NSApp.keyWindow?.makeFirstResponder(nil);showingNotes=false;let tab=FileSession(text:text,kind:kind,dirty:!text.isEmpty);tab.savedText="";tabs.append(tab);selection=tab.id;checkpoint()}
    func createOffice(_ kind:String) {
        let panel=NSSavePanel();panel.title="新建 \(kind.uppercased()) 文件";panel.nameFieldStringValue="未命名."+kind
        if panel.runModal() == .OK,let url=panel.url {do {try OfficeFactory.create(kind:kind,to:url);open(url)}catch{self.error=error.localizedDescription}}
    }
    @discardableResult func save(_ session:FileSession,asCopy:Bool=false) -> Bool {
        if !session.kind.isText {
            if let url=session.url {NotificationCenter.default.post(name:Notification.Name("GaoWenJian.saveActive"),object:url.path)}
            return !session.moduleDirty
        }
        var destination=session.url
        if destination == nil || asCopy {
            let panel=NSSavePanel();panel.title=asCopy ? "另存为" : "保存文件";panel.nameFieldStringValue=session.title
            if let folder {panel.directoryURL=folder}
            guard panel.runModal() == .OK,let url=panel.url else{return false};destination=url
        }
        guard let destination else{return false}
        do {
            let encoding = asCopy ? String.Encoding.utf8 : session.encoding
            guard let data=session.text.data(using:encoding) else {throw FileIssue.message("当前编码无法保存这些字符，请使用“另存为”生成 UTF-8 文件。")}
            try FileSafety.write(data,to:destination,expectedDigest:asCopy ? nil : session.originalDigest)
            session.url=destination;session.encoding=encoding;session.originalDigest=FileSafety.digest(data);session.savedText=session.text;session.restoredDraft=false;session.dirty=false
            recent.removeAll{$0 == destination};recent.insert(destination,at:0);persistState();checkpoint();refreshFolder();status="已保存 \(destination.lastPathComponent)"
            return true
        } catch {self.error=error.localizedDescription;return false}
    }
    func close(_ session:FileSession) {
        if session.dirty || session.moduleDirty {
            let alert=NSAlert();alert.messageText="保存对“\(session.title)”的修改？";alert.informativeText="未保存的修改将被关闭。";alert.addButton(withTitle:"保存");alert.addButton(withTitle:"取消");alert.addButton(withTitle:"不保存")
            switch alert.runModal(){case .alertFirstButtonReturn:guard save(session) else{return};case .alertSecondButtonReturn:return;default:if let path=session.url?.path{NotificationCenter.default.post(name:Notification.Name("GaoWenJian.discardDraft"),object:path)}}
        }
        let index=tabs.firstIndex{$0.id==session.id} ?? 0;tabs.removeAll{$0.id==session.id}
        if selection == session.id {selection=tabs.isEmpty ? nil : tabs[min(index,tabs.count-1)].id}
        checkpoint()
    }
    func prepareToQuit()->Bool {
        checkpoint()
        let dirty=tabs.filter{$0.dirty || $0.moduleDirty}
        guard !dirty.isEmpty else{return true}
        let alert=NSAlert();alert.messageText="还有 \(dirty.count) 个文件未保存";alert.informativeText="可以保存后退出，或返回继续编辑。文本草稿已写入本地恢复记录。";alert.addButton(withTitle:"全部保存并退出");alert.addButton(withTitle:"返回编辑")
        guard alert.runModal() == .alertFirstButtonReturn else{return false}
        return dirty.allSatisfy{save($0)}
    }
    func refreshFolder() {
        guard let folder else{entries=[];return}
        do {
            var result:[BrowserEntry]=[]
            func scan(_ dir:URL,_ depth:Int) throws {
                guard depth < 4 && result.count < 1500 else{return}
                let urls=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles]).sorted {a,b in
                    let ad=(try? a.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) ?? false
                    let bd=(try? b.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) ?? false
                    return ad != bd ? ad : a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
                }
                for url in urls {
                    let values=try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);if values.isSymbolicLink == true {continue}
                    let directory=values.isDirectory == true
                    result.append(BrowserEntry(url:url,directory:directory,depth:depth))
                    if directory && !["node_modules","build",".git"].contains(url.lastPathComponent) {try scan(url,depth+1)}
                }
            }
            try scan(folder,0);entries=result
        } catch{self.error="读取文件夹失败：\(error.localizedDescription)"}
    }
    func showHistory(){if let url=active?.url {do {_=try FileSafety.snapshot(url:url);let key=FileSafety.digest(Data(url.standardizedFileURL.path.utf8)).prefix(24);NSWorkspace.shared.open(FileSafety.root.appendingPathComponent("History/"+key))}catch{self.error=error.localizedDescription}}}
    func moduleDidSave(_ url:URL){status="已完成保存操作 · \(url.lastPathComponent)";refreshFolder()}
}
