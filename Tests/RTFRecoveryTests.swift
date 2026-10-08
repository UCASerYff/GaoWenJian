import AppKit
import Foundation

@main
struct RTFRecoveryTests {
    @MainActor static func main() throws {
        guard CommandLine.arguments.contains("--data-dir") else { fatalError("Tests require --data-dir pointing to an isolated temporary directory.") }
        _ = NSApplication.shared
        let folder=FileSafety.root.appendingPathComponent("TestFiles/RTF-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let source=folder.appendingPathComponent("original.rtf")
        func rtf(_ string:String)throws->Data{try NSAttributedString(string:string,attributes:[.font:NSFont.systemFont(ofSize:14)]).data(from:NSRange(location:0,length:(string as NSString).length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])}
        let original=try rtf("原件内容");try original.write(to:source)
        var count=0
        func expect(_ condition:Bool,_ message:String){precondition(condition,message);count+=1}
        let model=RichTextModel();try model.load(source)
        model.content=NSAttributedString(string:"恢复文字",attributes:[.font:NSFont.boldSystemFont(ofSize:17),.foregroundColor:NSColor.systemRed]);model.markDirty()
        let draftURL=RTFRecovery.url(for:source),draft=try Data(contentsOf:draftURL)
        expect(try Data(contentsOf:source)==original,"draft modified original")
        expect(model.dirty && model.recoveryError==nil,"draft was not written")
        let recovered=RichTextModel();try recovered.load(source)
        expect(recovered.content.string=="恢复文字" && recovered.dirty,"did not recover unsaved RTF")
        expect(recovered.recoveryMessage != nil,"missing recovery notice")
        let restoredFont=recovered.content.attribute(.font,at:0,effectiveRange:nil) as? NSFont
        expect(restoredFont?.pointSize==17 && NSFontManager.shared.traits(of:restoredFont!).contains(.boldFontMask),"formatting lost in recovery")
        expect(try Data(contentsOf:source)==original,"recovery modified original")

        let changed=try rtf("外部修改原件");try changed.write(to:source)
        let conflict=RichTextModel();try conflict.load(source)
        expect(conflict.content.string=="外部修改原件" && !conflict.dirty,"stale draft was applied to changed original")
        expect(conflict.recoveryError != nil,"missing changed-original warning")
        conflict.content=NSAttributedString(string:"当前编辑");conflict.markDirty()
        expect(try Data(contentsOf:draftURL)==draft,"changed-original draft was overwritten")
        do{try recovered.save(source);fatalError("overwrote externally modified original")}catch{}
        expect(try Data(contentsOf:source)==changed,"external original changed during refused save")

        let damaged=Data("{bad-json".utf8);try damaged.write(to:draftURL,options:.atomic)
        let corrupt=RichTextModel();try corrupt.load(source)
        expect(corrupt.content.string=="外部修改原件" && corrupt.recoveryError != nil,"corrupt draft was treated as blank")
        corrupt.content=NSAttributedString(string:"新编辑");corrupt.markDirty()
        expect(try Data(contentsOf:draftURL)==damaged,"corrupt draft was overwritten")
        let package=RTFRecovery.Draft(version:1,sourcePath:source.path,baseDigest:FileSafety.digest(changed),rtfDigest:String(repeating:"0",count:64),rtf:try rtf("篡改内容"),writtenAt:Date())
        let badChecksum=try JSONEncoder().encode(package);try badChecksum.write(to:draftURL,options:.atomic)
        let invalid=RichTextModel();try invalid.load(source)
        expect(invalid.recoveryError != nil && !invalid.dirty,"invalid checksum accepted")
        expect(try Data(contentsOf:draftURL)==badChecksum,"invalid checksum draft was removed")

        let freshURL=folder.appendingPathComponent("fresh.rtf");try original.write(to:freshURL)
        let fresh=RichTextModel();try fresh.load(freshURL);fresh.content=NSAttributedString(string:"正常保存");fresh.markDirty()
        expect(FileManager.default.fileExists(atPath:RTFRecovery.url(for:freshURL).path),"missing fresh recovery")
        try fresh.save(freshURL)
        expect(!fresh.dirty && !FileManager.default.fileExists(atPath:RTFRecovery.url(for:freshURL).path),"saved draft not cleared")
        expect(try FileSafety.snapshots(for:freshURL).count==1,"original snapshot missing")
        fresh.content=NSAttributedString(string:"待丢弃");fresh.markDirty()
        NotificationCenter.default.post(name:Notification.Name("GaoWenJian.discardDraft"),object:source.path)
        RunLoop.main.run(until:Date().addingTimeInterval(0.15))
        expect(FileManager.default.fileExists(atPath:RTFRecovery.url(for:freshURL).path),"unrelated discard removed draft")
        NotificationCenter.default.post(name:Notification.Name("GaoWenJian.discardDraft"),object:freshURL.path)
        RunLoop.main.run(until:Date().addingTimeInterval(0.15))
        expect(!FileManager.default.fileExists(atPath:RTFRecovery.url(for:freshURL).path),"authorized discard did not clear draft")

        let brokenURL=folder.appendingPathComponent("broken.rtf"),broken=Data("invalid original".utf8);try broken.write(to:brokenURL)
        let failed=RichTextModel()
        do{try failed.load(brokenURL);fatalError("accepted invalid original RTF")}catch{}
        do{try failed.save(brokenURL);fatalError("saved an unreadable original")}catch{}
        expect(try Data(contentsOf:brokenURL)==broken && !failed.loaded,"unreadable original overwritten")
        print("PASS: RTF recovery, rich formatting, unchanged original, digest conflict, corrupt/checksum drafts, safe save and exact discard notification (\(count) assertions).")
    }
}
