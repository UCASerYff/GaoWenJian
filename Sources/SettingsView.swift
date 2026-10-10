import AppKit
import SwiftUI

struct FileSettings:View{
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var stickyNotes:StickyNotesStore
    @AppStorage("editorFontSize") private var fontSize=15.0
    @AppStorage("wrapLines") private var wrap=true
    @AppStorage("appAppearance") private var appearance="system"
    var body:some View{
        TabView{
            Form{
                Section("编辑器"){HStack{Text("源码字号");Slider(value:$fontSize,in:11...24,step:1);Text("\(Int(fontSize)) pt").monospacedDigit().frame(width:45)};Toggle("源码自动换行",isOn:$wrap);Text("⌘S 保存 · ⌘O 打开 · ⌘N 新建 Markdown · ⌘B 编译 LaTeX").font(.caption).foregroundStyle(.secondary)}
                Section("外观"){Picker("主题",selection:$appearance){Text("跟随系统").tag("system");Text("浅色").tag("light");Text("深色").tag("dark")}.onChange(of:appearance){_,value in NSApp.appearance=value=="system" ? nil : NSAppearance(named:value=="dark" ? .darkAqua:.aqua)}}
                Section("保存与恢复"){Text("文本修改每 4 秒写入本地恢复记录。原文件通过保存操作更新；每次覆盖前自动留存原件快照。");Text("检测到其他程序修改文件时会停止覆盖。请重新打开或另存新文件。").font(.caption).foregroundStyle(.secondary)}
            }.formStyle(.grouped).tabItem{Label("编辑",systemImage:"slider.horizontal.3")}
            Form{
                Section("LaTeX"){LabeledContent("内置 Tectonic",value:LocalTools.tectonic == nil ? "未找到" : "可用 · 强制离线");ForEach(["xelatex","pdflatex","lualatex","latexmk"],id:\.self){name in LabeledContent(name,value:LocalTools.executable(name) == nil ? "未安装" : "可用")};Text("内置基础宏包随应用提供。未缓存的宏包会明确报错；不会联网下载。完整 TeX Live 可通过本机安装后使用。").font(.caption).foregroundStyle(.secondary)}
                Section("Office 转换"){LabeledContent("LibreOffice",value:LocalTools.office == nil ? "未找到" : "本机可用");Text("Word / Excel / PPT 的常用编辑直接在搞文件中完成。高保真分页预览、导出 PDF 和旧格式转换使用本机 LibreOffice。").font(.caption).foregroundStyle(.secondary)}
            }.formStyle(.grouped).tabItem{Label("运行环境",systemImage:"wrench.and.screwdriver")}
            Form{
                Section("便笺"){Text("便笺正文、格式、图片和 PDF 附件自动保存在本机资料目录内。关闭桌面便笺只会隐藏，删除会移到回收站。便笺中心支持搜索、分组和导入导出。");LabeledContent("便笺数量",value:String(stickyNotes.notes.filter{$0.deletedAt==nil}.count));Text("⌘2 打开便笺中心 · ⇧⌘N 新建桌面便笺。保存失败会保留修改并阻止关闭或退出。").font(.caption).foregroundStyle(.secondary)}
                Section("本地资料"){Text(FileSafety.root.path).font(.caption.monospaced()).textSelection(.enabled);Button("打开资料目录"){NSWorkspace.shared.open(FileSafety.root)};Button("打开历史快照目录"){let folder=FileSafety.root.appendingPathComponent("History");do{try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);NSWorkspace.shared.open(folder)}catch{store.error=error.localizedDescription}};Button("导出工作区备份…",action:exportBackup)}
                Section("文档位置"){Text("文档保留在你选择的本地文件夹中。工作区备份包含恢复草稿、设置记录和历史；外部文档请随项目文件夹一起备份。").font(.callout);Text("资料无法读取时不会以空记录覆盖。历史快照和备份不会随应用升级删除。").font(.caption).foregroundStyle(.secondary)}
            }.formStyle(.grouped).tabItem{Label("数据",systemImage:"internaldrive")}
            VStack(spacing:16){if let icon=NSImage(named:"AppIcon"){Image(nsImage:icon).resizable().frame(width:92,height:92)};Text("搞文件 V"+(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.03")).font(.title2.weight(.semibold));Text("本地文件编辑工作台").foregroundStyle(.secondary);Text("便笺 · Markdown · LaTeX · PDF · Word · Excel · PPT").font(.callout);Text("无需账户 · 本机处理").font(.caption).foregroundStyle(.secondary);Text("本地签名版本").font(.caption).foregroundStyle(.tertiary)}.frame(maxWidth:.infinity,maxHeight:.infinity).tabItem{Label("关于",systemImage:"info.circle")}
        }.padding(18)
    }
    private func exportBackup(){store.checkpoint();guard !stickyNotes.isDirty || stickyNotes.flush() else{store.error=stickyNotes.error;return};let panel=NSSavePanel();panel.nameFieldStringValue="搞文件-工作区备份-"+Date().formatted(.iso8601.year().month().day())+".zip";guard panel.runModal() == .OK,let url=panel.url else{return};Task{do{let result=try await LocalTools.run(URL(fileURLWithPath:"/usr/bin/ditto"),args:["-c","-k","--sequesterRsrc","--keepParent",FileSafety.root.path,url.path]);guard result.code==0 else{throw FileIssue.message(result.output)};store.status="已导出工作区备份"}catch{store.error=error.localizedDescription}}}
}
