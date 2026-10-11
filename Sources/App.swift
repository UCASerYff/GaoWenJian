import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor enum AppHub {
    static var store:WorkspaceStore?
    static var stickyNotes:StickyNotesStore?
    static var stickyWindows:StickyNotesWindowManager?
    static var isStickyWindow:Bool {NSApp.keyWindow?.identifier?.rawValue.hasPrefix("sticky-note-") == true}
    @discardableResult static func saveStickyNotes()->Bool {
        let window=NSApp.keyWindow, responder=window?.firstResponder
        window?.makeFirstResponder(nil)
        let saved=stickyNotes?.flush() ?? false
        if let responder{window?.makeFirstResponder(responder)}
        return saved
    }
}
@main @MainActor struct GaoWenJianApp:App {
    @NSApplicationDelegateAdaptor(FileAppDelegate.self) private var delegate
    @StateObject private var store:WorkspaceStore
    @StateObject private var stickyNotes:StickyNotesStore
    @Environment(\.openWindow) private var openWindow
    init(){
        let model=WorkspaceStore()
        let notes=StickyNotesStore()
        _store=StateObject(wrappedValue:model)
        _stickyNotes=StateObject(wrappedValue:notes)
        AppHub.store=model;AppHub.stickyNotes=notes
        AppHub.stickyWindows=StickyNotesWindowManager(store:notes)
        NSColorPanel.shared.showsAlpha=true
        let appearance=UserDefaults.standard.string(forKey:"appAppearance") ?? "system"
        NSApp.appearance=appearance=="system" ? nil : NSAppearance(named:appearance=="dark" ? .darkAqua:.aqua)
    }
    var body:some Scene{
        Window("搞文件 V"+(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.00"),id:"main"){
            RootWorkspace(store:store,stickyNotes:stickyNotes,stickyWindows:AppHub.stickyWindows!).frame(minWidth:1080,minHeight:700)
                .onAppear{delegate.store=store;delegate.reopen={openWindow(id:"main");NSApp.activate(ignoringOtherApps:true)}}
        }.defaultSize(width:1440,height:900)
        .commands{
            CommandGroup(replacing:.newItem){
                Button("新建 LaTeX"){store.newText(.latex,text:Templates.latex)}
                Button("新建 Markdown"){store.newText(.markdown)}.keyboardShortcut("n")
                Divider()
                Button("打开文件…",action:store.openPanel).keyboardShortcut("o")
                Button("打开文件夹…",action:store.openFolderPanel).keyboardShortcut("o",modifiers:[.command,.shift])
                Menu("新建其他格式"){
                    Button("CSV 表格"){store.newText(.csv,text:"名称,数值,备注\n项目,0,\n")};Button("纯文本"){store.newText(.text)}
                }
            }
            CommandGroup(replacing:.saveItem){
                Button("保存"){
                    if store.showingNotes || AppHub.isStickyWindow {_=AppHub.saveStickyNotes()}
                    else if let active=store.active{store.save(active)}
                }.keyboardShortcut("s").disabled(store.active?.kind.canSave != true && !store.showingNotes && !AppHub.isStickyWindow)
                Button("另存为…"){guard !store.showingNotes && !AppHub.isStickyWindow else{return};if let active=store.active{store.save(active,asCopy:true)}}.keyboardShortcut("s",modifiers:[.command,.shift]).disabled(store.active?.kind.isText != true || store.showingNotes || AppHub.isStickyWindow)
            }
            CommandGroup(after:.pasteboard){Button("查找…"){NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)),to:nil,from:FindSender())}.keyboardShortcut("f")}
            CommandMenu("工作区"){
                Button("返回首页"){store.showHome();openWindow(id:"main");NSApp.activate(ignoringOtherApps:true)}.keyboardShortcut("1")
                Divider()
                Button("编译当前 LaTeX"){guard !store.showingNotes && !AppHub.isStickyWindow else{return};if let active=store.active,store.save(active),let url=active.url{NotificationCenter.default.post(name:Notification.Name("GaoWenJian.compileActive"),object:url.path)}}.keyboardShortcut("b").disabled(store.active?.kind != .latex || store.showingNotes || AppHub.isStickyWindow)
                Button("关闭当前标签或便笺"){
                    if AppHub.isStickyWindow{NSApp.keyWindow?.performClose(nil)}
                    else if NSApp.keyWindow?.title.hasPrefix("搞文件 V") != true {NSApp.keyWindow?.performClose(nil)}
                    else if store.showingNotes{NSApp.keyWindow?.makeFirstResponder(nil);store.showingNotes=false}
                    else if let active=store.active{store.close(active)}
                }.keyboardShortcut("w")
                Button("文件历史…",action:store.showHistory).disabled(store.active?.url==nil)
                Button("在 Finder 显示"){if let url=store.active?.url{NSWorkspace.shared.activateFileViewerSelecting([url])}}.disabled(store.active?.url==nil)
                Divider();Button("显示主窗口"){openWindow(id:"main");NSApp.activate(ignoringOtherApps:true)}.keyboardShortcut("0")
            }
            CommandMenu("便笺"){
                Button("显示便笺中心"){showStickyNotes()}.keyboardShortcut("2")
                Button("新建便笺",action:newStickyNote).keyboardShortcut("n",modifiers:[.command,.shift])
                Divider()
                Button("恢复桌面便笺"){AppHub.stickyWindows?.restoreDesktopWindows()}
                Button("排列桌面便笺"){AppHub.stickyWindows?.arrangeDesktopWindows()}
                Button("隐藏桌面便笺"){AppHub.stickyWindows?.hideAll()}
            }
            CommandGroup(replacing:.help){Button("搞文件使用说明"){if let url=Bundle.main.url(forResource:"使用说明",withExtension:"txt"){NSWorkspace.shared.open(url)}}}
        }
        Settings{FileSettings(store:store,stickyNotes:stickyNotes).frame(width:720,height:550)}
    }
    private func showStickyNotes(){NSApp.keyWindow?.makeFirstResponder(nil);store.showingNotes=true;openWindow(id:"main");NSApp.activate(ignoringOtherApps:true)}
    private func newStickyNote(){NSApp.keyWindow?.makeFirstResponder(nil);if let id=stickyNotes.create(){AppHub.stickyWindows?.show(noteID:id)}}
}
final class FindSender:NSObject { @objc var tag:Int {Int(NSFindPanelAction.showFindPanel.rawValue)} }
@MainActor final class FileAppDelegate:NSObject,NSApplicationDelegate{
    weak var store:WorkspaceStore?
    var reopen:(()->Void)?
    func applicationDidFinishLaunching(_ notification:Notification){
        let args=CommandLine.arguments
        if let i=args.firstIndex(of:"--open"),args.count>i+1{(store ?? AppHub.store)?.open(URL(fileURLWithPath:args[i+1]))}
        AppHub.stickyWindows?.restoreDesktopWindows()
        if args.contains("--show-notes"){(store ?? AppHub.store)?.showingNotes=true}
    }
    func application(_ sender:NSApplication,openFiles filenames:[String]){for path in filenames{(store ?? AppHub.store)?.open(URL(fileURLWithPath:path))};reopen?();sender.reply(toOpenOrPrint:.success)}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{reopen?();return true}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply{
        sender.keyWindow?.makeFirstResponder(nil)
        guard (store ?? AppHub.store)?.prepareToQuit() != false else{return .terminateCancel}
        guard AppHub.stickyWindows?.prepareToQuit() != false else {
            let alert=NSAlert();alert.messageText="便笺尚未保存，已取消退出"
            alert.informativeText=AppHub.stickyNotes?.error ?? "请回到便笺中心重试保存或导出便笺。"
            alert.addButton(withTitle:"返回编辑");alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }
}

enum Templates {
    static let markdown="""
    # 新的开始

    在这里记录想法、整理材料和撰写文档。

    ## 待办

    - [ ] 整理资料
    - [ ] 完成初稿

    ## 数据

    | 项目 | 数值 |
    | --- | --- |
    | 示例 | 1 |

    ## 公式

    $$E = mc^2$$
    """
    static let latex="""
    \\documentclass[12pt]{article}
    \\usepackage{fontspec}
    \\usepackage{xeCJK}
    \\setCJKmainfont{PingFang SC}
    \\usepackage{amsmath,amssymb,graphicx}
    \\title{我的文档}
    \\author{}
    \\date{\\today}
    \\begin{document}
    \\maketitle
    \\section{开始写作}
    欢迎使用搞文件。本地编辑与离线编译。
    \\begin{equation}
    E = mc^2
    \\end{equation}
    \\end{document}
    """
}
