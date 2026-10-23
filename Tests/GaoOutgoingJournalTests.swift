import Foundation
import Darwin

/// Uses actual GaoActionWriter + fixed-FD transport, with no application, window or real user documents.
enum GaoOutgoingJournalTests {
    static func run(in root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let clock = GaoActionFixtures.clock
        let provider = "com.gaoseries.GaoJieTu"
        var assertions = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            assertions += 1; guard try condition() else { throw GaoActionContract.reject("testFailure","Outgoing journal: " + message) }
        }
        func rejects(_ code: String? = nil, _ body: () throws -> Void) throws {
            assertions += 1
            do { try body() }
            catch let e as GaoActionIssue { if let code, e.code != code { throw GaoActionContract.reject("testFailure","Outgoing journal expected " + code + " got " + e.code) }; return }
            catch { if code == nil { return }; throw error }
            throw GaoActionContract.reject("testFailure","Outgoing journal accepted unsafe state")
        }
        let exchange = root.appendingPathComponent("Exchange",isDirectory:true)
        let source = root.appendingPathComponent("中文 空格 扫描.png")
        let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO5YBdoAAAAASUVORK5CYII=")!
        try png.write(to:source); try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:source.path)
        let original = try Data(contentsOf:source)
        let outgoingFile = GaoOutgoingFile(url:source,uti:"public.png",id:"scan-1")
        let url = try GaoActionWriter.writeRequest(action:"ocr.files",items:[outgoingFile],parameters:["outputs":.array([.string("text"),.string("searchablePDF")])],targetBundleID:provider,exchangeRoot:exchange,now:clock)
        let journal = try GaoOutgoingJournal(exchangeRoot:exchange)
        let session = try journal.registerOutgoing(packageURL:url,expectedTargetBundleID:provider,bindings:[GaoOutgoingSourceBinding(itemID:"scan-1",versionKind:"original")],now:clock)
        try check(session.phase == .prepared && session.sources.count == 1 && session.sources[0].item.sha256 == FileSafety.digest(original),"written request and actual source version are journaled")
        try check(try Data(contentsOf:journal.sourceURL(requestID:session.requestID,itemID:"scan-1")) == original,"private source exact")
        let privateStat = try GaoPrivateIO.regularURL(journal.sourceURL(requestID:session.requestID,itemID:"scan-1")).statValue()
        try check(privateStat.st_mode & 0o777 == 0o600,"source version remains private")
        let same = try journal.registerOutgoing(packageURL:url,expectedTargetBundleID:provider,now:clock)
        try check(same.requestID == session.requestID && journal.allSessions().count == 1,"same outgoing request idempotent")
        _ = try journal.markDispatched(requestID:session.requestID,success:true,now:clock)
        try check(journal.lookup(session.requestID)?.phase == .dispatched,"dispatch is separate from provider completion")
        let requestBytes = try Data(contentsOf:url.appendingPathComponent("manifest.json"))
        let request = try JSONDecoder().decode(GaoActionManifest.self,from:requestBytes)
        func result(status: String, outputs: [(String,String,String,Data)] = [], mutate: ((inout GaoActionManifest) -> Void)? = nil) throws -> GaoValidatedPackage {
            var payload: [String:Data] = [:]
            var items: [GaoActionItem] = []
            var maps: [GaoJSONValue] = []
            for (id,name,uti,data) in outputs {
                payload[name] = data; items.append(GaoActionItem(id:id,relativePath:"payload/"+name,uti:uti,byteCount:Int64(data.count),sha256:FileSafety.digest(data)))
                maps.append(.object(["sourceID":.string("provider-page-group"),"sourceItemID":.string("scan-1"),"sourceSHA256":.string(session.sources[0].item.sha256),"resultItemID":.string(id),"format":.string(uti == "com.adobe.pdf" ? "searchablePDF" : "text")]))
            }
            var manifest = GaoActionManifest(kind:"result",requestID:UUID().uuidString,sourceBundleID:provider,targetBundleID:GaoActionContract.bundleID,action:"ocr.files",createdAt:GaoActionContract.timestamp(clock),expiresAt:GaoActionContract.timestamp(clock.addingTimeInterval(120)),nonce:Data(repeating:1,count:32).base64EncodedString(),items:items,references:[],parameters:request.parameters,inReplyTo:session.requestID,status:status,errorCode:"",provenance:["outputs":.array(maps),"sources":.array([.object(["sourceID":.string("provider-page-group"),"sourceItemID":.string("scan-1"),"sourceSHA256":.string(session.sources[0].item.sha256),"outputItemIDs":.array(items.map{.string($0.id)}),"pages":.array([.object(["pageNumber":.number(1),"status":.string(status == "partial" ? "failed" : "completed")])])])]),"engine":.string("Apple Vision"),"engineRevision":.number(3),"networkUsed":.bool(false)])
            mutate?(&manifest)
            let package = root.appendingPathComponent(UUID().uuidString+".gaoaction",isDirectory:true)
            try GaoActionFixtures.write(manifest:manifest,payload:payload,to:package)
            return try GaoActionTransport.receive(packageURL:package,exchangeRoot:exchange,now:clock)
        }
        let pending = try result(status:"pending")
        let pendingReceipt = try journal.receiveResult(pending,now:clock)
        try check(pendingReceipt.newOutputs.isEmpty && journal.lookup(session.requestID)?.phase == .pending,"pending does not create document output")
        _ = try journal.approveResult(requestID:pending.manifest.requestID,now:clock)
        _ = try journal.startResult(requestID:pending.manifest.requestID,now:clock)
        _ = try journal.finishResult(requestID:pending.manifest.requestID,now:clock)
        let text = Data("识别结果\n\u{000c}下一页\n".utf8)
        let partial = try result(status:"partial",outputs:[("text-1","result.txt","public.utf8-plain-text",text)])
        let received = try journal.receiveResult(partial,now:clock)
        try check(received.newOutputs.map(\.resultItemID) == ["text-1"] && received.record.status == "partial","real provider mapping accepted without forging action newText")
        _ = try journal.approveResult(requestID:received.record.requestID,now:clock)
        _ = try journal.startResult(requestID:received.record.requestID,now:clock)
        _ = try journal.finishResult(requestID:received.record.requestID,openedItemIDs:["text-1"],now:clock)
        try check(try journal.receiveResult(partial,now:clock).isDuplicate,"same result never reopens tabs")
        let restarted = try GaoOutgoingJournal(exchangeRoot:exchange)
        try check(try restarted.receiveResult(partial,now:clock).isDuplicate,"duplicate remains duplicate across restart")
        let pdf = Data("%PDF-1.7\nfixture-not-a-render-test\n".utf8)
        let completed = try result(status:"completed",outputs:[("text-2","result.txt","public.utf8-plain-text",text),("pdf-2","searchable.pdf","com.adobe.pdf",pdf)])
        let final = try journal.receiveResult(completed,now:clock)
        try check(final.newOutputs.map(\.resultItemID) == ["pdf-2"] && final.session.phase == .completed,"partial to completed imports only new content, not duplicate text")
        _ = try journal.approveResult(requestID:final.record.requestID,now:clock)
        _ = try journal.startResult(requestID:final.record.requestID,now:clock)
        _ = try journal.finishResult(requestID:final.record.requestID,openedItemIDs:["pdf-2"],now:clock)
        let lateCallback = try journal.markDispatched(requestID:session.requestID,success:false,now:clock)
        try check(lateCallback.phase == .completed,"late launch callback cannot regress result")
        let duplicateNewID = try result(status:"completed",outputs:[("text-3","result.txt","public.utf8-plain-text",text),("pdf-3","searchable.pdf","com.adobe.pdf",pdf)])
        try check(try journal.receiveResult(duplicateNewID,now:clock).newOutputs.isEmpty,"new result ID with same content has no repeat effects")
        var collided = completed; collided.manifestSHA256 = String(repeating:"a",count:64)
        try rejects("resultCollision") { _ = try journal.receiveResult(collided,now:clock) }
        try rejects("resultAfterTerminal") { _ = try journal.receiveResult(result(status:"completed",outputs:[("later","later.txt","public.utf8-plain-text",Data("different".utf8))]),now:clock) }
        try rejects("unmatchedResult") { _ = try journal.receiveResult(result(status:"completed",mutate:{$0.inReplyTo = UUID().uuidString}),now:clock) }
        try rejects("unmatchedResult") { _ = try journal.receiveResult(result(status:"completed",mutate:{$0.sourceBundleID = "com.gaoseries.Unrelated"}),now:clock) }
        try rejects("unmatchedResult") { _ = try journal.receiveResult(result(status:"completed",mutate:{$0.action = "documents.open"; $0.parameters = [:]}),now:clock) }
        try rejects("resultProvenance") { _ = try journal.receiveResult(result(status:"completed",outputs:[("bad-map","out.txt","public.utf8-plain-text",text)],mutate:{$0.provenance?["outputs"] = .array([.object(["sourceItemID":.string("scan-1"),"sourceSHA256":.string(String(repeating:"0",count:64)),"resultItemID":.string("bad-map")])])}),now:clock) }
        try rejects("resultProvenance") { _ = try journal.receiveResult(result(status:"partial",outputs:[("unmapped","out.txt","public.utf8-plain-text",text)],mutate:{$0.provenance?["outputs"] = .array([])}),now:clock) }
        try rejects("resultStatus") { _ = try journal.receiveResult(result(status:"pending",outputs:[("pending-file","out.txt","public.utf8-plain-text",text)]),now:clock) }
        // Separate sessions exercise non-success status and crash recovery without relying on a running App.
        func another(_ action: String = "ocr.files") throws -> GaoOutgoingSession {
            let package = try GaoActionWriter.writeRequest(action:action,items:action == "ocr.files" ? [outgoingFile] : [],parameters:[:],targetBundleID:provider,exchangeRoot:exchange,now:clock)
            return try journal.registerOutgoing(packageURL:package,expectedTargetBundleID:provider,now:clock)
        }
        for status in ["failed","cancelled","unsupported"] {
            let other = try another()
            let p = try result(status:status,mutate:{$0.inReplyTo = other.requestID; $0.provenance = [:]})
            let receipt = try journal.receiveResult(p,now:clock)
            try check(receipt.newOutputs.isEmpty && receipt.record.status == status,"unsuccessful provider status does not fabricate successful output")
        }
        let localCancelSession = try another()
        let localCancelResult = try result(status:"partial",outputs:[("local-cancel","out.txt","public.utf8-plain-text",text)],mutate:{$0.inReplyTo = localCancelSession.requestID})
        _ = try journal.receiveResult(localCancelResult,now:clock)
        _ = try journal.approveResult(requestID:localCancelResult.manifest.requestID,now:clock)
        _ = try journal.startResult(requestID:localCancelResult.manifest.requestID,now:clock)
        let localCancelRecord = try journal.cancelResult(requestID:localCancelResult.manifest.requestID,now:clock)
        try check(localCancelRecord.phase == .cancelled && localCancelRecord.executionStarted && localCancelRecord.openedItemIDs.isEmpty,"local cancellation while executing is accurate and preserves uncertainty marker")
        try check(try journal.receiveResult(localCancelResult,now:clock).isDuplicate,"cancelled execution cannot replay the same result")
        let afterCancel = try result(status:"completed",outputs:[("cancel-followup","out.txt","public.utf8-plain-text",text)],mutate:{$0.inReplyTo = localCancelSession.requestID})
        try check(try journal.receiveResult(afterCancel,now:clock).newOutputs.isEmpty,"follow-up provider result does not replay an uncertain cancelled execution")
        let uncertain = try another()
        let uncertainResult = try result(status:"partial",outputs:[("uncertain","out.txt","public.utf8-plain-text",text)],mutate:{$0.inReplyTo = uncertain.requestID})
        _ = try journal.receiveResult(uncertainResult,now:clock)
        _ = try journal.approveResult(requestID:uncertainResult.manifest.requestID,now:clock)
        _ = try journal.startResult(requestID:uncertainResult.manifest.requestID,now:clock)
        let recovered = try GaoOutgoingJournal(exchangeRoot:exchange)
        try check(recovered.lookupResult(uncertainResult.manifest.requestID)?.phase == .interrupted,"crash in executing becomes explicit interrupted record")
        try check(try recovered.receiveResult(uncertainResult,now:clock).isDuplicate,"uncertain executing result never replays after restart")
        try rejects("resultAlreadyProcessed") { _ = try recovered.startResult(requestID:uncertainResult.manifest.requestID,now:clock) }
        let chooseExchange = root.appendingPathComponent("ChooseExchange",isDirectory:true)
        let chooser = try GaoOutgoingJournal(exchangeRoot:chooseExchange)
        let chooseURL = try GaoActionWriter.writeRequest(action:"files.choose",parameters:["multiple":.bool(true)],targetBundleID:"com.gaoseries.GaoZhengLi",exchangeRoot:chooseExchange,now:clock)
        let choice = try chooser.registerOutgoing(packageURL:chooseURL,expectedTargetBundleID:"com.gaoseries.GaoZhengLi",now:clock)
        let reference = GaoActionReference(id:"chosen-1",kind:"file",fileURL:source.absoluteString,displayName:"用户选中的文档",declaredIdentity:GaoDeclaredIdentity(),sha256:FileSafety.digest(original))
        var chooseManifest = request; chooseManifest.kind = "result"; chooseManifest.requestID = UUID().uuidString; chooseManifest.sourceBundleID = "com.gaoseries.GaoZhengLi"; chooseManifest.targetBundleID = GaoActionContract.bundleID; chooseManifest.action = "files.choose"; chooseManifest.parameters = [:]; chooseManifest.items = []; chooseManifest.references = [reference]; chooseManifest.inReplyTo = choice.requestID; chooseManifest.status = "completed"; chooseManifest.errorCode = ""; chooseManifest.provenance = [:]
        let chooseResult = root.appendingPathComponent("choice.gaoaction",isDirectory:true)
        try GaoActionFixtures.write(manifest:chooseManifest,payload:[:],to:chooseResult)
        let choiceValidated = try GaoActionTransport.receive(packageURL:chooseResult,exchangeRoot:chooseExchange,now:clock)
        let choiceReceipt = try chooser.receiveResult(choiceValidated,now:clock)
        try check(choiceReceipt.newReferenceIDs == ["chosen-1"] && choiceReceipt.newOutputs.isEmpty,"files.choose matches original session and preserves explicit reference IDs without treating metadata as authorization")
        _ = try chooser.approveResult(requestID:chooseManifest.requestID,now:clock); _ = try chooser.startResult(requestID:chooseManifest.requestID,now:clock)
        _ = try chooser.finishResult(requestID:chooseManifest.requestID,openedReferenceIDs:["chosen-1"],now:clock)
        try check(try chooser.receiveResult(choiceValidated,now:clock).isDuplicate,"files.choose duplicate never reopens")
        var repeatedChoice = chooseManifest; repeatedChoice.requestID = UUID().uuidString; repeatedChoice.references[0].id = "chosen-new-id"
        let repeatedChoiceURL = root.appendingPathComponent("choice-new-result.gaoaction",isDirectory:true)
        try GaoActionFixtures.write(manifest:repeatedChoice,payload:[:],to:repeatedChoiceURL)
        let repeatedChoiceValidated = try GaoActionTransport.receive(packageURL:repeatedChoiceURL,exchangeRoot:chooseExchange,now:clock)
        try check(try chooser.receiveResult(repeatedChoiceValidated,now:clock).newReferenceIDs.isEmpty,"same selection with different result/reference IDs is not reopened")
        // The document-to-research action uses the same fixed V1 action and reply association.
        let researchExchange = root.appendingPathComponent("ResearchExchange",isDirectory:true)
        let researchJournal = try GaoOutgoingJournal(exchangeRoot:researchExchange)
        let researchTarget = "com.academic-achievement.manager"
        let researchDocument = root.appendingPathComponent("研究交接 副本.md")
        let researchText = Data("# 文档副本\n原件和当前编辑器独立保留。\n".utf8)
        try researchText.write(to:researchDocument); try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:researchDocument.path)
        let researchRequestURL = try GaoActionWriter.writeRequest(action:"research.importDocuments",items:[GaoOutgoingFile(url:researchDocument,uti:"net.daringfireball.markdown")],parameters:[:],targetBundleID:researchTarget,exchangeRoot:researchExchange,now:clock)
        let researchSession = try researchJournal.registerOutgoing(packageURL:researchRequestURL,expectedTargetBundleID:researchTarget,now:clock)
        try check(researchSession.action == "research.importDocuments" && researchSession.targetBundleID == researchTarget && researchSession.sources[0].item.sha256 == FileSafety.digest(researchText),"research import registers its real private source version and fixed target")
        let researchRequest = try JSONDecoder().decode(GaoActionManifest.self,from:Data(contentsOf:researchRequestURL.appendingPathComponent("manifest.json")))
        func researchResult(status: String, mutate: ((inout GaoActionManifest) -> Void)? = nil) throws -> GaoValidatedPackage {
            var reply = researchRequest; reply.kind = "result"; reply.requestID = UUID().uuidString
            reply.sourceBundleID = researchTarget; reply.targetBundleID = GaoActionContract.bundleID
            reply.items = []; reply.references = []; reply.inReplyTo = researchSession.requestID
            reply.status = status; reply.errorCode = nil
            reply.provenance = [
                "requestManifestSHA256":.string(researchSession.manifestSHA256),
                "workflowState":.string(status == "completed" ? "imported":status),
                "sources":.array(researchSession.sources.map { source in
                    .object(["sourceItemID":.string(source.item.id),"sourceSHA256":.string(source.item.sha256),
                             "status":.string(status == "completed" ? "imported":status)])
                })
            ]
            mutate?(&reply)
            let package = root.appendingPathComponent(UUID().uuidString+".gaoaction",isDirectory:true)
            try GaoActionFixtures.write(manifest:reply,payload:[:],to:package)
            return try GaoActionTransport.receive(packageURL:package,exchangeRoot:researchExchange,now:clock)
        }
        let researchPending = try researchResult(status:"pending")
        let researchPendingReceipt = try researchJournal.receiveResult(researchPending,now:clock)
        try check(researchPendingReceipt.newOutputs.isEmpty && researchPendingReceipt.session.phase == .pending,"research pending is status only")
        _ = try researchJournal.approveResult(requestID:researchPending.manifest.requestID,now:clock)
        _ = try researchJournal.startResult(requestID:researchPending.manifest.requestID,now:clock)
        _ = try researchJournal.finishResult(requestID:researchPending.manifest.requestID,now:clock)
        let researchCompleted = try researchResult(status:"completed")
        let researchCompletedReceipt = try researchJournal.receiveResult(researchCompleted,now:clock)
        try check(researchCompletedReceipt.session.action == "research.importDocuments" && researchCompletedReceipt.session.phase == .completed && researchCompletedReceipt.newOutputs.isEmpty,"research completion retains original action without creating or saving editor content")
        _ = try researchJournal.approveResult(requestID:researchCompleted.manifest.requestID,now:clock)
        _ = try researchJournal.startResult(requestID:researchCompleted.manifest.requestID,now:clock)
        _ = try researchJournal.finishResult(requestID:researchCompleted.manifest.requestID,now:clock)
        try check(try GaoOutgoingJournal(exchangeRoot:researchExchange).receiveResult(researchCompleted,now:clock).isDuplicate,"research reply remains idempotent after restart")
        try rejects("unmatchedResult") { _ = try researchJournal.receiveResult(researchResult(status:"completed",mutate:{$0.action = "documents.open"}),now:clock) }
        try rejects("unmatchedResult") { _ = try researchJournal.receiveResult(researchResult(status:"completed",mutate:{$0.sourceBundleID = "com.gaoseries.Unrelated"}),now:clock) }
        try rejects("unmatchedResult") { _ = try researchJournal.receiveResult(researchResult(status:"completed",mutate:{$0.inReplyTo = UUID().uuidString}),now:clock) }
        let wrongResearchURL = try GaoActionWriter.writeRequest(action:"research.importDocuments",items:[GaoOutgoingFile(url:researchDocument,uti:"net.daringfireball.markdown")],targetBundleID:"com.gaoseries.OtherResearch",exchangeRoot:researchExchange,now:clock)
        try rejects("outgoingMismatch") { _ = try researchJournal.registerOutgoing(packageURL:wrongResearchURL,expectedTargetBundleID:"com.gaoseries.OtherResearch",now:clock) }
        let unsupportedOutgoingURL = try GaoActionWriter.writeRequest(action:"files.search",parameters:["query":.string("fixture")],targetBundleID:"com.gaoseries.GaoZhengLi",exchangeRoot:researchExchange,now:clock)
        try rejects("outgoingMismatch") { _ = try researchJournal.registerOutgoing(packageURL:unsupportedOutgoingURL,expectedTargetBundleID:"com.gaoseries.GaoZhengLi",now:clock) }
        try check(try Data(contentsOf:researchDocument) == researchText,"research request/result journal never changes original text")
        // Completion must account for every requested input and requested output
        // format, not merely validate whichever subset the provider returned.
        let coverageExchange = root.appendingPathComponent("CoverageExchange",isDirectory:true)
        let coverageJournal = try GaoOutgoingJournal(exchangeRoot:coverageExchange)
        func coverageRequest(ids: [String], formats: [String]) throws -> GaoOutgoingSession {
            let files = ids.map { GaoOutgoingFile(url:source,uti:"public.png",id:$0) }
            let request = try GaoActionWriter.writeRequest(action:"ocr.files",items:files,parameters:["outputs":.array(formats.map(GaoJSONValue.string))],targetBundleID:provider,exchangeRoot:coverageExchange,now:clock)
            return try coverageJournal.registerOutgoing(packageURL:request,expectedTargetBundleID:provider,now:clock)
        }
        func coverageResult(_ session: GaoOutgoingSession, status: String, outputs: [(sourceID:String,id:String,uti:String,body:Data,format:String?)]) throws -> GaoValidatedPackage {
            var payload: [String:Data] = [:], items: [GaoActionItem] = [], mappings: [GaoJSONValue] = []
            for (index,output) in outputs.enumerated() {
                let filename = String(index)+(output.uti == "com.adobe.pdf" ? ".pdf":".txt")
                payload[filename] = output.body
                items.append(.init(id:output.id,relativePath:"payload/"+filename,uti:output.uti,byteCount:Int64(output.body.count),sha256:FileSafety.digest(output.body)))
                let source = session.sources.first(where:{$0.item.id == output.sourceID})!
                var mapping: [String:GaoJSONValue] = ["sourceID":.string("provider-"+source.item.id),"sourceItemID":.string(source.item.id),"sourceSHA256":.string(source.item.sha256),"resultItemID":.string(output.id)]
                if let format=output.format { mapping["format"] = .string(format) }
                mappings.append(.object(mapping))
            }
            let records = session.sources.filter { source in outputs.contains(where:{$0.sourceID == source.item.id}) }.map { source in GaoJSONValue.object(["sourceID":.string("provider-"+source.item.id),"sourceItemID":.string(source.item.id),"sourceSHA256":.string(source.item.sha256),"outputItemIDs":.array(outputs.filter({$0.sourceID == source.item.id}).map{.string($0.id)}),"pages":.array([.object(["pageNumber":.number(1),"status":.string("completed")])])]) }
            let manifest = GaoActionManifest(kind:"result",requestID:UUID().uuidString,sourceBundleID:provider,targetBundleID:GaoActionContract.bundleID,action:"ocr.files",createdAt:GaoActionContract.timestamp(clock),expiresAt:GaoActionContract.timestamp(clock.addingTimeInterval(120)),nonce:Data(repeating:3,count:32).base64EncodedString(),items:items,references:[],parameters:[:],inReplyTo:session.requestID,status:status,errorCode:"",provenance:["sources":.array(records),"outputs":.array(mappings),"engine":.string("Apple Vision"),"engineRevision":.number(3)])
            let package = root.appendingPathComponent(UUID().uuidString+".gaoaction",isDirectory:true)
            try GaoActionFixtures.write(manifest:manifest,payload:payload,to:package)
            return try GaoActionTransport.receive(packageURL:package,exchangeRoot:coverageExchange,now:clock)
        }
        let multipleSources = try coverageRequest(ids:["coverage-a","coverage-b"],formats:["text"])
        let missingSource = try coverageResult(multipleSources,status:"completed",outputs:[("coverage-a","coverage-a-only","public.utf8-plain-text",text,nil)])
        try rejects("resultIncomplete") { _ = try coverageJournal.receiveResult(missingSource,now:clock) }
        try check(coverageJournal.lookup(multipleSources.requestID)?.phase == .prepared && coverageJournal.lookupResult(missingSource.manifest.requestID) == nil,"incomplete completed result cannot persist terminal or result record")
        let partialA = try coverageResult(multipleSources,status:"partial",outputs:[("coverage-a","partial-a","public.utf8-plain-text",text,nil)])
        let receiptA = try coverageJournal.receiveResult(partialA,now:clock)
        try check(receiptA.newOutputs.first?.format == "text","missing optional OCR format is inferred from supported UTI")
        _ = try coverageJournal.approveResult(requestID:partialA.manifest.requestID,now:clock)
        _ = try coverageJournal.startResult(requestID:partialA.manifest.requestID,now:clock)
        _ = try coverageJournal.finishResult(requestID:partialA.manifest.requestID,openedItemIDs:["partial-a"],now:clock)
        let completeB = try coverageResult(multipleSources,status:"completed",outputs:[("coverage-b","completed-b","public.utf8-plain-text",text,nil)])
        let receiptB = try coverageJournal.receiveResult(completeB,now:clock)
        try check(receiptB.session.phase == .completed && receiptB.newOutputs.map(\.resultItemID) == ["completed-b"],"completed can cumulatively cover inputs from an earlier partial result")
        let requestedFormats = try coverageRequest(ids:["format-source"],formats:["text","searchablePDF"])
        let missingFormat = try coverageResult(requestedFormats,status:"completed",outputs:[("format-source","format-text-only","public.utf8-plain-text",text,nil)])
        try rejects("resultIncomplete") { _ = try coverageJournal.receiveResult(missingFormat,now:clock) }
        try check(coverageJournal.lookup(requestedFormats.requestID)?.phase == .prepared,"missing requested PDF does not mark source session completed")
        let partialText = try coverageResult(requestedFormats,status:"partial",outputs:[("format-source","format-partial-text","public.utf8-plain-text",text,nil)])
        _ = try coverageJournal.receiveResult(partialText,now:clock)
        _ = try coverageJournal.approveResult(requestID:partialText.manifest.requestID,now:clock)
        _ = try coverageJournal.startResult(requestID:partialText.manifest.requestID,now:clock)
        _ = try coverageJournal.finishResult(requestID:partialText.manifest.requestID,openedItemIDs:["format-partial-text"],now:clock)
        let completePDF = try coverageResult(requestedFormats,status:"completed",outputs:[("format-source","format-pdf","com.adobe.pdf",pdf,nil)])
        let completePDFReceipt = try coverageJournal.receiveResult(completePDF,now:clock)
        try check(completePDFReceipt.session.phase == .completed && completePDFReceipt.newOutputs.first?.format == "searchablePDF","requested formats cumulatively covered using inferred format")
        let invalidOutput = try coverageResult(requestedFormats,status:"partial",outputs:[("format-source","unsupported-format","public.rtf",text,nil)])
        try rejects("resultProvenance") { _ = try coverageJournal.receiveResult(invalidOutput,now:clock) }
        let requestCopy = coverageExchange.appendingPathComponent(requestedFormats.sources[0].privateRelativePath).deletingLastPathComponent().appendingPathComponent("manifest.json")
        let requestCopyBytes = try Data(contentsOf:requestCopy)
        try Data("changed private request".utf8).write(to:requestCopy)
        let freshCompleted = try coverageResult(requestedFormats,status:"completed",outputs:[("format-source","same-pdf-new-result","com.adobe.pdf",pdf,nil)])
        try rejects("privateRequestChanged") { _ = try coverageJournal.receiveResult(freshCompleted,now:clock) }
        try requestCopyBytes.write(to:requestCopy)
        // Corrupt, missing, newer, concurrently replaced journal and changed private copies all fail closed.
        let persisted = exchange.appendingPathComponent("OutgoingSessions.json")
        let goodJournal = try Data(contentsOf:persisted)
        var json = try JSONSerialization.jsonObject(with:goodJournal) as! [String:Any]; json["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject:json).write(to:persisted)
        try rejects("journalUnsupported") { _ = try GaoOutgoingJournal(exchangeRoot:exchange) }
        try check(try Data(contentsOf:persisted) != goodJournal,"newer journal is not overwritten")
        try Data("broken".utf8).write(to:persisted)
        try rejects("journalCorrupt") { _ = try GaoOutgoingJournal(exchangeRoot:exchange) }
        try check(try Data(contentsOf:persisted) == Data("broken".utf8),"corrupt journal preserved")
        try fm.removeItem(at:persisted)
        try rejects("journalMissing") { _ = try GaoOutgoingJournal(exchangeRoot:exchange) }
        try goodJournal.write(to:persisted)
        let conflictPendingURL = try GaoActionWriter.writeRequest(action:"ocr.files",items:[outgoingFile],targetBundleID:provider,exchangeRoot:exchange,now:clock)
        let conflictPending = try recovered.registerOutgoing(packageURL:conflictPendingURL,expectedTargetBundleID:provider,now:clock)
        let conflicting = try GaoOutgoingJournal(exchangeRoot:exchange)
        try Data("external replacement".utf8).write(to:persisted)
        try rejects("journalConflict") { _ = try conflicting.markDispatched(requestID:conflictPending.requestID,success:true,now:clock) }
        try goodJournal.write(to:persisted)
        let copy = try journal.sourceURL(requestID:session.requestID,itemID:"scan-1")
        try Data(repeating:0,count:original.count).write(to:copy)
        try rejects("privateSourceChanged") { _ = try GaoOutgoingJournal(exchangeRoot:exchange) }
        try rejects("privateSourceChanged") { _ = try journal.receiveResult(partial,now:clock) }
        try check(try Data(contentsOf:source) == original,"original source retained byte exact through all status/failure tests")
        print("PASS: outgoing request journal and actual package result matching (\(assertions) assertions)")
    }
}
