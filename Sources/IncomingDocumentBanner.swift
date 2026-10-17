import SwiftUI

struct IncomingDocumentBanner: View {
    let incoming: IncomingDocument
    @State private var expanded = false
    var body: some View {
        VStack(alignment:.leading,spacing:6){
            HStack {
                Image(systemName: incoming.pdfReport?.isVerifiedSearchable == true ? "checkmark.shield" : "doc.badge.arrow.up")
                Text(incoming.summary).font(.callout.weight(.medium))
                Text("来源声明："+HandoffNames.display(incoming.sourceName)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(expanded ? "收起来源与页状态":"查看来源与页状态"){expanded.toggle()}.font(.caption)
            }
            if expanded {
                ScrollView {
                    VStack(alignment:.leading,spacing:5){
                        Text(incoming.opensOriginal == true ? "来源声明未经身份认证。当前打开你选择的原件；保存会写回原文件，并保留历史快照。" : "来源声明未经身份认证。接收内容独立打开；原件和已有编辑内容保留。")
                        Text("接收文件："+HandoffNames.display(incoming.originalName))
                        if let name=incoming.sourceDisplayName {Text("对应输入："+HandoffNames.display(name))}
                        ForEach(Array(incoming.notes.enumerated()),id:\.offset){_,note in Text(HandoffNames.display(note,limit:1024)).foregroundStyle(.orange)}
                        if let report=incoming.pdfReport {
                            Text(report.summary)
                            ForEach(Array(report.issues.enumerated()),id:\.offset){_,issue in Text((issue.pageNumber.map{"第 \($0) 页："} ?? "")+HandoffNames.display(issue.message,limit:1024)).foregroundStyle(.orange)}
                        }
                        if let provenance=incoming.ocrProvenance {
                            Text("OCR 声明共 \(provenance.pages.count) 页；准确率与完整性需本人复核。")
                            ForEach(provenance.pages,id:\.pageNumber){page in
                                Text("第 \(page.pageNumber) 页："+status(page.status)+(page.failureReason.map{" · "+HandoffNames.display($0,limit:1024)} ?? ""))
                            }
                        }
                        if incoming.sourceBundleID == CurrentDocumentDispatcher.researchBundleID {
                            Text("编辑后可用“文件 → 导出编辑副本…”，再回搞研究原条目选择“导入编辑新版本…”。导出不表示已导入。")
                        }
                    }.font(.caption).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:170)
            }
        }.padding(10).background(.bar)
    }
    private func status(_ value:String?)->String {
        switch value {case "completed":return "已完成";case "partial":return "部分完成";case "failed":return "失败";case "cancelled":return "已取消";case "unsupported":return "不支持";default:return "未声明"}
    }
}
