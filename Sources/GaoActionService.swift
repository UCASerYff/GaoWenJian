import AppKit
import Foundation
import UniformTypeIdentifiers

struct GaoHandoffReview {
    let title: String
    let message: String
}
@MainActor struct GaoHandoffInteraction {
    var confirm: (GaoHandoffReview) -> Bool
    var selectReference: (GaoActionReference) -> URL?
    var offerResult: (GaoActionManifest, URL) -> Void
    static let application = GaoHandoffInteraction(confirm: { review in
        let alert=NSAlert();alert.messageText=review.title;alert.informativeText=review.message
        alert.addButton(withTitle:"确认接收");alert.addButton(withTitle:"取消")
        return alert.runModal() == .alertFirstButtonReturn
    },selectReference: { ref in
        let panel=NSOpenPanel();panel.title="核对并授权所选原件";panel.message="请选择“\(HandoffNames.display(ref.displayName))”。引用声明不会传递读取权限；打开的是经校验的副本。"
        panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        panel.directoryURL=(try? GaoActionContract.localFileURL(ref.fileURL))?.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url:nil
    },offerResult: { request,url in
        let alert=NSAlert();alert.messageText="文档交接处理完毕";alert.informativeText="可以把处理状态发送给来源声明为“\(HandoffNames.display(request.sourceBundleID))”的应用。打开文档不表示已经保存修改。"
        alert.addButton(withTitle:"发送处理状态");alert.addButton(withTitle:"仅保留本机")
        guard alert.runModal() == .alertFirstButtonReturn,
              let app=NSWorkspace.shared.urlForApplication(withBundleIdentifier:request.sourceBundleID),
              Bundle(url:app)?.bundleIdentifier == request.sourceBundleID else { return }
        let configuration=NSWorkspace.OpenConfiguration();configuration.activates=true
        NSWorkspace.shared.open([url],withApplicationAt:app,configuration:configuration) { _,_ in }
    })
}
struct GaoHandoffOutcome {
    let requestID: String
    let status: String
    var openedTabIDs: [UUID] = []
    var resultPackageURL: URL?
    var messages: [String] = []
    var duplicate = false
}
final class GaoHandoffCancellation: @unchecked Sendable {
    private let lock=NSLock();private var cancelled=false
    func cancel(){lock.lock();cancelled=true;lock.unlock()}
    var isCancelled:Bool {lock.lock();defer{lock.unlock()};return cancelled}
    func check() throws {lock.lock();let value=cancelled;lock.unlock();if value {throw GaoActionContract.reject("cancelled","已取消交接，原件与现有文档保留。")}}
}

/// All Finder/AppDelegate imports and non-GUI integration tests use this dispatcher.
/// Presentation is injectable; validation, journals and editor adapters are always real.
@MainActor enum GaoHandoffService {
    static var exchangeRoot:URL {FileSafety.root.appendingPathComponent("Exchange")}
    private static var queue:[(URL,WorkspaceStore)]=[]
    private static var receiving=false
    private static var cancellation:GaoHandoffCancellation?

