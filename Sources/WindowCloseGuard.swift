import AppKit
import SwiftUI

struct WindowCloseGuard:NSViewRepresentable {
    let store:WorkspaceStore
    let stickyNotes:StickyNotesStore
    func makeNSView(context:Context)->GuardView{GuardView(store:store,stickyNotes:stickyNotes)}
    func updateNSView(_ view:GuardView,context:Context){}
    final class GuardView:NSView {
        let store:WorkspaceStore
        let stickyNotes:StickyNotesStore
        var guardDelegate:Delegate?
        init(store:WorkspaceStore,stickyNotes:StickyNotesStore){self.store=store;self.stickyNotes=stickyNotes;super.init(frame:.zero)}
        required init?(coder:NSCoder){fatalError()}
        override func viewDidMoveToWindow(){
            super.viewDidMoveToWindow()
            if let window,guardDelegate==nil{
                let proxy=Delegate(store:store,stickyNotes:stickyNotes,previous:window.delegate)
                guardDelegate=proxy;window.delegate=proxy
            }
        }
    }
    final class Delegate:NSObject,NSWindowDelegate {
        let store:WorkspaceStore
        let stickyNotes:StickyNotesStore
        let previous:NSWindowDelegate?
        init(store:WorkspaceStore,stickyNotes:StickyNotesStore,previous:NSWindowDelegate?){self.store=store;self.stickyNotes=stickyNotes;self.previous=previous}
        func windowShouldClose(_ sender:NSWindow)->Bool{
            sender.makeFirstResponder(nil)
            guard store.prepareToQuit() else{return false}
            guard !stickyNotes.isDirty || stickyNotes.flush() else {
                let alert=NSAlert();alert.messageText="便笺尚未保存"
                alert.informativeText=stickyNotes.error ?? "请回到便笺中心重试保存。"
                alert.addButton(withTitle:"返回编辑");alert.runModal()
                return false
            }
            return previous?.windowShouldClose?(sender) ?? true
        }
        override func responds(to selector:Selector!)->Bool{super.responds(to:selector) || (previous?.responds(to:selector) ?? false)}
        override func forwardingTarget(for selector:Selector!)->Any?{if previous?.responds(to:selector)==true{return previous};return super.forwardingTarget(for:selector)}
    }
}
