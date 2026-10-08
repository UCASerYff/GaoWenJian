import AppKit
import Foundation

@main struct TestMain {
    @MainActor static func main() throws {
        guard CommandLine.arguments.contains("--data-dir"),FileSafety.root.path.hasPrefix("/private/tmp/gaowenjian-tests.") else {throw FileIssue.message("测试只能使用隔离临时资料路径")}
        _ = NSApplication.shared
        try CoreTests.run()
        try runOfficeRoundTripTests()
        try PDFModuleTests.run(in:FileSafety.root.appendingPathComponent("PDFTests"))
        try runStickyNotesTests()
        try runStickyNotesUITests()
        print("PASS: isolated native regression suite")
    }
}
