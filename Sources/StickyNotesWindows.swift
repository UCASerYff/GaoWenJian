import AppKit
import SwiftUI
import Combine

@MainActor final class StickyNotesWindowManager:NSObject,ObservableObject {
    let store:StickyNotesStore
    private var controllers:[UUID:StickyDesktopWindowController]=[:]
    private var observation:AnyCancellable?
    init(store:StickyNotesStore){
        self.store=store;super.init()
        observation=store.$notes.sink{[weak self] _ in DispatchQueue.main.async{self?.synchronize()}}
    }
    func show(noteID:UUID){
        guard store.notes.contains(where:{$0.id==noteID && $0.deletedAt == nil})else{return}
        _ = store.updateMetadata(id:noteID){$0.isOnDesktop=true}
        let controller=controller(for:noteID);controller.synchronize();controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func restoreDesktopWindows(){for note in store.notes where note.deletedAt == nil && note.isOnDesktop{let controller=controller(for:note.id);controller.synchronize();controller.showWindow(nil)}}
    func arrangeDesktopWindows(){
        guard let screen=NSScreen.main?.visibleFrame else{return}
        let visible=store.notes.filter{$0.deletedAt == nil && $0.isOnDesktop}.sorted{$0.createdAt<$1.createdAt}
        var x=screen.minX+24;var top=screen.maxY-24
        for note in visible {
            let width=min(max(270,note.frame.width),max(270,screen.width-48));let height=min(max(150,note.frame.height),max(150,screen.height-48))
            if x+width>screen.maxX-24{x=screen.minX+24;top -= 46}
            if top-height<screen.minY+24{top=screen.maxY-24}
            _ = store.updateMetadata(id:note.id){$0.frame=StickyNoteFrame(x:Double(x),y:Double(top-height),width:Double(width),height:Double(height))}
            let controller=controller(for:note.id);controller.restoreStoredFrame();controller.showWindow(nil)
            x += width+16
        }
        _ = store.flush()
    }
    /// A temporary hide preserves the launch restoration flag; closing a single window clears it.
    func hideAll(){guard prepareToQuit()else{return};for controller in controllers.values{controller.closeWithoutChangingVisibility()}}
    func prepareToQuit()->Bool{NSApp.keyWindow?.makeFirstResponder(nil);for controller in controllers.values{controller.commitEditing();controller.persistFrame()};return !store.isDirty || store.flush()}
    private func controller(for id:UUID)->StickyDesktopWindowController {
        if let existing=controllers[id]{return existing}
        let result=StickyDesktopWindowController(store:store,noteID:id);controllers[id]=result;return result
    }
    private func synchronize(){
        for (id,controller) in controllers {
            guard let note=store.notes.first(where:{$0.id==id}),note.deletedAt == nil else{controller.closeWithoutChangingVisibility();controllers.removeValue(forKey:id);continue}
            controller.synchronize()
            if !note.isOnDesktop && !store.isDirty {controller.closeWithoutChangingVisibility()}
        }
    }
}

@MainActor private final class StickyDesktopWindowController:NSWindowController,NSWindowDelegate {
    private let store:StickyNotesStore
    private let noteID:UUID
    private var applyingFrame=false
    private var collapsed=false
    private var frameTimer:Timer?
    private var didShow=false
    private var note:StickyNote? {store.notes.first{$0.id==noteID}}
    init(store:StickyNotesStore,noteID:UUID){
        self.store=store;self.noteID=noteID
        let panel=StickyDesktopPanel(contentRect:NSRect(x:180,y:180,width:360,height:300),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        super.init(window:panel)
        panel.delegate=self;panel.titleVisibility = .hidden;panel.titlebarAppearsTransparent=true;panel.isReleasedWhenClosed=false;panel.hidesOnDeactivate=false;panel.isFloatingPanel=false;panel.minSize=NSSize(width:270,height:150);panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.identifier=NSUserInterfaceItemIdentifier("sticky-note-"+noteID.uuidString)
        panel.doubleClickTitle={ [weak self] in self?.toggleCollapsed() }
        panel.contentView=NSHostingView(rootView:StickyDesktopContent(store:store,noteID:noteID,onCollapse:{[weak self] in self?.toggleCollapsed()}))
        panel.setAccessibilityLabel("搞文件桌面便笺")
        synchronize()
    }
    required init?(coder:NSCoder){fatalError("不支持归档窗口初始化")}
    override func showWindow(_ sender:Any?){if !didShow{restoreFrame();didShow=true};super.showWindow(sender)}
    func synchronize(){
        guard let note,let window else{return}
        window.title=note.title.isEmpty ? "未命名便笺" : note.title
        window.backgroundColor=note.color.paperColor;window.level=note.isPinned ? .floating:.normal;window.alphaValue=note.isTranslucent ? 0.82:1
        if note.isCollapsed != collapsed {applyCollapsed(note.isCollapsed)}
    }
    func hideKeepingNote(){commitEditing();guard store.flush()else{showSaveFailure();return};_ = store.updateMetadata(id:noteID){$0.isOnDesktop=false};guard store.flush()else{_ = store.updateMetadata(id:noteID){$0.isOnDesktop=true};showSaveFailure();return};window?.orderOut(nil)}
    func closeWithoutChangingVisibility(){window?.orderOut(nil)}
    func windowShouldClose(_ sender:NSWindow)->Bool{persistFrame();hideKeepingNote();return false}
    func windowDidMove(_ notification:Notification){scheduleFrameSave()}
    func windowDidResize(_ notification:Notification){scheduleFrameSave()}
    func windowDidMiniaturize(_ notification:Notification){persistFrame()}
    func persistFrame(){
        frameTimer?.invalidate();frameTimer=nil
        guard !applyingFrame,let window,let note else{return}
        let actual=window.frame
        let height=collapsed ? note.frame.height:Double(actual.height)
        let stored=StickyNoteFrame(x:Double(actual.origin.x),y:collapsed ? Double(actual.maxY)-height:Double(actual.origin.y),width:Double(actual.width),height:height)
        if abs(stored.x-note.frame.x)>0.1 || abs(stored.y-note.frame.y)>0.1 || abs(stored.width-note.frame.width)>0.1 || abs(stored.height-note.frame.height)>0.1 {_ = store.updateMetadata(id:noteID){$0.frame=stored}}
    }
    func commitEditing(){window?.makeFirstResponder(nil)}
    private func scheduleFrameSave(){guard !applyingFrame else{return};frameTimer?.invalidate();frameTimer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:false){[weak self] _ in Task{@MainActor in self?.persistFrame()}}}
    private func restoreFrame(){
        guard let note,let window else{return}
        var frame=NSRect(x:note.frame.x,y:collapsed ? note.frame.y+note.frame.height-56:note.frame.y,width:max(270,note.frame.width),height:collapsed ? 56:max(150,note.frame.height))
        let screens=NSScreen.screens.map(\.visibleFrame)
        if let screen=screens.first(where:{$0.intersects(frame)}) ?? NSScreen.main?.visibleFrame {
            frame.size.width=min(frame.width,screen.width);frame.size.height=min(frame.height,screen.height)
            frame.origin.x=max(screen.minX,min(frame.minX,screen.maxX-frame.width));frame.origin.y=max(screen.minY,min(frame.minY,screen.maxY-frame.height))
        }
        applyingFrame=true;window.setFrame(frame,display:false);applyingFrame=false
    }
    func restoreStoredFrame(){restoreFrame()}
    private func toggleCollapsed(){commitEditing();persistFrame();_ = store.updateMetadata(id:noteID){$0.isCollapsed.toggle()};synchronize()}
    private func applyCollapsed(_ value:Bool){
        guard let window,let note else{return};collapsed=value;applyingFrame=true
        let old=window.frame;let height=value ? CGFloat(56):CGFloat(max(150,note.frame.height))
        window.minSize=NSSize(width:270,height:value ? 56:150)
        if value{window.styleMask.remove(.resizable)}else{window.styleMask.insert(.resizable)}
        window.setFrame(NSRect(x:old.minX,y:old.maxY-height,width:old.width,height:height),display:true,animate:false);applyingFrame=false
    }
    private func showSaveFailure(){let alert=NSAlert();alert.messageText="便笺尚未保存";alert.informativeText=store.error ?? "自动保存未完成。窗口会保留，请重试保存或检查资料路径。";alert.addButton(withTitle:"好");if let window{alert.beginSheetModal(for:window)}else{alert.runModal()}}
}

@MainActor private final class StickyDesktopPanel:NSPanel {
    var doubleClickTitle:(()->Void)?
    override var canBecomeKey:Bool{true}
    override var canBecomeMain:Bool{true}
    override func sendEvent(_ event:NSEvent){
        if event.type == .leftMouseDown,event.clickCount == 2,event.locationInWindow.y>=contentLayoutRect.maxY {doubleClickTitle?();return}
        super.sendEvent(event)
    }
}

private struct StickyDesktopContent:View {
    @ObservedObject var store:StickyNotesStore
    let noteID:UUID
    let onCollapse:()->Void
    private var note:StickyNote?{store.notes.first{$0.id==noteID}}
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:8) {
                Text(note?.title.isEmpty == false ? note!.title:"未命名便笺").font(.system(size:12,weight:.semibold)).lineLimit(1)
                Spacer(minLength:0)
                if note?.isPinned == true{Image(systemName:"pin.fill").font(.system(size:10))}
                Button(action:onCollapse){Image(systemName:note?.isCollapsed == true ? "chevron.down":"chevron.up")}.buttonStyle(.plain).font(.system(size:10)).help(note?.isCollapsed == true ? "展开便笺（也可双击标题栏）":"收起便笺（也可双击标题栏）")
            }.padding(.leading,76).padding(.trailing,12).frame(height:32).contentShape(Rectangle()).onTapGesture(count:2,perform:onCollapse)
            if note?.isCollapsed != true {StickyNoteDetail(store:store,noteID:noteID,desktop:true,onCollapse:onCollapse)}
            else {Spacer(minLength:0)}
        }.background(Color(nsColor:note?.color.paperColor ?? StickyNoteColor.yellow.paperColor)).foregroundStyle(Color(nsColor:.black)).ignoresSafeArea()
    }
}
