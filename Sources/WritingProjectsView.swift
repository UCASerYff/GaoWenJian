import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WritingProjectsWorkspace: View {
    @ObservedObject var store: WorkspaceStore
    @State private var configuration: WritingProjectConfiguration?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ViewThatFits(in: .horizontal) {
                    HStack { heading; Spacer(); actions }
                    VStack(alignment: .leading, spacing: 8) { heading; actions }
                }
                if let error = store.writingProjectError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if !store.unavailableProjectFiles.isEmpty { unavailableFiles }
                if store.writingProjects.projects.isEmpty {
                    ContentUnavailableView("暂无写作项目", systemImage: "folder",
                                           description: Text("打开文稿和校样后，新建项目保存当前会话。"))
                        .frame(minHeight: 180)
                } else {
                    ForEach(store.writingProjects.projects) { project in projectRow(project) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(WorkspaceStyle.canvas)
        .sheet(item: $configuration) { item in
            WritingProjectConfigurationView(store: store, configuration: item)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("写作项目").font(.title2.weight(.semibold))
            Text("保存项目目录、主文件、打开的文档和 PDF 阅读位置。").foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            if store.currentWritingProject != nil {
                Button("保存项目会话") {
                    NSApp?.keyWindow?.makeFirstResponder(nil)
                    do {
                        try store.checkpointWritingProject()
                        store.status = "项目会话已保存"
                    } catch { store.error = error.localizedDescription }
                }
            }
            Button { configuration = .init(project: nil, folder: store.folder, active: store.active?.url) } label: {
                Label("新建项目", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.writingProjectError != nil)
        }
    }

    private var unavailableFiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("有 \(store.unavailableProjectFiles.count) 项无法打开，已有草稿已保留", systemImage: "exclamationmark.triangle")
                .font(.headline).foregroundStyle(.orange)
            ForEach(store.unavailableProjectFiles) { file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: file.path).lastPathComponent).font(.subheadline.weight(.semibold))
                    Text(file.reason).font(.caption).foregroundStyle(.secondary)
                }.help(file.path)
            }
            if let id = store.activeWritingProjectID {
                Button("重新检查文件") { store.promptToRestoreWritingProject(id) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func projectRow(_ project: WritingProject) -> some View {
        let isCurrent = project.id == store.activeWritingProjectID
        return ViewThatFits(in: .horizontal) {
            HStack { projectDescription(project); Spacer(); projectActions(project, isCurrent: isCurrent) }
            VStack(alignment: .leading, spacing: 8) {
                projectDescription(project)
                projectActions(project, isCurrent: isCurrent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(isCurrent ? WorkspaceStyle.accent : WorkspaceStyle.line) }
    }

    private func projectDescription(_ project: WritingProject) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder").foregroundStyle(WorkspaceStyle.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.headline)
                Text(project.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(project.folder)
                Text("\(URL(fileURLWithPath: project.main).lastPathComponent) · \(project.documents.count) 项会话记录")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func projectActions(_ project: WritingProject, isCurrent: Bool) -> some View {
        HStack {
            if isCurrent {
                Button("项目设置") { configuration = .init(project: project, folder: nil, active: nil) }
                if let tab = store.active { Button("返回文档") { store.select(tab) } }
            } else {
                Button("打开项目") { store.promptToRestoreWritingProject(project.id) }
            }
        }
    }
}

private struct WritingProjectConfiguration: Identifiable {
    let id = UUID()
    let projectID: UUID?
    var name: String
    var folder: String
    var main: String

    init(project: WritingProject?, folder: URL?, active: URL?) {
        projectID = project?.id
        let selectedFolder = project?.folder ?? folder?.path ?? active?.deletingLastPathComponent().path ?? ""
        self.folder = selectedFolder
        name = project?.name ?? folder?.lastPathComponent ?? ""
        let selectedMain = active.flatMap { WritingProjectPaths.isMain($0.path) && WritingProjectPaths.contains($0.path, in: selectedFolder) ? $0.path : nil }
        main = project?.main ?? selectedMain ?? ""
    }
}

private struct WritingProjectConfigurationView: View {
    @ObservedObject var store: WorkspaceStore
    @State var configuration: WritingProjectConfiguration
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(store: WorkspaceStore, configuration: WritingProjectConfiguration) {
        self.store = store
        _configuration = State(initialValue: configuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(configuration.projectID == nil ? "新建写作项目" : "项目设置").font(.headline)
            TextField("项目名称", text: $configuration.name)
            HStack {
                TextField("项目目录", text: $configuration.folder)
                Button("选择目录…", action: chooseFolder)
            }
            HStack {
                TextField("Markdown 或 LaTeX 主文件", text: $configuration.main)
                Button("选择文件…", action: chooseMain)
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存项目会话", action: save).keyboardShortcut(.defaultAction)
                    .disabled(configuration.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || configuration.folder.isEmpty || configuration.main.isEmpty)
            }
        }.padding(22).frame(minWidth: 470, idealWidth: 560)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.title = "选择项目目录"
        if !configuration.folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: configuration.folder, isDirectory: true) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        configuration.folder = url.path
        if configuration.name.isEmpty { configuration.name = url.lastPathComponent }
    }

    private func chooseMain() {
        let panel = NSOpenPanel()
        panel.title = "选择 Markdown 或 LaTeX 主文件"
        panel.allowedContentTypes = ["md", "markdown", "tex"].compactMap { UTType(filenameExtension: $0) }
        if !configuration.folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: configuration.folder, isDirectory: true) }
        if panel.runModal() == .OK, let url = panel.url { configuration.main = url.path }
    }

    private func save() {
        do {
            try store.saveWritingProject(id: configuration.projectID, name: configuration.name, folder: configuration.folder, main: configuration.main)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
