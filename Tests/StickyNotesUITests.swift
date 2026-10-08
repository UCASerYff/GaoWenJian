import AppKit
import Foundation
import SwiftUI

@MainActor private final class StickyTestTextView:StickyNativeTextView {
    let testUndo=UndoManager()
    override var undoManager:UndoManager? {testUndo}
}

@MainActor func runStickyNotesUITests()throws {
    guard FileSafety.root.path.hasPrefix("/private/tmp/"),CommandLine.arguments.contains("--data-dir")else{throw FileIssue.message("便笺 UI 测试只能使用隔离 /private/tmp 资料目录。")}
    func expect(_ condition:@autoclosure ()->Bool,_ reason:String)throws {if !condition(){throw FileIssue.message("便笺编辑器测试失败："+reason)}}
    let textView=StickyTestTextView(frame:NSRect(x:0,y:0,width:400,height:300))
    textView.isRichText=true;textView.allowsUndo=true;textView.testUndo.groupsByEvent=false
    let session=StickyRichEditorSession();session.textView=textView
    let original=NSAttributedString(string:"标题\n正文",attributes:[.font:NSFont.systemFont(ofSize:15)])
    textView.textStorage?.setAttributedString(original);textView.setSelectedRange(NSRange(location:0,length:2))
    textView.testUndo.removeAllActions()
    textView.testUndo.beginUndoGrouping();session.format("bold");textView.testUndo.endUndoGrouping()
    let bold=textView.textStorage?.attribute(.font,at:0,effectiveRange:nil) as? NSFont
    try expect(bold.map{NSFontManager.shared.traits(of:$0).contains(.boldFontMask)} == true,"选中内容未加粗")
    textView.testUndo.undo();try expect(textView.attributedString().isEqual(to:original),"加粗撤销没有恢复字体")
    textView.testUndo.redo();try expect(NSFontManager.shared.traits(of:textView.textStorage!.attribute(.font,at:0,effectiveRange:nil) as! NSFont).contains(.boldFontMask),"加粗重做失败")
    textView.testUndo.removeAllActions()
    let lines=NSAttributedString(string:"第一行\n第二行\n",attributes:[.font:NSFont.systemFont(ofSize:15)])
    textView.textStorage?.setAttributedString(lines);textView.setSelectedRange(NSRange(location:0,length:lines.length))
    textView.testUndo.removeAllActions()
    textView.testUndo.beginUndoGrouping();session.bullet();textView.testUndo.endUndoGrouping()
    try expect(textView.string=="• 第一行\n• 第二行\n","多行项目符号不正确")
    textView.testUndo.undo();try expect(textView.attributedString().isEqual(to:lines),"列表撤销留下重复文字")
    textView.testUndo.redo();try expect(textView.string=="• 第一行\n• 第二行\n","列表重做不正确")
    let wrapper=FileWrapper(regularFileWithContents:Data("fake PDF fixture".utf8));wrapper.preferredFilename="材料.pdf"
    let attached=NSMutableAttributedString(string:"附件保留在便笺中：")
    attached.append(NSAttributedString(attachment:NSTextAttachment(fileWrapper:wrapper)))
    let markdown=StickyMarkdown.text(attached,title:"标题")
    try expect(markdown.hasPrefix("# 标题\n\n"),"Markdown转换没有标题")
    try expect(markdown.contains("[附件：材料.pdf]"),"Markdown转换静默丢弃了附件标注")

    let folder=FileSafety.root.appendingPathComponent("StickyUITests-"+UUID().uuidString,isDirectory:true)
    defer{try? FileManager.default.removeItem(at:folder)}
    let store=StickyNotesStore(rootURL:folder)
    guard let id=store.create(title:"输入法测试",content:NSAttributedString(string:"起始：",attributes:[.font:NSFont.systemFont(ofSize:15)]))else{throw FileIssue.message(store.error ?? "无法创建输入法测试便笺")}
    let composing=StickyTestTextView(frame:NSRect(x:0,y:0,width:400,height:300))
    composing.isRichText=true;composing.allowsUndo=true
    composing.textStorage?.setAttributedString(store.content(for:id)!);composing.setSelectedRange(NSRange(location:composing.string.utf16.count,length:0))
    let composingSession=StickyRichEditorSession();composingSession.textView=composing
    let composingEditor=StickyRichTextEditor(store:store,noteID:id,session:composingSession)
    let coordinator=composingEditor.makeCoordinator();composing.delegate=coordinator
    composing.setMarkedText("zhongwen",selectedRange:NSRange(location:8,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
    try expect(composing.hasMarkedText(),"NSTextView没有建立真实marked composition")
    coordinator.textDidChange(Notification(name:NSText.didChangeNotification,object:composing))
    try expect(store.content(for:id)?.string == "起始：","临时拼音进入了正文或自动保存")
    try expect(!store.isDirty,"临时拼音错误地标为待保存")
    composing.setMarkedText("中文",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
    coordinator.textDidChange(Notification(name:NSText.didChangeNotification,object:composing))
    try expect(store.content(for:id)?.string == "起始：","尚未确认的中文候选提前进入正文")
    coordinator.textDidEndEditing(Notification(name:NSText.didEndEditingNotification,object:composing))
    try expect(!composing.hasMarkedText(),"结束编辑没有提交中文组合输入")
    try expect(store.content(for:id)?.string == "起始：中文","结束编辑丢失了中文组合输入")
    try expect(store.flush(),"中文组合输入没有成功落盘")
    try expect(StickyNotesStore(rootURL:folder).content(for:id)?.string == "起始：中文","重开资料未恢复已确认中文")

    try expect(store.trash(id:id),"输入法测试便笺未能进入回收站")
    let beforeTrashContent=store.content(for:id)?.string
    composing.string="不应写入回收站的迟到编辑通知"
    coordinator.textDidChange(Notification(name:NSText.didChangeNotification,object:composing))
    coordinator.textDidEndEditing(Notification(name:NSText.didEndEditingNotification,object:composing))
    try expect(store.error == nil && !store.isDirty && store.saveStatus == "已保存","移入回收站后的编辑器销毁通知产生了虚假保存错误")
    try expect(store.content(for:id)?.string == beforeTrashContent,"迟到编辑通知覆盖了回收站正文")

    guard let syncedID=store.create(title:"双编辑器",content:NSAttributedString(string:"原来较长的正文，足够产生旧范围",attributes:[.font:NSFont.systemFont(ofSize:15)]))else{throw FileIssue.message(store.error ?? "无法创建同步测试便笺")}
    let first=StickyRichEditorSession(),second=StickyRichEditorSession()
    let firstEditor=StickyRichTextEditor(store:store,noteID:syncedID,session:first)
    let secondEditor=StickyRichTextEditor(store:store,noteID:syncedID,session:second)
    let firstHost=NSHostingView(rootView:firstEditor.frame(width:380,height:260)),secondHost=NSHostingView(rootView:secondEditor.frame(width:380,height:260))
    let firstWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:380,height:260),styleMask:[.titled],backing:.buffered,defer:false)
    let secondWindow=NSWindow(contentRect:NSRect(x:400,y:0,width:380,height:260),styleMask:[.titled],backing:.buffered,defer:false)
    firstWindow.isReleasedWhenClosed=false;secondWindow.isReleasedWhenClosed=false;firstWindow.contentView=firstHost;secondWindow.contentView=secondHost
    defer{firstWindow.close();secondWindow.close()}
    func settle(){for _ in 0..<5{firstHost.layoutSubtreeIfNeeded();secondHost.layoutSubtreeIfNeeded();RunLoop.current.run(until:Date(timeIntervalSinceNow:0.015))}}
    settle()
    guard let firstView=first.textView,let secondView=second.textView else{throw FileIssue.message("双编辑器测试未建立原生NSTextView")}
    firstView.isContinuousSpellCheckingEnabled=false;secondView.isContinuousSpellCheckingEnabled=false
    firstView.setSelectedRange(NSRange(location:firstView.string.utf16.count,length:0));firstView.insertText("新增的长尾巴",replacementRange:firstView.selectedRange())
    settle()
    try expect(firstView.undoManager?.canUndo == true,"本地编辑未建立可撤销记录")
    try expect(secondView.string == firstView.string,"两个原生编辑器未同步相同便笺")
    secondView.setSelectedRange(NSRange(location:0,length:secondView.string.utf16.count));secondView.insertText("短文",replacementRange:secondView.selectedRange())
    settle()
    try expect(firstView.string == "短文","外部编辑器的新正文未同步回来")
    try expect(firstView.undoManager?.canUndo != true,"外部同步后仍保留已失效旧范围的undo记录")
    firstView.undoManager?.undo()
    try expect(firstView.string == "短文","失效撤销范围套到了外部正文")
    try expect(secondView.undoManager?.canUndo == true,"本地第二编辑器自己的撤销被错误清除")
    secondView.undoManager?.undo()
    settle()
    try expect(secondView.string.contains("新增的长尾巴") && firstView.string == secondView.string,"有效本地撤销没有保留并同步")
    try expect(secondView.undoManager?.canRedo == true,"有效本地撤销未保留重做")
    secondView.undoManager?.redo();settle()
    try expect(secondView.string == "短文" && firstView.string == "短文" && store.content(for:syncedID)?.string == "短文","重做没有进入自动保存正文并同步到另一窗口")
    try expect(store.flush(),"同步测试正文未保存")
    try expect(StickyNotesStore(rootURL:folder).content(for:syncedID)?.string == "短文","重开资料没有恢复重做后的正文")
    print("PASS: sticky formatting/list undo-redo, Markdown attachments, native IME commit, trash teardown and two-editor undo isolation")
}
