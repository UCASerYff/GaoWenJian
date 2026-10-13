import Foundation

/// Values in a handoff are data only. They are never decoded into commands or callback URLs.
enum GaoJSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), array([GaoJSONValue]), object([String:GaoJSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode([GaoJSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String:GaoJSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    var objectValue: [String:GaoJSONValue]? { if case .object(let v) = self { return v }; return nil }
    var arrayValue: [GaoJSONValue]? { if case .array(let v) = self { return v }; return nil }
    var numberValue: Double? { if case .number(let v) = self { return v }; return nil }
    var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
}

struct GaoActionItem: Codable, Equatable, Identifiable {
    var id: String
    var relativePath: String
    var uti: String
    var byteCount: Int64
    var sha256: String
}

struct GaoDeclaredIdentity: Codable, Equatable {
    var volumeUUID: String?
    var device: UInt64?
    var inode: UInt64?
    var byteCount: Int64?
    var modifiedAt: String?
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(volumeUUID,forKey:.volumeUUID); try c.encode(device,forKey:.device)
        try c.encode(inode,forKey:.inode); try c.encode(byteCount,forKey:.byteCount); try c.encode(modifiedAt,forKey:.modifiedAt)
    }
}

struct GaoActionReference: Codable, Equatable, Identifiable {
    var id: String
    var kind: String
    var fileURL: String
    var displayName: String
    var declaredIdentity: GaoDeclaredIdentity
    var bundleID: String?
    var sha256: String?
}

struct GaoActionManifest: Codable, Equatable {
    var schemaVersion: Int = 1
    var kind: String
    var requestID: String
    var sourceBundleID: String
    var targetBundleID: String
    var action: String
    var createdAt: String
    var expiresAt: String
    var nonce: String
    var items: [GaoActionItem]
    var references: [GaoActionReference]
    var parameters: [String:GaoJSONValue]
    var inReplyTo: String?
    var status: String?
    var errorCode: String?
    var provenance: [String:GaoJSONValue]?
    var isLocalDocumentRequest: Bool { kind == "request" && ["documents.open","documents.newText"].contains(action) }
}

struct GaoStagedItem: Identifiable {
    var item: GaoActionItem
    var url: URL
    var id: String { item.id }
}

struct GaoValidatedPackage {
    var manifest: GaoActionManifest
    var manifestSHA256: String
    var stagingURL: URL
    var stagedItems: [GaoStagedItem]
}

struct GaoOutgoingFile {
    var url: URL
    var uti: String
    var id: String = UUID().uuidString
}

enum GaoActionIssue: Error, LocalizedError {
    case rejected(String, String)
    var code: String { if case .rejected(let code,_) = self { return code }; return "invalidPackage" }
    var errorDescription: String? { if case .rejected(_,let message) = self { return message }; return nil }
}

enum GaoActionContract {
    static let bundleID = "com.gaoseries.GaoWenJian"
    static let packageUTI = "com.gaoseries.action-package"
    static let maximumManifestBytes = 1_048_576
    static let maximumItems = 256
    static let maximumPayloadBytes: Int64 = 2_147_483_648
    static let maximumTextBytes: Int64 = 8_388_608
    static let ttl: TimeInterval = 120
    static let supportedActions = ["documents.open", "documents.newText"]
    static let knownActions: Set<String> = ["capture.region","capture.window","capture.display","ocr.files","images.annotate","images.pin","text.translate","storage.inspect","cleanup.review","apps.uninstall.review","files.search","files.choose","files.reveal","associations.manage","documents.open","documents.newText","research.importDocuments","portal.openSite","portal.openWorkspace","portal.focusSearch","portal.proposeSite","portal.prepareDownload","windows.overview","desktop.openSettings","downloads.prepare"]
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT:0)
        return formatter.string(from:date)
    }
    static func date(_ string: String) -> Date? {
        guard string.hasSuffix("Z") else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from:string) { return date }
        formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return formatter.date(from:string)
    }
    static func reject(_ code: String, _ message: String) -> GaoActionIssue { .rejected(code,message) }
    static func validate(_ manifest: GaoActionManifest, expectedTargetBundleID: String, now: Date) throws {
        guard manifest.schemaVersion == 1 else { throw reject("unsupportedSchema","交接包版本暂不支持，原文档未修改。") }
        guard ["request","result"].contains(manifest.kind), UUID(uuidString:manifest.requestID) != nil else { throw reject("invalidManifest","交接包类型或请求编号无效。") }
        guard validBundleID(manifest.sourceBundleID), manifest.targetBundleID == expectedTargetBundleID else { throw reject("wrongTarget","交接包的目标应用不匹配。") }
        guard knownActions.contains(manifest.action) else { throw reject("unsupportedAction","交接动作暂不支持。") }
        guard let nonce = Data(base64Encoded:manifest.nonce), nonce.count == 32 else { throw reject("invalidNonce","交接包随机标记无效。") }
        guard let created = date(manifest.createdAt), let expires = date(manifest.expiresAt), expires > created, expires.timeIntervalSince(created) <= ttl, created <= now, now < expires else { throw reject("expired","交接包已过期或时间无效，请重新发送。") }
        guard manifest.items.count <= maximumItems, manifest.references.count <= maximumItems, manifest.items.count + manifest.references.count <= maximumItems else { throw reject("itemLimit","交接文件过多，请分批发送。") }
        var total: Int64 = 0; var ids = Set<String>(); var paths = Set<String>()
        for item in manifest.items {
            guard !item.id.isEmpty, item.id.utf8.count <= 256, ids.insert(item.id).inserted, validUTI(item.uti), item.byteCount >= 0, item.byteCount <= maximumPayloadBytes, validSHA(item.sha256) else { throw reject("invalidItem","交接文件信息无效。") }
            let parts = try payloadComponents(item.relativePath)
            guard paths.insert(parts.joined(separator:"/")).inserted else { throw reject("duplicatePath","交接包存在重复附件路径。") }
            let sum = total.addingReportingOverflow(item.byteCount)
            guard !sum.overflow, sum.partialValue <= maximumPayloadBytes else { throw reject("payloadLimit","交接文件超过 2 GiB，请分批发送或重新选择文件。") }
            total = sum.partialValue
        }
        for reference in manifest.references {
            guard !reference.id.isEmpty, reference.id.utf8.count <= 256, ids.insert(reference.id).inserted, ["file","directory","application"].contains(reference.kind), !reference.displayName.isEmpty, reference.displayName.utf8.count <= 4096 else { throw reject("invalidReference","原件引用信息无效。") }
            _ = try localFileURL(reference.fileURL)
            if reference.kind == "application" { guard let bundle = reference.bundleID, validBundleID(bundle) else { throw reject("invalidReference","应用引用缺少有效 bundleID。") } }
            else if reference.bundleID != nil { throw reject("invalidReference","普通原件引用不能声明应用身份。") }
            if let sha = reference.sha256 { guard reference.kind == "file", validSHA(sha) else { throw reject("invalidReference","原件摘要无效。") } }
            if let size = reference.declaredIdentity.byteCount, size < 0 { throw reject("invalidReference","原件大小无效。") }
            if let modified = reference.declaredIdentity.modifiedAt, date(modified) == nil { throw reject("invalidReference","原件时间无效。") }
        }
        if manifest.kind == "result" {
            guard let reply = manifest.inReplyTo, UUID(uuidString:reply) != nil, let status = manifest.status, ["pending","completed","partial","cancelled","failed","unsupported"].contains(status), manifest.provenance != nil else { throw reject("invalidResult","交接结果缺少关联编号或状态。") }
            guard manifest.errorCode == nil || manifest.errorCode!.utf8.count <= 256 else { throw reject("invalidResult","交接结果错误编号无效。") }
            try validateParameters(manifest.parameters,action:manifest.action,requireInputs:false)
        } else {
            guard manifest.inReplyTo == nil, manifest.status == nil, manifest.errorCode == nil, manifest.provenance == nil else { throw reject("invalidManifest","请求包不能混入结果字段。") }
            try validateParameters(manifest.parameters,action:manifest.action)
            try validateRequestShape(manifest)
        }
    }
    static func payloadComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { throw reject("invalidPath","交接附件路径不安全。") }
        var components = path.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
        guard !components.contains(where:{ $0.isEmpty || $0 == "." || $0 == ".." }) else { throw reject("invalidPath","交接附件路径不安全。") }
        if components.first == "payload" { components.removeFirst() }
        guard !components.isEmpty else { throw reject("invalidPath","交接附件不是普通文件。") }
        return components
    }
    static func localFileURL(_ string: String) throws -> URL {
        guard string.utf8.count <= 16_384, let url = URL(string:string), url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost", url.query == nil, url.fragment == nil, url.user == nil, url.password == nil, url.path.hasPrefix("/"), !url.path.contains("\0"), !url.path.split(separator:"/").contains(where:{$0 == "." || $0 == ".."}), !url.path.contains("//") else { throw reject("invalidReference","仅接受规范化的本机原件引用。") }
        return url
    }
    static func safeFilename(_ input: String) -> String {
        var name = String(input.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\" })
        while name.utf8.count > 220 { name.removeLast() }
        if name.isEmpty || name == "." || name == ".." { return "交接文档" }
        return name
    }
    static func validSHA(_ string: String) -> Bool { string.count == 64 && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func validBundleID(_ string: String) -> Bool { string.utf8.count <= 255 && string.contains(".") && string.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 } }
    static func validUTI(_ string: String) -> Bool { !string.isEmpty && string.utf8.count <= 256 && !string.contains(where:{$0.isWhitespace || $0.isNewline}) && !string.contains("\0") }
    private static func validateParameters(_ p: [String:GaoJSONValue], action: String, requireInputs: Bool = true) throws {
        let keys: [String]
        switch action {
        case "capture.region","capture.window","capture.display": keys = ["delaySeconds"]
        case "ocr.files": keys = ["languages","outputs"]
        case "text.translate": keys = ["sourceLanguage","targetLanguage"]
        case "storage.inspect": keys = ["mode"]
        case "files.search": keys = ["query"]
        case "files.choose": keys = ["allowedUTIs","multiple"]
        case "associations.manage": keys = ["uti"]
        case "documents.newText": keys = ["suggestedTitle"]
        case "research.importDocuments": keys = ["targetRecordID"]
        case "portal.openSite": keys = ["siteID","browserID"]
        case "portal.openWorkspace": keys = ["workspaceID"]
        case "portal.focusSearch": keys = ["query"]
        case "portal.proposeSite": keys = ["url","title"]
        case "portal.prepareDownload": keys = ["urls"]
        case "downloads.prepare": keys = ["urls","mediaType"]
        default: keys = []
        }
        guard Set(p.keys).isSubset(of:Set(keys)) else { throw reject("unsupportedParameter","交接参数不受支持，未执行动作。") }
        func string(_ key: String, maximum: Int = 4096, required: Bool = false) throws -> String? {
            guard let value = p[key] else { if required && requireInputs { throw reject("invalidParameter","交接缺少必要参数。") }; return nil }
            guard let s = value.stringValue, s.count <= maximum, !s.contains("\0") else { throw reject("invalidParameter","交接文字参数无效。") }; return s
        }
        func list(_ key: String, maximum: Int = 256) throws -> [String]? {
            guard let value = p[key] else { return nil }
            guard let a = value.arrayValue, a.count <= maximum, a.allSatisfy({$0.stringValue != nil}) else { throw reject("invalidParameter","交接列表参数无效。") }
            return a.compactMap(\.stringValue)
        }
        func language(_ s: String) -> Bool { s.utf8.count <= 63 && s.range(of:"^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$",options:.regularExpression) != nil }
        switch action {
        case "capture.region","capture.window","capture.display":
            if let value = p["delaySeconds"] { guard let n = value.numberValue, n >= 0, n <= 60 else { throw reject("invalidParameter","延时必须为 0 至 60 秒。") } }
        case "ocr.files":
            if let a = try list("languages") { guard !a.isEmpty, a.allSatisfy(language) else { throw reject("invalidParameter","识别语言参数无效。") } }
            if let a = try list("outputs") { guard !a.isEmpty, Set(a).isSubset(of:["text","markdown","json","searchablePDF"]) else { throw reject("invalidParameter","识别输出格式无效。") } }
        case "text.translate":
            if let target = try string("targetLanguage",required:true), !language(target) { throw reject("invalidParameter","目标语言无效。") }
            if let source = try string("sourceLanguage"), source != "auto", !language(source) { throw reject("invalidParameter","来源语言无效。") }
        case "storage.inspect": if let s = try string("mode"), !["metadata","duplicates"].contains(s) { throw reject("invalidParameter","检查模式无效。") }
        case "files.search": _ = try string("query",required:true)
        case "files.choose":
            if let a = try list("allowedUTIs"), !a.allSatisfy(validUTI) { throw reject("invalidParameter","文件类型列表无效。") }
            if let b = p["multiple"], b.boolValue == nil { throw reject("invalidParameter","多选参数无效。") }
        case "associations.manage": if let s = try string("uti"), !validUTI(s) { throw reject("invalidParameter","文件类型无效。") }
        case "documents.newText": _ = try string("suggestedTitle",maximum:256)
        case "research.importDocuments": _ = try string("targetRecordID",maximum:4096)
        case "portal.openSite": _ = try string("siteID",required:true); _ = try string("browserID")
        case "portal.openWorkspace": _ = try string("workspaceID",required:true)
        case "portal.focusSearch": _ = try string("query")
        case "portal.proposeSite":
            if let s = try string("url",required:true), !webURL(s) { throw reject("invalidParameter","网站地址必须为 http 或 https。") }; _ = try string("title",maximum:256)
        case "portal.prepareDownload","downloads.prepare":
            if let urls = try list("urls",maximum:32) { guard !urls.isEmpty, urls.allSatisfy(webURL) else { throw reject("invalidParameter","下载地址必须为最多 32 个 http 或 https 地址。") } }
            else if requireInputs { throw reject("invalidParameter","下载地址必须为最多 32 个 http 或 https 地址。") }
            if let s = try string("mediaType"), !["file","video","audio","image","subtitle"].contains(s) { throw reject("invalidParameter","媒体类型无效。") }
        default: break
        }
    }
    private static func webURL(_ s: String) -> Bool { guard s.utf8.count <= 16_384, let u = URL(string:s), ["http","https"].contains(u.scheme?.lowercased() ?? ""), let host = u.host, !host.isEmpty, u.user == nil, u.password == nil else { return false }; return true }
    private static func validateRequestShape(_ m: GaoActionManifest) throws {
        func check(_ yes: Bool) throws { if !yes { throw reject("invalidActionInput","交接动作的输入类型或数量不匹配。") } }
        let textUTIs: Set<String> = ["public.utf8-plain-text","public.plain-text","text/plain","net.daringfireball.markdown","public.markdown","text/markdown"]
        let imageUTIs: Set<String> = ["public.png","public.jpeg","public.tiff","public.heic","public.heif","com.compuserve.gif","public.webp","org.webmproject.webp","image/png","image/jpeg","image/tiff","image/heic","image/heif","image/gif","image/webp"]
        switch m.action {
        case "documents.newText": try check(m.items.count == 1 && m.references.isEmpty && textUTIs.contains(m.items[0].uti) && m.items[0].byteCount <= maximumTextBytes)
        case "documents.open": try check(!m.items.isEmpty || !m.references.isEmpty); try check(m.references.allSatisfy({$0.kind == "file"})); try check(m.items.isEmpty || m.references.isEmpty)
        case "ocr.files": try check(!m.items.isEmpty && m.references.isEmpty && m.items.allSatisfy { imageUTIs.contains($0.uti) || ["com.adobe.pdf","application/pdf"].contains($0.uti) })
        case "images.annotate","images.pin": try check(m.items.count == 1 && m.references.isEmpty && imageUTIs.contains(m.items[0].uti))
        case "text.translate": try check(m.items.count == 1 && m.references.isEmpty && ["public.utf8-plain-text","public.plain-text","text/plain"].contains(m.items[0].uti) && m.items[0].byteCount <= maximumTextBytes)
        case "storage.inspect": try check(m.items.isEmpty && m.references.count == 1 && m.references[0].kind == "directory")
        case "apps.uninstall.review": try check(m.items.isEmpty && m.references.count == 1 && m.references[0].kind == "application")
        case "files.search","files.choose": try check(m.items.isEmpty && m.references.count <= 1 && m.references.allSatisfy({$0.kind == "directory"}))
        case "files.reveal": try check(m.items.isEmpty && m.references.count == 1)
        case "research.importDocuments": try check(!m.items.isEmpty && m.references.isEmpty)
        default: try check(m.items.isEmpty && m.references.isEmpty)
        }
    }
}
