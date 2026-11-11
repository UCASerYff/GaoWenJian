import Foundation
import CryptoKit

enum FileSafety {
    static var root: URL {
        if let i = CommandLine.arguments.firstIndex(of: "--data-dir"), CommandLine.arguments.count > i + 1 {
            return URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GaoSeries/GaoWenJian", isDirectory: true)
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format:"%02x", $0) }.joined() }
    static func write(_ data: Data, to url: URL, expectedDigest: String? = nil) throws {
        if let expectedDigest {
            guard FileManager.default.fileExists(atPath:url.path) else {throw FileIssue.message("原文件已被移动或删除，请另存为，避免在旧位置静默重建文件。")}
            if digest(try Data(contentsOf:url)) != expectedDigest {throw FileIssue.message("文件已被其他程序修改。请重新打开或另存为，避免覆盖外部修改。")}
        }
        try data.write(to:url,options:.atomic)
    }
}

enum FileIssue: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

struct DelimitedText {
    static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows:[[String]] = [], row:[String] = [], value = "", quoted = false
        // CRLF is one Swift grapheme cluster; parse scalars so Windows line endings stay record separators.
        let chars = text.unicodeScalars.map { Character(String($0)) }; var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i+1 < chars.count && chars[i+1] == "\"" { value.append("\""); i += 1 }
                else if quoted || value.isEmpty { quoted.toggle() } else { value.append(c) }
            } else if c == delimiter && !quoted { row.append(value); value = "" }
            else if (c == "\n" || c == "\r") && !quoted {
                if c == "\r" && i+1 < chars.count && chars[i+1] == "\n" { i += 1 }
                row.append(value); rows.append(row); row = []; value = ""
            } else { value.append(c) }
            i += 1
        }
        if !value.isEmpty || !row.isEmpty || rows.isEmpty { row.append(value); rows.append(row) }
        let width = rows.map(\.count).max() ?? 1
        return rows.map { $0 + Array(repeating:"",count:width-$0.count) }
    }
    static func encode(_ rows:[[String]], delimiter:Character = ",") -> String {
        rows.map { row in row.map { value in
            if value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r") { return "\"" + value.replacingOccurrences(of:"\"",with:"\"\"") + "\"" }
            return value
        }.joined(separator:String(delimiter)) }.joined(separator:"\n") + "\n"
    }
    static func markdown(_ rows:[[String]]) -> String {
        guard let first = rows.first else { return "" }
        func line(_ cells:[String]) -> String { "| " + cells.map { $0.replacingOccurrences(of:"|",with:"\\|").replacingOccurrences(of:"\n",with:"<br>") }.joined(separator:" | ") + " |" }
        return ([line(first),line(first.map { _ in "---" })] + rows.dropFirst().map(line)).joined(separator:"\n")
    }
}
