import AppKit
import CoreText
import Foundation
import PDFKit

/// Exercises the exact menu/AppDelegate business dispatchers without creating an
/// NSApplication or a window. Only confirmation, version selection and authority
/// selection are substituted; transport, persistence and editor adapters are real.
@MainActor enum HandoffProductionTests {
    static func run(in root: URL, providerExecutable: URL? = nil) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var assertions = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw GaoActionContract.reject("productionTest", label) }; assertions += 1
        }
        func rejects(_ label: String, _ body: () throws -> Void) throws {
            do { try body() } catch { assertions += 1; return }
            throw GaoActionContract.reject("productionTest", "Expected rejection: " + label)
        }
        try check(NSApp == nil, "No application is initialized")
        let clock = GaoActionFixtures.clock
        let store = WorkspaceStore()
        store.newText(.markdown, text: "# 原有未保存内容\n\n保留光标所属标签与正文 😀\n")
        let existing = store.active!
        existing.edited(existing.text + "待保存\n")
        let initialText = existing.text
        store.newText(.latex, text: "\\documentclass{article}\n\\begin{document}core retained\\end{document}\n")
        let latex = store.active!
        store.select(existing)

        let stickyRoot = FileSafety.root.appendingPathComponent("ProductionNotes")
        let notes = StickyNotesStore(rootURL: stickyRoot)
        let rich = NSMutableAttributedString(string: "便笺富文本与附件\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 17)])
        let wrapper = FileWrapper(regularFileWithContents: try scanPDF())
        wrapper.preferredFilename = "便笺附件.pdf"
        let attachment = NSTextAttachment(); attachment.fileWrapper = wrapper
        rich.append(NSAttributedString(attachment: attachment))
        guard let noteID = notes.create(title: "附属便笺", content: rich), notes.flush() else { throw FileIssue.message(notes.error ?? "Note fixture failed") }
        let noteBytes = try files(stickyRoot)

        let office = root.appendingPathComponent("只读 原件.docx")
        try OfficeFactory.create(kind: "docx", to: office)
        let officeOriginal = try Data(contentsOf: office)
        let officePackage = try OfficePackage(url: office)
        let oldWord = try OfficeWordDocument(package: officePackage)
        oldWord.setText(id: oldWord.paragraphs[0].id, text: "旧版未保存恢复内容")
        try oldWord.apply()
        try OfficeRecovery.persist(package: officePackage, original: office, originalDigest: OfficePackage.hash(officeOriginal))
        let officeRecovery = FileSafety.root.appendingPathComponent("Recovery/Office")
        let oldOfficeDrafts = try files(officeRecovery)

        var confirmations = 0, replies: [URL] = [], referenceSelections: [String] = []
        var allowReceive = true
        var allowedReferences: [String: URL] = [:]
        let interaction = GaoHandoffInteraction(confirm: { review in
            confirmations += 1
            return allowReceive
        }, selectReference: { reference in
            referenceSelections.append(reference.id)
            return allowedReferences[reference.id]
        }, offerResult: { _, package in replies.append(package) })
        let foreignExchange = root.appendingPathComponent("ForeignExchange")
        let text = root.appendingPathComponent("识别 中文与空格.md")
        let incomingText = "# OCR 衍生稿\n\nUnicode e\u{301} 😀\n\u{000c}第二页\r\n"
        try Data(incomingText.utf8).write(to: text)
        let request = try GaoActionWriter.writeRequest(action: "documents.newText", items: [.init(url: text, uti: "net.daringfireball.markdown")], parameters: ["suggestedTitle": .string("交接 草稿")], sourceBundleID: "com.gaoseries.FixtureSender", targetBundleID: GaoActionContract.bundleID, exchangeRoot: foreignExchange, now: clock)
        let accepted = try GaoHandoffService.receive(url: request, store: store, interaction: interaction, now: clock)
        try check(accepted.status == "completed" && accepted.openedTabIDs.count == 1, "Actual newText dispatcher opens one tab")
        let imported = store.tabs.first { $0.id == accepted.openedTabIDs[0] }!
        try check(imported.url == nil && imported.dirty && imported.kind == .markdown && imported.text == incomingText, "OCR text is a distinct unsaved Unicode Markdown tab")
        try check(existing.text == initialText && existing.dirty && store.tabs.contains { $0 === latex }, "Existing unsaved text and LaTeX remain")
        try check(try Data(contentsOf: text) == Data(incomingText.utf8), "Incoming original remains unchanged")
        let response = try readManifest(accepted.resultPackageURL!)
        try check(response.kind == "result" && response.action == "documents.newText" && response.items.isEmpty && response.provenance?["saved"]?.boolValue == false, "Open reply never claims saved output")
        let tabsAfterText = store.tabs.count
        let duplicate = try GaoHandoffService.receive(url: request, store: store, interaction: interaction, now: clock)
        try check(duplicate.duplicate && store.tabs.count == tabsAfterText && replies.count == 1, "Duplicate actual request has no tab or reply side effects")
        let cold = WorkspaceStore()
        try check(cold.tabs.contains { $0.id == imported.id && $0.text == incomingText && $0.dirty && $0.url == nil && $0.incoming?.requestID == imported.incoming?.requestID }, "Cold store reload retains unsaved incoming content and origin")
        try check(cold.tabs.contains { $0.id == existing.id && $0.text == initialText && $0.dirty }, "Cold store reload retains pre-existing draft")

        let officeRequest = try GaoActionWriter.writeRequest(action: "documents.open", items: [.init(url: office, uti: "org.openxmlformats.wordprocessingml.document")], sourceBundleID: "com.gaoseries.FixtureSender", targetBundleID: GaoActionContract.bundleID, exchangeRoot: foreignExchange, now: clock)
        let openedOffice = try GaoHandoffService.receive(url: officeRequest, store: store, interaction: interaction, now: clock)
        let officeTab = store.tabs.first { $0.id == openedOffice.openedTabIDs.first }!
        try check(officeTab.kind == .word && !officeTab.kind.canSave && officeTab.url != office, "Office enters existing read-only viewer using its verified copy")
        try check(store.save(officeTab) && (try Data(contentsOf: office)) == officeOriginal, "Office generic save cannot modify original")
        try check(try files(officeRecovery) == oldOfficeDrafts && files(stickyRoot) == noteBytes, "Actual receive preserves legacy Office drafts and full sticky attachment bytes")
        try check(notes.content(for: noteID)?.string == rich.string, "In-memory sticky rich text remains")

        allowReceive = false
        let deniedRequest = try GaoActionWriter.writeRequest(action: "documents.newText", items: [.init(url: text, uti: "net.daringfireball.markdown")], sourceBundleID: "com.gaoseries.FixtureSender", targetBundleID: GaoActionContract.bundleID, exchangeRoot: foreignExchange, now: clock)
        let deniedCount = store.tabs.count
        let denied = try GaoHandoffService.receive(url: deniedRequest, store: store, interaction: interaction, now: clock)
        try check(denied.status == "cancelled" && store.tabs.count == deniedCount, "User decline leaves current documents intact")
        allowReceive = true
        let cancelledRequest = try GaoActionWriter.writeRequest(action: "documents.newText", items: [.init(url: text, uti: "net.daringfireball.markdown")], sourceBundleID: "com.gaoseries.FixtureSender", targetBundleID: GaoActionContract.bundleID, exchangeRoot: foreignExchange, now: clock)
        let cancelToken = GaoHandoffCancellation(); cancelToken.cancel()
        try rejects("Cancellation during real receive") { _ = try GaoHandoffService.receive(url: cancelledRequest, store: store, interaction: interaction, now: clock, cancellation: cancelToken) }
        try check(store.tabs.count == deniedCount && existing.text == initialText, "Copy cancellation does not mutate editor state")

        let source = root.appendingPathComponent("未保存 PDF.pdf")
        let originalBytes = try scanPDF(form: true)
        try originalBytes.write(to: source)
        store.open(source)
        let pdfTab = store.active!
        let pdf = PDFWorkspaceModel(url: source)
        try pdf.addText("当前未保存批注", note: false, page: pdf.document!.page(at: 0)!, at: CGPoint(x: 30, y: 160))
        let pdfRecovery = FileSafety.root.appendingPathComponent("Recovery/PDF/\(FileSafety.digest(Data(source.standardizedFileURL.path.utf8)))")
        let recoveryBefore = try files(pdfRecovery)
        var commits = 0
        let registry = CurrentDocumentHandoffRegistry(formCommitter: { model in
            commits += 1
            model.formEntries.first?.annotation.widgetStringValue = "IMMEDIATE LATEST FORM"
            model.formMayHaveChanged()
        })
        registry.register(pdf)
        let current = try OCRHandoffDispatcher.prepare(files: [source], store: store, registry: registry, chooseVersion: { _ in .currentEdits }, now: clock)
        try check(try readManifest(current.packageURL).items.allSatisfy { !$0.relativePath.hasPrefix("payload/") && !$0.relativePath.contains("/") }, "New production writer uses payload-root relative filenames compatible with the real provider")
        let currentSource = current.session.sources[0]
        let journal = try GaoOutgoingJournal(exchangeRoot: GaoHandoffService.exchangeRoot)
        let sentCurrentURL = try journal.sourceURL(requestID: current.session.requestID, itemID: currentSource.item.id)
        let sentCurrent = PDFDocument(url: sentCurrentURL)!
        try check(commits >= 1 && currentSource.binding.versionKind == "currentEdits", "Actual OCR prepare commits the registered current model and journals chosen version")
        try check(sentCurrent.page(at: 0)?.annotations.contains { $0.contents == "当前未保存批注" } == true && sentCurrent.page(at: 0)?.annotations.first { $0.fieldName == "Latest" }?.widgetStringValue == "IMMEDIATE LATEST FORM", "Production request contains immediate unsaved form and annotation")
        try check(pdf.dirty && pdf.canUndo && (try files(pdfRecovery)) == recoveryBefore && (try Data(contentsOf: source)) == originalBytes, "Production OCR prepare preserves dirty/undo/recovery and source")
        try check(currentSource.item.sha256 == FileSafety.digest(try Data(contentsOf: sentCurrentURL)), "Journal source digest is the actual sent current version")
        try check(try currentSource.binding.originalReference.map { try GaoActionContract.localFileURL($0.fileURL).standardizedFileURL } == source.standardizedFileURL, "Current version keeps private original context for export protection")
        try rejects("Actual fallback export cannot overwrite original") {
            _ = try OCRHandoffDispatcher.exportCopy(current, itemID: currentSource.item.id, to: source, overwrite: .replace(expectedSHA256: FileSafety.digest(originalBytes)))
        }
        let originalHardLink = root.appendingPathComponent("原件硬链接.pdf")
        try fm.linkItem(at: source, to: originalHardLink)
        try rejects("Actual fallback export rejects original inode alias") {
            _ = try OCRHandoffDispatcher.exportCopy(current, itemID: currentSource.item.id, to: originalHardLink, overwrite: .replace(expectedSHA256: FileSafety.digest(originalBytes)))
        }
        try fm.removeItem(at: originalHardLink)
        let exportedCurrent = root.appendingPathComponent("导出当前 PDF 副本.pdf")
        let exportedReceipt = try OCRHandoffDispatcher.exportCopy(current, itemID: currentSource.item.id, to: exportedCurrent)
        try check(exportedReceipt.sha256 == currentSource.item.sha256 && (try Data(contentsOf: source)) == originalBytes, "Actual fallback exports journaled current version to a new file and preserves source")
        let collision = root.appendingPathComponent("冲突导出.pdf"), collisionBytes = Data("existing user target".utf8)
        try collisionBytes.write(to: collision)
        try rejects("Actual fallback existing target needs explicit conflict approval") { _ = try OCRHandoffDispatcher.exportCopy(current, itemID: currentSource.item.id, to: collision) }
        let replaced = try OCRHandoffDispatcher.exportCopy(current, itemID: currentSource.item.id, to: collision, overwrite: .replace(expectedSHA256: FileSafety.digest(collisionBytes)))
        try check(try Data(contentsOf: replaced.snapshotURL!) == collisionBytes && FileSafety.digest(Data(contentsOf: collision)) == currentSource.item.sha256, "Actual fallback replacement snapshots old target before atomic copy")

        store.select(existing)
        let researchText = try CurrentDocumentDispatcher.prepare(store: store, registry: registry, chooseVersion: { _ in .currentEdits }, now: clock)
        let researchRequest = try readManifest(researchText.packageURL)
        let researchTextSource = researchText.session.sources[0]
        let researchTextURL = try GaoOutgoingJournal(exchangeRoot: GaoHandoffService.exchangeRoot).sourceURL(requestID: researchText.session.requestID, itemID: researchTextSource.item.id)
        try check(researchRequest.action == "research.importDocuments" && researchRequest.targetBundleID == CurrentDocumentDispatcher.researchBundleID && researchTextSource.binding.versionKind == "currentEdits", "Actual current-document action targets fixed research import contract")
        try check(try String(contentsOf: researchTextURL, encoding: .utf8) == initialText && existing.dirty && existing.url == nil, "Current-document text transfer captures unsaved content without saving it")
        store.select(latex)
        let researchLaTeX = try CurrentDocumentDispatcher.prepare(store: store, registry: registry, chooseVersion: { _ in .currentEdits }, now: clock)
        let texItem = researchLaTeX.session.sources[0]
        let texURL = try GaoOutgoingJournal(exchangeRoot: GaoHandoffService.exchangeRoot).sourceURL(requestID: researchLaTeX.session.requestID, itemID: texItem.item.id)
        try check(texItem.item.relativePath.hasSuffix(".tex.txt") && texItem.item.uti == "public.utf8-plain-text" && (try String(contentsOf: texURL, encoding: .utf8)) == latex.text && latex.dirty && latex.url == nil, "LaTeX transfer produces supported .tex.txt source copy, preserving unsaved compiler document")
        store.select(pdfTab)
        let researchPDF = try CurrentDocumentDispatcher.prepare(store: store, registry: registry, chooseVersion: { _ in .currentEdits }, now: clock)
        let researchPDFSource = researchPDF.session.sources[0]
        let researchPDFURL = try GaoOutgoingJournal(exchangeRoot: GaoHandoffService.exchangeRoot).sourceURL(requestID: researchPDF.session.requestID, itemID: researchPDFSource.item.id)
        try check(researchPDFSource.binding.versionKind == "currentEdits" && PDFDocument(url: researchPDFURL)?.page(at: 0)?.annotations.first { $0.fieldName == "Latest" }?.widgetStringValue == "IMMEDIATE LATEST FORM", "Current-document research PDF transfer uses same immediate live model")
        let researchDisk = try CurrentDocumentDispatcher.prepare(store: store, registry: registry, chooseVersion: { _ in .diskOriginal }, now: clock)
        try check(researchDisk.session.sources[0].binding.versionKind == "savedVersion" && researchDisk.session.sources[0].item.sha256 == FileSafety.digest(originalBytes), "Current-document PDF disk choice is explicitly journaled saved version")
        try rejects("Current-document PDF cancellation") { _ = try CurrentDocumentDispatcher.prepare(store: store, registry: registry, chooseVersion: { _ in .cancel }, now: clock) }
        store.showingNotes = true
        try rejects("Accessory sticky context is not sent as current document") { _ = try CurrentDocumentDispatcher.prepare(store: store, registry: registry, chooseVersion: { _ in .currentEdits }, now: clock) }
        store.showingNotes = false
        if fm.fileExists(atPath: "/Applications/搞研究.app") {
            let provider = try GaoCapabilityDiscovery.provider(applicationURL: URL(fileURLWithPath: "/Applications/搞研究.app"), bundleID: CurrentDocumentDispatcher.researchBundleID, action: "research.importDocuments")
            try check(provider?.capability.accepts(parameterKeys: ["targetRecordID"]) == true && provider?.capability.action == "research.importDocuments", "Actual installed research dictionary capability is readable without NSWorkspace or launching it")
        }
        let disk = try OCRHandoffDispatcher.prepare(files: [source], store: store, registry: registry, chooseVersion: { _ in .diskOriginal }, now: clock)
        try check(disk.session.sources[0].binding.versionKind == "original" && disk.session.sources[0].item.sha256 == FileSafety.digest(originalBytes), "Original choice sends exact disk version")
        let sessionsBeforeCancel = try GaoOutgoingJournal(exchangeRoot: GaoHandoffService.exchangeRoot).allSessions().count
        try rejects("Version choice cancel") { _ = try OCRHandoffDispatcher.prepare(files: [source], store: store, registry: registry, chooseVersion: { _ in .cancel }, now: clock) }
        try check(try GaoOutgoingJournal(exchangeRoot: GaoHandoffService.exchangeRoot).allSessions().count == sessionsBeforeCancel, "Cancel creates no outgoing session")
        registry.unregister(pdf)
        pdfTab.moduleDirty = true
        try rejects("No current model cannot reconstruct stale recovery for current export") { _ = try OCRHandoffDispatcher.prepare(files: [source], store: store, registry: registry, chooseVersion: { _ in .currentEdits }, now: clock) }
        pdfTab.moduleDirty = false

        let requestManifest = try readManifest(disk.packageURL)
        let partialText = root.appendingPathComponent("partial.txt")
        try Data("OCR PAGE ONE\n\u{000c}PAGE TWO FAILED\n".utf8).write(to: partialText)
        let pending = try result(for: requestManifest, status: "pending", files: [], root: foreignExchange, clock: clock)
        let pendingTabs = store.tabs.count
        let pendingOutcome = try GaoHandoffService.receive(url: pending, store: store, interaction: interaction, now: clock)
        try check(pendingOutcome.status == "pending" && store.tabs.count == pendingTabs && (try GaoOutgoingJournal(exchangeRoot: GaoHandoffService.exchangeRoot).lookup(disk.session.requestID)?.phase) == .pending, "Pending result routes by original ocr.files and creates no document")
        let partialFile = GaoOutgoingFile(url: partialText, uti: "public.utf8-plain-text", id: "partial-text")
        let partial = try result(for: requestManifest, status: "partial", files: [partialFile], root: foreignExchange, clock: clock, pageStatuses: ["completed", "failed"])
        let partialOutcome = try GaoHandoffService.receive(url: partial, store: store, interaction: interaction, now: clock)
        let partialTab = store.tabs.first { $0.id == partialOutcome.openedTabIDs.first }!
        try check(partialOutcome.status == "partial" && partialTab.url == nil && partialTab.dirty && partialTab.text.contains("OCR PAGE ONE"), "Partial real result opens new unsaved text rather than switching action")
        try check(partialTab.incoming?.ocrProvenance?.engineVersion == "3" && partialTab.incoming?.ocrProvenance?.sourceSHA256 == FileSafety.digest(originalBytes) && partialTab.incoming?.ocrProvenance?.pages.last?.status == "failed", "Real provider provenance maps to sent original and failed-page metadata")
        let repeatedPartial = try GaoHandoffService.receive(url: partial, store: store, interaction: interaction, now: clock)
        try check(repeatedPartial.duplicate && store.tabs.count == pendingTabs + 1, "Partial result replay has no duplicate tab")
        let searchable = root.appendingPathComponent("可搜索 衍生.pdf")
        try searchablePDF(from: originalBytes).write(to: searchable)
        let complete = try result(for: requestManifest, status: "completed", files: [.init(url: partialText, uti: "public.utf8-plain-text", id: "new-text-id"), .init(url: searchable, uti: "com.adobe.pdf", id: "searchable-pdf")], root: foreignExchange, clock: clock)
        let completedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: complete.appendingPathComponent("manifest.json"))) as! [String: Any]
        try check(completedJSON["errorCode"] == nil, "Successful provider JSON can omit its nil optional errorCode")
        let completed = try GaoHandoffService.receive(url: complete, store: store, interaction: interaction, now: clock)
        try check(completed.status == "completed" && completed.openedTabIDs.count == 1, "Partial to completed imports only new PDF, not prior identical text")
        let derived = store.tabs.first { $0.id == completed.openedTabIDs.first }!
        try check(derived.kind == .pdf && derived.url != source && derived.incoming?.pdfReport?.sourceDigestMatches == true && derived.incoming?.pdfReport?.pageChecks.count == 2, "Actual PDF receive executes original-digest/page validation branch")
        try check(derived.incoming?.pdfReport?.isVerifiedSearchable == true, "Real page text, original page geometry/order and full statuses produce basic searchable verification")
        try check(try Data(contentsOf: source) == originalBytes && files(pdfRecovery) == recoveryBefore, "Receiving derived PDF never overwrites original or unsaved recovery")
        let completedAgain = try GaoHandoffService.receive(url: complete, store: WorkspaceStore(), interaction: interaction, now: clock)
        try check(completedAgain.duplicate, "Cold consumer duplicate is journal-backed")

        for status in ["failed", "cancelled", "unsupported"] {
            let fresh = try OCRHandoffDispatcher.prepare(files: [source], store: store, registry: registry, chooseVersion: { _ in .diskOriginal }, now: clock)
            let package = try result(for: readManifest(fresh.packageURL), status: status, files: [], root: foreignExchange, clock: clock)
            let before = store.tabs.count
            let outcome = try GaoHandoffService.receive(url: package, store: store, interaction: interaction, now: clock)
            try check(outcome.status == status && store.tabs.count == before, "Provider " + status + " does not fabricate output")
        }
        let association = try OCRHandoffDispatcher.prepare(files: [source], store: store, registry: registry, chooseVersion: { _ in .diskOriginal }, now: clock)
        let associationRequest = try readManifest(association.packageURL)
        for alteration in ["reply", "sender", "action", "sourceHash"] {
            let invalid = try result(for: associationRequest, status: "completed", files: [partialFile], root: foreignExchange, clock: clock, alter: { manifest in
                switch alteration {
                case "reply": manifest.inReplyTo = UUID().uuidString
                case "sender": manifest.sourceBundleID = "com.gaoseries.Unrelated"
                case "action": manifest.action = "documents.open"; manifest.parameters = [:]
                default:
                    var outputs = manifest.provenance!["outputs"]!.arrayValue!, item = outputs[0].objectValue!
                    item["sourceSHA256"] = .string(String(repeating: "0", count: 64)); outputs[0] = .object(item); manifest.provenance!["outputs"] = .array(outputs)
                }
            })
            let before = store.tabs.count
            try rejects("Actual result association " + alteration) { _ = try GaoHandoffService.receive(url: invalid, store: store, interaction: interaction, now: clock) }
            try check(store.tabs.count == before, "Wrong association cannot open tabs")
        }
        let malformedError = try result(for: associationRequest, status: "completed", files: [partialFile, .init(url: searchable, uti: "com.adobe.pdf", id: "malformed-code-pdf")], root: foreignExchange, clock: clock)
        let malformedErrorURL = malformedError.appendingPathComponent("manifest.json")
        var malformedErrorJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: malformedErrorURL)) as! [String: Any]
        malformedErrorJSON["errorCode"] = 123
        try JSONSerialization.data(withJSONObject: malformedErrorJSON).write(to: malformedErrorURL)
        let tabsBeforeMalformed = store.tabs.count
        try rejects("Optional errorCode still rejects wrong wire type") { _ = try GaoHandoffService.receive(url: malformedError, store: store, interaction: interaction, now: clock) }
        try check(store.tabs.count == tabsBeforeMalformed, "Malformed optional field cannot mutate documents")

        for (ext, uti, format) in [("txt", "public.utf8-plain-text", "text"), ("md", "net.daringfireball.markdown", "markdown")] {
            let payload = root.appendingPathComponent("无格式声明." + ext)
            try Data("OCR WITHOUT OPTIONAL FORMAT\n\n# Unicode 中文\n".utf8).write(to: payload)
            let package = try GaoActionWriter.writeRequest(action: "ocr.files", items: [.init(url: source, uti: "com.adobe.pdf")], parameters: ["outputs": .array([.string(format)])], targetBundleID: "com.gaoseries.GaoJieTu", exchangeRoot: GaoHandoffService.exchangeRoot, now: clock)
            _ = try GaoOutgoingJournal(exchangeRoot: GaoHandoffService.exchangeRoot).registerOutgoing(packageURL: package, expectedTargetBundleID: "com.gaoseries.GaoJieTu", now: clock)
            let response = try result(for: readManifest(package), status: "completed", files: [.init(url: payload, uti: uti)], root: foreignExchange, clock: clock, alter: { manifest in
                var values = manifest.provenance!["outputs"]!.arrayValue!, output = values[0].objectValue!
                output.removeValue(forKey: "format"); values[0] = .object(output); manifest.provenance!["outputs"] = .array(values)
            })
            let outcome = try GaoHandoffService.receive(url: response, store: store, interaction: interaction, now: clock)
            let tab = store.tabs.first { $0.id == outcome.openedTabIDs.first }
            try check(outcome.status == "completed" && tab?.url == nil && tab?.dirty == true, "Actual OCR result with no optional format opens an unsaved " + ext + " tab")
            try check(tab?.kind == (ext == "md" ? .markdown : .text) && tab?.text.contains("WITHOUT OPTIONAL FORMAT") == true, "Missing format routes by validated text file type and preserves content")
            try check(try Data(contentsOf: source) == originalBytes && existing.text == initialText && existing.dirty, "Missing-format import preserves original and active drafts")
        }

        let batchSource = root.appendingPathComponent("批次 第二源.pdf")
        let batchSourceBytes = try scanPDF()
        try batchSourceBytes.write(to: batchSource)
        let batch = try OCRHandoffDispatcher.prepare(files: [source, batchSource], store: store, registry: registry, chooseVersion: { _ in .diskOriginal }, now: clock)
        let batchRequest = try readManifest(batch.packageURL)
        let firstBatchFiles: [GaoOutgoingFile] = [.init(url: partialText, uti: "public.utf8-plain-text", id: "batch-one-text"), .init(url: searchable, uti: "com.adobe.pdf", id: "batch-one-pdf")]
        let incomplete = try result(for: batchRequest, status: "completed", files: firstBatchFiles, root: foreignExchange, clock: clock)
        let beforeIncomplete = store.tabs.count
        try rejects("A two-input OCR completion cannot silently omit the second source") { _ = try GaoHandoffService.receive(url: incomplete, store: store, interaction: interaction, now: clock) }
        try check(store.tabs.count == beforeIncomplete && (try GaoOutgoingJournal(exchangeRoot: GaoHandoffService.exchangeRoot).lookup(batch.session.requestID)?.phase) == .prepared, "Incomplete completion has no editor effects or persisted terminal success")
        let firstBatch = try result(for: batchRequest, status: "partial", files: firstBatchFiles, root: foreignExchange, clock: clock)
        let firstBatchOutcome = try GaoHandoffService.receive(url: firstBatch, store: store, interaction: interaction, now: clock)
        try check(firstBatchOutcome.status == "partial" && firstBatchOutcome.openedTabIDs.count == 2, "Partial batch can import the first source's actual outputs")
        let batchSearchable = root.appendingPathComponent("第二源 可搜索.pdf")
        try searchablePDF(from: batchSourceBytes).write(to: batchSearchable)
        let secondBatchText = root.appendingPathComponent("第二源.txt")
        try Data("OCR SECOND SOURCE\n".utf8).write(to: secondBatchText)
        var secondRequestContext = batchRequest
        secondRequestContext.items = [batchRequest.items[1]]
        let secondBatch = try result(for: secondRequestContext, status: "completed", files: [.init(url: secondBatchText, uti: "public.utf8-plain-text", id: "batch-two-text"), .init(url: batchSearchable, uti: "com.adobe.pdf", id: "batch-two-pdf")], root: foreignExchange, clock: clock)
        let secondBatchOutcome = try GaoHandoffService.receive(url: secondBatch, store: store, interaction: interaction, now: clock)
        try check(secondBatchOutcome.status == "completed" && secondBatchOutcome.openedTabIDs.count == 2, "Cumulative partial plus new outputs can honestly complete all input sources")
        try check(try Data(contentsOf: source) == originalBytes && Data(contentsOf: batchSource) == batchSourceBytes, "Batch partial/completion leaves both originals intact")

        let selectionRequestURL = try GaoActionWriter.writeRequest(action: "files.choose", parameters: ["multiple": .bool(true)], targetBundleID: "com.gaoseries.GaoZhengLi", exchangeRoot: GaoHandoffService.exchangeRoot, now: clock)
        let selectionRequest = try readManifest(selectionRequestURL)
        _ = try GaoOutgoingJournal(exchangeRoot: GaoHandoffService.exchangeRoot).registerOutgoing(packageURL: selectionRequestURL, expectedTargetBundleID: "com.gaoseries.GaoZhengLi", now: clock)
        let selectedOne = root.appendingPathComponent("获准.txt"), selectedTwo = root.appendingPathComponent("拒绝.txt")
        try Data("用户明确授权的文档".utf8).write(to: selectedOne)
        try Data("不可默读的第二份".utf8).write(to: selectedTwo)
        let selectedReferences = try [reference(selectedOne, id: "allowed"), reference(selectedTwo, id: "declined")]
        allowedReferences = ["allowed": selectedOne]
        let selectionResult = try result(for: selectionRequest, status: "completed", files: [], references: selectedReferences, root: foreignExchange, clock: clock)
        let choice = try GaoHandoffService.receive(url: selectionResult, store: store, interaction: interaction, now: clock)
        try check(choice.status == "partial" && choice.openedTabIDs.count == 1 && Array(referenceSelections.suffix(2)) == ["allowed", "declined"], "files.choose asks this consumer for each original and honors refusal")
        let selectedTab = store.tabs.first { $0.id == choice.openedTabIDs.first }!
        try check(selectedTab.url != selectedOne && selectedTab.text == "用户明确授权的文档", "Selected reference opens only a verified private copy")
        let beforeSelectionRepeat = store.tabs.count
        let choiceRepeat = try GaoHandoffService.receive(url: selectionResult, store: store, interaction: interaction, now: clock)
        try check(choiceRepeat.duplicate && store.tabs.count == beforeSelectionRepeat && referenceSelections.count == 2, "Selected/denied references do not reauthorize on duplicate")

        let damaged = root.appendingPathComponent("损坏.pdf")
        try Data("not a PDF".utf8).write(to: damaged)
        let damagedRequest = try GaoActionWriter.writeRequest(action: "documents.open", items: [.init(url: damaged, uti: "com.adobe.pdf")], sourceBundleID: "com.gaoseries.FixtureSender", targetBundleID: GaoActionContract.bundleID, exchangeRoot: foreignExchange, now: clock)
        let beforeDamage = store.tabs.count
        let damage = try GaoHandoffService.receive(url: damagedRequest, store: store, interaction: interaction, now: clock)
        try check(damage.status == "failed" && store.tabs.count == beforeDamage, "Damaged input goes through actual failure result without touching existing tabs")
        try check(existing.text == initialText && existing.dirty && (try files(stickyRoot)) == noteBytes && (try files(officeRecovery)) == oldOfficeDrafts, "All business result/failure paths preserve drafts, notes and attachments")
        try check(NSApp == nil && confirmations > 0, "Production dispatch tests did not start an application/window")

        if let providerExecutable {
            assertions += try realProvider(in: root.appendingPathComponent("RealProvider"), executable: providerExecutable, store: store, interaction: interaction)
        }
        pdf.discardDraft()
        print("PASS: actual handoff production dispatchers \(assertions) checks (not a GUI/installed-app end-to-end or smoke test)")
        return assertions
    }

    private static func realProvider(in root: URL, executable: URL, store: WorkspaceStore, interaction: GaoHandoffInteraction) throws -> Int {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let scans = [root.appendingPathComponent("两页 扫描.pdf"), root.appendingPathComponent("第二输入.pdf")]
        for url in scans { try scanPDF().write(to: url) }
        let original = try scans.map { try Data(contentsOf: $0) }
        let prepared = try OCRHandoffDispatcher.prepare(files: scans, store: store, registry: CurrentDocumentHandoffRegistry(), chooseVersion: { _ in .diskOriginal })
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.arguments = [prepared.packageURL.path, root.appendingPathComponent("ProviderExchange").path]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile(), errorBytes = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let resultPath = object["resultPackage"] as? String, object["nonGUI"] as? Bool == true,
              object["nsApplicationInitialized"] as? Bool == false else {
            throw GaoActionContract.reject("realProviderTest", "Actual provider production OCR failed: " + (String(data: errorBytes, encoding: .utf8) ?? "non-UTF8 provider error").prefix(1024))
        }
        let manifest = try readManifest(URL(fileURLWithPath: resultPath))
        let outcome = try GaoHandoffService.receive(url: URL(fileURLWithPath: resultPath), store: store, interaction: interaction)
        let tabs = store.tabs.filter { outcome.openedTabIDs.contains($0.id) }
        guard manifest.action == "ocr.files", manifest.status == "completed", outcome.status == "completed", tabs.count == 4,
              tabs.filter({ $0.url == nil && $0.dirty && $0.text.uppercased().contains("OCR") }).count == 2,
              tabs.filter({ $0.kind == .pdf && $0.incoming?.pdfReport?.isVerifiedSearchable == true }).count == 2,
              try scans.enumerated().allSatisfy({ try Data(contentsOf: $0.element) == original[$0.offset] }), NSApp == nil else {
            throw GaoActionContract.reject("realProviderTest", "Actual provider/consumer chain did not produce two unsaved OCR texts and two structurally verified searchable PDFs while retaining originals")
        }
        if let option = CommandLine.arguments.lastIndex(of: "--evidence-dir"), option + 1 < CommandLine.arguments.count {
            let destination = URL(fileURLWithPath: CommandLine.arguments[option + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let evidence: [String: Any] = [
                "test": "actual-provider-production-methods-to-consumer-dispatcher",
                "nonGUI": true, "smokeTestRun": false, "installedAppUIEndToEndRun": false,
                "providerMethodSHA256": object["originalPerformOCRSHA256"] ?? NSNull(),
                "providerNSApplicationInitialized": object["nsApplicationInitialized"] ?? NSNull(),
                "status": manifest.status ?? "missing", "action": manifest.action,
                "inReplyToMatches": manifest.inReplyTo == prepared.session.requestID,
                "inputCount": scans.count, "sourcePages": 4,
                "originalSHA256Before": original.map(FileSafety.digest),
                "originalSHA256After": try scans.map { FileSafety.digest(try Data(contentsOf: $0)) },
                "outputs": manifest.items.map { ["id": $0.id, "uti": $0.uti, "sha256": $0.sha256, "byteCount": $0.byteCount] as [String: Any] },
                "receivedTextTabs": tabs.filter { $0.url == nil && $0.dirty }.count,
                "receivedPDFTabs": tabs.filter { $0.kind == .pdf }.count,
                "PDFChecks": tabs.filter { $0.kind == .pdf }.map { tab -> [String: Any] in
                    let report = tab.incoming!.pdfReport!
                    return ["verifiedSearchable": report.isVerifiedSearchable, "digestMatches": report.sourceDigestMatches == true,
                            "pageCount": report.pageChecks.count, "rotations": report.pageChecks.map(\.rotation),
                            "allGeometryMatches": report.pageChecks.allSatisfy { $0.geometryMatchesSource == true },
                            "allPageRenderingMatches": report.pageChecks.allSatisfy { $0.renderedPageMatchesSource == true },
                            "allPagesSelectable": report.pageChecks.allSatisfy(\.hasSelectablePageText)]
                }
            ]
            let bytes = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: destination.appendingPathComponent("RealOCRProductionChain.json"), options: .atomic)
        }
        print("PASS: real producer performOCR → Vision → Exporter → GaoAction result → consumer dispatcher, 2 inputs / 4 scanned pages / 4 result tabs; no app/window start")
        return 8
    }

    private static func result(for request: GaoActionManifest, status: String, files: [GaoOutgoingFile], references: [GaoActionReference] = [], root: URL, clock: Date, pageStatuses: [String] = ["completed", "completed"], alter: ((inout GaoActionManifest) -> Void)? = nil) throws -> URL {
        var provenance: [String: GaoJSONValue] = [:]
        if request.action == "ocr.files", let source = request.items.first {
            let sourceID = "11111111-1111-4111-8111-111111111111"
            provenance = ["engine": .string("Apple Vision VNRecognizeTextRequest"), "engineRevision": .number(3), "networkUsed": .bool(false),
                "outputs": .array(files.map { file in .object(["sourceID": .string(sourceID), "sourceItemID": .string(source.id), "sourceSHA256": .string(source.sha256), "resultItemID": .string(file.id), "format": .string(file.uti == "com.adobe.pdf" ? "searchablePDF" : "text")]) }),
                "sources": .array([.object(["sourceID": .string(sourceID), "sourceItemID": .string(source.id), "sourceSHA256": .string(source.sha256), "outputItemIDs": .array(files.map { .string($0.id) }), "pages": .array(pageStatuses.enumerated().map { .object(["pageNumber": .number(Double($0.offset + 1)), "status": .string($0.element), "elapsedSeconds": .number(0.2), "lineCount": .number(1), "failureReason": .null]) })])])]
        }
        let package = try GaoActionWriter.writeResult(inReplyTo: request, status: status, items: files, references: references, provenance: provenance, exchangeRoot: root, now: clock)
        var manifest = try readManifest(package)
        manifest.sourceBundleID = request.targetBundleID
        if status == "completed" { manifest.errorCode = nil }
        alter?(&manifest)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        return package
    }
    private static func readManifest(_ package: URL) throws -> GaoActionManifest {
        try JSONDecoder().decode(GaoActionManifest.self, from: Data(contentsOf: package.appendingPathComponent("manifest.json")))
    }
    private static func reference(_ url: URL, id: String) throws -> GaoActionReference {
        let value = try GaoPrivateIO.regularURL(url).statValue()
        let modified = Date(timeIntervalSince1970: Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1_000_000_000)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .init(id: id, kind: "file", fileURL: url.absoluteString, displayName: url.lastPathComponent,
            declaredIdentity: .init(volumeUUID: try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString, device: UInt64(bitPattern: Int64(value.st_dev)), inode: UInt64(value.st_ino), byteCount: Int64(value.st_size), modifiedAt: formatter.string(from: modified)), sha256: FileSafety.digest(try Data(contentsOf: url)))
    }
    private static func files(_ root: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [:] }
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { throw FileIssue.message("Cannot inventory isolated test files") }
        var result: [String: String] = [:]
        for case let url as URL in entries where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(root.path.count + 1))] = FileSafety.digest(try Data(contentsOf: url))
        }
        return result
    }
    private static func scanPDF(form: Bool = false) throws -> Data {
        let buffer = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 500)
        let consumer = CGDataConsumer(data: buffer)!, context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for index in 0..<2 {
            context.beginPDFPage(nil); context.setFillColor(NSColor.white.cgColor); context.fill(box)
            // Rasterize the text before putting it on the PDF page: source has
            // no searchable page text and the real provider must perform OCR.
            let bitmap = CGContext(data: nil, width: 800, height: 1000, bitsPerComponent: 8, bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            bitmap.setFillColor(NSColor.white.cgColor); bitmap.fill(CGRect(x: 0, y: 0, width: 800, height: 1000))
            bitmap.setFillColor(NSColor.black.cgColor)
            bitmap.textPosition = CGPoint(x: 60, y: 800)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "OCR SCANNED PAGE \(index + 1)", attributes: [.font: NSFont(name: "Helvetica", size: 36)!]))
            CTLineDraw(line, bitmap)
            context.draw(bitmap.makeImage()!, in: box)
            context.endPDFPage()
        }
        context.closePDF()
        let document = PDFDocument(data: buffer as Data)!
        for index in 0..<document.pageCount {
            let page = document.page(at: index)!
            page.rotation = index == 0 ? 90 : 270
            page.setBounds(CGRect(x: 10, y: 20, width: 380, height: 460), for: .cropBox)
        }
        if form {
            let widget = PDFAnnotation(bounds: CGRect(x: 30, y: 70, width: 200, height: 25), forType: .widget, withProperties: nil)
            widget.widgetFieldType = .text; widget.fieldName = "Latest"; widget.widgetStringValue = "SAVED"; widget.font = NSFont(name: "Helvetica", size: 12)
            document.page(at: 0)!.addAnnotation(widget)
        }
        return document.dataRepresentation()!
    }
    private static func searchablePDF(from bytes: Data) throws -> Data {
        let source = PDFDocument(data: bytes)!, output = PDFDocument()
        for index in 0..<source.pageCount {
            let page = source.page(at: index)!
            let buffer = NSMutableData()
            var box = page.bounds(for: .mediaBox)
            let writer = CGContext(consumer: CGDataConsumer(data: buffer)!, mediaBox: &box, nil)!
            writer.beginPDFPage(nil)
            // Draw original page contents unrotated, then restore its page
            // dictionaries after creating a genuine invisible text layer.
            writer.drawPDFPage(page.pageRef!)
            writer.setTextDrawingMode(.invisible); writer.textPosition = CGPoint(x: 40, y: 320)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "OCR PAGE \(index + 1)", attributes: [.font: NSFont(name: "Helvetica", size: 20)!])), writer)
            writer.endPDFPage(); writer.closePDF()
            let result = PDFDocument(data: buffer as Data)!.page(at: 0)!
            result.rotation = page.rotation; result.setBounds(page.bounds(for: .cropBox), for: .cropBox)
            for annotation in page.annotations {
                if let copy = annotation.copy() as? PDFAnnotation { result.addAnnotation(copy) }
            }
            output.insert(result, at: output.pageCount)
        }
        return output.dataRepresentation()!
    }
}
