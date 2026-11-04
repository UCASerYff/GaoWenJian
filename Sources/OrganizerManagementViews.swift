// Organizer module port; source application is not a runtime dependency.
import SwiftUI
import AppKit

struct OFAssociationsView: View {
    @EnvironmentObject var model: OFAppModel
    @ObservedObject var controller: OFAssociationController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("默认打开方式").font(.title2.bold())
                Text("按文件类型或 URL scheme 管理默认应用。搜索结果在搞文件中打开；此处的系统关联变更须单独确认。").foregroundStyle(.secondary)
                HStack {
                    Picker("作用范围", selection: $controller.mode) { Text("全部同类型文件").tag("type"); Text("URL scheme").tag("scheme") }.frame(width: 235)
                    TextField(controller.mode == "type" ? "public.jpeg" : "例如 mailto", text: $controller.identifier).textFieldStyle(.roundedBorder)
                    Button("读取系统关联") { controller.refresh() }
                }.disabled(controller.busy)
                GroupBox("当前系统默认应用") {
                    HStack { Image(systemName: "app").font(.title2); VStack(alignment: .leading) { Text(controller.current?.deletingPathExtension().lastPathComponent ?? "尚未读取 / 未设置").font(.headline); if let current = controller.current { Text(current.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }; Spacer() }.padding(8)
                }
                GroupBox("已安装候选") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("应用", selection: $controller.selected) {
                            Text("请选择").tag(nil as URL?)
                            ForEach(controller.candidates, id: \.self) { Text($0.deletingPathExtension().lastPathComponent).tag(Optional($0)) }
                        }
                        HStack {
                            Button("选择其他已安装应用…") {
                                let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false; p.allowedContentTypes = [.applicationBundle]; p.directoryURL = URL(fileURLWithPath: "/Applications")
                                if p.runModal() == .OK, let app = p.url { if !controller.candidates.contains(app) { controller.candidates.append(app) }; controller.selected = app }
                            }
                            Spacer()
                            Button("确认变更…") {
                                guard let app = controller.selected else { return }
                                guard ofConfirm(title: "修改默认打开应用？", message: "范围：\(controller.mode == "type" ? "所有此类型文件" : "此 URL scheme")\n标识：\(controller.identifier)\n旧应用：\(controller.current?.lastPathComponent ?? "无")\n新应用：\(app.lastPathComponent)\n系统可能另行要求确认，最终以读回结果为准。", action: "提交系统确认") else { return }
                                Task { await model.commitAssociation(to: app) }
                            }.buttonStyle(.borderedProminent).disabled(controller.selected == nil || controller.busy)
                        }
                    }.padding(8)
                }
                if model.hasPendingAssociation {
                    HStack { Text("外部请求等待你明确变更并读回确认；仅打开此页不代表完成。").font(.caption); Button("取消本次关联请求") { model.cancelPendingAssociation() }.disabled(controller.busy) }
                }
                Text(controller.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if controller.busy { ProgressView("等待系统确认并核对实际关联…") }
                Text("变更记录与恢复").font(.headline)
                ForEach(controller.history.prefix(50)) { record in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(record.identifier) → \(record.requestedApplication.lastPathComponent)")
                            Text("\(record.status) · \(record.detail)").font(.caption).foregroundStyle(.secondary)
                            Text(record.date, format: .dateTime).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if record.previousApplication != nil { Button("恢复旧关联…") { guard ofConfirm(title: "恢复旧关联？", message: "将 \(record.identifier) 恢复为 \(record.previousApplication!.lastPathComponent)，之后读取系统实际结果。", action: "恢复") else { return }; Task { await model.restoreAssociation(record) } }.disabled(controller.busy) }
                    }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(24)
        }
    }
}
struct OFMoveView: View {
    @EnvironmentObject var model: OFAppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("物理整理计划").font(.title2.bold())
                Text("从搜索结果选择文件并生成预览。V1 支持同卷普通文件；跨卷、目录包、符号链接、硬链接及云端占位文件均会拒绝。重名不覆盖，可在执行前重命名。整体批次并非原子事务。").foregroundStyle(.secondary)
                if model.moving { ProgressView("正在核验或执行，可请求取消；已完成项目保持可恢复日志。") }
                if let plan = model.movePlan {
                    GroupBox("当前计划 · \(plan.state.rawValue)") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(plan.id.uuidString).font(.caption).textSelection(.enabled)
                            Text("\(plan.operations.count) 项 · \(ByteCountFormatter.string(fromByteCount: plan.estimatedBytes, countStyle: .file))")
                            ForEach(plan.operations) { operation in OFOperationRow(operation: operation) }
                            if let failure = plan.failure { Text(failure).foregroundStyle(.orange) }
                            HStack {
                                Button("执行此预览计划…") { Task { await model.executeMove() } }.buttonStyle(.borderedProminent).disabled(plan.state != .awaitingConfirmation || model.moving)
                                Button(model.moving ? "请求取消" : "取消计划") { model.cancelMove() }
                            }
                        }.padding(10)
                    }
                }
                HStack { Text("持久记录与恢复").font(.headline); Spacer(); Button("刷新") { model.refreshMoveHistory() }.disabled(model.moving) }
                if model.moveHistory.isEmpty { Text("尚无计划。仅建立虚拟面板不会出现在此处。").foregroundStyle(.secondary) }
                ForEach(model.moveHistory.sorted(by: { $0.createdAt > $1.createdAt })) { plan in
                    DisclosureGroup("\(plan.createdAt.formatted()) · \(plan.state.rawValue) · \(plan.operations.count) 项") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(plan.operations) { operation in
                                OFOperationRow(operation: operation)
                                ForEach(operation.journal) { entry in Text("\(entry.phase) · \(entry.detail)").font(.caption2).foregroundStyle(.secondary) }
                            }
                            if let failure = plan.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
                            Button("重新授权并恢复原位置…") { Task { await model.rollbackMove(plan) } }.disabled(model.moving)
                        }.padding(12)
                    }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(24)
        }
    }
}
struct OFOperationRow: View {
    let operation: OFMoveOperation
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(operation.source.path).textSelection(.enabled)
            Label(operation.destination.path, systemImage: "arrow.turn.down.right").textSelection(.enabled)
            Text(operation.state.rawValue).font(.caption).foregroundStyle(.secondary)
            if let failure = operation.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        }.font(.callout)
    }
}
