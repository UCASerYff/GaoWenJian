import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Darwin

enum FileKind: String, CaseIterable {
    case markdown, latex, pdf, word, spreadsheet, presentation, csv, text, image, richText, other
    init(url:URL) {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": self = .markdown
        case "tex", "bib", "sty", "cls": self = .latex
        case "pdf": self = .pdf
        case "doc", "docx", "docm", "dotx", "dotm", "odt": self = .word
        case "xls", "xlsx", "xlsm", "xltx", "xltm", "ods": self = .spreadsheet
        case "ppt", "pptx", "pptm", "potx", "potm", "pps", "ppsx", "odp": self = .presentation
        case "csv", "tsv": self = .csv
        case "rtf": self = .richText
        case "txt", "json", "xml", "yaml", "yml", "html", "css", "js", "swift", "py", "r", "log", "sh": self = .text
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp", "svg": self = .image
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
    var isOfficeViewer:Bool { [.word,.spreadsheet,.presentation].contains(self) }
    var canSave:Bool { isText || self == .pdf || self == .richText }
    var extensions:[String] { switch self {
        case .latex:return ["tex","bib","sty","cls"]
        case .markdown:return ["md","markdown"]
        case .pdf:return ["pdf"]
        case .word:return ["doc","docx","docm","dotx","dotm","odt"]
        case .spreadsheet:return ["xls","xlsx","xlsm","xltx","xltm","ods"]
        case .presentation:return ["ppt","pptx","pptm","potx","potm","pps","ppsx","odp"]
        default:return []
    }}
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
    @Published var incoming:IncomingDocument?
    var suggestedTitle:String?
    let projectReading = WritingProjectReadingTracker()
    var title:String { url?.lastPathComponent ?? suggestedTitle ?? "未命名." + suggestedExtension }
    var suggestedExtension:String { switch kind {case .markdown:return "md";case .latex:return "tex";case .csv:return "csv";default:return "txt"} }
    init(id:UUID=UUID(),url:URL?=nil,text:String="",kind:FileKind = .markdown,dirty:Bool=false) {
        self.id=id;self.url=url;self.text=text;self.kind=kind;self.dirty=dirty;self.savedText=text
    }
    func edited(_ value:String) { text=value;dirty = restoredDraft || value != savedText }
}
struct BrowserEntry:Identifiable { var url:URL;var directory:Bool;var depth:Int;var id:String {url.path} }
private struct WorkspaceState:Codable { var recent:[String] = [];var folder:String? }
private struct RecoveryItem:Codable,Equatable { var id:UUID;var path:String?;var kind:String;var text:String;var digest:String?;var encoding:UInt;var suggestedTitle:String?;var incoming:IncomingDocument? }

@MainActor final class WorkspaceStore:ObservableObject {
    @Published var tabs:[FileSession] = []
    @Published var selection:UUID?
    @Published var folder:URL?
    @Published var entries:[BrowserEntry] = []
    @Published var recent:[URL] = []
    @Published var error:String?
    @Published var status = "文件仅保存在本机"
    @Published var restoredCount = 0
    @Published var showingNotes = false { didSet { if showingNotes { showingOrganizer = false; showingProjects = false } } }
    @Published var showingOrganizer = false { didSet { if showingOrganizer { showingProjects = false } } }
    @Published var showingProjects = false
    @Published private(set) var writingProjects = WritingProjectCatalog()
    @Published private(set) var activeWritingProjectID: UUID?
    @Published private(set) var unavailableProjectFiles: [WritingProjectUnavailable] = []
    @Published private(set) var writingProjectError: String?
    private var projectRepository: WritingProjectRepository?
    private var unavailableProjectReferences: [WritingProjectDocument] = []
    private var carriedProjectDrafts = Set<UUID>()
    let organizerHost = OrganizerHostController()
    @Published var handoffBusy = false
    private var stateReadable = true
    private var recoveryReadable = true
    private var persistedRecovery: [RecoveryItem] = []
    private var timer:Timer?
    private let workspaceRoot: URL
    var active:FileSession? { tabs.first {$0.id == selection} }
    init(dataRoot: URL = FileSafety.root) {
        workspaceRoot = dataRoot
        organizerHost.configure(openDocument:{[weak self] url in self?.open(url)})
        organizerHost.validateMoveSources = { [weak self] urls in
            guard let self else {throw FileIssue.message("写作工作区不可用，已停止整理。")}
            let protected=self.tabs.compactMap{ $0.url?.standardizedFileURL }
            let dataRoot=self.workspaceRoot.standardizedFileURL.path
            for url in urls {
                let path=url.standardizedFileURL.path
                var candidateIdentity=stat()
                let hasIdentity=lstat(url.path,&candidateIdentity)==0
                let isOpenObject=protected.contains { opened in
                    if opened.path==path{return true}
                    var identity=stat()
                    return hasIdentity && lstat(opened.path,&identity)==0 && identity.st_dev==candidateIdentity.st_dev && identity.st_ino==candidateIdentity.st_ino
                }
                guard path != dataRoot, !path.hasPrefix(dataRoot+"/"), !isOpenObject else {
                    throw FileIssue.message("文件正在编辑或属于应用资料：\(url.lastPathComponent)。请先保存并关闭文档，再重新预览整理；应用资料不能作为原件整理。")
                }
            }
        }
        do {
            try FileManager.default.createDirectory(at:workspaceRoot,withIntermediateDirectories:true)
            do {
                let repository = try WritingProjectRepository(root: workspaceRoot)
                projectRepository = repository
                writingProjects = repository.catalog
            } catch { writingProjectError = "项目记录无法读取，已保留磁盘文件。" }
            let stateURL=workspaceRoot.appendingPathComponent("workspace.json")
            if FileManager.default.fileExists(atPath:stateURL.path) {
                do {
                    let state=try JSONDecoder().decode(WorkspaceState.self,from:Data(contentsOf:stateURL));recent=state.recent.map{URL(fileURLWithPath:$0)}
                    if let path=state.folder, FileManager.default.fileExists(atPath:path) {folder=URL(fileURLWithPath:path); refreshFolder()}
                } catch {stateReadable=false;self.error="工作区记录无法读取，已保留原文件：\(error.localizedDescription)"}
            }
            let recoveryURL=workspaceRoot.appendingPathComponent("recovery.json")
            if FileManager.default.fileExists(atPath:recoveryURL.path) {
                do {
                    let recovered=try JSONDecoder().decode([RecoveryItem].self,from:Data(contentsOf:recoveryURL))
                    persistedRecovery = recovered
                    for item in recovered {
                        let session=FileSession(id:item.id,url:item.path.map{URL(fileURLWithPath:$0)},text:item.text,kind:FileKind(rawValue:item.kind) ?? .text,dirty:true)
                        session.originalDigest=item.digest;session.encoding=String.Encoding(rawValue:item.encoding);session.savedText="";session.restoredDraft=true;session.suggestedTitle=item.suggestedTitle;session.incoming=item.incoming;tabs.append(session)
                    }
                    restoredCount=tabs.count;selection=tabs.first?.id
                } catch {recoveryReadable=false;self.error="恢复草稿无法读取，已保留原文件：\(error.localizedDescription)"}
            }
        } catch {self.error=error.localizedDescription}
        let checkpointTimer = Timer.scheduledTimer(withTimeInterval:4,repeats:true){[weak self] _ in Task{@MainActor in self?.checkpoint()}}
        checkpointTimer.tolerance = 0.5
        timer = checkpointTimer
    }
    func checkpoint() {
        guard recoveryReadable else {return}
        do { try writeCheckpoint() } catch {self.error="草稿恢复文件保存失败：\(error.localizedDescription)"}
    }
    private func writeCheckpoint() throws {
        guard recoveryReadable else { throw FileIssue.message("恢复草稿不可读取，已保留原记录。") }
        let items=tabs.filter{$0.kind.isText && $0.dirty}.map{RecoveryItem(id:$0.id,path:$0.url?.path,kind:$0.kind.rawValue,text:$0.text,digest:$0.originalDigest,encoding:$0.encoding.rawValue,suggestedTitle:$0.suggestedTitle,incoming:$0.incoming)}
        let recoveryURL = workspaceRoot.appendingPathComponent("recovery.json")
        if items == persistedRecovery && (items.isEmpty || FileManager.default.fileExists(atPath: recoveryURL.path)) {
            return
        }
        try JSONEncoder().encode(items).write(to: recoveryURL, options: .atomic)
        persistedRecovery = items
    }
    private func persistState() {
        guard stateReadable else {return}
        do {try JSONEncoder().encode(WorkspaceState(recent:recent.map(\.path),folder:folder?.path)).write(to:workspaceRoot.appendingPathComponent("workspace.json"),options:.atomic)}
        catch{self.error=error.localizedDescription}
    }
    func select(_ session:FileSession){NSApp?.keyWindow?.makeFirstResponder(nil);showingNotes=false;showingOrganizer=false;showingProjects=false;selection=session.id}
    func showHome(){NSApp?.keyWindow?.makeFirstResponder(nil);showingNotes=false;showingOrganizer=false;showingProjects=false;selection=nil}
    func showOrganizer(){NSApp?.keyWindow?.makeFirstResponder(nil);showingNotes=false;showingOrganizer=true}
    func openPanel(){let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=true;panel.title="打开文件";if panel.runModal() == .OK {panel.urls.forEach(open)}}
    func openPanel(for kinds:[FileKind]) {
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=true
        panel.title="打开 " + kinds.map(\.title).joined(separator:" / ")
        panel.allowedContentTypes=kinds.flatMap(\.extensions).compactMap{UTType(filenameExtension:$0)}
        panel.allowsOtherFileTypes=false
        if panel.runModal() == .OK {panel.urls.forEach(open)}
    }
    func openFolderPanel(){let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.title="打开工作文件夹";if panel.runModal() == .OK, let url=panel.url {folder=url;refreshFolder();persistState()}}
    func open(_ url:URL) {
        guard !organizerHost.isMoving else {error="物理整理尚在进行，请等待结束后打开文档。";return}
        if GaoHandoffService.handleIncoming(url: url, store: self) { return }
        var directory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:url.path,isDirectory:&directory) else {error="文件不存在：\(url.lastPathComponent)";return}
        if directory.boolValue {folder=url;refreshFolder();persistState();return}
        showingNotes=false;showingOrganizer=false;showingProjects=false
        if let existing=tabs.first(where:{$0.url?.standardizedFileURL == url.standardizedFileURL}) {selection=existing.id;return}
        do {
            let session = try makeFileSession(url)
            tabs.append(session);selection=session.id
            recent.removeAll{$0.standardizedFileURL == url.standardizedFileURL};recent.insert(url,at:0);recent=Array(recent.prefix(40));persistState()
            status="已打开 \(url.lastPathComponent)"
        } catch {self.error="无法打开文件：\(error.localizedDescription)"}
    }
    private func makeFileSession(_ url: URL) throws -> FileSession {
        let kind = FileKind(url: url)
        let session = FileSession(url: url, kind: kind)
        do { session.incoming = try DocumentOriginStorage.load(for: url) }
        catch { self.error = "文档来源记录无法读取，已保留原记录。" }
        if kind.isText {
            let data = try Data(contentsOf: url)
            guard data.count <= 20_000_000 else { throw FileIssue.message("文本超过 20 MB，请使用专用大文件工具打开。") }
            var actual = String.Encoding.utf8.rawValue
            session.text = try NSString(contentsOf: url, usedEncoding: &actual) as String
            session.encoding = String.Encoding(rawValue: actual)
            session.savedText = session.text
            session.originalDigest = FileSafety.digest(data)
        }
        return session
    }
    func newText(_ kind:FileKind,text:String="") {NSApp?.keyWindow?.makeFirstResponder(nil);showingNotes=false;showingOrganizer=false;showingProjects=false;let tab=FileSession(text:text,kind:kind,dirty:!text.isEmpty);tab.savedText="";tabs.append(tab);selection=tab.id;checkpoint()}
    @discardableResult func newHandoffText(_ text:String,markdown:Bool,title:String?,incoming:IncomingDocument) throws -> FileSession {
        guard recoveryReadable else { throw FileIssue.message("草稿恢复记录无法读取，交接文字尚未导入，请先处理现有恢复记录。") }
        guard text.utf8.count <= DocumentHandoffSafety.maximumTextBytes, !text.contains("\0") else { throw FileIssue.message("交接正文超过限制或含无效字符，未改变当前文档。") }
        NSApp?.keyWindow?.makeFirstResponder(nil)
        let previousSelection=selection, previousNotes=showingNotes, previousOrganizer=showingOrganizer, previousProjects=showingProjects
        let tab=FileSession(text:text,kind:markdown ? .markdown:.text,dirty:true)
        tab.incoming=incoming; tab.suggestedTitle=HandoffNames.title(title,fallback:incoming.originalName)
        tab.savedText="";tabs.append(tab);selection=tab.id;showingNotes=false;showingOrganizer=false;showingProjects=false
        do { try writeCheckpoint() } catch {tabs.removeAll{$0.id==tab.id};selection=previousSelection;showingNotes=previousNotes;showingOrganizer=previousOrganizer;showingProjects=previousProjects;throw error}
        status="已新建未保存的交接文字 · 当前原文档保留"
        return tab
    }
    @discardableResult func openHandoffDocument(_ url:URL,incoming:IncomingDocument) throws -> FileSession {
        try DocumentOriginStorage.save(incoming,for:url)
        NSApp?.keyWindow?.makeFirstResponder(nil)
        let previousSelection=selection, previousNotes=showingNotes, previousOrganizer=showingOrganizer, previousProjects=showingProjects
        open(url)
        guard let tab=tabs.first(where:{$0.url?.standardizedFileURL==url.standardizedFileURL}) else { selection=previousSelection;showingNotes=previousNotes;showingOrganizer=previousOrganizer;showingProjects=previousProjects;throw FileIssue.message("交接文档无法打开，原有标签保留。") }
        tab.incoming=incoming
        return tab
    }
    @discardableResult func save(_ session:FileSession,asCopy:Bool=false) -> Bool {
        guard session.kind.canSave else {return true}
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
            if let incoming=session.incoming { do { try DocumentOriginStorage.save(incoming,for:destination) } catch { self.error="文档已保存，但来源说明记录未能保存；已有来源记录保留。" } }
            recent.removeAll{$0 == destination};recent.insert(destination,at:0);persistState();checkpoint();refreshFolder();status="已保存 \(destination.lastPathComponent)"
            return true
        } catch {self.error=error.localizedDescription;return false}
    }
    /// Close/quit cannot depend on the asynchronous SwiftUI dirty notification:
    /// PDFKit may still own a focused field editor when the action is invoked.
    func commitCurrentPDFEdits(for session:FileSession) throws {
        guard session.kind == .pdf, let url=session.url else { return }
        if let model=try CurrentDocumentHandoffRegistry.shared.commitPDFSession(for:url) {
            session.moduleDirty=model.dirty
        }
    }
    func close(_ session:FileSession) {
        do { try commitCurrentPDFEdits(for:session) } catch { self.error=error.localizedDescription;return }
        if session.dirty || session.moduleDirty {
            let alert=NSAlert();alert.messageText="保存对“\(session.title)”的修改？";alert.informativeText="未保存的修改将被关闭。";alert.addButton(withTitle:"保存");alert.addButton(withTitle:"取消");alert.addButton(withTitle:"不保存")
            switch alert.runModal(){case .alertFirstButtonReturn:guard save(session) else{return};case .alertSecondButtonReturn:return;default:if let path=session.url?.path{NotificationCenter.default.post(name:Notification.Name("GaoWenJian.discardDraft"),object:path)}}
        }
        let index=tabs.firstIndex{$0.id==session.id} ?? 0;tabs.removeAll{$0.id==session.id}
        PDFReaderWindow.close(for: session.projectReading)
        if selection == session.id {selection=tabs.isEmpty ? nil : tabs[min(index,tabs.count-1)].id}
        checkpoint()
    }
    func prepareToQuit()->Bool {
        do { for session in tabs { try commitCurrentPDFEdits(for:session) } }
        catch { self.error=error.localizedDescription;return false }
        checkpoint()
        let dirty=tabs.filter{$0.dirty || $0.moduleDirty}
        guard !dirty.isEmpty else{checkpointWritingProjectBeforeClose();return true}
        let alert=NSAlert();alert.messageText="还有 \(dirty.count) 个文件未保存";alert.informativeText="可以保存后退出，或返回继续编辑。文本草稿已写入本地恢复记录。";alert.addButton(withTitle:"全部保存并退出");alert.addButton(withTitle:"返回编辑")
        guard alert.runModal() == .alertFirstButtonReturn else{return false}
        guard dirty.allSatisfy({save($0)}) else { return false }
        checkpointWritingProjectBeforeClose()
        return true
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
    func moduleDidSave(_ url:URL){status="已完成保存操作 · \(url.lastPathComponent)";refreshFolder()}
}