    @discardableResult static func handleIncoming(url:URL,store:WorkspaceStore)->Bool {
        guard url.pathExtension.lowercased()=="gaoaction" else{return false}
        guard queue.count<16 else {store.error="待处理交接过多，请完成当前批次后重试。";return true}
        queue.append((url,store));runNext();return true
    }
    static func cancelCurrent(){cancellation?.cancel()}
    private static func runNext(){
        guard !receiving,!queue.isEmpty else{return}
        receiving=true;let (url,store)=queue.removeFirst(), token=GaoHandoffCancellation()
        cancellation=token;store.handoffBusy=true;store.status="正在复制并核验交接文件，可取消…"
        Task {
            defer {store.handoffBusy=false;cancellation=nil;receiving=false;runNext()}
            do {
                let root=exchangeRoot
                let validated=try await Task.detached(priority:.userInitiated){
                    try GaoActionTransport.receive(packageURL:url,exchangeRoot:root,chunkObserver:{try token.check()})
                }.value
                _ = try process(validated,store:store,interaction:.application,cancellation:token)
            } catch {store.error=error.localizedDescription;store.status="交接未执行 · 原文档保留"}
        }
    }
    @discardableResult static func receive(url:URL,store:WorkspaceStore,interaction:GaoHandoffInteraction,now:Date=Date(),cancellation:GaoHandoffCancellation=GaoHandoffCancellation()) throws -> GaoHandoffOutcome {
        let package=try GaoActionTransport.receive(packageURL:url,exchangeRoot:exchangeRoot,now:now,chunkObserver:{try cancellation.check()})
        return try process(package,store:store,interaction:interaction,now:now,cancellation:cancellation)
    }
    private static func process(_ package:GaoValidatedPackage,store:WorkspaceStore,interaction:GaoHandoffInteraction,now:Date=Date(),cancellation:GaoHandoffCancellation) throws -> GaoHandoffOutcome {
        try cancellation.check()
        if package.manifest.kind=="result" {return try processResult(package,store:store,interaction:interaction,now:now,cancellation:cancellation)}
        return try processRequest(package,store:store,interaction:interaction,now:now,cancellation:cancellation)
    }
    private static func review(_ package:GaoValidatedPackage,status:String?=nil)->GaoHandoffReview {
        let manifest=package.manifest
        let inputs=package.stagedItems.map{"• \(HandoffNames.display(URL(fileURLWithPath:$0.item.relativePath).lastPathComponent))（\($0.item.byteCount) 字节）"}
            + manifest.references.map{"• \(HandoffNames.display($0.displayName))（需要本端核对读取权限）"}
        return GaoHandoffReview(title:manifest.kind=="result" ? "接收文档交接结果？":"接收交接文档？",message:
            "来源声明：\(HandoffNames.display(manifest.sourceBundleID))（不是身份认证）\n动作：\(manifest.action)\n"+(status.map{"对方状态：\($0)\n"} ?? "")+inputs.joined(separator:"\n")+"\n\n文字进入新的未保存标签，其他文档打开校验副本；原件及当前未保存内容保留。OCR准确率需人工复核。")
    }
    private static func processRequest(_ package:GaoValidatedPackage,store:WorkspaceStore,interaction:GaoHandoffInteraction,now:Date,cancellation:GaoHandoffCancellation) throws -> GaoHandoffOutcome {
        let m=package.manifest, ledger=try GaoProcessedRequestStore(root:exchangeRoot)
        let receipt=try ledger.receive(package,now:now)
        if case .duplicate(let previous)=receipt {
            try? FileManager.default.removeItem(at:package.stagingURL)
            store.status="此交接请求已有记录，未重复打开（\(previous.phase.rawValue)）"
            return .init(requestID:m.requestID,status:previous.phase.rawValue,duplicate:true)
        }
        guard GaoActionContract.supportedActions.contains(m.action) else {
            return try requestReply(m,status:"unsupported",tabs:[],itemIDs:[],messages:["搞文件仅提供文档打开与新建文字动作。"],ledger:ledger,interaction:interaction,now:now)
        }
        if !interaction.confirm(review(package)) || cancellation.isCancelled {
            return try requestReply(m,status:"cancelled",tabs:[],itemIDs:[],messages:[],ledger:ledger,interaction:interaction,now:now)
        }
        _ = try ledger.transition(requestID:m.requestID,to:.approved,now:now)
        _ = try ledger.transition(requestID:m.requestID,to:.executing,now:now)
        var tabs:[UUID]=[],opened:[String]=[],messages:[String]=[]
        for item in package.stagedItems {
            if cancellation.isCancelled {break}
            do {try cancellation.check();let tab=try open(item,manifest:m,store:store,forceNewText:m.action=="documents.newText",now:now);tabs.append(tab.id);opened.append(item.id)}
            catch {messages.append(error.localizedDescription)}
        }
        for ref in m.references {
            if cancellation.isCancelled {break}
            do {try cancellation.check();guard let selected=interaction.selectReference(ref) else {messages.append("用户取消了所选原件授权。");continue}
                let item=try copyReference(ref,selected:selected,into:package.stagingURL)
                let tab=try open(item,manifest:m,store:store,forceNewText:false,now:now);tabs.append(tab.id);opened.append(ref.id)
            } catch {messages.append(error.localizedDescription)}
        }
        if cancellation.isCancelled {messages.append("用户取消了后续交接，已打开的文档保留。")}
        let status=cancellation.isCancelled ? (tabs.isEmpty ? "cancelled":"partial") : messages.isEmpty ? "completed":tabs.isEmpty ? "failed":"partial"
        store.status=tabs.isEmpty ? "交接未打开新文档 · 现有内容保留":"已打开 \(tabs.count) 个交接文档 · 原件保留"
        return try requestReply(m,status:status,tabs:tabs,itemIDs:opened,messages:messages,ledger:ledger,interaction:interaction,now:now)
    }
    private static func requestReply(_ m:GaoActionManifest,status:String,tabs:[UUID],itemIDs:[String],messages:[String],ledger:GaoProcessedRequestStore,interaction:GaoHandoffInteraction,now:Date) throws -> GaoHandoffOutcome {
        let reply=try GaoActionWriter.writeResult(inReplyTo:m,status:status,errorCode:status=="failed" || status=="partial" ? "documentOpenFailed":nil,
            provenance:["workflowState":.string(status=="completed" ? "opened":status),"openedItemIDs":.array(itemIDs.map(GaoJSONValue.string)),"saved":.bool(false)],exchangeRoot:exchangeRoot,now:now)
        _ = try ledger.transition(requestID:m.requestID,to:GaoRequestPhase(rawValue:status)!,resultPackageName:reply.lastPathComponent,errorCode:messages.isEmpty ? nil:"documentOpenFailed",now:now)
        interaction.offerResult(m,reply)
        return .init(requestID:m.requestID,status:status,openedTabIDs:tabs,resultPackageURL:reply,messages:messages)
    }
    private static func processResult(_ package:GaoValidatedPackage,store:WorkspaceStore,interaction:GaoHandoffInteraction,now:Date,cancellation:GaoHandoffCancellation) throws -> GaoHandoffOutcome {
        let m=package.manifest,journal=try GaoOutgoingJournal(exchangeRoot:exchangeRoot)
        let receipt=try journal.receiveResult(package,now:now)
        if receipt.isDuplicate {
            try? FileManager.default.removeItem(at:package.stagingURL)
            store.status="交接结果已有处理记录，未重复打开"
            return .init(requestID:m.requestID,status:receipt.record.status,duplicate:true)
        }
        let status=m.status ?? "failed"
        if receipt.newOutputs.isEmpty && receipt.newReferenceIDs.isEmpty {
            _ = try journal.approveResult(requestID:m.requestID,now:now)
            _ = try journal.startResult(requestID:m.requestID,now:now)
            _ = try journal.finishResult(requestID:m.requestID,openedItemIDs:[],now:now)
            if m.action=="research.importDocuments" {
                store.status="搞研究报告状态：\(status)；当前文档未自动保存或覆盖"
            }else{store.status=status=="pending" ? "对方仍在处理，尚无文档结果":"已收到对方状态：\(status)；没有新文档可打开"}
            return .init(requestID:m.requestID,status:status)
        }
        guard interaction.confirm(review(package,status:status)) else {
            _ = try journal.cancelResult(requestID:m.requestID,now:now)
            return .init(requestID:m.requestID,status:"cancelled")
        }
        _ = try journal.approveResult(requestID:m.requestID,now:now)
        _ = try journal.startResult(requestID:m.requestID,now:now)
        var tabs:[UUID]=[],opened:[String]=[],refs:[String]=[],messages:[String]=[]
        for output in receipt.newOutputs {
            if cancellation.isCancelled {break}
            do {
                try cancellation.check()
                guard let item=package.stagedItems.first(where:{$0.id==output.resultItemID}) else {throw GaoActionContract.reject("missingResult","结果附件缺失。")}
                var provenance:OCRProvenance?,report:PDFHandoffReport?
                if m.action=="ocr.files" {
                    guard let sourceID=output.sourceItemID,let hash=output.sourceSHA256 else {throw GaoActionContract.reject("missingSource","识别结果缺少原件关联。")}
                    provenance=try OCRResultProvenance.normalize(manifest:m,resultItemID:item.id,sourceItemID:sourceID,sourceSHA256:hash)
                    let original=try journal.sourceURL(requestID:receipt.session.requestID,itemID:sourceID)
                    if item.url.pathExtension.lowercased()=="pdf" {
                        report=try PDFHandoffVerifier.inspect(resultData:GaoPrivateIO.read(GaoPrivateIO.regularURL(item.url),maximum:Int64(DocumentHandoffSafety.maximumDocumentBytes)),originalData:GaoPrivateIO.read(GaoPrivateIO.regularURL(original),maximum:Int64(DocumentHandoffSafety.maximumDocumentBytes)),provenance:provenance,expectedSourceItemID:sourceID)
                    }
                }
                let isOCRText=m.action=="ocr.files" && FileKind(url:item.url).isText
                let tab=try open(item,manifest:m,store:store,forceNewText:isOCRText,provenance:provenance,report:report,now:now)
                tabs.append(tab.id);opened.append(item.id)
            }catch {messages.append(error.localizedDescription)}
        }
        for ref in m.references where receipt.newReferenceIDs.contains(ref.id) {
            if cancellation.isCancelled {break}
            do {try cancellation.check();guard let selected=interaction.selectReference(ref) else {messages.append("用户取消了原件授权。");continue}
                let item=try copyReference(ref,selected:selected,into:package.stagingURL)
                let tab=try open(item,manifest:m,store:store,forceNewText:false,now:now);tabs.append(tab.id);refs.append(ref.id)
            }catch {messages.append(error.localizedDescription)}
        }
        if cancellation.isCancelled {messages.append("用户取消了后续结果接收，已打开的文档保留。")}
        if cancellation.isCancelled && tabs.isEmpty {_ = try journal.cancelResult(requestID:m.requestID,now:now)}
        else if !messages.isEmpty && tabs.isEmpty {_ = try journal.failResult(requestID:m.requestID,errorCode:"documentOpenFailed",now:now)}
        else {_ = try journal.finishResult(requestID:m.requestID,openedItemIDs:opened,openedReferenceIDs:refs,now:now)}
        store.status="已接收 \(tabs.count) 个结果文档；对方状态：\(status) · 原件保留"
        if !messages.isEmpty {store.error=messages.joined(separator:"\n")}
        return .init(requestID:m.requestID,status:cancellation.isCancelled && tabs.isEmpty ? "cancelled":messages.isEmpty ? status:tabs.isEmpty ? "failed":"partial",openedTabIDs:tabs,messages:messages)
    }
    private static func open(_ item:GaoStagedItem,manifest:GaoActionManifest,store:WorkspaceStore,forceNewText:Bool,provenance:OCRProvenance?=nil,report:PDFHandoffReport?=nil,now:Date) throws -> FileSession {
        let kind=try DocumentHandoffSafety.review(item.url,declaredUTI:item.item.uti,verifiedStaging:true)
        let name=URL(fileURLWithPath:item.item.relativePath).lastPathComponent
        var checkedReport=report
        if kind == .pdf && checkedReport==nil {
            checkedReport=try PDFHandoffVerifier.inspect(resultData:GaoPrivateIO.read(GaoPrivateIO.regularURL(item.url),maximum:Int64(DocumentHandoffSafety.maximumDocumentBytes)),provenance:provenance)
        }
        let incoming=IncomingDocument(requestID:manifest.requestID,itemID:item.id,sourceBundleID:manifest.sourceBundleID,type:manifest.action=="ocr.files" && kind.isText ? "ocrText":kind.rawValue,receivedAt:GaoActionContract.timestamp(now),contentSHA256:item.item.sha256,originalName:name,ocrProvenance:provenance,pdfReport:checkedReport,notes:manifest.status=="partial" ? ["对方报告部分完成；请检查失败页及缺失结果。"]:[])
        if forceNewText {
            guard kind.isText,let text=String(data:try GaoPrivateIO.read(GaoPrivateIO.regularURL(item.url),maximum:GaoActionContract.maximumTextBytes),encoding:.utf8) else {throw GaoActionContract.reject("invalidUTF8","交接正文必须为有界 UTF-8 文字。")}
            return try store.newHandoffText(text,markdown:kind == .markdown,title:manifest.parameters["suggestedTitle"]?.stringValue ?? name,incoming:incoming)
        }
        return try store.openHandoffDocument(item.url,incoming:incoming)
    }
    private static func copyReference(_ ref:GaoActionReference,selected:URL,into stage:URL) throws -> GaoStagedItem {
        guard ref.kind=="file" else {throw GaoActionContract.reject("invalidReference","文档交接仅接受用户所选普通文件。")}
        try DocumentHandoffSafety.permittedLocation(selected)
        try GaoActionTransport.verifyReference(ref,selectedURL:selected)
        _ = try DocumentHandoffSafety.review(selected)
        let fd=try GaoPrivateIO.regularURL(selected),before=try fd.statValue()
        let destination=try GaoPrivateIO.directory(stage,requirePrivate:true)
        let name=UUID().uuidString+"-"+GaoActionContract.safeFilename(selected.lastPathComponent)
        let result=try GaoPrivateIO.copy(fd,to:destination,name:name,maximum:Int64(DocumentHandoffSafety.maximumDocumentBytes),expectedSize:ref.declaredIdentity.byteCount,expectedSHA256:ref.sha256)
        try GaoActionTransport.verifyReference(ref,selectedURL:selected)
        guard GaoPrivateIO.unchanged(before,try fd.statValue()) else {throw GaoActionContract.reject("referenceChanged","所选原件在复制期间发生变化。")}
        return .init(item:.init(id:ref.id,relativePath:"payload/"+name,uti:documentUTI(selected),byteCount:result.0,sha256:result.1),url:stage.appendingPathComponent(name))
    }
    static func documentUTI(_ url:URL)->String {
        switch url.pathExtension.lowercased() {
        case "pdf":return "com.adobe.pdf"
        case "md","markdown":return "net.daringfireball.markdown"
        case "png":return "public.png"
        case "jpg","jpeg":return "public.jpeg"
        case "tif","tiff":return "public.tiff"
        case "heic":return "public.heic"
        case "gif":return "com.compuserve.gif"
        case "webp":return "org.webmproject.webp"
        case "bmp":return "com.microsoft.bmp"
        case "rtf":return "public.rtf"
        case "doc":return "com.microsoft.word.doc"
        case "xls":return "com.microsoft.excel.xls"
        case "ppt","pps":return "com.microsoft.powerpoint.ppt"
        case "odt":return "org.oasis-open.opendocument.text"
        case "ods":return "org.oasis-open.opendocument.spreadsheet"
        case "odp":return "org.oasis-open.opendocument.presentation"
        case "txt","tex","bib","sty","cls","csv","tsv","json","xml","yaml","yml","html","css","js","swift","py","r","log","sh":return "public.utf8-plain-text"
        case "docx":return "org.openxmlformats.wordprocessingml.document"
        case "xlsx":return "org.openxmlformats.spreadsheetml.sheet"
        case "pptx":return "org.openxmlformats.presentationml.presentation"
        default:return UTType(filenameExtension:url.pathExtension)?.identifier ?? "public.plain-text"
        }
    }
    /// Private journal context only; never grants another app access to this path.
    static func originalContext(_ url:URL) throws -> GaoActionReference {
        let file=try GaoPrivateIO.regularURL(url),state=try file.statValue()
        let volume=try url.resourceValues(forKeys:[.volumeUUIDStringKey]).volumeUUIDString
        let modified=Date(timeIntervalSince1970:Double(state.st_mtimespec.tv_sec)+Double(state.st_mtimespec.tv_nsec)/1_000_000_000)
        return GaoActionReference(id:UUID().uuidString,kind:"file",fileURL:url.standardizedFileURL.absoluteString,
            displayName:url.lastPathComponent,declaredIdentity:.init(volumeUUID:volume,device:UInt64(state.st_dev),inode:UInt64(state.st_ino),byteCount:state.st_size,modifiedAt:GaoActionContract.timestamp(modified)))
    }
}

