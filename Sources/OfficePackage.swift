import Foundation
import CryptoKit

enum OfficeFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

enum OfficeXML {
    static func local(_ node: XMLNode) -> String { (node.name ?? "").split(separator: ":").last.map(String.init) ?? "" }
    static func children(_ element: XMLElement, _ name: String) -> [XMLElement] {
        (element.children ?? []).compactMap { $0 as? XMLElement }.filter { local($0) == name }
    }
    static func child(_ element: XMLElement, _ name: String) -> XMLElement? { children(element, name).first }
    static func descendants(_ element: XMLElement, _ name: String) -> [XMLElement] {
        // Foundation's XPath bridge can include nodes following a detached/context element.
        // Explicit child traversal guarantees the edit never crosses into another paragraph/cell/shape.
        var result: [XMLElement] = []
        func walk(_ parent: XMLElement) {
            for child in parent.children ?? [] {
                guard let element = child as? XMLElement else { continue }
                if local(element) == name { result.append(element) }
                walk(element)
            }
        }
        walk(element)
        return result
    }
    static func attribute(_ element: XMLElement, _ name: String) -> String? {
        element.attribute(forName: name)?.stringValue ?? element.attributes?.first(where: { local($0) == name })?.stringValue
    }
    static func set(_ element: XMLElement, _ name: String, _ value: String) {
        if let old = element.attribute(forName: name) { old.stringValue = value }
        else { element.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
    }
    static func remove(_ element: XMLElement, _ name: String) {
        for child in children(element, name) { child.detach() }
    }
    static func element(_ name: String, uri: String? = nil, text: String? = nil) -> XMLElement {
        let element = XMLElement(name: name, uri: uri)
        element.stringValue = text
        return element
    }
    static func qualified(_ name: String, like reference: XMLElement) -> String {
        if let full = reference.name, let colon = full.firstIndex(of: ":") { return String(full[..<colon]) + ":" + name }
        return name
    }
    static func append(_ local: String, to parent: XMLElement, like reference: XMLElement? = nil) -> XMLElement {
        let ref = reference ?? parent
        let element = XMLElement(name: qualified(local, like: ref), uri: ref.uri)
        parent.addChild(element)
        return element
    }
    // Keep runs and unknown objects in place; distribute replacement text across existing text runs.
    static func replaceText(_ text: String, nodes: [XMLElement], create: () -> XMLElement) {
        let targets = nodes.isEmpty ? [create()] : nodes
        var remaining = Array(text)
        for (index, target) in targets.enumerated() {
            let take = index == targets.count - 1 ? remaining.count : min(remaining.count, (target.stringValue ?? "").count)
            target.stringValue = String(remaining.prefix(take))
            remaining.removeFirst(take)
            set(target, "xml:space", "preserve")
        }
    }
}

final class OfficePackage {
    private(set) var source: URL?
    let directory: URL
    private var sourceDigest: String?
    private static let fm = FileManager.default
    init(url: URL) throws {
        source = url.standardizedFileURL
        sourceDigest = try Self.digest(url)
        directory = Self.fm.temporaryDirectory.appendingPathComponent("GaoWenJian-Office-\(UUID().uuidString)", isDirectory: true)
        try Self.fm.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let listing = try Self.run("/usr/bin/unzip", ["-Z1", url.path])
            let entries = listing.split(separator: "\n").map(String.init)
            guard !entries.isEmpty, entries.count <= 50000 else { throw OfficeFailure.message("文档压缩包为空或包含过多文件。") }
            for entry in entries {
                guard !entry.hasPrefix("/"), !entry.contains("\\"), !entry.split(separator: "/").contains("..") else {
                    throw OfficeFailure.message("文档压缩包包含不安全的路径，无法打开。")
                }
            }
            try Self.run("/usr/bin/unzip", ["-q", url.path, "-d", directory.path])
            if let enumerator = Self.fm.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                for case let file as URL in enumerator {
                    if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                        throw OfficeFailure.message("文档压缩包含有符号链接，无法打开。")
                    }
                }
            }
            guard Self.fm.fileExists(atPath: directory.appendingPathComponent("[Content_Types].xml").path) else {
                throw OfficeFailure.message("这不是有效的 Office Open XML 文档。")
            }
        } catch { try? Self.fm.removeItem(at: directory); throw error }
    }
    init(files: [String: String]) throws {
        directory = Self.fm.temporaryDirectory.appendingPathComponent("GaoWenJian-Office-\(UUID().uuidString)", isDirectory: true)
        try Self.fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, text) in files {
            let file = try location(path)
            try Self.fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }
    deinit { try? Self.fm.removeItem(at: directory) }
    func location(_ path: String) throws -> URL {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let file = directory.appendingPathComponent(normalized).standardizedFileURL
        guard file.path.hasPrefix(directory.path + "/") else { throw OfficeFailure.message("文档部件路径超出文档范围。") }
        return file
    }
    func exists(_ path: String) -> Bool { (try? location(path)).map { Self.fm.fileExists(atPath: $0.path) } ?? false }
    func xml(_ path: String) throws -> XMLDocument {
        try XMLDocument(contentsOf: location(path), options: [.nodePreserveAll])
    }
    func write(_ document: XMLDocument, path: String) throws {
        let file = try location(path)
        try Self.fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.xmlData(options: []).write(to: file, options: .atomic)
    }
    func remove(_ path: String) throws { let file = try location(path); if Self.fm.fileExists(atPath: file.path) { try Self.fm.removeItem(at: file) } }
    func resolve(_ target: String, relativeTo part: String) throws -> String {
        let url: URL
        if target.hasPrefix("/") { url = try location(target) }
        else { url = try location(part).deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL }
        guard url.path.hasPrefix(directory.path + "/") else { throw OfficeFailure.message("文档关系指向了文档外部。") }
        return String(url.path.dropFirst(directory.path.count + 1))
    }
    func bindOriginal(_ url: URL, expectedDigest: String) throws {
        guard try Self.digest(url) == expectedDigest else { throw OfficeFailure.message("原件在草稿生成后发生了变化。请保留草稿，避免覆盖新版原件。") }
        source = url.standardizedFileURL; sourceDigest = expectedDigest
    }
    func save(to destination: URL, updateSource: Bool = true, createSnapshot: Bool = true) throws {
        let target = destination.standardizedFileURL
        if target == source, let expected = sourceDigest {
            guard try Self.digest(target) == expected else {
                throw OfficeFailure.message("原文件已被其他程序修改。请另存为新文件，避免覆盖外部修改。")
            }
        }
        let output = directory.deletingLastPathComponent().appendingPathComponent("GaoWenJian-Office-\(UUID().uuidString).zip")
        defer { try? Self.fm.removeItem(at: output) }
        try Self.run("/usr/bin/zip", ["-q", "-r", output.path, "."], cwd: directory)
        try Self.run("/usr/bin/unzip", ["-tq", output.path])
        let bytes = try Data(contentsOf: output)
        if createSnapshot, Self.fm.fileExists(atPath: target.path) { try Self.backup(target) }
        try bytes.write(to: target, options: .atomic)
        if updateSource { source = target; sourceDigest = Self.hash(bytes) }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func digest(_ url: URL) throws -> String { hash(try Data(contentsOf: url)) }
    @discardableResult static func backup(_ source: URL) throws -> URL {
        guard let target = try FileSafety.snapshot(url: source) else { throw OfficeFailure.message("无法读取原件并创建备份，已停止覆盖保存。") }
        return target
    }
    @discardableResult static func run(_ path: String, _ arguments: [String], cwd: URL? = nil) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments; process.currentDirectoryURL = cwd
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw OfficeFailure.message("文档处理失败：\(output.prefix(1200))") }
        return output
    }
}
