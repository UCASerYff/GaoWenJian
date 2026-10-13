import AppKit
import Foundation
import UniformTypeIdentifiers
import PDFKit

@MainActor
enum GaoHandoffService {
    static var exchangeRoot: URL {
        FileSafety.root.appendingPathComponent("Exchange")
    }

    /// Handles incoming .gaoaction packages. Returns true if handled, false if not a gaoaction.
    @discardableResult
    static func handleIncoming(url: URL, store: WorkspaceStore) -> Bool {
        guard url.pathExtension.lowercased() == "gaoaction" else { return false }
        do {
            let root = exchangeRoot
            let ledger = try GaoProcessedRequestStore(root: root)
            let validated = try GaoActionTransport.receive(packageURL: url, exchangeRoot: root)
            let receipt = try ledger.receive(validated)
            switch receipt {
            case .duplicate(let record):
                let alert = NSAlert()
                alert.messageText = "交接请求已处理"
                alert.informativeText = "来自【\(sourceDisplayName(record.sourceBundleID))】的交接请求（ID: \(record.requestID)）已于 \(record.updatedAt) 处理完成（状态: \(record.phase.rawValue)），不重复执行。"
                alert.addButton(withTitle: "好")
                alert.runModal()
                return true
            case .new(let record):
                try processValidatedPackage(validated, record: record, ledger: ledger, store: store)
                return true
            }
        } catch let issue as GaoActionIssue {
            let msg = issue.errorDescription ?? issue.code
            let alert = NSAlert()
            alert.messageText = "文档交接未通过安全检查"
            alert.informativeText = "\(msg) (代码: \(issue.code))"
            alert.addButton(withTitle: "确定")
            alert.runModal()
            store.error = msg
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法接收文档交接"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "确定")
            alert.runModal()
            store.error = error.localizedDescription
            return true
        }
    }

    private static func sourceDisplayName(_ bundleID: String) -> String {
        switch bundleID {
        case "com.gaoseries.GaoJieTu": return "搞截图"
        case "com.gaoseries.GaoZhengLi": return "搞整理"
        case "com.gaoseries.GaoWenJian": return "搞文件"
        default: return bundleID
        }
    }