extension WorkspaceStore {
    var currentWritingProject: WritingProject? { writingProjects.projects.first { $0.id == activeWritingProjectID } }

    func writingProjectMain(for tab: FileSession) -> URL? {
        guard let project = currentWritingProject, let url = tab.url,
              WritingProjectPaths.contains(url.path, in: project.folder),
              URL(fileURLWithPath: project.main).pathExtension.lowercased() == "tex" else { return nil }
        return URL(fileURLWithPath: project.main)
    }

    func showWritingProjects() {
        NSApp?.keyWindow?.makeFirstResponder(nil)
        showingNotes = false
        showingOrganizer = false
        showingProjects = true
    }

    func saveWritingProject(id: UUID?, name: String, folder folderPath: String, main mainPath: String) throws {
        try requireProjectOperation()
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty, displayName.count <= 120, !displayName.contains("\0") else {
            throw FileIssue.message("请输入不超过 120 个字符的项目名称。")
        }
        let directory = try WritingProjectPaths.requireExisting(folderPath, directory: true, dataRoot: workspaceRoot)
        let previous = id.flatMap { id in writingProjects.projects.first { $0.id == id } }
        if id != nil, previous == nil { throw FileIssue.message("写作项目已不存在。") }
        let mainKey = WritingProjectPaths.key(mainPath)
        guard WritingProjectPaths.isAbsolute(mainPath), WritingProjectPaths.isMain(mainKey),
              WritingProjectPaths.contains(mainKey, in: directory.path) else {
            throw FileIssue.message("请选择项目目录内的 Markdown 或 LaTeX 主文件。")
        }
        if previous?.main != mainKey || FileManager.default.fileExists(atPath: mainKey) {
            _ = try WritingProjectPaths.requireExisting(mainKey, directory: false, dataRoot: workspaceRoot)
        }
        if tabs.contains(where: { $0.kind.isText && $0.dirty }) { try writeCheckpoint() }
        let reference = WritingProject(id: id ?? UUID(), name: displayName, folder: directory.path, main: mainKey,
                                       documents: previous?.documents ?? [])
        var catalog = writingProjects
        let updated = captureWritingProject(reference, keepUnavailable: activeWritingProjectID == id && id != nil)
        catalog.projects.removeAll { $0.id == updated.id }
        catalog.projects.insert(updated, at: 0)
        catalog.lastOpened = updated.id
        try persistWritingProjects(catalog)
        if activeWritingProjectID != updated.id { unavailableProjectFiles = []; unavailableProjectReferences = [] }
        activeWritingProjectID = updated.id
        folder = directory
        refreshFolder()
        persistState()
        status = "已保存项目会话 · \(updated.name)"
    }