enum OCRPDFVersion {case currentEdits,diskOriginal,cancel}
struct PreparedDocumentHandoff {let packageURL:URL;let session:GaoOutgoingSession}
typealias PreparedOCRHandoff = PreparedDocumentHandoff
@MainActor enum OCRHandoffDispatcher {
    static func isRecognizable(_ url:URL)->Bool {["pdf","png","jpg","jpeg","tiff","tif","heic"].contains(url.pathExtension.lowercased())}
    /// The same operation is called by the menu and by non-GUI integration tests.
    static func prepare(files:[URL],store:WorkspaceStore,registry:CurrentDocumentHandoffRegistry? = nil,chooseVersion:(URL)->OCRPDFVersion,now:Date=Date()) throws -> PreparedOCRHandoff {
        let registry=registry ?? .shared
        guard !files.isEmpty,files.count<=128 else {throw GaoActionContract.reject("itemLimit","每批识别最多选择 128 个文档，请分批发送。")}
        var outgoing:[GaoOutgoingFile]=[],bindings:[GaoOutgoingSourceBinding]=[]
        var temporary:[URL]=[]
        defer{for url in temporary{try? FileManager.default.removeItem(at:url)}}
        for url in files {
            guard isRecognizable(url) else {throw GaoActionContract.reject("unsupportedOCRInput","请选择常见位图或 PDF 扫描件。")}
            let original=try GaoHandoffService.originalContext(url)
            var selected=url,version="original"
            if url.pathExtension.lowercased()=="pdf" {
                let model=try registry.commitCurrentPDF(for:url)
                let session=store.tabs.first(where:{$0.url?.standardizedFileURL==url.standardizedFileURL})
                if model?.dirty == true || session?.moduleDirty == true || session?.dirty == true {
                    switch chooseVersion(url) {
                    case .cancel:throw GaoActionContract.reject("cancelled","已取消识别交接。")
                    case .diskOriginal:break
                    case .currentEdits:
                        let directory=GaoHandoffService.exchangeRoot.appendingPathComponent("Staging/OutgoingExports")
                        _ = try GaoPrivateIO.directory(directory,create:true,requirePrivate:true)
                        selected=try registry.snapshotCurrentPDF(for:url,to:directory.appendingPathComponent(UUID().uuidString+".pdf")).url;version="currentEdits";temporary.append(selected)
                    }
                }
            }
            let isOwn=temporary.contains(selected) || selected.standardizedFileURL.path.hasPrefix(GaoHandoffService.exchangeRoot.appendingPathComponent("Staging").standardizedFileURL.path+"/")
            _ = try DocumentHandoffSafety.review(selected,declaredUTI:GaoHandoffService.documentUTI(selected),verifiedStaging:isOwn)
            let file=GaoOutgoingFile(url:selected,uti:GaoHandoffService.documentUTI(selected));outgoing.append(file)
            bindings.append(.init(itemID:file.id,originalReference:original,versionKind:version))
        }
        let package=try GaoActionWriter.writeRequest(action:"ocr.files",items:outgoing,parameters:["outputs":.array([.string("text"),.string("searchablePDF")])],targetBundleID:"com.gaoseries.GaoJieTu",exchangeRoot:GaoHandoffService.exchangeRoot,now:now)
        let journal=try GaoOutgoingJournal(exchangeRoot:GaoHandoffService.exchangeRoot)
        let session=try journal.registerOutgoing(packageURL:package,expectedTargetBundleID:"com.gaoseries.GaoJieTu",bindings:bindings,now:now)
        return .init(packageURL:package,session:session)
    }
    /// The fallback menu and integration tests share the exact safe export operation.
    @discardableResult static func exportCopy(_ prepared:PreparedOCRHandoff,itemID:String,to destination:URL,overwrite:HandoffSafeExport.Overwrite = .rejectExisting) throws -> HandoffSafeExport.Receipt {
        guard let source=prepared.session.sources.first(where:{$0.item.id==itemID}) else {throw GaoActionContract.reject("unknownSource","待导出的文档不存在。")}
        let journal=try GaoOutgoingJournal(exchangeRoot:GaoHandoffService.exchangeRoot)
        let url=try journal.sourceURL(requestID:prepared.session.requestID,itemID:itemID)
        let original=try source.binding.originalReference.map{try GaoActionContract.localFileURL($0.fileURL)}
        return try HandoffSafeExport.copy(source:url,to:destination,protectedOriginal:original,overwrite:overwrite)
    }
    static func startOCR(for fileURL:URL?=nil,store:WorkspaceStore){
        var inputs:[URL]=[]
        if let fileURL {inputs=[fileURL]}
        else if let active=store.active?.url,isRecognizable(active){inputs=[active]}
        else {
            let panel=NSOpenPanel();panel.title="选择扫描件或图片";panel.allowedContentTypes=[.pdf,.png,.jpeg,.tiff,.heic];panel.allowsMultipleSelection=true
            guard panel.runModal() == .OK else{return};inputs=panel.urls
        }
        do {
            let prepared=try prepare(files:inputs,store:store,chooseVersion:{_ in
                let alert=NSAlert();alert.messageText="选择要识别的 PDF 版本";alert.informativeText="当前编辑器有未保存修改。导出当前副本会包含刚输入的表单和批注，磁盘版本只包含已保存内容；两种方式都保留原件。"
                alert.addButton(withTitle:"导出当前副本并识别");alert.addButton(withTitle:"发送磁盘已保存版本");alert.addButton(withTitle:"取消")
                switch alert.runModal(){case .alertFirstButtonReturn:return .currentEdits;case .alertSecondButtonReturn:return .diskOriginal;default:return .cancel}
            })
            guard let provider=try GaoCapabilityDiscovery.installedProvider(bundleID:"com.gaoseries.GaoJieTu",action:"ocr.files"),provider.capability.accepts(parameterKeys:["outputs"]) else {
                fallback(prepared,store:store);return
            }
            GaoCapabilityDiscovery.send(packageURL:prepared.packageURL,to:provider){ error in
                Task { @MainActor in
                    do {try GaoOutgoingJournal(exchangeRoot:GaoHandoffService.exchangeRoot).markDispatched(requestID:prepared.session.requestID,success:error==nil)}catch{store.error=error.localizedDescription;return}
                    if let error {store.error="发送请求失败："+error.localizedDescription}
                    else {store.status="识别请求已交给搞截图，等待用户处理并发送结果；尚未完成识别"}
                }
            }
        }catch {store.error=error.localizedDescription}
    }
    static func fallback(_ prepared:PreparedDocumentHandoff,store:WorkspaceStore,title:String="未找到兼容的搞截图 OCR 能力"){
        let alert=NSAlert();alert.messageText=title;alert.informativeText="可以导出本次核验的文档副本，或在 Finder 显示交接包；交接包过期后请重新发起。"
        alert.addButton(withTitle:"导出文档副本…");alert.addButton(withTitle:"在 Finder 显示交接包");alert.addButton(withTitle:"取消")
        switch alert.runModal(){
        case .alertFirstButtonReturn:
            if prepared.session.sources.count>1 {
                let panel=NSOpenPanel();panel.title="导出全部待识别文档副本";panel.message="选择目标文件夹；已有同名文件不会被覆盖。";panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.allowsMultipleSelection=false
                guard panel.runModal() == .OK,let folder=panel.url else{return}
                var count=0,errors:[String]=[]
                for source in prepared.session.sources {
                    let name=URL(fileURLWithPath:source.item.relativePath).lastPathComponent
                    do{_ = try exportCopy(prepared,itemID:source.item.id,to:folder.appendingPathComponent(name));count += 1}
                    catch{errors.append(HandoffNames.display(name)+"："+error.localizedDescription)}
                }
                store.status="已导出 \(count) / \(prepared.session.sources.count) 份文档副本"
                if !errors.isEmpty{store.error=errors.joined(separator:"\n")}
                return
            }
            guard let source=prepared.session.sources.first else{return}
            let panel=NSSavePanel();panel.nameFieldStringValue=URL(fileURLWithPath:source.item.relativePath).lastPathComponent;panel.title="导出待识别文档副本"
            guard panel.runModal() == .OK,let destination=panel.url else{return}
            do {
                var overwrite=HandoffSafeExport.Overwrite.rejectExisting
                if FileManager.default.fileExists(atPath:destination.path){overwrite = .replace(expectedSHA256:FileSafety.digest(try GaoPrivateIO.read(GaoPrivateIO.regularURL(destination),maximum:GaoActionContract.maximumPayloadBytes)))}
                _ = try exportCopy(prepared,itemID:source.item.id,to:destination,overwrite:overwrite)
                store.status="文档副本已安全导出；已有目标的原件快照保留"
            }catch {store.error=error.localizedDescription}
        case .alertSecondButtonReturn:NSWorkspace.shared.activateFileViewerSelecting([prepared.packageURL])
        default:break
        }
    }
    static func chooseDocuments(store:WorkspaceStore){
        do {
            guard let provider=try GaoCapabilityDiscovery.installedProvider(bundleID:"com.gaoseries.GaoZhengLi",action:"files.choose"),provider.capability.accepts(parameterKeys:["multiple"]) else {store.openPanel();return}
            let url=try GaoActionWriter.writeRequest(action:"files.choose",parameters:["multiple":.bool(true)],targetBundleID:provider.bundleID,exchangeRoot:GaoHandoffService.exchangeRoot)
            let journal=try GaoOutgoingJournal(exchangeRoot:GaoHandoffService.exchangeRoot)
            let session=try journal.registerOutgoing(packageURL:url,expectedTargetBundleID:provider.bundleID)
            GaoCapabilityDiscovery.send(packageURL:url,to:provider){error in Task{@MainActor in
                do{try GaoOutgoingJournal(exchangeRoot:GaoHandoffService.exchangeRoot).markDispatched(requestID:session.requestID,success:error==nil)}catch{store.error=error.localizedDescription;return}
                store.status=error==nil ? "已请求搞整理选择文档，等待用户发送所选结果":"文件选择请求发送失败"
            }}
        }catch{store.error=error.localizedDescription}
    }
}

