import Foundation
import Darwin

enum GaoActionTests {
    static func run(in root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fixtureRoot = root.appendingPathComponent("Fixtures")
        let fixtures = try GaoActionFixtures.generate(in:fixtureRoot)
        let exchange = root.appendingPathComponent("Exchange")
        var assertions = 0
        func check(_ valid: @autoclosure () throws -> Bool, _ message: String) throws {
            assertions += 1
            guard try valid() else { throw GaoActionContract.reject("testFailure","GaoAction: " + message) }
        }
        func rejects(_ code: String? = nil, _ block: () throws -> Void) throws {
            assertions += 1
            do { try block() } catch let error as GaoActionIssue {
                if let code, error.code != code { throw GaoActionContract.reject("testFailure","GaoAction unexpected rejection code: " + error.code) }; return
            } catch { return }
            throw GaoActionContract.reject("testFailure","GaoAction unsafe input was accepted")
        }
        func receive(_ url: URL) throws -> GaoValidatedPackage { try GaoActionTransport.receive(packageURL:url,exchangeRoot:exchange,now:GaoActionFixtures.clock) }
        let text = try receive(fixtures["v1-documents-newText"]!)
        try check(text.manifest.isLocalDocumentRequest,"newText dispatch")
        try check(try Data(contentsOf:text.stagedItems[0].url) == GaoActionFixtures.hello,"UTF-8 payload byte exact")
        let stageStat = try GaoPrivateIO.directory(text.stagingURL).statValue()
        let fileStat = try GaoPrivateIO.regularURL(text.stagedItems[0].url).statValue()
        try check(stageStat.st_mode & 0o777 == 0o700 && fileStat.st_mode & 0o777 == 0o600,"private staging modes")
        let directory = try receive(fixtures["v1-storage-directory"]!)
        try check(!directory.manifest.isLocalDocumentRequest && directory.manifest.action == "storage.inspect","valid foreign action is transport-valid and dispatch-unsupported")
        let ref = directory.manifest.references[0]
        try GaoActionTransport.verifyReference(ref,selectedURL:GaoActionContract.localFileURL(ref.fileURL))
        try check(true,"explicit reference verification")
        var changedRef = ref; changedRef.declaredIdentity.inode = (ref.declaredIdentity.inode ?? 0) + 1
        try rejects("referenceChanged") { try GaoActionTransport.verifyReference(changedRef,selectedURL:GaoActionContract.localFileURL(ref.fileURL)) }
        let partial = try receive(fixtures["v1-ocr-partial"]!)
        try check(partial.manifest.kind == "result" && partial.manifest.status == "partial" && partial.manifest.inReplyTo == GaoActionFixtures.requestID(3),"partial result association")
        let ledger = try GaoProcessedRequestStore(root:exchange)
        let duplicate = try receive(fixtures["v1-duplicate-request"]!)
        if case .new = try ledger.receive(duplicate,now:GaoActionFixtures.clock) { try check(true,"first receive") } else { try check(false,"first receive") }
        _ = try ledger.transition(requestID:duplicate.manifest.requestID,to:.approved,now:GaoActionFixtures.clock)
        _ = try ledger.transition(requestID:duplicate.manifest.requestID,to:.executing,now:GaoActionFixtures.clock)
        _ = try ledger.transition(requestID:duplicate.manifest.requestID,to:.completed,now:GaoActionFixtures.clock)
        let restarted = try GaoProcessedRequestStore(root:exchange)
        if case .duplicate(let record) = try restarted.receive(duplicate,now:GaoActionFixtures.clock) { try check(record.phase == .completed,"completed action not replayed after restart") } else { try check(false,"duplicate request") }
        try rejects("alreadyProcessed") { _ = try restarted.transition(requestID:duplicate.manifest.requestID,to:.executing) }
        var collision = duplicate; collision.manifestSHA256 = String(repeating:"a",count:64)
        try rejects("requestCollision") { _ = try restarted.receive(collision) }
        try rejects("expired") { _ = try receive(fixtures["v1-expired"]!) }
        try rejects("invalidPath") { _ = try receive(fixtures["v1-path-traversal"]!) }
        try rejects("unsupportedAction") { _ = try receive(fixtures["v1-unknown-action"]!) }
        try rejects("unsupportedSchema") { _ = try receive(fixtures["v2-unsupported"]!) }
        let base = text.manifest
        func package(_ manifest: GaoActionManifest, bytes: Data = GaoActionFixtures.hello) throws -> URL {
            let url = root.appendingPathComponent(UUID().uuidString+".gaoaction")
            try GaoActionFixtures.write(manifest:manifest,payload:["input.txt":bytes],to:url); return url
        }
        var m = base; m.targetBundleID = "com.gaoseries.Other"
        let wrongTarget = try package(m); try rejects("wrongTarget") { _ = try receive(wrongTarget) }
        m = base; m.parameters["shell"] = .string("arbitrary")
        let shell = try package(m); try rejects("unsupportedParameter") { _ = try receive(shell) }
        m = base; m.parameters["suggestedTitle"] = .string(String(repeating:"字",count:257))
        let title = try package(m); try rejects("invalidParameter") { _ = try receive(title) }
        m = base; m.items[0].relativePath = "/etc/passwd"
        let absolute = try package(m); try rejects("invalidPath") { _ = try receive(absolute) }
        m = base; m.items[0].relativePath = "payload//input.txt"
        let emptyPath = try package(m); try rejects("invalidPath") { _ = try receive(emptyPath) }
        m = base; m.items[0].sha256 = String(repeating:"0",count:64)
        let badDigest = try package(m); try rejects("digestMismatch") { _ = try receive(badDigest) }
        m = base; m.items[0].byteCount = 5
        let badSize = try package(m); try rejects("sizeMismatch") { _ = try receive(badSize) }
        m = base; m.items[0].byteCount = 2; m.items[0].sha256 = FileSafety.digest(Data([0xC0,0xAF]))
        let invalidUTF8 = try package(m,bytes:Data([0xC0,0xAF])); try rejects("invalidUTF8") { _ = try receive(invalidUTF8) }
        m = base; m.action = "documents.open"; m.parameters = [:]
        m.items = (0...256).map { GaoActionItem(id:String($0),relativePath:"payload/\($0).txt",uti:"text/plain",byteCount:0,sha256:FileSafety.digest(Data())) }
        let tooMany = try package(m); try rejects("itemLimit") { _ = try receive(tooMany) }
        m = base; m.action = "documents.open"; m.parameters = [:]; m.items[0].byteCount = GaoActionContract.maximumPayloadBytes + 1
        let tooLarge = try package(m); try rejects("invalidItem") { _ = try receive(tooLarge) }
        let bigManifest = try package(base)
        try Data(repeating:32,count:GaoActionContract.maximumManifestBytes+1).write(to:bigManifest.appendingPathComponent("manifest.json"))
        try rejects("sizeLimit") { _ = try receive(bigManifest) }
        let unknownField = try package(base)
        let manifestURL = unknownField.appendingPathComponent("manifest.json")
        var json = try JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as! [String:Any]
        json["callbackURL"] = "gao://execute"
        try JSONSerialization.data(withJSONObject:json).write(to:manifestURL)
        try rejects("invalidManifest") { _ = try receive(unknownField) }
        let external = root.appendingPathComponent("外部 中文.txt"); try GaoActionFixtures.hello.write(to:external)
        let symlinkPackage = try package(base); let symlinkFile = symlinkPackage.appendingPathComponent("payload/input.txt")
        try fm.removeItem(at:symlinkFile); try fm.createSymbolicLink(at:symlinkFile,withDestinationURL:external)
        try rejects { _ = try receive(symlinkPackage) }
        let hardlinkPackage = try package(base); let hardlinkFile = hardlinkPackage.appendingPathComponent("payload/input.txt")
        try fm.removeItem(at:hardlinkFile); try fm.linkItem(at:external,to:hardlinkFile)
        try rejects("unsafeFile") { _ = try receive(hardlinkPackage) }
        try fm.removeItem(at:hardlinkFile)
        let fifoPackage = try package(base); let fifoFile = fifoPackage.appendingPathComponent("payload/input.txt")
        try fm.removeItem(at:fifoFile); guard mkfifo(fifoFile.path,mode_t(0o600)) == 0 else { throw GaoActionContract.reject("testFailure","fifo creation") }
        try rejects("unsafeFile") { _ = try receive(fifoPackage) }
        let nestedPackage = try package(base); let payload = nestedPackage.appendingPathComponent("payload")
        try fm.removeItem(at:payload); try fm.createSymbolicLink(at:payload,withDestinationURL:external.deletingLastPathComponent())
        try rejects { _ = try receive(nestedPackage) }
        let manifestLink = try package(base); let linkManifest = manifestLink.appendingPathComponent("manifest.json")
        try fm.removeItem(at:linkManifest); try fm.createSymbolicLink(at:linkManifest,withDestinationURL:external)
        try rejects { _ = try receive(manifestLink) }
        let sourceData = Data(repeating:65,count:200_000)
        m = base; m.items[0].byteCount = Int64(sourceData.count); m.items[0].sha256 = FileSafety.digest(sourceData)
        let racing = try package(m,bytes:sourceData); var mutated = false
        try rejects("sourceChanged") {
            _ = try GaoActionTransport.receive(packageURL:racing,exchangeRoot:exchange,now:GaoActionFixtures.clock,chunkObserver:{
                if !mutated { mutated = true; let handle = try FileHandle(forWritingTo:racing.appendingPathComponent("payload/input.txt")); try handle.seek(toOffset:100_000); try handle.write(contentsOf:Data([66])); try handle.close() }
            })
        }
        let privateExchange = root.appendingPathComponent("WriterExchange")
        let produced = try GaoActionWriter.writeRequest(action:"documents.newText",items:[GaoOutgoingFile(url:external,uti:"text/plain")],parameters:["suggestedTitle":.string("中文 空格")],sourceBundleID:"com.gaoseries.FixtureSender",targetBundleID:GaoActionContract.bundleID,exchangeRoot:privateExchange,now:GaoActionFixtures.clock)
        let generated = try receive(produced)
        try check(Data(base64Encoded:generated.manifest.nonce) != Data(repeating:0,count:32),"production nonce uses real randomness")
        try check(try Data(contentsOf:external) == GaoActionFixtures.hello,"writer leaves original in place unchanged")
        let result = try GaoActionWriter.writeResult(inReplyTo:generated.manifest,status:"completed",provenance:["workflowState":.string("opened")],exchangeRoot:privateExchange,now:GaoActionFixtures.clock)
        let validatedResult = try GaoActionTransport.receive(packageURL:result,exchangeRoot:exchange,expectedTargetBundleID:"com.gaoseries.FixtureSender",now:GaoActionFixtures.clock)
        try check(validatedResult.manifest.inReplyTo == generated.manifest.requestID && validatedResult.manifest.items.isEmpty,"result association and no auto-save attachment")
        let resultManifestURL = result.appendingPathComponent("manifest.json")
        var resultJSON = try JSONSerialization.jsonObject(with:Data(contentsOf:resultManifestURL)) as! [String:Any]
        resultJSON["errorCode"] = NSNull()
        try JSONSerialization.data(withJSONObject:resultJSON).write(to:resultManifestURL)
        let nullError = try GaoActionTransport.receive(packageURL:result,exchangeRoot:exchange,expectedTargetBundleID:"com.gaoseries.FixtureSender",now:GaoActionFixtures.clock)
        try check(nullError.manifest.errorCode == nil,"successful results may explicitly have no error")
        let retainedStageBytes = try Data(contentsOf:text.stagedItems[0].url)
        try Data("changed after staging".utf8).write(to:fixtures["v1-documents-newText"]!.appendingPathComponent("payload/input.txt"))
        try check(try Data(contentsOf:text.stagedItems[0].url) == retainedStageBytes,"processing uses fixed private copy")
        // Corrupt/newer histories must be preserved, never treated as empty.
        let ledgerURL = exchange.appendingPathComponent("ProcessedRequests.json")
        let corrupt = Data("do-not-erase".utf8); try corrupt.write(to:ledgerURL)
        try rejects("recordCorrupt") { _ = try GaoProcessedRequestStore(root:exchange) }
        try check(try Data(contentsOf:ledgerURL) == corrupt,"corrupt processed state preserved")
        let newer = Data("{\"schemaVersion\":2,\"records\":[]}".utf8); try newer.write(to:ledgerURL)
        try rejects("recordUnsupported") { _ = try GaoProcessedRequestStore(root:exchange) }
        try check(try Data(contentsOf:ledgerURL) == newer,"newer processed state preserved")
        try capabilityTests(in:root,check:check,rejects:rejects)
        print("GaoAction: PASS (\(assertions) transport, fixture, idempotency, race, privacy and capability checks)")
    }