    private static func processValidatedPackage(_ validated: GaoValidatedPackage, record: GaoProcessedRequest, ledger: GaoProcessedRequestStore, store: WorkspaceStore) throws {
        let manifest = validated.manifest
        let sourceName = sourceDisplayName(manifest.sourceBundleID)

        switch manifest.action {
        case "documents.newText":
            guard let item = validated.stagedItems.first else {
                throw GaoActionContract.reject("missingItem", "交接文本缺少正文内容。")
            }
            let data = try Data(contentsOf: item.url)
            guard let text = String(data: data, encoding: .utf8) else {
                throw GaoActionContract.reject("invalidUTF8", "交接文本必须为有效 UTF-8。")
            }
            let suggestedTitle = manifest.parameters["suggestedTitle"]?.stringValue
            let isMarkdown = item.item.uti == "text/markdown" || item.item.uti == "net.daringfireball.markdown" || item.item.relativePath.lowercased().hasSuffix(".md")

            var ocrInfo = ""
            var ocrProvenance: OCRProvenance?
            if let prov = manifest.provenance?["ocr"] {
                if let provData = try? JSONEncoder().encode(prov), let parsed = try? OCRProvenance.parse(jsonData: provData) {
                    ocrProvenance = parsed
                    ocrInfo = "\n\n【识别来源】引擎：\(parsed.engine ?? "搞截图") \(parsed.engineVersion ?? "")\n识别语言：\(parsed.languages.joined(separator: ", "))\n原件摘要：\(parsed.sourceSHA256 ?? "无")\n（注：识别文字仅供参考，不篡改原文件）"
                }
            }

            let alert = NSAlert()
            alert.messageText = "接收来自【\(sourceName)】的文字内容？"
            alert.informativeText = "请求动作：新建未保存文档\n建议标题：\(suggestedTitle ?? item.item.relativePath)\n字数与大小：约 \(text.count) 字 (\(data.count) 字节)\(ocrInfo)\n\n确认后将在新标签中打开未保存文档，不会覆盖已有文档或自动落盘。"
            alert.addButton(withTitle: "确认接收并打开")
            alert.addButton(withTitle: "取消")

            if alert.runModal() != .alertFirstButtonReturn {
                _ = try ledger.transition(requestID: manifest.requestID, to: .cancelled)
                return
            }

            _ = try ledger.transition(requestID: manifest.requestID, to: .approved)
            _ = try ledger.transition(requestID: manifest.requestID, to: .executing)

            let incoming = IncomingDocument(
                requestID: manifest.requestID,
                itemID: item.item.id,
                sourceBundleID: manifest.sourceBundleID,
                type: "ocrText",
                receivedAt: manifest.createdAt,
                contentSHA256: item.item.sha256,
                originalName: item.item.relativePath.components(separatedBy: "/").last ?? "文字",
                ocrProvenance: ocrProvenance
            )

            try store.newHandoffText(text, markdown: isMarkdown, title: suggestedTitle, incoming: incoming)
            _ = try ledger.transition(requestID: manifest.requestID, to: .completed)
            store.status = "已接收来自【\(sourceName)】的文字内容"

        case "documents.open":
            if !validated.stagedItems.isEmpty {
                // Staged copies handoff
                var summaryList: [String] = []
                for staged in validated.stagedItems {
                    summaryList.append("• \(staged.item.relativePath) (\(staged.item.byteCount) 字节)")
                }

                let alert = NSAlert()
                alert.messageText = "接收来自【\(sourceName)】的交接文档？"
                alert.informativeText = "请求动作：在新标签打开交接文档\n包含文件：\n\(summaryList.joined(separator: "\n"))\n\n确认后将作为新标签打开，不会修改或覆盖原有文件。"
                alert.addButton(withTitle: "确认打开")
                alert.addButton(withTitle: "取消")

                if alert.runModal() != .alertFirstButtonReturn {
                    _ = try ledger.transition(requestID: manifest.requestID, to: .cancelled)
                    return
                }

                _ = try ledger.transition(requestID: manifest.requestID, to: .approved)
                _ = try ledger.transition(requestID: manifest.requestID, to: .executing)

                for staged in validated.stagedItems {
                    _ = try DocumentHandoffSafety.review(staged.url, declaredUTI: staged.item.uti, verifiedStaging: true)

                    var pdfReport: PDFHandoffReport?
                    var ocrProvenance: OCRProvenance?
                    if staged.url.pathExtension.lowercased() == "pdf" {
                        if let prov = manifest.provenance?["ocr"],
                           let provData = try? JSONEncoder().encode(prov),
                           let parsed = try? OCRProvenance.parse(jsonData: provData) {
                            ocrProvenance = parsed
                            // If source original is available, verify it
                            if let sourceHash = parsed.sourceSHA256,
                               let originalURL = store.tabs.first(where: { $0.url?.pathExtension.lowercased() == "pdf" && $0.originalDigest == sourceHash })?.url,
                               let candData = try? Data(contentsOf: staged.url),
                               let origData = try? Data(contentsOf: originalURL) {
                                pdfReport = try? PDFHandoffVerifier.inspect(resultData: candData, originalData: origData, provenance: parsed)
                            }
                        }
                    }

                    let incoming = IncomingDocument(
                        requestID: manifest.requestID,
                        itemID: staged.item.id,
                        sourceBundleID: manifest.sourceBundleID,
                        type: staged.url.pathExtension.lowercased(),
                        receivedAt: manifest.createdAt,
                        contentSHA256: staged.item.sha256,
                        originalName: staged.item.relativePath.components(separatedBy: "/").last ?? staged.url.lastPathComponent,
                        ocrProvenance: ocrProvenance,
                        pdfReport: pdfReport
                    )
                    try store.openHandoffDocument(staged.url, incoming: incoming)
                }

                _ = try ledger.transition(requestID: manifest.requestID, to: .completed)
                store.status = "已打开来自【\(sourceName)】的交接文档"

            } else if !manifest.references.isEmpty {
                // References handoff (e.g. from 搞整理 files.choose)
                var summaryList: [String] = []
                for ref in manifest.references {
                    summaryList.append("• \(ref.displayName)")
                }

                let alert = NSAlert()
                alert.messageText = "打开来自【\(sourceName)】所选的文件？"
                alert.informativeText = "请求动作：打开选中文档\n所选文件：\n\(summaryList.joined(separator: "\n"))\n\n搞文件仅打开所选文档，不获取任何索引库或全局磁盘权限。"
                alert.addButton(withTitle: "确认打开")
                alert.addButton(withTitle: "取消")

                if alert.runModal() != .alertFirstButtonReturn {
                    _ = try ledger.transition(requestID: manifest.requestID, to: .cancelled)
                    return
                }

                _ = try ledger.transition(requestID: manifest.requestID, to: .approved)
                _ = try ledger.transition(requestID: manifest.requestID, to: .executing)

                for ref in manifest.references {
                    let targetURL = try GaoActionContract.localFileURL(ref.fileURL)
                    do {
                        try GaoActionTransport.verifyReference(ref, selectedURL: targetURL)
                        _ = try DocumentHandoffSafety.review(targetURL, declaredUTI: nil, verifiedStaging: false)
                        let incoming = IncomingDocument(
                            requestID: manifest.requestID,
                            itemID: ref.id,
                            sourceBundleID: manifest.sourceBundleID,
                            type: targetURL.pathExtension.lowercased(),
                            receivedAt: manifest.createdAt,
                            contentSHA256: ref.sha256 ?? "",
                            originalName: ref.displayName
                        )
                        try store.openHandoffDocument(targetURL, incoming: incoming)
                    } catch {
                        // If file access failed (e.g. sandbox boundary), prompt user to locate file
                        let openPanel = NSOpenPanel()
                        openPanel.title = "请授权打开：\(ref.displayName)"
                        openPanel.message = "请确认并选中该文件以完成安全打开："
                        openPanel.canChooseFiles = true
                        openPanel.canChooseDirectories = false
                        openPanel.allowsMultipleSelection = false
                        openPanel.directoryURL = targetURL.deletingLastPathComponent()
                        if openPanel.runModal() == .OK, let selected = openPanel.url {
                            try GaoActionTransport.verifyReference(ref, selectedURL: selected)
                            _ = try DocumentHandoffSafety.review(selected, declaredUTI: nil, verifiedStaging: false)
                            let incoming = IncomingDocument(
                                requestID: manifest.requestID,
                                itemID: ref.id,
                                sourceBundleID: manifest.sourceBundleID,
                                type: selected.pathExtension.lowercased(),
                                receivedAt: manifest.createdAt,
                                contentSHA256: ref.sha256 ?? "",
                                originalName: ref.displayName
                            )
                            try store.openHandoffDocument(selected, incoming: incoming)
                        } else {
                            throw error
                        }
                    }
                }

                _ = try ledger.transition(requestID: manifest.requestID, to: .completed)
                store.status = "已打开来自【\(sourceName)】所选的文档"
            } else {
                throw GaoActionContract.reject("emptyRequest", "交接请求未提供任何文件或附件。")
            }

        default:
            _ = try ledger.transition(requestID: manifest.requestID, to: .unsupported)
            let alert = NSAlert()
            alert.messageText = "暂不支持该交接动作"
            alert.informativeText = "应用【\(sourceName)】请求执行 “\(manifest.action)”，但搞文件作为编辑工作台仅支持 documents.open 与 documents.newText。"
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }
}

@MainActor
enum OCRHandoffDispatcher {
    static func startOCR(for fileURL: URL? = nil, store: WorkspaceStore) {
        if let fileURL {
            dispatchOCR(for: fileURL, store: store)
        } else if let activeURL = store.active?.url, isRecognizable(activeURL) {
            dispatchOCR(for: activeURL, store: store)
        } else {
            // Prompt user to pick a file
            let panel = NSOpenPanel()
            panel.title = "选择要识别文字的扫描件或图片"
            panel.prompt = "选择并识别"
            panel.allowedContentTypes = [UTType.pdf, UTType.png, UTType.jpeg, UTType.tiff, UTType.heic].compactMap { $0 }
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let selected = panel.url {
                dispatchOCR(for: selected, store: store)
            }
        }
    }