/// Sends an explicit snapshot of the selected editor, without saving its original.
@MainActor enum CurrentDocumentDispatcher {
    static let researchBundleID="com.academic-achievement.manager"
    private static let researchFormats:Set<String>=["doc","docx","xls","xlsx","csv","tsv","ppt","pptx","pdf","md","markdown","txt","rtf","json","xml","yaml","yml","png","jpg","jpeg","heic","tif","tiff"]
    static func usesPlainTextCopy(_ tab:FileSession)->Bool {
        tab.kind.isText && !researchFormats.contains(URL(fileURLWithPath:tab.title).pathExtension.lowercased())
    }

    static func prepare(store:WorkspaceStore,registry:CurrentDocumentHandoffRegistry? = nil,chooseVersion:(URL)->OCRPDFVersion,now:Date=Date()) throws -> PreparedDocumentHandoff {
        guard !store.showingNotes,let tab=store.active else {throw GaoActionContract.reject("noDocument","请先选择要交接的文档标签。")}
        guard NSApp?.keyWindow?.makeFirstResponder(nil) != false else {throw GaoActionContract.reject("editorBusy","当前输入无法提交，请完成输入后重试。")}
        let registry=registry ?? .shared
        let directory=GaoHandoffService.exchangeRoot.appendingPathComponent("Staging/OutgoingExports")
        _ = try GaoPrivateIO.directory(directory,create:true,requirePrivate:true)
        var temporary:URL?,selected:URL,version="savedVersion"
        defer{if let temporary{try? FileManager.default.removeItem(at:temporary)}}
        if tab.kind.isText {
            let data=Data(tab.text.utf8)
            guard data.count<=DocumentHandoffSafety.maximumTextBytes,!tab.text.contains("\0") else {throw GaoActionContract.reject("textLimit","交接正文须为不含空字符的 UTF-8，且不超过 8 MiB。")}
            selected=directory.appendingPathComponent(UUID().uuidString+"-"+GaoActionContract.safeFilename(tab.title))
            if usesPlainTextCopy(tab){selected=selected.appendingPathExtension("txt")}
            temporary=selected
            try data.write(to:selected,options:.withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:selected.path)
            // An unnamed title can lack an extension; always preserve the editor's format.
            if !FileKind(url:selected).isText {
                let renamed=selected.appendingPathExtension(tab.suggestedExtension)
                try FileManager.default.moveItem(at:selected,to:renamed);selected=renamed;temporary=renamed
            }
            version="currentEdits"
        } else {
            guard let url=tab.url else {throw GaoActionContract.reject("noDocument","此文档尚无可读取的本机内容。")}
            guard researchFormats.contains(url.pathExtension.lowercased()) else {throw GaoActionContract.reject("unsupportedResearchFormat","搞研究暂不接收这种格式。请先导出 PDF 或受支持的文档副本，再进行交接。")}
            selected=url
            if tab.kind == .pdf {
                let model=try registry.commitCurrentPDF(for:url)
                if model?.dirty == true || tab.moduleDirty || tab.dirty {
                    switch chooseVersion(url) {
                    case .cancel:throw GaoActionContract.reject("cancelled","已取消文档交接。")
                    case .diskOriginal:break
                    case .currentEdits:
                        selected=try registry.snapshotCurrentPDF(for:url,to:directory.appendingPathComponent(UUID().uuidString+".pdf")).url
                        temporary=selected;version="currentEdits"
                    }
                }
            } else if tab.dirty || tab.moduleDirty {
                throw GaoActionContract.reject("unsavedDocument","此格式暂不能无损导出当前修改。请先在原编辑器保存或另存，再交接文档。")
            }
        }
        _ = try DocumentHandoffSafety.review(selected,declaredUTI:GaoHandoffService.documentUTI(selected),verifiedStaging:temporary != nil || selected.standardizedFileURL.path.hasPrefix(GaoHandoffService.exchangeRoot.appendingPathComponent("Staging").standardizedFileURL.path+"/"))
        let file=GaoOutgoingFile(url:selected,uti:GaoHandoffService.documentUTI(selected))
        let original=try tab.url.map{try GaoHandoffService.originalContext($0)}
        let package=try GaoActionWriter.writeRequest(action:"research.importDocuments",items:[file],targetBundleID:researchBundleID,exchangeRoot:GaoHandoffService.exchangeRoot,now:now)
        let journal=try GaoOutgoingJournal(exchangeRoot:GaoHandoffService.exchangeRoot)
        let session=try journal.registerOutgoing(packageURL:package,expectedTargetBundleID:researchBundleID,bindings:[.init(itemID:file.id,originalReference:original,versionKind:version)],now:now)
        return .init(packageURL:package,session:session)
    }