    func checkpointWritingProject() throws {
        guard activeWritingProjectID != nil else { return }
        try requireProjectOperation()
        if tabs.contains(where: { $0.kind.isText && $0.dirty }) { try writeCheckpoint() }
        try persistWritingProjects(catalogWithCurrentSession())
    }

    func promptToRestoreWritingProject(_ id: UUID) {
        if let window = NSApp?.keyWindow, !window.makeFirstResponder(nil) {
            error = "当前编辑尚未结束，请先确认正在输入的内容。"
            return
        }
        do {
            for session in tabs { try commitCurrentPDFEdits(for: session) }
            let dirty = tabs.filter { $0.dirty || $0.moduleDirty }
            if dirty.isEmpty { try restoreWritingProject(id, drafts: .requireSaved); return }
            let alert = NSAlert()
            alert.messageText = "切换写作项目前有 \(dirty.count) 个文档尚未保存"
            alert.informativeText = "可以先保存文件，也可以切换项目并让草稿继续留在标签栏。"
            alert.addButton(withTitle: "全部保存并切换")
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "保留草稿并切换")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard dirty.allSatisfy({ save($0) }) else { return }
                try restoreWritingProject(id, drafts: .requireSaved)
            case .alertThirdButtonReturn:
                try restoreWritingProject(id, drafts: .preserveDrafts)
            default: break
            }
        } catch { self.error = error.localizedDescription }
    }

    func restoreWritingProject(_ id: UUID, drafts: WritingProjectSwitch) throws {
        try requireProjectOperation()
        guard let requested = writingProjects.projects.first(where: { $0.id == id }) else { throw FileIssue.message("找不到要打开的写作项目。") }
        for session in tabs { try commitCurrentPDFEdits(for: session) }
        let dirty = tabs.filter { $0.dirty || $0.moduleDirty }
        if drafts == .requireSaved, !dirty.isEmpty { throw FileIssue.message("还有未保存的文档，请先保存或明确保留草稿。") }
        if dirty.contains(where: { $0.kind.isText && $0.dirty }) { try writeCheckpoint() }

        var catalog = catalogWithCurrentSession()
        let project = catalog.projects.first { $0.id == id } ?? requested
        var issues: [WritingProjectUnavailable] = []
        var missing: [WritingProjectDocument] = []
        var reopened: [FileSession] = []
        var positions: [UUID: ProjectReadingPositions] = [:]
        let directory: URL?
        do { directory = try WritingProjectPaths.requireExisting(project.folder, directory: true, dataRoot: workspaceRoot) }
        catch { directory = nil; issues.append(.init(path: project.folder, reason: error.localizedDescription)) }

        for reference in project.documents {
            if let path = reference.path {
                do {
                    let url = try WritingProjectPaths.requireExisting(path, directory: false, dataRoot: workspaceRoot)
                    let existing = tabs.first { $0.url.map { WritingProjectPaths.key($0.path) == url.path } ?? false }
                    let session = try (existing ?? makeFileSession(url))
                    if !reopened.contains(where: { $0.id == session.id }) { reopened.append(session) }
                    positions[session.id] = reference.reading
                } catch {
                    issues.append(.init(path: path, reason: error.localizedDescription))
                    missing.append(reference)
                }
            } else if let draft = reference.draftID, let existing = tabs.first(where: { $0.id == draft }) {
                if !reopened.contains(where: { $0.id == existing.id }) { reopened.append(existing) }
                positions[existing.id] = reference.reading
            }
        }
        let restoredIDs = Set(reopened.map(\.id))
        let carried = dirty.filter { !restoredIDs.contains($0.id) }
        let nextTabs = reopened + carried
        catalog.projects.removeAll { $0.id == id }
        catalog.projects.insert(project, at: 0)
        catalog.lastOpened = id
        try persistWritingProjects(catalog)

        let nextIDs = Set(nextTabs.map(\.id))
        for tab in tabs where !nextIDs.contains(tab.id) { PDFReaderWindow.close(for: tab.projectReading) }
        for tab in reopened { if let reading = positions[tab.id] { tab.projectReading.restore(reading) } }
        tabs = nextTabs
        let preferred = reopened.first { tab in
            if let path = project.selectedPath { return tab.url.map { WritingProjectPaths.key($0.path) == WritingProjectPaths.key(path) } ?? false }
            return tab.id == project.selectedDraftID
        }
        selection = preferred?.id ?? reopened.first { $0.url.map { WritingProjectPaths.key($0.path) == project.main } ?? false }?.id ?? reopened.first?.id ?? carried.first?.id
        folder = directory
        activeWritingProjectID = id
        carriedProjectDrafts = Set(carried.map(\.id))
        unavailableProjectFiles = issues
        unavailableProjectReferences = missing
        showingNotes = false
        showingOrganizer = false
        showingProjects = selection == nil
        refreshFolder()
        persistState()
        status = "已打开项目 · \(project.name)" + (issues.isEmpty ? "" : " · \(issues.count) 项无法打开")
    }

    private func requireProjectOperation() throws {
        guard !organizerHost.isMoving else { throw FileIssue.message("物理整理尚在进行，请等待结束后再切换项目。") }
        guard projectRepository != nil else { throw FileIssue.message(writingProjectError ?? "项目记录不可用。") }
    }

    private func persistWritingProjects(_ catalog: WritingProjectCatalog) throws {
        guard let projectRepository else { throw FileIssue.message("项目记录不可用。") }
        try projectRepository.save(catalog)
        writingProjects = catalog
    }

    private func checkpointWritingProjectBeforeClose() {
        do { try checkpointWritingProject() }
        catch { writingProjectError = error.localizedDescription }
    }

    private func catalogWithCurrentSession() -> WritingProjectCatalog {
        var catalog = writingProjects
        if let index = catalog.projects.firstIndex(where: { $0.id == activeWritingProjectID }) {
            catalog.projects[index] = captureWritingProject(catalog.projects[index], keepUnavailable: true)
        }
        return catalog
    }

    private func captureWritingProject(_ reference: WritingProject, keepUnavailable: Bool) -> WritingProject {
        var updated = reference
        updated.documents = []
        updated.selectedPath = nil
        updated.selectedDraftID = nil
        let existingPaths = Set(reference.documents.compactMap(\.path).map(WritingProjectPaths.key))
        var recorded = Set<String>()
        for tab in tabs {
            let path = tab.url.map { WritingProjectPaths.key($0.path) }
            let alreadyInProject = path.map(existingPaths.contains) ?? false
            if carriedProjectDrafts.contains(tab.id) && !alreadyInProject { continue }
            let reading = tab.projectReading.capture()
            if let path, WritingProjectPaths.isAbsolute(path), !WritingProjectPaths.isHandoff(path) {
                guard recorded.insert(path).inserted else { continue }
                updated.documents.append(.init(path: path, reading: reading))
                if selection == tab.id { updated.selectedPath = path }
            } else if tab.url == nil && tab.dirty {
                updated.documents.append(.init(draftID: tab.id, reading: reading))
                if selection == tab.id { updated.selectedDraftID = tab.id }
            }
        }
        if keepUnavailable {
            for entry in unavailableProjectReferences {
                if let path = entry.path, recorded.insert(path).inserted { updated.documents.append(entry) }
            }
        }
        if !recorded.contains(reference.main) { updated.documents.insert(.init(path: reference.main), at: 0) }
        return updated
    }
}
