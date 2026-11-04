// Organizer module port; source application is not a runtime dependency.
import SwiftUI
import AppKit

struct OFSettingsView: View {
    @EnvironmentObject var model: OFAppModel
    var body: some View {
        TabView {
            Form {
                Toggle("监听已授权目录的变更提示", isOn: $model.config.automaticMonitoring).onChange(of: model.config.automaticMonitoring) { _, _ in model.saveConfig(); model.configureMonitor() }
                Text("FSEvents 仅提示可能发生变化，随后由安全扫描核对。退出程序时停止监听；授权目录可单独暂停。").font(.caption).foregroundStyle(.secondary)
                LabeledContent("文件内容", value: "索引不读取正文，不主动下载占位文件")
                LabeledContent("物理整理", value: "每次预览与单独确认，默认不覆盖")
                LabeledContent("打开文档", value: "由搞文件编辑器处理，保留已有标签和未保存内容")
                Text("添加目录使用整理工具栏。默认打开方式在主窗口“默认打开方式”管理。").foregroundStyle(.secondary)
            }.padding(24).tabItem { Label("功能", systemImage: "switch.2") }
            Form {
                Picker("外观", selection: $model.config.appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }.onChange(of: model.config.appearance) { _, _ in model.saveConfig() }
                Text("使用系统原生表格、侧栏和快捷键。工作区面板可折叠、暂停、排序。").foregroundStyle(.secondary)
            }.padding(24).tabItem { Label("外观", systemImage: "circle.lefthalf.filled") }
            VStack(alignment: .leading, spacing: 16) {
                Text("本地资料与恢复").font(.headline)
                Text(OFAppLocations.directory.path).font(.caption).textSelection(.enabled)
                Text("备份包含索引、授权书签、配置、关联历史、整理日志及迁移原始归档，含敏感元数据，请妥善保管。核验备份不会上传到 GitHub。").foregroundStyle(.secondary)
                HStack {
                    Button("创建核验备份") { Task { await model.createBackup() } }.disabled(model.backingUp || model.moving)
                    Button("显示资料") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: OFAppLocations.directory.path) }
                    Button("显示备份") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: OFAppLocations.backups.path) }
                }
                Text("恢复时先退出程序，保留当前资料，将完整核验备份将备份 Data 恢复到 Organizer 目录，同时将备份根 Organizer.initialized 恢复到搞文件资料根；保留同一钥匙串与签名。缺库、摘要不符或过新格式会停止写入。不要删除初始化标记来重置。").font(.caption).foregroundStyle(.secondary)
                Text(model.status).font(.caption).textSelection(.enabled)
                if model.backingUp { ProgressView("正在创建并核对备份…") }
                Spacer()
            }.padding(24).tabItem { Label("数据", systemImage: "externaldrive") }
        }.disabled(model.backingUp)
    }
}
