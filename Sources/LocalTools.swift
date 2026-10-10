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

@MainActor enum PDFReaderWindow {
    static var windows:[NSWindow]=[]
    static func open(_ url:URL) {
        let view=PDFView();view.document=PDFDocument(url:url);view.autoScales=true
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:850,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title=url.lastPathComponent;window.contentView=view;window.isReleasedWhenClosed=false;window.center();window.makeKeyAndOrderFront(nil);windows.append(window)
    }
}
