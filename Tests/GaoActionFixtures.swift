import Foundation
import CoreGraphics
import Darwin

/// Portable fixture identities are filled only inside the isolated temporary test root.
enum GaoActionFixtures {
    static let clock = GaoActionContract.date("2026-10-12T12:00:00Z")!
    static let names = ["v1-documents-newText","v1-storage-directory","v1-ocr-partial","v1-duplicate-request","v1-expired","v1-path-traversal","v1-unknown-action","v2-unsupported"]
    static let hello = Data("hello\n".utf8)
    static func requestID(_ number: Int) -> String { String(format:"11111111-1111-4111-8111-%012d",number) }
    static func generate(in root: URL) throws -> [String:URL] {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let referenced = root.appendingPathComponent("测试 临时目录",isDirectory:true)
        try FileManager.default.createDirectory(at:referenced,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let stat = try GaoPrivateIO.directory(referenced).statValue()
        let modified = Date(timeIntervalSince1970:Double(stat.st_mtimespec.tv_sec)+Double(stat.st_mtimespec.tv_nsec)/1_000_000_000)
        let reference = GaoActionReference(id:"directory-1",kind:"directory",fileURL:referenced.absoluteString,displayName:"测试 临时目录",declaredIdentity:GaoDeclaredIdentity(volumeUUID:try referenced.resourceValues(forKeys:[.volumeUUIDStringKey]).volumeUUIDString,device:UInt64(bitPattern:Int64(stat.st_dev)),inode:UInt64(stat.st_ino),byteCount:Int64(stat.st_size),modifiedAt:fractionalDate(modified)))
        let originalPDF = root.appendingPathComponent("两页扫描件.pdf")
        var box = CGRect(x:0,y:0,width:200,height:300)
        guard let context = CGContext(originalPDF as CFURL,mediaBox:&box,nil) else { throw GaoActionContract.reject("fixtureFailure","测试 PDF 创建失败。") }
        for _ in 0..<2 { context.beginPDFPage(nil); context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(box); context.endPDFPage() }; context.closePDF()
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:originalPDF.path)
        let originalSHA = FileSafety.digest(try Data(contentsOf:originalPDF))
        var outputs: [String:URL] = [:]
        for (offset,name) in names.enumerated() {
            var manifest = GaoActionManifest(kind:"request",requestID:requestID(offset+1),sourceBundleID:"com.gaoseries.FixtureSender",targetBundleID:GaoActionContract.bundleID,action:"documents.newText",createdAt:"2026-10-12T12:00:00Z",expiresAt:"2026-10-12T12:02:00Z",nonce:Data(repeating:0,count:32).base64EncodedString(),items:[GaoActionItem(id:"input-1",relativePath:"payload/input.txt",uti:"text/plain",byteCount:6,sha256:"5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")],references:[],parameters:["suggestedTitle":.string("交接测试")])
            switch name {
            case "v1-storage-directory": manifest.action = "storage.inspect"; manifest.items = []; manifest.references = [reference]; manifest.parameters = ["mode":.string("metadata")]
            case "v1-ocr-partial":
                manifest.kind = "result"; manifest.sourceBundleID = "com.gaoseries.GaoJieTu"; manifest.action = "ocr.files"; manifest.parameters = [:]
                manifest.inReplyTo = requestID(3); manifest.status = "partial"; manifest.errorCode = "pageFailed"
                manifest.provenance = ["sourceItemID":.string("two-page-input"),"sourceSHA256":.string(originalSHA),"pages":.array([.object(["pageNumber":.number(1),"status":.string("completed")]),.object(["pageNumber":.number(2),"status":.string("failed"),"errorCode":.string("recognitionFailed")])])]
            case "v1-expired": manifest.createdAt = "2026-10-12T11:57:00Z"; manifest.expiresAt = "2026-10-12T11:59:00Z"
            case "v1-path-traversal": manifest.items[0].relativePath = "payload/../input.txt"
            case "v1-unknown-action": manifest.action = "documents.executeShell"
            case "v2-unsupported": manifest.schemaVersion = 2
            default: break
            }
            let url = root.appendingPathComponent(name+".gaoaction",isDirectory:true)
            try write(manifest:manifest,payload:manifest.items.isEmpty ? [:] : ["input.txt":hello],to:url)
            outputs[name] = url
        }
        return outputs
    }
    static func write(manifest: GaoActionManifest, payload: [String:Data], to url: URL) throws {
        try FileManager.default.createDirectory(at:url.appendingPathComponent("payload"),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path)
        for (name,bytes) in payload {
            let file = url.appendingPathComponent("payload/"+name)
            try bytes.write(to:file); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        let destination = url.appendingPathComponent("manifest.json")
        try encoder.encode(manifest).write(to:destination)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
    }
    private static func fractionalDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return f.string(from:date)
    }
}
