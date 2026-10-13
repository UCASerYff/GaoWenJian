import Foundation
import Darwin

enum DocumentHandoffSafetyTests {
    /// Use a sibling of the isolated data directory: internal records must stay blocked.
    static func run(in parent: URL) throws {
        let fm = FileManager.default
        let root = parent.appendingPathComponent("DocumentSafety-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            let passed:Bool
            do { passed = try condition() }
            catch { throw FileIssue.message("文档交接安全测试异常：" + message + "：" + error.localizedDescription) }
            guard passed else { throw FileIssue.message("文档交接安全测试失败：" + message) }
            checks += 1
        }
        func rejected(_ message: String, _ operation: () throws -> Void) throws {
            var refused = false
            do { try operation() } catch { refused = true }
            try check(refused, message)
        }
        func file(_ name: String, _ bytes: Data) throws -> URL {
            let url = root.appendingPathComponent(name)
            try bytes.write(to: url, options: .withoutOverwriting)
            return url
        }
        func text(_ name: String, _ value: String) throws -> URL { try file(name, Data(value.utf8)) }
        func archive(_ name: String, _ entries: [ZIPPart], declaredCount: UInt16? = nil) throws -> URL {
            try file(name, storedZIP(entries, declaredCount: declaredCount))
        }

        // Genuine documents use the same original local factories as normal user files.
        for (ext, kind) in [("docx", FileKind.word), ("xlsx", .spreadsheet), ("pptx", .presentation)] {
            let original = root.appendingPathComponent("中文 空格 只读.\(ext)")
            try OfficeFactory.create(kind: ext, to: original)
            let before = try Data(contentsOf: original)
            let modified = try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            try check(try DocumentHandoffSafety.review(original) == kind, "正常 \(ext) 可以安全交接")
            try check(try Data(contentsOf: original) == before, "\(ext) 检查不改写原文件")
            try check(try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified, "\(ext) 检查不修改时间戳")
        }

        let unicode = "中文 e\u{301} 😀\r\n第二页\u{000C}\n"
        let plain = try text("文字 输入.txt", unicode)
        try check(try DocumentHandoffSafety.review(plain, declaredUTI: "public.utf8-plain-text") == .text, "UTF-8 普通文本可过")
        try check(try String(contentsOf: plain, encoding: .utf8) == unicode, "Unicode、CRLF、页分隔不转换或截断")
        let markdown = try text("识别.md", "# 标题\n\n- [ ] 待办\n")
        try check(try DocumentHandoffSafety.review(markdown, declaredUTI: "text/markdown") == .markdown, "Markdown MIME 类型可过")
        let html = try text("安全加载.html", "<script>throw 1</script><img src='https://invalid.example/image'>")
        try check(try DocumentHandoffSafety.review(html) == .text, "HTML 使用现有纯文本路由")
        try rejected("文本不接受图像 UTI") { _ = try DocumentHandoffSafety.review(plain, declaredUTI: "public.image") }
        try rejected("拒绝未知 UTI") { _ = try DocumentHandoffSafety.review(plain, declaredUTI: "com.example.unregistered-document-safety") }
        let unknown = try text("未知.unknown-handoff", "hello\n")
        try rejected("拒绝未知扩展名") { _ = try DocumentHandoffSafety.review(unknown) }
        let badUTF8 = try file("损坏.txt", Data([0xC0, 0xAF, 0xFF]))
        try rejected("拒绝损坏 UTF-8") { _ = try DocumentHandoffSafety.review(badUTF8) }
        let nul = try file("空字符.txt", Data([0x61, 0, 0x62]))
        try rejected("拒绝嵌入 NUL 的文本") { _ = try DocumentHandoffSafety.review(nul) }
        let exactLimit = try file("正文上限.txt", Data(repeating: 0x61, count: DocumentHandoffSafety.maximumTextBytes))
        try check(try DocumentHandoffSafety.review(exactLimit) == .text, "8 MiB 正文边界不截断")
        let longText = try file("正文超限.txt", Data(repeating: 0x61, count: DocumentHandoffSafety.maximumTextBytes + 1))
        try rejected("8 MiB + 1 正文明确拒绝") { _ = try DocumentHandoffSafety.review(longText) }
        let large = try file("单文件超限.pdf", Data())
        let largeHandle = try FileHandle(forWritingTo: large)
        try largeHandle.truncate(atOffset: UInt64(DocumentHandoffSafety.maximumDocumentBytes + 1))
        try largeHandle.close()
        try rejected("普通文件总量上限在加载前拒绝") { _ = try DocumentHandoffSafety.review(large) }
        let officeLarge = try file("Office超限.docx", Data())
        let officeHandle = try FileHandle(forWritingTo: officeLarge)
        try officeHandle.truncate(atOffset: UInt64(DocumentHandoffSafety.maximumOfficeBytes + 1))
        try officeHandle.close()
        try rejected("Office 压缩载荷超限拒绝") { _ = try DocumentHandoffSafety.review(officeLarge) }
        let link = root.appendingPathComponent("文档链接.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: plain)
        try rejected("拒绝符号链接文档") { _ = try DocumentHandoffSafety.review(link) }
        let directory = root.appendingPathComponent("目录.txt", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        try rejected("不能把目录作为普通文档") { _ = try DocumentHandoffSafety.review(directory) }
        try rejected("缺失文件明确失败") { _ = try DocumentHandoffSafety.review(root.appendingPathComponent("不存在.txt")) }

        let safeRTF = try text("安全文字.rtf", "{\\rtf1\\ansi\\deff0 Safe \\b bold\\b0\\par \\u20013?\\u25991?}")
        try check(try DocumentHandoffSafety.review(safeRTF, declaredUTI: "public.rtf") == .richText, "无对象的文字 RTF 可过")
        for control in ["object", "objdata", "objlink", "pict", "field", "filetbl", "htmltag", "import", "include"] {
            let rtf = try text("RTF-\(control).rtf", "{\\rtf1\\ansi {\\*\\\(control) content}}")
            try rejected("RTF 拒绝 \(control) 控制字") { _ = try DocumentHandoffSafety.review(rtf) }
        }
        let uppercaseRTF = try text("RTF大小写.rtf", "{\\rtf1{\\FIELD 123}}")
        try rejected("RTF 危险控制字大小写不能绕过") { _ = try DocumentHandoffSafety.review(uppercaseRTF) }
        let fakeRTF = try text("伪RTF.rtf", "{not rtf}")
        try rejected("伪 RTF 头不加载") { _ = try DocumentHandoffSafety.review(fakeRTF) }

        let minimalXML = Data("<?xml version=\"1.0\"?><root>静态文字</root>".utf8)
        let staticArchive = try archive("静态ZIP.docx", [.init("[Content_Types].xml", minimalXML), .init("word/document.xml", minimalXML)])
        try check(try DocumentHandoffSafety.review(staticArchive) == .word, "安全静态 ZIP 逐条检查成功")
        for dangerousPath in ["word/vbaProject.bin", "word/embeddings/object.bin", "word/activeX/control.xml", "xl/externalLinks/externalLink1.xml"] {
            let url = try archive("Office危险\(checks).docx", [.init("[Content_Types].xml", minimalXML), .init(dangerousPath, Data("payload".utf8))])
            try rejected("Office 拒绝宏或嵌入路径 \(dangerousPath)") { _ = try DocumentHandoffSafety.review(url) }
        }
        for relationship in ["<Relationship TargetMode=\"External\" Target=\"https://invalid.example/a\"/>", "<Relationship TargetMode = 'external' Target='file:///private/secret'/>"] {
            let url = try archive("外部关系\(checks).docx", [.init("word/_rels/document.xml.rels", Data(relationship.utf8))])
            try rejected("Office 外部关系拒绝") { _ = try DocumentHandoffSafety.review(url) }
        }
        for xml in ["<!DOCTYPE root SYSTEM 'https://invalid.example/test.dtd'><root/>", "<!DOCTYPE root [<!ENTITY x SYSTEM 'file:///private/secret'>]><root>&x;</root>", "<!ENTITY x 'expansion'><root/>"] {
            let url = try archive("XML实体\(checks).xlsx", [.init("xl/workbook.xml", Data(xml.utf8))])
            try rejected("Office 外部 DTD 与实体声明拒绝") { _ = try DocumentHandoffSafety.review(url) }
        }
        let utf16DTD = "<?xml version='1.0' encoding='UTF-16'?><!DOCTYPE r SYSTEM 'https://invalid.example/e'><r/>".data(using: .utf16)!
        let utf16Archive = try archive("UTF16实体.pptx", [.init("ppt/presentation.xml", utf16DTD)])
        try rejected("UTF-16 XML 同样检查实体声明") { _ = try DocumentHandoffSafety.review(utf16Archive) }

        // Header metadata is untrusted: assert actual output size and links before existing viewers run.
        let symlinkArchive = try archive("ZIP符号链接.docx", [.init("word/document.xml", Data("target".utf8), unixMode: 0o120777)])
        try rejected("ZIP 符号链接在展开前拒绝") { _ = try DocumentHandoffSafety.review(symlinkArchive) }
        let specialArchive = try archive("ZIP特殊文件.docx", [.init("word/document.xml", Data(), unixMode: 0o010600)])
        try rejected("ZIP 特殊文件拒绝") { _ = try DocumentHandoffSafety.review(specialArchive) }
        for path in ["../outside.xml", "/absolute.xml", "word/../../outside.xml", "word\\document.xml", "word/./document.xml"] {
            let url = try archive("ZIP路径\(checks).docx", [.init(path, minimalXML)])
            try rejected("ZIP 不安全路径拒绝 \(path)") { _ = try DocumentHandoffSafety.review(url) }
        }
        let duplicate = try archive("ZIP重复.docx", [.init("word/document.xml", minimalXML), .init("word/document.xml", minimalXML)])
        try rejected("ZIP 重名条目拒绝") { _ = try DocumentHandoffSafety.review(duplicate) }
        let expandedForgery = try archive("展开量伪造.docx", [.init("word/document.xml", minimalXML, declaredExpanded: 1)])
        try rejected("实际展开量超过 central 声明拒绝") { _ = try DocumentHandoffSafety.review(expandedForgery) }
        let inflatedForgery = try archive("展开量虚增.docx", [.init("word/document.xml", minimalXML, declaredExpanded: UInt32(minimalXML.count + 1))])
        try rejected("实际展开量少于 central 声明拒绝") { _ = try DocumentHandoffSafety.review(inflatedForgery) }
        let oneTooLarge = try archive("条目超限.docx", [.init("word/media/image.bin", Data(), declaredExpanded: 67_108_865)])
        try rejected("单个展开条目超限拒绝") { _ = try DocumentHandoffSafety.review(oneTooLarge) }
        let aggregate = try archive("展开总量超限.docx", (0..<5).map { .init("word/media/\($0).bin", Data(), declaredExpanded: 67_108_864) })
        try rejected("展开总量超限在加载前拒绝") { _ = try DocumentHandoffSafety.review(aggregate) }
        let wrongCount = try archive("项目数量伪造.docx", [.init("word/document.xml", minimalXML)], declaredCount: 2)
        try rejected("ZIP 项目数量伪造拒绝") { _ = try DocumentHandoffSafety.review(wrongCount) }
        let xmlTooLarge = try archive("XML展开超限.docx", [.init("word/document.xml", Data(), declaredExpanded: 8_388_609)])
        try rejected("XML 内容独立限额拒绝") { _ = try DocumentHandoffSafety.review(xmlTooLarge) }

        // These checks require no reads or writes of actual user records.
        for protected in [FileSafety.root, FileSafety.root.appendingPathComponent("recovery.json"), FileSafety.root.appendingPathComponent("StickyNotes/Contents/blob.rtfd"), FileSafety.root.appendingPathComponent("History/snapshot.pdf")] {
            try rejected("内部记录不能作为普通交接文档") { try DocumentHandoffSafety.permittedLocation(protected) }
        }
        let incoming = FileSafety.root.appendingPathComponent("Exchange/Staging/test/payload/input.txt")
        try rejected("未核验 staging 不自动绕过内部保护") { try DocumentHandoffSafety.permittedLocation(incoming) }
        try DocumentHandoffSafety.permittedLocation(incoming, verifiedStaging: true)
        checks += 1
        try rejected("verifiedStaging 不能扩大到恢复稿") { try DocumentHandoffSafety.permittedLocation(FileSafety.root.appendingPathComponent("Recovery/PDF/draft.pdf"), verifiedStaging: true) }
        try rejected("staging 路径前缀相似不能绕过") { try DocumentHandoffSafety.permittedLocation(FileSafety.root.appendingPathComponent("Exchange/StagingOther/input.txt"), verifiedStaging: true) }
        try rejected("staging 相对越界不能绕过") { try DocumentHandoffSafety.permittedLocation(FileSafety.root.appendingPathComponent("Exchange/Staging/../../recovery.json"), verifiedStaging: true) }
        try check(try Data(contentsOf: plain) == Data(unicode.utf8), "拒绝失败后合法原件仍逐字节保留")
        print("PASS: \(checks) document handoff checks: static Office, UTF-8/RTF, XML/ZIP attacks, limits and protected records")
    }

    private struct ZIPPart {
        let name: String
        let bytes: Data
        let declaredExpanded: UInt32?
        let unixMode: UInt16
        init(_ name: String, _ bytes: Data, declaredExpanded: UInt32? = nil, unixMode: UInt16 = 0o100600) {
            self.name = name; self.bytes = bytes; self.declaredExpanded = declaredExpanded; self.unixMode = unixMode
        }
    }
    /// Original, uncompressed ZIP fixtures keep local headers honest while allowing malicious central metadata.
    private static func storedZIP(_ entries: [ZIPPart], declaredCount: UInt16? = nil) -> Data {
        var result = Data(), central = Data()
        func u16(_ number: UInt16, _ data: inout Data) { data.append(UInt8(number & 255)); data.append(UInt8(number >> 8)) }
        func u32(_ number: UInt32, _ data: inout Data) { u16(UInt16(number & 65535), &data); u16(UInt16(number >> 16), &data) }
        for entry in entries {
            let name = Data(entry.name.utf8), size = UInt32(entry.bytes.count), checksum = crc32(entry.bytes), offset = UInt32(result.count)
            u32(0x04034b50, &result); u16(20, &result); u16(0x0800, &result); u16(0, &result)
            u16(0, &result); u16(0, &result); u32(checksum, &result); u32(size, &result); u32(size, &result)
            u16(UInt16(name.count), &result); u16(0, &result); result.append(name); result.append(entry.bytes)
            u32(0x02014b50, &central); u16(0x0314, &central); u16(20, &central); u16(0x0800, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(checksum, &central); u32(size, &central); u32(entry.declaredExpanded ?? size, &central)
            u16(UInt16(name.count), &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central)
            u32(UInt32(entry.unixMode) << 16, &central); u32(offset, &central); central.append(name)
        }
        let centralOffset = UInt32(result.count), count = declaredCount ?? UInt16(entries.count)
        result.append(central)
        u32(0x06054b50, &result); u16(0, &result); u16(0, &result); u16(count, &result); u16(count, &result)
        u32(UInt32(central.count), &result); u32(centralOffset, &result); u16(0, &result)
        return result
    }
    private static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        return crc ^ 0xffff_ffff
    }
}