    private static func capabilityTests(in root: URL, check: (@autoclosure () throws -> Bool,String) throws -> Void, rejects: (String?,() throws -> Void) throws -> Void) throws {
        let app = root.appendingPathComponent("FixtureProvider.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let info: [String:Any] = ["CFBundleIdentifier":"com.gaoseries.FixtureProvider","CFBundleShortVersionString":"1.00","CFBundlePackageType":"APPL","CFBundleName":"FixtureProvider"]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:app.appendingPathComponent("Contents/Info.plist"))
        let file = resources.appendingPathComponent("GaoCapabilities.json")
        var caps: [String:Any] = ["schemaVersion":1,"bundleID":"com.gaoseries.FixtureProvider","appVersion":"1.00","actions":[["action":"ocr.files","parametersSchema":["type":"object","properties":["outputs":["type":"array"]],"additionalProperties":false]]]]
        try JSONSerialization.data(withJSONObject:caps).write(to:file)
        guard let found = try GaoCapabilityDiscovery.provider(applicationURL:app,bundleID:"com.gaoseries.FixtureProvider",action:"ocr.files") else { throw GaoActionContract.reject("testFailure","installed capability missing") }
        try check(found.capability.accepts(parameterKeys:["outputs"]) && !found.capability.accepts(parameterKeys:["languages"]),"capability does not ignore undeclared optional parameters")
        try check(try GaoCapabilityDiscovery.provider(applicationURL:app,bundleID:"com.gaoseries.FixtureProvider",action:"images.annotate") == nil,"unimplemented provider action absent")
        caps["appVersion"] = "9.00"; try JSONSerialization.data(withJSONObject:caps).write(to:file)
        try rejects("invalidCapabilities") { _ = try GaoCapabilityDiscovery.provider(applicationURL:app,bundleID:"com.gaoseries.FixtureProvider",action:"ocr.files") }
    }
}
