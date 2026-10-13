import Foundation
import UniformTypeIdentifiers
import ImageIO
import PDFKit

/// Preflight for untrusted handoff files. Editors continue to use their existing engines.
enum DocumentHandoffSafety {
    static let maximumDocumentBytes = 268_435_456
    static let maximumOfficeBytes = 67_108_864
    static let maximumExpandedOfficeBytes: UInt64 = 268_435_456
    static let maximumTextBytes = 8_388_608

    private static func canonicalPath(_ url:URL)->String {
        var path=url.resolvingSymlinksInPath().standardizedFileURL.path
        for alias in ["/tmp","/var","/etc"] where path == alias || path.hasPrefix(alias + "/") { path="/private"+path;break }
        return path
    }

    static func permittedLocation(_ url: URL, verifiedStaging: Bool = false) throws {
        let path = canonicalPath(url)
        let home = FileManager.default.homeDirectoryForCurrentUser
        var blocked = [FileSafety.root, home.appendingPathComponent("Library/Application Support/GaoSeries/GaoWenJian-Backups"),
                       home.appendingPathComponent("Library/Keychains"), home.appendingPathComponent("Library/Preferences"),
                       home.appendingPathComponent("Desktop/搞app/搞文件/安全备份")]
        if Bundle.main.bundleURL.pathExtension == "app" { blocked.append(Bundle.main.bundleURL) }
        // The app's own incoming payload is intentionally usable; other internal records are not documents.
        let incoming = canonicalPath(FileSafety.root.appendingPathComponent("Exchange/Staging"))
        if verifiedStaging && path.hasPrefix(incoming + "/") { return }
        for root in blocked {
            let protected = canonicalPath(root)
            if path == protected || path.hasPrefix(protected + "/") {
                throw GaoActionIssue.rejected("protectedLocation", "不能通过文档交接读取应用内部资料、凭据或安全备份。")
            }
        }
    }