    static func isRecognizable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["pdf", "png", "jpg", "jpeg", "tiff", "tif", "heic"].contains(ext)
    }

    private static func dispatchOCR(for targetURL: URL, store: WorkspaceStore) {
        var finalURL = targetURL

        // If it's a dirty PDF currently open in the active tab, ask user how to send
        if let active = store.active, active.url?.standardizedFileURL == targetURL.standardizedFileURL,
           targetURL.pathExtension.lowercased() == "pdf" && (active.dirty || active.moduleDirty) {
            let alert = NSAlert()
            alert.messageText = "当前 PDF 有未保存的修改"
            alert.informativeText = "您在当前 PDF 上有尚未保存的文字或标注修改。请选择要发送给 OCR 识别的内容："
            alert.addButton(withTitle: "导出包含批注的副本并识别")
            alert.addButton(withTitle: "发送磁盘上的未修改原件")
            alert.addButton(withTitle: "取消")
            let choice = alert.runModal()
            if choice == .alertThirdButtonReturn { return }
            if choice == .alertFirstButtonReturn {
                // Export dirty copy to staging
                do {
                    let exportDir = GaoHandoffService.exchangeRoot.appendingPathComponent("Staging/OutgoingExports", isDirectory: true)
                    try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let exportedFile = exportDir.appendingPathComponent("Draft-" + UUID().uuidString + ".pdf")
                    let model = PDFWorkspaceModel(url: targetURL)
                    let snapshot = try model.safeHandoffSnapshot(to: exportedFile)
                    finalURL = snapshot.url
                } catch {
                    store.error = "导出交接副本失败：\(error.localizedDescription)"
                    return
                }
            }
        }

        // Check if GaoJieTu is installed and supports ocr.files
        let provider: GaoInstalledProvider?
        do {
            provider = try GaoCapabilityDiscovery.installedProvider(bundleID: "com.gaoseries.GaoJieTu", action: "ocr.files")
        } catch {
            provider = nil
        }

        guard let provider else {
            // Provider unavailable
            let alert = NSAlert()
            alert.messageText = "未检测到可用的文字识别（OCR）应用"
            alert.informativeText = "本机尚未检测到支持 ocr.files 能力的“搞截图”（com.gaoseries.GaoJieTu）。搞文件遵循纯本地原则，不内置云端 OCR 或联网服务，亦不自动下载外部依赖。\n\n您可以将文档导出为副本，或在访达中显示该文件以便配合其他工具处理。"
            alert.addButton(withTitle: "在访达中显示")
            alert.addButton(withTitle: "导出副本…")
            alert.addButton(withTitle: "取消")
            let choice = alert.runModal()
            if choice == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([finalURL])
            } else if choice == .alertSecondButtonReturn {
                let savePanel = NSSavePanel()
                savePanel.title = "导出待识别文档副本"
                savePanel.nameFieldStringValue = finalURL.lastPathComponent
                if savePanel.runModal() == .OK, let dest = savePanel.url {
                    do {
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.copyItem(at: finalURL, to: dest)
                        store.status = "副本已导出至访达"
                    } catch {
                        store.error = "导出副本失败：\(error.localizedDescription)"
                    }
                }
            }
            return
        }

        // Package and send to GaoJieTu
        do {
            let uti = UTType(filenameExtension: finalURL.pathExtension)?.identifier ?? "public.data"
            let outgoingFile = GaoOutgoingFile(url: finalURL, uti: uti)
            let exchangeRoot = GaoHandoffService.exchangeRoot
            let packageURL = try GaoActionWriter.writeRequest(
                action: "ocr.files",
                items: [outgoingFile],
                parameters: [
                    "outputs": .array([.string("searchablePDF"), .string("text")])
                ],
                sourceBundleID: GaoActionContract.bundleID,
                targetBundleID: provider.bundleID,
                exchangeRoot: exchangeRoot
            )
            GaoCapabilityDiscovery.send(packageURL: packageURL, to: provider) { error in
                if let error {
                    Task { @MainActor in
                        store.error = "发送交接请求失败：\(error.localizedDescription)"
                    }
                } else {
                    Task { @MainActor in
                        store.status = "已向搞截图发起 OCR 识别请求 · 识别完成后将交接返回"
                    }
                }
            }
        } catch {
            store.error = "打包交接请求失败：\(error.localizedDescription)"
        }
    }
}
