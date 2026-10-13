import AppKit
import Foundation

@main struct TestMain {
    @MainActor static func main() throws {
        guard CommandLine.arguments.contains("--data-dir"),FileSafety.root.path.hasPrefix("/private/tmp/gaowenjian-tests.") else {throw FileIssue.message("测试只能使用隔离临时资料路径")}
        _ = NSApplication.shared
        try CoreTests.run()
        try runOfficeRoundTripTests()
        try runOfficeViewerTests()
        try PDFModuleTests.run(in:FileSafety.root.appendingPathComponent("PDFTests"))
        try GaoActionTests.run(in:FileSafety.root.appendingPathComponent("GaoActionTests"))
        try PDFHandoffTests.run(in:FileSafety.root.appendingPathComponent("PDFHandoffTests"))
        try DocumentHandoffSafetyTests.run(in:FileSafety.root.deletingLastPathComponent().appendingPathComponent("UntrustedDocumentFixtures"))
        try LaTeXTests.run()
        try runStickyNotesTests()
        try runStickyNotesUITests()
        print("PASS: isolated native regression suite")
    }
}
