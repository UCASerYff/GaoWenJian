import AppKit
import Foundation

@MainActor enum CoreTests {
    static func run() throws {
        func require(_ valid: @autoclosure () -> Bool, _ message: String) throws {
            guard valid() else { throw FileIssue.message("Core test failed: " + message) }
        }
        let rows = [["编号", "内容", "说明"], ["00123", "逗号,与\"引号\"", "多行\n中文 😀"], ["", "尾列", ""]]
        try require(DelimitedText.parse(DelimitedText.encode(rows)) == rows, "CSV quoted Unicode/newline roundtrip")
        try require(DelimitedText.parse("A\tB\r\n1\t\"x\ty\"\r\n", delimiter:"\t") == [["A", "B"], ["1", "x\ty"]], "TSV CRLF parsing")
        let root = FileSafety.root
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let file = root.appendingPathComponent("安全测试.txt")
        let original = Data("原始文档与附件索引 😀".utf8)
        try original.write(to:file)
        try FileSafety.write(Data("新内容".utf8),to:file,expectedDigest:FileSafety.digest(original))
        let snapshots = try FileSafety.snapshots(for:file)
        guard let first=snapshots.first else {throw FileIssue.message("missing history")}
        let backedUp = try Data(contentsOf:first)
        try require(backedUp == original,"history bytes read back exactly")
        var rejected = false
        do {try FileSafety.write(original,to:file,expectedDigest:FileSafety.digest(original))} catch {rejected=true}
        try require(rejected,"external mutation rejected")
        let latest = try Data(contentsOf:file)
        try require(latest == Data("新内容".utf8),"conflict does not mutate current file")
        try FileManager.default.removeItem(at:file)
        rejected=false
        do {try FileSafety.write(original,to:file,expectedDigest:FileSafety.digest(latest))} catch {rejected=true}
        try require(rejected && !FileManager.default.fileExists(atPath:file.path),"external deletion does not silently recreate file")
        let malformed = Data("damaged-do-not-replace".utf8)
        let state=root.appendingPathComponent("workspace.json")
        let recovery=root.appendingPathComponent("recovery.json")
        try malformed.write(to:state);try malformed.write(to:recovery)
        do {
            let store=WorkspaceStore();store.newText(.text,text:"新草稿");store.checkpoint()
            let preservedState=try Data(contentsOf:state),preservedRecovery=try Data(contentsOf:recovery)
            try require(store.error != nil && preservedState == malformed && preservedRecovery == malformed,"unreadable state and drafts remain untouched")
        }
        try FileManager.default.removeItem(at:state)
        let id=UUID()
        let recoveryBytes=try JSONSerialization.data(withJSONObject:[["id":id.uuidString,"kind":"text","text":"","encoding":String.Encoding.utf8.rawValue]])
        try recoveryBytes.write(to:recovery)
        do {
            let store=WorkspaceStore()
            try require(store.tabs.count==1 && store.tabs[0].text.isEmpty && store.tabs[0].dirty,"recovered deleted-to-empty draft stays dirty")
            store.tabs[0].edited("")
            try require(store.tabs[0].dirty,"empty restored draft still needs saving")
        }
        try FileManager.default.removeItem(at:recovery)
        print("Core: PASS (CSV/TSV, exact history, external mutation/deletion, corrupt-state preservation, empty-draft recovery)")
    }
}
