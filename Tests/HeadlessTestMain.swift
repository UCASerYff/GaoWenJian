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
        let parent = FileSafety.root.deletingLastPathComponent()
        var suites = 0
        func suite(_ name: String, _ run: () throws -> Void) throws {
            guard NSApp == nil else { throw FileIssue.message("Unexpected application initialization before " + name) }
            try run()
            guard NSApp == nil else { throw FileIssue.message("Application initialized by headless suite " + name) }
            suites += 1
        }
        if CommandLine.arguments.contains("--backup-removal-only") {
            try suite("saving without backups") { try CoreTests.run() }
            try suite("Office save/recovery without previous backups") { try runOfficeRoundTripTests() }
            try suite("PDF save without backups") { try PDFModuleTests.run(in: FileSafety.root.appendingPathComponent("PDFModelTests")) }
            try suite("safe export without retained backups") { try HandoffSafeExportTests.run(in: parent.appendingPathComponent("SafeExports")) }
            try suite("sticky body lifecycle without backups") { try BackupRemovalTests.run(in: FileSafety.root.appendingPathComponent("BackupRemovalTests")) }
            print("PASS: focused backup-removal regression; NSApp remained nil; no App, windows or smoke test.")
            return
        }
        if CommandLine.arguments.contains("--ocr-provider-routing-only") {
            var assertions = 0
            try suite("OCR canonical owner and legacy fences") { assertions = try OCRProviderRoutingTests.run(in:parent.appendingPathComponent("OCRRoutingTests")) }
            print("PASS: focused OCR provider routing; \(assertions) assertions; NSApp remained nil. No provider App/window or smoke test.")
            return
        }
        if CommandLine.arguments.contains("--writing-and-ocr-returns-only") {
            try suite("writing project sessions") { try WritingProjectsTests.run(in: parent.appendingPathComponent("WritingProjects")) }
            try suite("OCR return mailbox and review bindings") { try OCRReturnMailboxTests.run(in: parent.appendingPathComponent("OCRReturns")) }
            try suite("OCR return opens only through the inbox") { try checkOCRReturnOpenRoute() }
            #if GAO_OCR_RETURN_CROSSCHECK
            try suite("OCR provider and receiver on the same private mailbox") { try OCRReturnCrossImplementationTests.run(in: parent.appendingPathComponent("OCRCross")) }
            #endif
            print("PASS: focused writing project and OCR return regressions; NSApp remained nil.")
            return
        }
        if CommandLine.arguments.contains("--research-handoff-only") {
            try suite("current text format") { try CurrentDocumentHandoffTests.runText(in: parent.appendingPathComponent("CurrentTextTests")) }
            var receiptChecks = 0
            try suite("research import receipts") { receiptChecks = try ResearchImportReceiptTests.run(in: parent.appendingPathComponent("ResearchReceiptTests")) }
            print("PASS: focused research handoff checks; \(receiptChecks) receipt assertions; NSApp remained nil. No App, window or smoke test.")
            return
        }
        if CommandLine.arguments.contains("--reference-selection-only") {
            var assertions = 0
            try suite("reference modification precision") { assertions = try ReferenceSelectionTests.runTimePrecision(in: parent.appendingPathComponent("ReferenceTimeTests")) }
            print("PASS: focused reference modification time checks; \(assertions) assertions; NSApp remained nil. No App, window or smoke test.")
            return
        }
        try suite("core") { try CoreTests.run() }
        try suite("Office models/recovery") { try runOfficeRoundTripTests() }
        try suite("Office readonly") { try runOfficeViewerTests() }
        try suite("PDF model") { try PDFModuleTests.run(in: FileSafety.root.appendingPathComponent("PDFModelTests")) }
        try suite("PDF handoff") { try PDFHandoffTests.run(in: FileSafety.root.appendingPathComponent("PDFHandoffTests")) }
        try suite("PDF form commit/recovery") { try PDFFormFocusTests.run(in: FileSafety.root.appendingPathComponent("PDFFormFocusTests")) }
        try suite("writing project sessions") { try WritingProjectsTests.run(in: parent.appendingPathComponent("WritingProjects")) }
        try suite("current PDF bridge") { try CurrentDocumentHandoffTests.run(in: FileSafety.root.appendingPathComponent("CurrentDocumentHandoffTests")) }
        try suite("OCR provenance") { try OCRResultProvenanceTests.run() }
        try suite("OCR JSON body") { try OCRJSONPayloadVerifierTests.run() }
        try suite("OCR return mailbox and review bindings") { try OCRReturnMailboxTests.run(in: parent.appendingPathComponent("OCRReturns")) }
        try suite("OCR return opens only through the inbox") { try checkOCRReturnOpenRoute() }
        #if GAO_OCR_RETURN_CROSSCHECK
        try suite("OCR provider and receiver on the same private mailbox") { try OCRReturnCrossImplementationTests.run(in: parent.appendingPathComponent("OCRCross")) }
        #endif
        try suite("explicit edited export") { try EditedDocumentExportTests.run(in: FileSafety.root.appendingPathComponent("EditedExportTests")) }
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
        try suite("image OCR PDF verification") { _ = try PDFImageHandoffTests.run(in:parent.appendingPathComponent("ImageHandoffTests"),providerExecutable:provider) }
        try suite("OCR dispatch options/JSON") { try OCRDispatchOptionsTests.run(in:parent.appendingPathComponent("OCRDispatchOptionsTests")) }
        try suite("provider path compatibility") { _ = try GaoActionWriterCompatibilityTests.run(in:parent.appendingPathComponent("WriterCompatibilityTests")) }
        try suite("reference modification precision") { try ReferenceSelectionTests.runTimePrecision(in:parent.appendingPathComponent("ReferenceTimeTests")) }
        try suite("reference selection") { try ReferenceSelectionTests.run(in:parent.appendingPathComponent("ReferenceSelectionTests")) }
        var productionChecks = 0
        try suite("production handoff dispatch") { productionChecks = try HandoffProductionTests.run(in: parent.appendingPathComponent("ProductionFixtures"), providerExecutable: provider) }
        print("PASS: \(suites) headless Swift regression suites; production dispatcher \(productionChecks) checks; NSApp remained nil. No smoke test, App/browser/simulator/test window or actual installed-app UI end-to-end was run.")
    }

    @MainActor private static func checkOCRReturnOpenRoute() throws {
        let store = WorkspaceStore()
        let originalTabs = store.tabs.map(\.id)
        let root = GaoHandoffService.ocrMailboxRoot
        guard root.path.hasPrefix(FileSafety.root.path + "/") else {
            throw FileIssue.message("An isolated launch must use its injected OCR mailbox")
        }
        let package = root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("result.gaoaction", isDirectory: true)
        let member = package.appendingPathComponent("manifest.json")
        guard GaoHandoffService.handleIncoming(url: package, store: store) else {
            throw FileIssue.message("Opening a mailbox result should route to the inbox")
        }
        store.open(member)
        guard store.tabs.map(\.id) == originalTabs, !store.handoffBusy, store.status.contains("OCR 与交接") else {
            throw FileIssue.message("Opening a mailbox path must leave editors and approval idle")
        }
        do {
            _ = try GaoHandoffService.receive(url: package, store: store, interaction: .application)
        } catch let error as GaoActionIssue {
            guard error.code == "ocrReviewRequired" else { throw error }
            return
        }
        throw FileIssue.message("The generic handoff receiver bypassed the OCR inbox")
    }
}
