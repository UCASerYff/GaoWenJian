// Organizer module port; source application is not a runtime dependency.
import SwiftUI

struct OFWorkspaceView: View {
    @EnvironmentObject var model: OFAppModel
    let workspaceID: UUID
    var workspace: OFVirtualWorkspace? { model.config.workspaces.first { $0.id == workspaceID } }
    var body: some View {
        if let workspace {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) { Text(workspace.name).font(.title2.bold()); Text("目录与查询映射成面板，原件保留在原位置。").foregroundStyle(.secondary) }
                    Spacer()
                    Menu("添加面板") {
                        Menu("映射授权目录") { ForEach(model.roots) { root in Button(root.displayName) { model.addPanel(workspaceID: workspaceID, kind: "directory", root: root) } } }
                        Button("使用当前查询") { model.addPanel(workspaceID: workspaceID, kind: "query") }
                        Button("收藏面板") { model.addPanel(workspaceID: workspaceID, kind: "favorites") }
                    }
                }
                if workspace.panels.isEmpty {
                    ContentUnavailableView("添加第一个面板", systemImage: "rectangle.badge.plus", description: Text("可组合多个目录、当前查询或收藏。拖入文件会先让你明确授权其目录，不会搬动文件。"))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), alignment: .top)], alignment: .leading, spacing: 16) {
                            ForEach(workspace.panels) { panel in OFWorkspacePanelView(workspaceID: workspaceID, panel: panel) }
                        }
                    }
                }
            }.padding(22)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    guard let first = providers.first else { return false }
                    _ = first.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in model.addRoot(suggested: url.hasDirectoryPath ? url : url.deletingLastPathComponent()) } }
                    }
                    return true
                }
        } else { ContentUnavailableView("工作区配置已移除", systemImage: "rectangle.3.group") }
    }
}
struct OFWorkspacePanelView: View {
    @EnvironmentObject var model: OFAppModel
    let workspaceID: UUID
    let panel: OFVirtualPanel
    @State private var files: [OFIndexedFile] = []
    @State private var count = 0
    @State private var error: String?
    private var filter: OFSearchFilter {
        var f = panel.filter ?? OFSearchFilter()
        f.rootID = panel.rootID; f.query = panel.query; f.extensionName = panel.extensionName; f.sort = OFSearchSort(rawValue: panel.sort) ?? .name; f.ascending = panel.ascending
        if panel.kind == "favorites" { f.favoritesOnly = true }
        return f
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { edit { $0.collapsed.toggle() } } label: { Image(systemName: panel.collapsed ? "chevron.right" : "chevron.down") }.buttonStyle(.plain)
                Text(panel.name).font(.headline).lineLimit(1)
                Spacer()
                Text(panel.paused ? "暂停" : "\(count) 项").foregroundStyle(.secondary).font(.caption)
                Menu {
                    Button("重命名…") { if let name = ofAskText(title: "面板显示名", message: "", initial: panel.name) { edit { $0.name = name } } }
                    Button("修改查询…") { if let text = ofAskText(title: "面板查询", message: "修改虚拟匹配规则，不改变原件。", initial: panel.query) { edit { $0.query = text } } }
                    Button("修改扩展名筛选…") { if let text = ofAskText(title: "扩展名", message: "例如 pdf；输入 * 表示全部。", initial: panel.extensionName) { edit { $0.extensionName = text == "*" ? "" : text } } }
                    Menu("排序") { Button("名称") { edit { $0.sort = "name" } }; Button("修改时间") { edit { $0.sort = "modified" } }; Button("大小") { edit { $0.sort = "size" } }; Button("反转顺序") { edit { $0.ascending.toggle() } } }
                    Button(panel.paused ? "恢复规则" : "暂停规则") { edit { $0.paused.toggle() } }
                    Button("向前排列") { model.movePanel(workspaceID: workspaceID, panelID: panel.id, direction: -1) }
                    Button("向后排列") { model.movePanel(workspaceID: workspaceID, panelID: panel.id, direction: 1) }
                    Divider(); Button("删除面板配置", role: .destructive) { model.removePanel(workspaceID: workspaceID, panelID: panel.id) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }
            if !panel.collapsed {
                Text(panel.kind == "directory" ? "目录映射" : panel.kind == "favorites" ? "应用内收藏" : "查询：\(panel.query.isEmpty ? "全部项目" : panel.query)").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                if panel.paused { Text("已暂停规则计算，恢复后刷新。").foregroundStyle(.secondary).padding(.vertical, 12) }
                else if files.isEmpty { Text("暂无匹配项目").foregroundStyle(.secondary).padding(.vertical, 12) }
                else {
                    ForEach(files.prefix(12)) { file in
                        HStack {
                            Image(systemName: file.isDirectory ? "folder" : file.isSymbolicLink ? "link" : "doc").foregroundStyle(.secondary)
                            Text(file.name).lineLimit(1); Spacer()
                            if file.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                        }.padding(.vertical, 4).contentShape(Rectangle()).onTapGesture(count: 2) { model.openFile(file) }.contextMenu { OFFileActions(file: file) }
                    }
                }
                Button("在查找中查看全部") { model.filter = filter; model.section = .search; model.refreshSearch() }.controlSize(.small)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .task(id: "\(model.dataRevision)-\(panel.id)") { await load() }
    }
    func edit(_ body: (inout OFVirtualPanel) -> Void) { model.editPanel(workspaceID: workspaceID, panelID: panel.id, action: body) }
    func load() async {
        guard !panel.paused, let index = model.index else { return }
        let f = filter
        do { let result = try await Task.detached { try index.search(f, pageSize: 12) }.value; guard !Task.isCancelled else { return }; files = result.files; count = result.totalCount; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