    static func review(_ url: URL, declaredUTI: String? = nil, verifiedStaging: Bool = false) throws -> FileKind {
        try permittedLocation(url,verifiedStaging:verifiedStaging)
        let values = try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.isReadableKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.isReadable != false,
              let count = values.fileSize, count <= maximumDocumentBytes else {
            throw GaoActionIssue.rejected("documentLimit", "交接仅接收可读取的普通文档；单份文档限 256 MiB，请另选文件。")
        }
        let kind = FileKind(url:url)
        guard kind != .other else { throw GaoActionIssue.rejected("unsupportedDocument", "此文档格式尚未支持安全交接，请使用普通文件导入。") }
        if let declaredUTI {
            let declared = UTType(declaredUTI) ?? UTType(mimeType:declaredUTI)
            let textNames:Set<String> = ["public.utf8-plain-text","public.plain-text","text/plain","net.daringfireball.markdown","public.markdown","text/markdown"]
            let textCompatible = kind.isText && (textNames.contains(declaredUTI) || declared?.conforms(to:.text) == true)
            // Extension lookup depends on LaunchServices and may be dynamic in an
            // isolated process. Fixed known pairs remain deterministic and reject
            // generic public.data claims instead of trusting global associations.
            let known: [String:Set<String>] = [
                "pdf":["com.adobe.pdf","application/pdf"], "rtf":["public.rtf","text/rtf","application/rtf"],
                "png":["public.png","image/png"], "jpg":["public.jpeg","image/jpeg"], "jpeg":["public.jpeg","image/jpeg"],
                "tiff":["public.tiff","image/tiff"], "gif":["com.compuserve.gif","image/gif"],
                "heic":["public.heic","image/heic"], "webp":["org.webmproject.webp","public.webp","image/webp"],
                "bmp":["com.microsoft.bmp","image/bmp"],
                "doc":["com.microsoft.word.doc","application/msword"],
                "docx":["org.openxmlformats.wordprocessingml.document","application/vnd.openxmlformats-officedocument.wordprocessingml.document"],
                "xlsx":["org.openxmlformats.spreadsheetml.sheet","application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"],
                "xls":["com.microsoft.excel.xls","application/vnd.ms-excel"],
                "pptx":["org.openxmlformats.presentationml.presentation","application/vnd.openxmlformats-officedocument.presentationml.presentation"],
                "ppt":["com.microsoft.powerpoint.ppt","application/vnd.ms-powerpoint"],
                "odt":["org.oasis-open.opendocument.text","application/vnd.oasis.opendocument.text"],
                "ods":["org.oasis-open.opendocument.spreadsheet","application/vnd.oasis.opendocument.spreadsheet"],
                "odp":["org.oasis-open.opendocument.presentation","application/vnd.oasis.opendocument.presentation"]
            ]
            let fixedCompatible = known[url.pathExtension.lowercased()]?.contains(declaredUTI) == true
            let actual=UTType(filenameExtension:url.pathExtension)
            let registeredCompatible = actual?.isDeclared == true && declared?.isDeclared == true
                && declaredUTI != "public.data" && (actual!.conforms(to:declared!) || declared!.conforms(to:actual!))
            guard textCompatible || fixedCompatible || registeredCompatible else {
                throw GaoActionIssue.rejected("documentTypeMismatch", "文档扩展名与声明类型不一致或类型未知，已停止打开。")
            }
        }
        if kind.isText {
            guard count <= maximumTextBytes, let text = String(data:try Data(contentsOf:url),encoding:.utf8), !text.contains("\0") else {
                throw GaoActionIssue.rejected("invalidText", "交接文本须为有效 UTF-8，正文限 8 MiB；内容不会被截断。")
            }
        } else if kind == .pdf {
            guard let pdf = PDFDocument(url:url), !pdf.isLocked, pdf.pageCount > 0, pdf.pageCount <= 10_000 else {
                throw GaoActionIssue.rejected("invalidPDF", "PDF 无法读取、需要密码或页面过多，请先在本机核对。")
            }
        } else if kind.isOfficeViewer {
            guard count <= maximumOfficeBytes else { throw GaoActionIssue.rejected("officeLimit", "Office 交接文档限 64 MiB，请另选文件。") }
            if ["docx","docm","dotx","dotm","xlsx","xlsm","xltx","xltm","pptx","pptm","potx","potm","ppsx","odt","ods","odp"].contains(url.pathExtension.lowercased()) {
                try reviewOfficeArchive(url)
            }
        } else if kind == .richText {
            guard count <= maximumTextBytes else { throw GaoActionIssue.rejected("richTextLimit", "富文本交接文档限 8 MiB。") }
            let bytes = try Data(contentsOf:url)
            guard let source = String(data:bytes,encoding:.ascii) ?? String(data:bytes,encoding:.isoLatin1), source.hasPrefix("{\\rtf"),
                  source.range(of:"\\\\(?:object|objdata|objlink|filetbl|field|pict|htmltag|import|include)[^a-zA-Z]",options:[.regularExpression,.caseInsensitive]) == nil else {
                throw GaoActionIssue.rejected("unsafeRichText", "交接只接收不含图片、嵌入对象或外部字段的文字 RTF；请由原应用导出纯文本或 PDF。")
            }
        } else if kind == .image {
            guard url.pathExtension.lowercased() != "svg", count <= maximumOfficeBytes,
                  let source = CGImageSourceCreateWithURL(url as CFURL,nil), CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue > 0, height.doubleValue > 0, width.doubleValue * height.doubleValue <= 80_000_000 else {
                throw GaoActionIssue.rejected("invalidImage", "图片无法安全解码或尺寸过大；请使用 64 MiB / 8000 万像素以内的常见位图。")
            }
        }
        return kind
    }