    static func sendCurrent(store:WorkspaceStore){
        do {
            if let tab=store.active,usesPlainTextCopy(tab) {
                let alert=NSAlert();alert.messageText="以源文本副本交接？";alert.informativeText="搞研究暂不接收此源码格式。可以发送当前内容的 UTF-8 TXT 副本；若需要排版结果，请先编译并打开 PDF 后交接。"
                alert.addButton(withTitle:"发送 TXT 副本");alert.addButton(withTitle:"取消")
                guard alert.runModal() == .alertFirstButtonReturn else{return}
            }
            let prepared=try prepare(store:store,chooseVersion:{_ in
                let alert=NSAlert();alert.messageText="选择要交接的 PDF 版本";alert.informativeText="当前 PDF 有未保存的内容；请选择当前副本或磁盘已保存版本。原件保持保留。"
                alert.addButton(withTitle:"交接当前副本");alert.addButton(withTitle:"交接已保存版本");alert.addButton(withTitle:"取消")
                switch alert.runModal(){case .alertFirstButtonReturn:return .currentEdits;case .alertSecondButtonReturn:return .diskOriginal;default:return .cancel}
            })
            guard let provider=try GaoCapabilityDiscovery.installedProvider(bundleID:researchBundleID,action:"research.importDocuments"),provider.capability.accepts(parameterKeys:[]) else {
                OCRHandoffDispatcher.fallback(prepared,store:store,title:"未找到兼容的搞研究导入能力");return
            }
            GaoCapabilityDiscovery.send(packageURL:prepared.packageURL,to:provider){error in Task{@MainActor in
                do{try GaoOutgoingJournal(exchangeRoot:GaoHandoffService.exchangeRoot).markDispatched(requestID:prepared.session.requestID,success:error==nil)}catch{store.error=error.localizedDescription;return}
                if let error{store.error=error.localizedDescription}
                else{store.status="文档副本已交给搞研究，等待其复核导入并返回结果；尚未确认导入完成"}
            }}
        }catch{store.error=error.localizedDescription}
    }
}
