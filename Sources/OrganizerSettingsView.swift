// Organizer module port; source application is not a runtime dependency.
import SwiftUI
import AppKit

struct OFSettingsView: View {
    @EnvironmentObject var model: OFAppModel
    var body: some View {
        Form {
            Section("目录索引") {
                Toggle("监听已授权目录的变更提示", isOn: $model.config.automaticMonitoring)
                    .onChange(of: model.config.automaticMonitoring) { _, _ in model.saveConfig(); model.configureMonitor() }
                Text("系统变更提示到达后，由安全扫描核对。退出程序时停止监听；每个授权目录可单独暂停。")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("文件正文", value: "不读取，不主动下载云端占位文件")
                LabeledContent("物理整理", value: "先预览、再确认，重名不覆盖")
            }
            Section("整理区外观") {
                Picker("主题", selection: $model.config.appearance) {
                    Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                }.onChange(of: model.config.appearance) { _, _ in model.saveConfig() }
            }
            Section("现用资料") {
                Text(OFAppLocations.directory.path).font(.caption.monospaced()).textSelection(.enabled)
                Button("在 Finder 中显示资料") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: OFAppLocations.directory.path)
                }
                Text("索引、授权书签、收藏、工作区、关联记录与整理日志保存在这里。缺库、摘要不符或格式过新时会停止写入；不要删除初始化标记来重置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).tint(WorkspaceStyle.accent)
    }
}