    private struct ZIPEntry { let name:String; let expanded:UInt64 }
    static func reviewOfficeArchive(_ url:URL) throws {
        let bytes = [UInt8](try Data(contentsOf:url))
        func u16(_ offset:Int)->UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset+1]) << 8 }
        func u32(_ offset:Int)->UInt32 { UInt32(u16(offset)) | UInt32(u16(offset+2)) << 16 }
        guard bytes.count >= 22 else { throw invalidArchive() }
        var end:Int?
        for index in stride(from:bytes.count-22,through:max(0,bytes.count-65_557),by:-1) {
            if u32(index) == 0x06054b50, index + 22 + Int(u16(index+20)) == bytes.count { end=index; break }
        }
        guard let end, u16(end+4)==0, u16(end+6)==0, u16(end+8)==u16(end+10),
              u16(end+10) > 0, u16(end+10) < 10_000,
              u32(end+12) != UInt32.max, u32(end+16) != UInt32.max else { throw invalidArchive() }
        let centralStart = Int(u32(end+16)), centralSize = Int(u32(end+12))
        guard centralStart >= 0, centralStart + centralSize <= end else { throw invalidArchive() }
        var offset = centralStart, total:UInt64 = 0, seen=Set<String>(), entries:[ZIPEntry]=[]
        for _ in 0..<Int(u16(end+10)) {
            guard offset + 46 <= centralStart + centralSize, u32(offset)==0x02014b50 else { throw invalidArchive() }
            let flags=u16(offset+8), method=u16(offset+10), expanded=UInt64(u32(offset+24))
            let nameSize=Int(u16(offset+28)), extraSize=Int(u16(offset+30)), commentSize=Int(u16(offset+32))
            let next=offset+46+nameSize+extraSize+commentSize
            guard next <= centralStart+centralSize, nameSize > 0, nameSize <= 4096,
                  flags & 1 == 0, [0,8].contains(method), expanded <= 67_108_864,
                  let name=String(bytes:bytes[(offset+46)..<(offset+46+nameSize)],encoding:.utf8),
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"),
                  !name.split(separator:"/").contains(where:{$0==".." || $0=="."}), seen.insert(name).inserted else { throw invalidArchive() }
            let unixMode = u32(offset+38) >> 16
            guard unixMode & 0xf000 == 0 || unixMode & 0xf000 == 0x8000 || (unixMode & 0xf000 == 0x4000 && name.hasSuffix("/")) else { throw invalidArchive() }
            let lower=name.lowercased()
            guard !lower.contains("/embeddings/"), !lower.contains("/activex/"), !lower.contains("/externallinks/"), !lower.hasSuffix("vbaproject.bin") else {
                throw GaoActionIssue.rejected("activeOfficeContent", "Office 文件含宏、外部链接或嵌入对象，未通过安全交接；请导出静态文档或 PDF。")
            }
            total += expanded
            guard total <= maximumExpandedOfficeBytes else { throw GaoActionIssue.rejected("officeExpansionLimit", "Office 文档展开后过大，已停止加载。") }
            entries.append(ZIPEntry(name:name,expanded:expanded)); offset=next
        }
        guard offset==centralStart+centralSize else { throw invalidArchive() }
        for entry in entries where !entry.name.hasSuffix("/") {
            if Task.isCancelled { throw GaoActionIssue.rejected("cancelled","已取消文档检查，原件未改动。") }
            let isXML = entry.name.lowercased().hasSuffix(".xml") || entry.name.lowercased().hasSuffix(".rels")
            guard !isXML || entry.expanded <= 8_388_608 else { throw invalidArchive() }
            let process=Process(), output=Pipe()
            process.executableURL=URL(fileURLWithPath:"/usr/bin/unzip")
            let literalMember = entry.name.map { ["\\","[","]","*","?"].contains(String($0)) ? "\\"+String($0):String($0) }.joined()
            process.arguments=["-p",url.path,literalMember]
            process.standardOutput=output; process.standardError=FileHandle.nullDevice
            try process.run()
            var content=Data(), actual:UInt64=0
            while true {
                let chunk=output.fileHandleForReading.readData(ofLength:65_536)
                if chunk.isEmpty { break }
                actual += UInt64(chunk.count)
                if actual > entry.expanded || Task.isCancelled { process.terminate(); process.waitUntilExit(); throw invalidArchive() }
                if isXML { content.append(chunk) }
            }
            process.waitUntilExit()
            guard process.terminationStatus==0, actual==entry.expanded else { throw invalidArchive() }
            guard !isXML || (String(data:content,encoding:.utf8) ?? String(data:content,encoding:.utf16)) != nil else { throw invalidArchive() }
            if isXML {
                guard
                  let xml=String(data:content,encoding:.utf8) ?? String(data:content,encoding:.utf16),
                  xml.range(of:"<!\\s*(DOCTYPE|ENTITY)|TargetMode\\s*=\\s*['\"]External['\"]",options:[.regularExpression,.caseInsensitive]) == nil else {
                throw GaoActionIssue.rejected("externalOfficeContent", "Office 文件包含外部资源或 XML 实体声明，已停止加载。请导出静态 PDF。")
                }
            }
        }
    }
    private static func invalidArchive()->GaoActionIssue { .rejected("invalidOfficeArchive","Office 文档包损坏、加密、包含不安全条目或展开过大，已停止加载。") }
}
