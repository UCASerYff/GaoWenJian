import AppKit
import Foundation
import Darwin

@main struct HeadlessTestMain {
    @MainActor static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data(("FAIL headless regression: " + error.localizedDescription + "\n").utf8))
            Darwin.exit(1)
        }
    }
    @MainActor private static func run() throws {
        guard CommandLine.arguments.contains("--data-dir"), FileSafety.root.path.hasPrefix("/private/tmp/gaowenjian-headless.") else { throw FileIssue.message("Headless regression requires its own isolated temporary data root") }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-data-copy"), index + 1 < CommandLine.arguments.count {
            try DataCopyVerification.run(backup: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
            return
        }
        let parent = FileSafety.root.deletingLastPathComponent()
        var suites = 0
        func suite(_ name: String, _ run: () throws -> Void) throws {
            guard NSApp == nil else { throw FileIssue.message("Unexpected application initialization before " + name) }
            try run()
            guard NSApp == nil else { throw FileIssue.message("Application initialized by headless suite " + name) }
            suites += 1
        }
        try suite("core") { try CoreTests.run() }
        try suite("Office models/recovery") { try runOfficeRoundTripTests() }
        try suite("Office readonly") { try runOfficeViewerTests() }
        try suite("PDF model") { try PDFModuleTests.run(in: FileSafety.root.appendingPathComponent("PDFModelTests")) }
        try suite("PDF handoff") { try PDFHandoffTests.run(in: FileSafety.root.appendingPathComponent("PDFHandoffTests")) }
        try suite("current PDF bridge") { try CurrentDocumentHandoffTests.run(in: FileSafety.root.appendingPathComponent("CurrentDocumentHandoffTests")) }
        try suite("OCR provenance") { try OCRResultProvenanceTests.run() }
        try suite("transport/ledger") { try GaoActionTests.run(in: parent.appendingPathComponent("TransportTests")) }
        try suite("outgoing journal") { try GaoOutgoingJournalTests.run(in: parent.appendingPathComponent("JournalTests")) }
        try suite("safe export") { try HandoffSafeExportTests.run(in: parent.appendingPathComponent("SafeExports")) }
        try suite("untrusted document safety") { try DocumentHandoffSafetyTests.run(in: parent.appendingPathComponent("UntrustedDocumentTests")) }
        try suite("LaTeX model") { try LaTeXTests.run() }
        try suite("sticky data/attachments") { try runStickyNotesTests() }
        var provider: URL?
        if let index = CommandLine.arguments.firstIndex(of: "--ocr-provider"), index + 1 < CommandLine.arguments.count {
            provider = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        var productionChecks = 0
        try suite("production handoff dispatch") { productionChecks = try HandoffProductionTests.run(in: parent.appendingPathComponent("ProductionFixtures"), providerExecutable: provider) }
        print("PASS: \(suites) headless Swift regression suites; production dispatcher \(productionChecks) checks; NSApp remained nil. No smoke test, App/browser/simulator/test window or actual installed-app UI end-to-end was run.")
    }
}
