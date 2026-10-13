import Foundation
import CryptoKit
import Security
import Darwin

/// The open directory/file descriptors keep subsequent checks anchored to the same objects.
final class GaoFixedFD {
    let value: Int32
    init(_ value: Int32) throws { guard value >= 0 else { throw GaoActionContract.reject("unreadable","交接文件无法安全读取，请重新选择文件。") }; self.value = value }
    deinit { Darwin.close(value) }
    func statValue() throws -> stat { var s = stat(); guard fstat(value,&s) == 0 else { throw GaoActionContract.reject("unreadable","交接文件信息无法读取。") }; return s }
}

enum GaoPrivateIO {
    static func directory(_ url: URL, create: Bool = false, requirePrivate: Bool = false) throws -> GaoFixedFD {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw GaoActionContract.reject("invalidPath","交接目录无效。") }
        var path = url.path
        for alias in ["/tmp","/var","/etc"] where path == alias || path.hasPrefix(alias + "/") { path = "/private" + path; break }
        guard !path.split(separator:"/").contains(where:{$0 == "." || $0 == ".."}) else { throw GaoActionContract.reject("invalidPath","交接目录路径不安全。") }
        if create {
            do {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw GaoActionContract.reject("unwritable","无法建立本机私有交接目录。")
            }
        }
        let current = try GaoFixedFD(Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        let s = try current.statValue()
        guard (s.st_mode & S_IFMT) == S_IFDIR else { throw GaoActionContract.reject("invalidPath","交接路径不是目录。") }
        guard s.st_uid == geteuid() else { throw GaoActionContract.reject("wrongOwner","交接目录不属于当前用户。") }
        if requirePrivate, s.st_mode & 0o077 != 0 { throw GaoActionContract.reject("unsafePermissions","交接目录权限不安全，请使用本应用创建的私有交接包。") }
        return current
    }
    static func childDirectory(_ parent: GaoFixedFD, _ name: String, create: Bool = false, requirePrivate: Bool = false) throws -> GaoFixedFD {
        if create, mkdirat(parent.value,name,mode_t(0o700)) != 0 { throw GaoActionContract.reject("unwritable","无法建立本机私有交接目录。") }
        let fd = try GaoFixedFD(openat(parent.value,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        let s = try fd.statValue()
        guard s.st_uid == geteuid(), !requirePrivate || s.st_mode & 0o077 == 0 else { throw GaoActionContract.reject("unsafePermissions","交接目录所有者或权限不安全。") }
        return fd
    }
    static func regular(_ directory: GaoFixedFD, components: [String]) throws -> GaoFixedFD {
        guard let last = components.last else { throw GaoActionContract.reject("invalidPath","交接附件路径无效。") }
        var parent = directory
        for part in components.dropLast() { parent = try childDirectory(parent,part) }
        let fd = try GaoFixedFD(openat(parent.value,last,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
        try checkRegular(try fd.statValue())
        return fd
    }
    static func regularURL(_ url: URL) throws -> GaoFixedFD {
        let parent = try directory(url.deletingLastPathComponent())
        return try regular(parent,components:[url.lastPathComponent])
    }
    static func checkRegular(_ s: stat) throws {
        guard s.st_mode & S_IFMT == S_IFREG, s.st_nlink == 1, s.st_uid == geteuid(), s.st_size >= 0 else { throw GaoActionContract.reject("unsafeFile","交接附件必须是当前用户可读的普通文件，不能是链接、目录或设备。") }
    }
    static func unchanged(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_uid == b.st_uid && a.st_nlink == b.st_nlink && a.st_mode == b.st_mode && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    static func read(_ fd: GaoFixedFD, maximum: Int64) throws -> Data {
        let before = try fd.statValue(); try checkRegular(before)
        guard before.st_size <= maximum else { throw GaoActionContract.reject("sizeLimit","交接文件过大，请分批发送。") }
        var bytes = Data(); var buffer = [UInt8](repeating:0,count:65_536)
        while true {
            let count = Darwin.read(fd.value,&buffer,buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw GaoActionContract.reject("unreadable","交接内容读取失败。") }
            guard Int64(bytes.count) + Int64(count) <= maximum else { throw GaoActionContract.reject("sizeLimit","交接内容超过允许大小。") }
            bytes.append(contentsOf:buffer.prefix(count))
        }
        guard unchanged(before,try fd.statValue()), Int64(bytes.count) == before.st_size else { throw GaoActionContract.reject("sourceChanged","交接源文件在读取期间发生变化，请重新发送。") }
        return bytes
    }
    @discardableResult static func copy(_ source: GaoFixedFD, to destination: GaoFixedFD, name: String, maximum: Int64, expectedSize: Int64? = nil, expectedSHA256: String? = nil, chunkObserver: (() throws -> Void)? = nil) throws -> (Int64,String) {
        let before = try source.statValue(); try checkRegular(before)
        guard before.st_size <= maximum, expectedSize == nil || before.st_size == expectedSize else { throw GaoActionContract.reject("sizeMismatch","交接附件大小与声明不一致或超过限制。") }
        let output = try GaoFixedFD(openat(destination.value,name,O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC,mode_t(0o600)))
        var hasher = SHA256(); var total: Int64 = 0; var buffer = [UInt8](repeating:0,count:65_536)
        do {
            while true {
                let count = Darwin.read(source.value,&buffer,buffer.count)
                if count == 0 { break }
                if count < 0 { if errno == EINTR { continue }; throw GaoActionContract.reject("unreadable","交接附件读取失败。") }
                guard total + Int64(count) <= maximum else { throw GaoActionContract.reject("payloadLimit","交接文件超过允许大小。") }
                let data = Data(buffer.prefix(count)); hasher.update(data:data)
                try writeAll(data,to:output.value); total += Int64(count)
                try chunkObserver?()
            }
            let after = try source.statValue()
            guard unchanged(before,after), total == before.st_size else { throw GaoActionContract.reject("sourceChanged","交接附件在复制期间发生变化，请重新发送。") }
            let digest = hasher.finalize().map { String(format:"%02x",$0) }.joined()
            guard expectedSHA256 == nil || expectedSHA256 == digest else { throw GaoActionContract.reject("digestMismatch","交接附件摘要不符，未打开文档。") }
            guard fsync(output.value) == 0 else { throw GaoActionContract.reject("unwritable","交接副本无法完整写入。") }
            return (total,digest)
        } catch {
            _ = unlinkat(destination.value,name,0)
            throw error
        }
    }
    static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                if n < 0 { if errno == EINTR { continue }; throw GaoActionContract.reject("unwritable","交接内容写入失败。") }
                guard n > 0 else { throw GaoActionContract.reject("unwritable","交接内容写入失败。") }; offset += n
            }
        }
    }
    static func atomicJSON(_ data: Data, directory: GaoFixedFD, name: String) throws {
        let temporary = ".pending-" + UUID().uuidString
        let fd = try GaoFixedFD(openat(directory.value,temporary,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,mode_t(0o600)))
        do {
            try writeAll(data,to:fd.value)
            guard fsync(fd.value) == 0, renameat(directory.value,temporary,directory.value,name) == 0, fsync(directory.value) == 0 else { throw GaoActionContract.reject("unwritable","交接清单无法原子写入。") }
        } catch { _ = unlinkat(directory.value,temporary,0); throw error }
    }
}

enum GaoActionTransport {
    static func receive(packageURL: URL, exchangeRoot: URL, expectedTargetBundleID: String = GaoActionContract.bundleID, now: Date = Date(), chunkObserver: (() throws -> Void)? = nil) throws -> GaoValidatedPackage {
        guard packageURL.pathExtension.lowercased() == "gaoaction" else { throw GaoActionContract.reject("invalidPackage","请选择 .gaoaction 交接包。") }
        let package = try GaoPrivateIO.directory(packageURL)
        let manifestFD = try GaoPrivateIO.regular(package,components:["manifest.json"])
        let bytes = try GaoPrivateIO.read(manifestFD,maximum:Int64(GaoActionContract.maximumManifestBytes))
        let manifest = try decodeManifest(bytes)
        try GaoActionContract.validate(manifest,expectedTargetBundleID:expectedTargetBundleID,now:now)
        let payload = try GaoPrivateIO.childDirectory(package,"payload")
        let exchange = try GaoPrivateIO.directory(exchangeRoot,create:true,requirePrivate:true)
        if mkdirat(exchange.value,"Staging",mode_t(0o700)) != 0, errno != EEXIST { throw GaoActionContract.reject("unwritable","无法建立本机交接暂存目录。") }
        let stagingParent = try GaoPrivateIO.childDirectory(exchange,"Staging",requirePrivate:true)
        let stageName = UUID().uuidString
        let staging = try GaoPrivateIO.childDirectory(stagingParent,stageName,create:true,requirePrivate:true)
        let stagingURL = exchangeRoot.appendingPathComponent("Staging/" + stageName,isDirectory:true)
        do {
            var stagedItems: [GaoStagedItem] = []
            for (index,item) in manifest.items.enumerated() {
                let fd = try GaoPrivateIO.regular(payload,components:GaoActionContract.payloadComponents(item.relativePath))
                let name = String(index) + "-" + GaoActionContract.safeFilename(URL(fileURLWithPath:item.relativePath).lastPathComponent)
                _ = try GaoPrivateIO.copy(fd,to:staging,name:name,maximum:item.byteCount,expectedSize:item.byteCount,expectedSHA256:item.sha256,chunkObserver:chunkObserver)
                stagedItems.append(GaoStagedItem(item:item,url:stagingURL.appendingPathComponent(name)))
            }
            // A copy is complete only when its private manifest is durably written as well.
            try GaoPrivateIO.atomicJSON(bytes,directory:staging,name:"manifest.json")
            if manifest.kind == "request", ["documents.newText","text.translate"].contains(manifest.action) {
                guard let text = stagedItems.first, String(data:try Data(contentsOf:text.url),encoding:.utf8) != nil else { throw GaoActionContract.reject("invalidUTF8","文字交接必须是有效 UTF-8 文件。") }
            }
            return GaoValidatedPackage(manifest:manifest,manifestSHA256:FileSafety.digest(bytes),stagingURL:stagingURL,stagedItems:stagedItems)
        } catch {
            // This fresh UUID directory belongs only to this failed receive operation.
            try? FileManager.default.removeItem(at:stagingURL)
            throw error
        }
    }
    static func decodeManifest(_ data: Data) throws -> GaoActionManifest {
        guard data.count <= GaoActionContract.maximumManifestBytes else { throw GaoActionContract.reject("manifestLimit","交接清单超过 1 MiB。") }
        do {
            guard let object = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw GaoActionContract.reject("invalidManifest","交接清单不是有效对象。") }
            let base: Set<String> = ["schemaVersion","kind","requestID","sourceBundleID","targetBundleID","action","createdAt","expiresAt","nonce","items","references","parameters"]
            let resultKeys: Set<String> = ["inReplyTo","status","errorCode","provenance"]
            guard base.isSubset(of:Set(object.keys)), Set(object.keys).isSubset(of:base.union(resultKeys)) else { throw GaoActionContract.reject("invalidManifest","交接清单缺少必要字段或包含未知字段。") }
            if object["kind"] as? String == "result", !resultKeys.isSubset(of:Set(object.keys)) { throw GaoActionContract.reject("invalidResult","交接结果缺少状态字段。") }
            for key in ["items","references"] {
                guard let entries = object[key] as? [[String:Any]] else { throw GaoActionContract.reject("invalidManifest","交接项目列表无效。") }
                for entry in entries {
                    let required: Set<String> = key == "items" ? ["id","relativePath","uti","byteCount","sha256"] : ["id","kind","fileURL","displayName","declaredIdentity"]
                    let allowed = key == "items" ? required : required.union(["bundleID","sha256"])
                    guard required.isSubset(of:Set(entry.keys)), Set(entry.keys).isSubset(of:allowed) else { throw GaoActionContract.reject("invalidManifest","交接项目包含未知字段。") }
                    if key == "references" {
                        guard let identity = entry["declaredIdentity"] as? [String:Any], Set(identity.keys) == ["volumeUUID","device","inode","byteCount","modifiedAt"] else { throw GaoActionContract.reject("invalidReference","原件身份字段不完整。") }
                    }
                }
            }
            return try JSONDecoder().decode(GaoActionManifest.self,from:data)
        } catch let error as GaoActionIssue { throw error }
        catch { throw GaoActionContract.reject("invalidManifest","交接清单损坏或数据类型无效。") }
    }

    /// References confer no permission. Call only for a URL independently chosen/authorized here.
    static func verifyReference(_ reference: GaoActionReference, selectedURL: URL) throws {
        let declared = try GaoActionContract.localFileURL(reference.fileURL)
        guard declared.standardizedFileURL.path == selectedURL.standardizedFileURL.path else { throw GaoActionContract.reject("referenceMismatch","所选对象与交接原件不匹配，请重新复核。") }
        let fd: GaoFixedFD
        if reference.kind == "file" { fd = try GaoPrivateIO.regularURL(selectedURL) }
        else { fd = try GaoPrivateIO.directory(selectedURL) }
        let identity = reference.declaredIdentity; let s = try fd.statValue()
        guard identity.device == nil || identity.device == UInt64(bitPattern:Int64(s.st_dev)), identity.inode == nil || identity.inode == UInt64(s.st_ino), identity.byteCount == nil || identity.byteCount == Int64(s.st_size) else { throw GaoActionContract.reject("referenceChanged","原件身份或大小已变化，请重新发送。") }
        if let modified = identity.modifiedAt, let expected = GaoActionContract.date(modified) {
            let actual = Date(timeIntervalSince1970:Double(s.st_mtimespec.tv_sec) + Double(s.st_mtimespec.tv_nsec)/1_000_000_000)
            guard abs(actual.timeIntervalSince(expected)) < 0.001 else { throw GaoActionContract.reject("referenceChanged","原件修改时间已变化，请重新发送。") }
        }
        if let volume = identity.volumeUUID {
            guard (try selectedURL.resourceValues(forKeys:[.volumeUUIDStringKey])).volumeUUIDString == volume else { throw GaoActionContract.reject("referenceChanged","原件所在卷已变化。") }
        }
        if let sha = reference.sha256 {
            var hasher = SHA256(); var buffer = [UInt8](repeating:0,count:65_536); var total: Int64 = 0
            while true {
                let n = Darwin.read(fd.value,&buffer,buffer.count)
                if n == 0 { break }; if n < 0 { if errno == EINTR { continue }; throw GaoActionContract.reject("unreadable","原件无法读取。") }
                total += Int64(n); guard total <= GaoActionContract.maximumPayloadBytes else { throw GaoActionContract.reject("payloadLimit","原件过大，请重新选择。") }; hasher.update(data:Data(buffer.prefix(n)))
            }
            guard GaoPrivateIO.unchanged(s,try fd.statValue()), hasher.finalize().map({String(format:"%02x",$0)}).joined() == sha else { throw GaoActionContract.reject("referenceChanged","原件内容已变化，请重新发送。") }
        }
        if reference.kind == "application" {
            guard let info = Bundle(url:selectedURL), info.bundleIdentifier == reference.bundleID else { throw GaoActionContract.reject("referenceChanged","应用原件的 bundleID 不匹配。") }
        }
    }
}

enum GaoActionWriter {
    static func writeRequest(action: String, items: [GaoOutgoingFile] = [], references: [GaoActionReference] = [], parameters: [String:GaoJSONValue] = [:], sourceBundleID: String = GaoActionContract.bundleID, targetBundleID: String, exchangeRoot: URL, now: Date = Date(), requestID: UUID = UUID()) throws -> URL {
        let manifest = GaoActionManifest(kind:"request",requestID:requestID.uuidString,sourceBundleID:sourceBundleID,targetBundleID:targetBundleID,action:action,createdAt:GaoActionContract.timestamp(now),expiresAt:GaoActionContract.timestamp(now.addingTimeInterval(GaoActionContract.ttl)),nonce:try nonce(),items:[],references:references,parameters:parameters)
        return try write(manifest:manifest,files:items,exchangeRoot:exchangeRoot,now:now)
    }
    static func writeResult(inReplyTo request: GaoActionManifest, status: String, items: [GaoOutgoingFile] = [], references: [GaoActionReference] = [], errorCode: String? = nil, provenance: [String:GaoJSONValue] = [:], exchangeRoot: URL, now: Date = Date()) throws -> URL {
        let manifest = GaoActionManifest(kind:"result",requestID:UUID().uuidString,sourceBundleID:GaoActionContract.bundleID,targetBundleID:request.sourceBundleID,action:request.action,createdAt:GaoActionContract.timestamp(now),expiresAt:GaoActionContract.timestamp(now.addingTimeInterval(GaoActionContract.ttl)),nonce:try nonce(),items:[],references:references,parameters:request.parameters,inReplyTo:request.requestID,status:status,errorCode:errorCode ?? "",provenance:provenance)
        return try write(manifest:manifest,files:items,exchangeRoot:exchangeRoot,now:now)
    }
    private static func nonce() throws -> String {
        var bytes = [UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { throw GaoActionContract.reject("randomFailure","无法建立安全随机交接标记。") }
        return Data(bytes).base64EncodedString()
    }
    private static func write(manifest original: GaoActionManifest, files: [GaoOutgoingFile], exchangeRoot: URL, now: Date) throws -> URL {
        guard files.count + original.references.count <= GaoActionContract.maximumItems else { throw GaoActionContract.reject("itemLimit","文件过多，请分批发送。") }
        let exchange = try GaoPrivateIO.directory(exchangeRoot,create:true,requirePrivate:true)
        if mkdirat(exchange.value,"Outgoing",mode_t(0o700)) != 0, errno != EEXIST { throw GaoActionContract.reject("unwritable","无法建立私有发送目录。") }
        let outgoing = try GaoPrivateIO.childDirectory(exchange,"Outgoing",requirePrivate:true)
        let name = UUID().uuidString + ".gaoaction"
        let package = try GaoPrivateIO.childDirectory(outgoing,name,create:true,requirePrivate:true)
        let payload = try GaoPrivateIO.childDirectory(package,"payload",create:true,requirePrivate:true)
        let url = exchangeRoot.appendingPathComponent("Outgoing/" + name,isDirectory:true)
        do {
            var manifest = original; var total: Int64 = 0
            for file in files {
                let fd = try GaoPrivateIO.regularURL(file.url)
                let filename = String(UUID().uuidString.prefix(8)) + "-" + GaoActionContract.safeFilename(file.url.lastPathComponent)
                let copied = try GaoPrivateIO.copy(fd,to:payload,name:filename,maximum:GaoActionContract.maximumPayloadBytes-total)
                total += copied.0
                manifest.items.append(GaoActionItem(id:file.id,relativePath:"payload/" + filename,uti:file.uti,byteCount:copied.0,sha256:copied.1))
            }
            try GaoActionContract.validate(manifest,expectedTargetBundleID:manifest.targetBundleID,now:now)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
            let bytes = try encoder.encode(manifest)
            guard bytes.count <= GaoActionContract.maximumManifestBytes else { throw GaoActionContract.reject("manifestLimit","交接清单超过 1 MiB，请分批发送。") }
            try GaoPrivateIO.atomicJSON(bytes,directory:package,name:"manifest.json")
            return url
        } catch { try? FileManager.default.removeItem(at:url); throw error }
    }
}
