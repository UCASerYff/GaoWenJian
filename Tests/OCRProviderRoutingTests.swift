import AppKit
import Foundation
import ImageIO

/// Focused expanded-scope checks. Compile/run only in the coordinator's later
/// client validation slot; neither provider nor NSApplication is launched.
@MainActor enum OCRProviderRoutingTests {
    static func run(in directory: URL) throws -> Int {
        guard NSApp == nil, FileSafety.root.path.hasPrefix("/private/tmp/gaowenjian-") else {
            throw FileIssue.message("OCR routing tests require an isolated root and NSApp=nil")
        }
        let fm=FileManager.default
        try fm.createDirectory(at:directory,withIntermediateDirectories:true)
        var checks=0
        func check(_ condition:@autoclosure() throws->Bool,_ message:String)throws {
            guard try condition() else{throw FileIssue.message("OCR routing: "+message)};checks += 1
        }
        let input=directory.appendingPathComponent("公开扫描.png")
        guard let context=CGContext(data:nil,width:4,height:4,bitsPerComponent:8,bytesPerRow:16,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let image=context.makeImage() else{throw FileIssue.message("Synthetic image allocation failed")}
        let bytes=NSMutableData()
        guard let writer=CGImageDestinationCreateWithData(bytes,"public.png" as CFString,1,nil) else{throw FileIssue.message("Synthetic image writer failed")}
        CGImageDestinationAddImage(writer,image,nil)
        guard CGImageDestinationFinalize(writer) else{throw FileIssue.message("Synthetic image encode failed")}
        try (bytes as Data).write(to:input)
        let original=try Data(contentsOf:input),clock=Date()
        let store=WorkspaceStore(),registry=CurrentDocumentHandoffRegistry()
        let fresh=try OCRHandoffDispatcher.prepare(files:[input],store:store,registry:registry,outputs:["text"],chooseVersion:{_ in .diskOriginal},now:clock)
        func manifest(_ url:URL)throws->GaoActionManifest {try JSONDecoder().decode(GaoActionManifest.self,from:Data(contentsOf:url.appendingPathComponent("manifest.json")))}
        let freshRequest=try manifest(fresh.packageURL)
        try check(OCRHandoffDispatcher.providerBundleID=="com.gaoseries.GaoCaoZuo" && freshRequest.targetBundleID==OCRHandoffDispatcher.providerBundleID && fresh.session.targetBundleID==freshRequest.targetBundleID,"new request and durable expected target use the operation host")
        let oldOwner="com.gaoseries.GaoJieTu"
        let legacyURL=try GaoActionWriter.writeRequest(action:"ocr.files",items:[.init(url:input,uti:"public.png")],parameters:["outputs":.array([.string("text")])],targetBundleID:oldOwner,exchangeRoot:GaoHandoffService.exchangeRoot,now:clock)
        let journal=try GaoOutgoingJournal(exchangeRoot:GaoHandoffService.exchangeRoot)
        let legacy=try journal.registerOutgoing(packageURL:legacyURL,expectedTargetBundleID:oldOwner,now:clock)
        let legacyBytes=try Data(contentsOf:legacyURL.appendingPathComponent("manifest.json")),legacyRequest=try manifest(legacyURL)
        guard let legacySource=legacy.sources.first else{throw FileIssue.message("Legacy source fixture missing")}
        let privateLegacyManifest=GaoHandoffService.exchangeRoot.appendingPathComponent(legacySource.privateRelativePath).deletingLastPathComponent().appendingPathComponent("manifest.json")
        let privateLegacyBytes=try Data(contentsOf:privateLegacyManifest)
        func result(_ request:GaoActionManifest,owner:String)throws->GaoValidatedPackage {
            let foreign=directory.appendingPathComponent("Foreign-"+UUID().uuidString)
            let url=try GaoActionWriter.writeResult(inReplyTo:request,status:"pending",exchangeRoot:foreign,now:clock)
            var wire=try manifest(url);wire.sourceBundleID=owner
            try JSONEncoder().encode(wire).write(to:url.appendingPathComponent("manifest.json"))
            // Production journals accept only their own verified private staging.
            // This exchange root belongs to the isolated headless data directory.
            return try GaoActionTransport.receive(packageURL:url,exchangeRoot:GaoHandoffService.exchangeRoot,expectedTargetBundleID:GaoActionContract.bundleID,now:clock)
        }
        for (request,wrongOwner) in [(freshRequest,oldOwner),(legacyRequest,OCRHandoffDispatcher.providerBundleID)] {
            let invalid=try result(request,owner:wrongOwner)
            do {_=try journal.receiveResult(invalid,now:clock);throw FileIssue.message("cross-owner result accepted")}
            catch let issue as GaoActionIssue {try check(issue.code=="unmatchedResult","results must match their original persisted owner in both directions")}
        }
        let reloaded=try GaoOutgoingJournal(exchangeRoot:GaoHandoffService.exchangeRoot)
        guard let old=try reloaded.lookup(legacy.requestID),let new=try reloaded.lookup(fresh.session.requestID) else{throw FileIssue.message("Session reload lost history")}
        try check(old.targetBundleID==oldOwner && old.manifestSHA256==legacy.manifestSHA256 && old.phase == .prepared,"old session identity and phase are not redirected, replayed or dispatched")
        try check(new.targetBundleID==OCRHandoffDispatcher.providerBundleID && new.phase == .prepared,"new request remains prepared until actual explicit dispatch")
        try check(try Data(contentsOf:legacyURL.appendingPathComponent("manifest.json"))==legacyBytes && Data(contentsOf:privateLegacyManifest)==privateLegacyBytes && Data(contentsOf:input)==original,"outgoing and private legacy requests and original source bytes remain unchanged")
        let pending=try reloaded.receiveResult(result(freshRequest,owner:OCRHandoffDispatcher.providerBundleID),now:clock)
        try check(pending.record.status=="pending" && pending.newOutputs.isEmpty,"new provider pending is not fabricated completion")
        let legacyPending=try reloaded.receiveResult(result(legacyRequest,owner:oldOwner),now:clock)
        try check(legacyPending.record.status=="pending" && legacyPending.newOutputs.isEmpty,"legacy provider can still reply to its own original session without fabricated completion")
        let finalJournal=try GaoOutgoingJournal(exchangeRoot:GaoHandoffService.exchangeRoot)
        guard let finalOld=finalJournal.lookup(legacy.requestID),let finalNew=finalJournal.lookup(fresh.session.requestID) else{throw FileIssue.message("Pending receipt reload lost history")}
        try check(finalOld.targetBundleID==oldOwner && finalOld.manifestSHA256==legacy.manifestSHA256 && finalOld.phase == .pending && finalNew.targetBundleID==OCRHandoffDispatcher.providerBundleID && finalNew.phase == .pending,"both correct-owner pending receipts persist under their original owners")
        try check(try Data(contentsOf:privateLegacyManifest)==privateLegacyBytes,"accepting correct-owner receipts never redirects the private legacy request")
        try check(NSApp == nil,"no App/provider launched")
        print("PASS OCR provider routing: \(checks) assertions; synthetic only, original-owner fences and no fake completion")
        return checks
    }
}
