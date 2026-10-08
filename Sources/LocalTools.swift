import AppKit
import SwiftUI
import PDFKit

struct ToolResult { let code:Int32;let output:String }
enum LocalTools {
    static var tectonic:URL? {
        let candidates=[Bundle.main.resourceURL?.appendingPathComponent("Tools/tectonic"),URL(fileURLWithPath:FileManager.default.homeDirectoryForCurrentUser.path+"/.local/bin/tectonic")]
        return candidates.compactMap{$0}.first{FileManager.default.isExecutableFile(atPath:$0.path)}
    }
    static var office:URL? {
        ["/Applications/LibreOffice.app/Contents/MacOS/soffice","/Applications/ONLYOFFICE.app/Contents/MacOS/onlyoffice"].map{URL(fileURLWithPath:$0)}.first{FileManager.default.isExecutableFile(atPath:$0.path)}
    }
    static func executable(_ name:String)->URL? {
        ["/Library/TeX/texbin","/usr/texbin","/opt/homebrew/bin","/usr/local/bin"].map{URL(fileURLWithPath:$0).appendingPathComponent(name)}.first{FileManager.default.isExecutableFile(atPath:$0.path)}
    }
    static func run(_ executable:URL,args:[String],directory:URL?=nil,environment:[String:String]?=nil,timeout:TimeInterval=120) async throws -> ToolResult {
        try await withCheckedThrowingContinuation { continuation in
            let process=Process();process.executableURL=executable;process.arguments=args;process.currentDirectoryURL=directory
            var env=ProcessInfo.processInfo.environment
            environment?.forEach{env[$0.key]=$0.value};process.environment=env
            let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("GaoWenJian-log-"+UUID().uuidString)
            FileManager.default.createFile(atPath:temporary.path,contents:nil)
            do {
                let handle=try FileHandle(forWritingTo:temporary);process.standardOutput=handle;process.standardError=handle
                process.terminationHandler={task in
                    try? handle.close();let data=(try? Data(contentsOf:temporary)) ?? Data();try? FileManager.default.removeItem(at:temporary)
                    continuation.resume(returning:ToolResult(code:task.terminationStatus,output:String(data:data,encoding:.utf8) ?? "无法解码工具输出"))
                }
                try process.run()
                DispatchQueue.global().asyncAfter(deadline:.now()+timeout){if process.isRunning{process.terminate()}}
            } catch {try? FileManager.default.removeItem(at:temporary);continuation.resume(throwing:error)}
        }
    }
    static func prepareTeXCache() throws -> URL {
        let destination=FileSafety.root.appendingPathComponent("TeXCache",isDirectory:true)
        guard let source=Bundle.main.resourceURL?.appendingPathComponent("TeXCache"),FileManager.default.fileExists(atPath:source.path) else {return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Tectonic")}
        if !FileManager.default.fileExists(atPath:destination.path) {
            try FileManager.default.copyItem(at:source,to:destination)
        } else {
            // An app update can add cached packages without replacing existing local resources.
            guard let files=FileManager.default.enumerator(at:source,includingPropertiesForKeys:[.isRegularFileKey,.isDirectoryKey],options:[.skipsHiddenFiles]) else {throw FileIssue.message("无法读取应用内置宏包。")}
            for case let file as URL in files {
                let relative=String(file.path.dropFirst(source.path.count+1))
                let target=destination.appendingPathComponent(relative)
                if !FileManager.default.fileExists(atPath:target.path) {
                    let values=try file.resourceValues(forKeys:[.isRegularFileKey,.isDirectoryKey])
                    if values.isDirectory==true {try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)}
                    else if values.isRegularFile==true {try FileManager.default.copyItem(at:file,to:target)}
                }
            }
        }
        return destination
    }
    static func officeConvert(_ input:URL,format:String,destination:URL) async throws -> URL {
        guard let office,office.lastPathComponent == "soffice" else {throw FileIssue.message("需要本机 LibreOffice 才能进行此转换。可在设置查看运行环境。")}
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("GaoWenJian-convert-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:temp)}
        let profile=temp.appendingPathComponent("profile")
        let result=try await run(office,args:["-env:UserInstallation="+profile.absoluteString,"--headless","--norestore","--convert-to",format,"--outdir",temp.path,input.path],timeout:90)
        let produced=temp.appendingPathComponent(input.deletingPathExtension().lastPathComponent+"."+format.components(separatedBy:":")[0])
        guard result.code == 0,FileManager.default.fileExists(atPath:produced.path) else {throw FileIssue.message("转换失败："+result.output)}
        try FileSafety.write(Data(contentsOf:produced),to:destination)
        return destination
    }
}

@MainActor final class LaTeXBuildModel:ObservableObject {
    @Published var busy=false
    @Published var output="选择主文件后编译。编译器仅使用本机资源。"
    @Published var pdfURL:URL?
    @Published var issues:[String]=[]
    @Published var engine="tectonic"
    @Published var mainPath=""
    @Published var compiledEditorText:String?
    private var generation=UUID()
    func compile(_ file:URL,editorText:String) async {
        guard !busy else{return};busy=true;defer{busy=false};output="正在准备本地编译…";issues=[]
        let generation=UUID();self.generation=generation
        do {
            let source=mainPath.isEmpty ? file : URL(fileURLWithPath:mainPath)
            guard FileManager.default.fileExists(atPath:source.path),source.pathExtension.lowercased()=="tex" else{throw FileIssue.message("请选择有效的 .tex 主文件。")}
            let inputDigest=FileSafety.digest(try Data(contentsOf:source))
            let build=FileSafety.root.appendingPathComponent("Builds/"+FileSafety.digest(Data(source.path.utf8)).prefix(24),isDirectory:true)
            try FileManager.default.createDirectory(at:build,withIntermediateDirectories:true)
            let run=build.appendingPathComponent(generation.uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:run,withIntermediateDirectories:true)
            let result:ToolResult
            if engine == "tectonic" {
                guard let tool=LocalTools.tectonic else{throw FileIssue.message("找不到本地 Tectonic 编译器。")}
                let cache=try LocalTools.prepareTeXCache()
                result=try await LocalTools.run(tool,args:["--only-cached","--untrusted","--keep-logs","--synctex","--outdir",run.path,source.path],directory:source.deletingLastPathComponent(),environment:["TECTONIC_CACHE_DIR":cache.path],timeout:120)
            } else {
                guard let tool=LocalTools.executable(engine) else{throw FileIssue.message("本机尚未安装 \(engine)。请选择内置 Tectonic 或在设置中配置 TeX Live。")}
                result=try await LocalTools.run(tool,args:["-no-shell-escape","-interaction=nonstopmode","-halt-on-error","-synctex=1","-output-directory="+run.path,source.path],directory:source.deletingLastPathComponent(),timeout:120)
            }
            guard self.generation == generation else{return}
            guard FileSafety.digest(try Data(contentsOf:source))==inputDigest else {throw FileIssue.message("编译期间主文件发生变化，请重新编译以获得对应当前稿件的 PDF。")}
            output=result.output
            issues=result.output.components(separatedBy:.newlines).filter{$0.contains("error:") || $0.hasPrefix("!") || $0.contains("Warning:") || $0.contains("Overfull") || $0.contains("Underfull")}
            let pdf=run.appendingPathComponent(source.deletingPathExtension().lastPathComponent+".pdf")
            if result.code==0,FileManager.default.fileExists(atPath:pdf.path){pdfURL=pdf;compiledEditorText=editorText;output="编译成功 · "+source.lastPathComponent+"\n\n"+result.output}
            else {throw FileIssue.message("编译未完成。请查看日志；离线缺失的宏包需通过本地工具包补充。\n"+result.output)}
            let children=try FileManager.default.contentsOfDirectory(at:build,includingPropertiesForKeys:[.creationDateKey])
            for old in children where old.lastPathComponent != run.lastPathComponent {try? FileManager.default.removeItem(at:old)}
        } catch{output=error.localizedDescription;issues=[error.localizedDescription.components(separatedBy:"\n").first ?? "编译失败"]}
    }
}

struct LaTeXWorkspace:View {
    @Binding var text:String
    let url:URL?
    let save:()->URL?
    let onError:(String)->Void
    @StateObject private var build=LaTeXBuildModel()
    @State private var showLog=false
    @State private var showOutline=true
    var body:some View {
        VStack(spacing:0){
            HStack {
                Label("LaTeX 工作区",systemImage:"function").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("编译器",selection:$build.engine){Text("Tectonic · 离线").tag("tectonic");ForEach(["xelatex","pdflatex","lualatex"],id:\.self){Text($0).tag($0)}}.labelsHidden().frame(width:185)
                Button("主文件…"){let p=NSOpenPanel();p.allowedContentTypes=[.init(filenameExtension:"tex")!];if p.runModal() == .OK,let u=p.url{build.mainPath=u.path}}
                Button(action:compile) {Label(build.busy ? "正在编译" : "编译",systemImage:build.busy ? "hourglass" : "play.fill")}.disabled(build.busy)
                Button{showLog.toggle()}label:{Image(systemName:"terminal")}.help("编译日志")
            }.padding(12).background(.bar)
            if !build.mainPath.isEmpty {HStack{Text("主文件："+build.mainPath).font(.caption).lineLimit(1);Spacer();Button("使用当前文件"){build.mainPath=""}.font(.caption)}.padding(.horizontal,12).padding(.vertical,6)}
            HSplitView {
                SourceEditor(text:$text,language:"tex").frame(minWidth:320)
                VStack(spacing:0){
                    if let pdf=build.pdfURL {ReadOnlyPDF(url:pdf)}
                    else {VStack(spacing:14){Image(systemName:"doc.richtext").font(.system(size:46,weight:.light)).foregroundStyle(.tertiary);Text("编译后在这里预览 PDF").font(.headline);Text("内置编译器不联网获取宏包").font(.callout).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,maxHeight:.infinity)}
                    if let pdf=build.pdfURL {HStack{Text(build.compiledEditorText==text ? "上次成功编译结果" : "源码已修改 · 请重新编译").font(.caption).foregroundStyle(build.compiledEditorText==text ? Color.secondary : .orange);Spacer();Button("导出 PDF…"){let p=NSSavePanel();p.nameFieldStringValue=pdf.lastPathComponent;if p.runModal() == .OK,let out=p.url{do{try FileSafety.write(Data(contentsOf:pdf),to:out)}catch{onError(error.localizedDescription)}}};Button("独立阅读"){PDFReaderWindow.open(pdf)}}.padding(10).background(.bar)}
                }.frame(minWidth:320)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
            if showLog {ScrollView{Text(build.output).font(.system(size:12,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(12)}.frame(height:180).background(Color(nsColor:.textBackgroundColor))}
            else if let issue=build.issues.first {Text(issue).font(.caption).foregroundStyle(.orange).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading).padding(8)}
        }.onReceive(NotificationCenter.default.publisher(for:Notification.Name("GaoWenJian.compileActive"))) { note in
            if note.object as? String == url?.path { compile() }
        }
    }
    private func compile(){guard let savedURL=save() else{return};let editorText=text;Task{await build.compile(savedURL,editorText:editorText)}}
}

struct ReadOnlyPDF:NSViewRepresentable {
    let url:URL
    func makeNSView(context:Context)->PDFView {let v=PDFView();v.autoScales=true;v.displayMode = .singlePageContinuous;v.backgroundColor = .windowBackgroundColor;v.document=PDFDocument(url:url);v.identifier=NSUserInterfaceItemIdentifier(url.path);return v}
    func updateNSView(_ v:PDFView,context:Context){if v.identifier?.rawValue != url.path{v.document=PDFDocument(url:url);v.identifier=NSUserInterfaceItemIdentifier(url.path);v.autoScales=true}}
}
@MainActor enum PDFReaderWindow {
    static var windows:[NSWindow]=[]
    static func open(_ url:URL) {
        let view=PDFView();view.document=PDFDocument(url:url);view.autoScales=true
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:850,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title=url.lastPathComponent;window.contentView=view;window.isReleasedWhenClosed=false;window.center();window.makeKeyAndOrderFront(nil);windows.append(window)
    }
}
