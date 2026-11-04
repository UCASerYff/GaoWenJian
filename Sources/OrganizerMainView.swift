// Organizer module port; source application is not a runtime dependency.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct OFMainView: View {
    @ObservedObject var model: OFAppModel
    var body: some View {
        Group {
            if let error = model.fatalError {
                VStack(spacing: 18) {
                    Image(systemName: "externaldrive.badge.exclamationmark").font(.system(size: 52)).foregroundStyle(.orange)
                    Text("资料需要恢复").font(.title2.bold())
                    Text(error).textSelection(.enabled).frame(maxWidth: 620)
                    Text("已停止写入。保留现有资料和初始化记录，从已核验备份恢复后重新打开应用。").foregroundStyle(.secondary)
                    HStack { Button("显示资料位置") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: OFAppLocations.directory.deletingLastPathComponent().path) }; Button("显示备份位置") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: OFAppLocations.backups.path) } }
                }.padding(40)
            } else {
                NavigationSplitView {
                    List(selection: $model.section) {
                        Section("文件") {
                            Label("快速查找", systemImage: "magnifyingglass").tag(OFAppSection.search)
                            Label("收藏", systemImage: "star").tag(OFAppSection.favorites)
                            Label("授权目录", systemImage: "folder.badge.plus").tag(OFAppSection.roots)
                        }
                        Section("虚拟工作区") {
                            ForEach(model.config.workspaces) { workspace in
                                Label(workspace.name, systemImage: "rectangle.3.group").tag(OFAppSection.workspace(workspace.id))
                                    .contextMenu { Button("重命名…") { model.renameWorkspace(workspace.id) }; Button("删除配置…", role: .destructive) { model.removeWorkspace(workspace.id) } }
                            }
                            Button { model.createWorkspace() } label: { Label("新建工作区…", systemImage: "plus") }.buttonStyle(.plain)
                        }
                        if !model.config.savedQueries.isEmpty {
                            Section("保存的查询") {
                                ForEach(model.config.savedQueries) { query in
                                    Button { model.applyQuery(query) } label: { Label(query.name, systemImage: "line.3.horizontal.decrease.circle") }
                                        .buttonStyle(.plain)
                                        .contextMenu { Button("删除查询配置", role: .destructive) { model.config.savedQueries.removeAll { $0.id == query.id }; model.saveConfig() } }
                                }
                            }
                        }
                        Section("管理") {
                            Label("默认打开方式", systemImage: "app.badge.checkmark").tag(OFAppSection.associations)
                            Label("物理整理计划", systemImage: "arrow.triangle.branch").tag(OFAppSection.moves)
                            Label("整理设置", systemImage: "slider.horizontal.3").tag(OFAppSection.settings)
                        }
                    }.listStyle(.sidebar).navigationSplitViewColumnWidth(min: 190, ideal: 215)
                } detail: {
                    VStack(spacing: 0) {
                        detail
                        Divider()
                        HStack(spacing: 8) {
                            if model.scanning { ProgressView().controlSize(.mini) }
                            Text(model.scanning ? model.scanMessage : model.status.isEmpty ? model.scanMessage : model.status).lineLimit(2).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Spacer()
                            if model.scanning { Button("取消扫描") { model.cancelScan() }.controlSize(.small) }
                        }.padding(.horizontal, 14).padding(.vertical, 9)
                    }
                }
                .onChange(of: model.section) { _, section in if section == .search || section == .favorites { model.refreshSearch() } }
                .onChange(of: model.filter) { _, _ in model.refreshSearch() }
                .disabled(model.backingUp)
                .toolbar {
                    ToolbarItem { Button { model.addRoot() } label: { Label("添加授权目录", systemImage: "folder.badge.plus") }.help("通过系统面板授权一个目录") }
                }
            }
        }.environmentObject(model)
            .preferredColorScheme(model.config.appearance == "light" ? .light : model.config.appearance == "dark" ? .dark : nil)
    }
    @ViewBuilder var detail: some View {
        switch model.section {
        case .search, .favorites: OFSearchView()
        case .roots: OFRootsView()
        case .associations: if let controller = model.associations { OFAssociationsView(controller: controller) }
        case .moves: OFMoveView()
        case .settings: OFSettingsView().environmentObject(model)
        case .workspace(let id): OFWorkspaceView(workspaceID: id)
        }
    }
}

struct OFSearchView: View {
    @EnvironmentObject var model: OFAppModel
    @State var filtersExpanded = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索名称、路径片段、类型或应用内标签", text: $model.filter.query).textFieldStyle(.plain).font(.title3).accessibilityLabel("文件搜索")
                if model.searching { ProgressView().controlSize(.small) }
                Button { filtersExpanded.toggle() } label: { Label("筛选", systemImage: "line.3.horizontal.decrease") }
                Button("保存查询…") { model.saveQuery() }
            }.padding(18)
            if filtersExpanded { OFSearchFilters().padding(.horizontal, 18).padding(.bottom, 14) }
            HStack {
                Picker("范围", selection: $model.filter.rootID) {
                    Text("全部授权目录").tag(nil as UUID?)
                    ForEach(model.roots) { Text($0.displayName).tag(Optional($0.id)) }
                }.frame(maxWidth: 280)
                Picker("排序", selection: $model.filter.sort) {
                    Text("名称").tag(OFSearchSort.name); Text("修改时间").tag(OFSearchSort.modified); Text("大小").tag(OFSearchSort.size); Text("路径").tag(OFSearchSort.path)
                }.frame(maxWidth: 200)
                Toggle("升序", isOn: $model.filter.ascending).toggleStyle(.checkbox)
                Spacer(); Text("\(model.result.totalCount) 项").foregroundStyle(.secondary).monospacedDigit()
            }.padding(.horizontal, 18).padding(.bottom, 12)
            Divider()
            if model.roots.isEmpty {
                ContentUnavailableView { Label("先选择一个目录", systemImage: "folder.badge.plus") } description: { Text("只索引你明确授权的范围。虚拟整理不改变原件位置。") } actions: { Button("添加授权目录…") { model.addRoot() }.buttonStyle(.borderedProminent) }
            } else if model.result.files.isEmpty && !model.searching {
                ContentUnavailableView("没有匹配项目", systemImage: "magnifyingglass", description: Text("调整筛选条件，或到授权目录检查扫描状态。"))
            } else {
                OFFileTable(files: model.result.files)
            }
            Divider()
            HStack {
                Button("打开") { model.openSelected() }.disabled(model.selection.isEmpty)
                Button("Finder") { model.revealSelected() }.disabled(model.selection.isEmpty)
                Menu("物理整理") {
                    Button("移动到目录 · 先预览…") { Task { await model.previewMove() } }
                    Button("重命名 · 先预览…") { Task { await model.previewMove(rename: true) } }.disabled(model.selection.count != 1)
                }.disabled(model.selection.isEmpty || model.moving)
                Spacer()
                Button { model.page -= 1; model.refreshSearch(resetPage: false) } label: { Image(systemName: "chevron.left") }.disabled(model.page == 0)
                Text("第 \(model.page + 1) 页").font(.caption).monospacedDigit()
                Button { model.page += 1; model.refreshSearch(resetPage: false) } label: { Image(systemName: "chevron.right") }.disabled((model.page + 1) * 100 >= model.result.totalCount)
            }.controlSize(.small).padding(12)
        }
    }
}
struct OFSearchFilters: View {
    @EnvironmentObject var model: OFAppModel
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                TextField("扩展名，如 pdf", text: $model.filter.extensionName)
                TextField("路径包含", text: $model.filter.pathContains)
                TextField("UTType，如 public.image", text: $model.filter.typeIdentifier)
                Picker("项目", selection: $model.filter.kind) { Text("全部").tag(OFSearchKind.all); Text("文件").tag(OFSearchKind.files); Text("目录").tag(OFSearchKind.folders) }.frame(width: 160)
            }
            GridRow {
                TextField("最小字节数", value: $model.filter.minSize, format: .number)
                TextField("最大字节数", value: $model.filter.maxSize, format: .number)
                TextField("应用内标签", text: $model.filter.tag)
                Button("清除筛选") { let q = model.filter.query; model.filter = OFSearchFilter(query: q) }
            }
            GridRow {
                OFOptionalDatePicker(title: "修改自", date: $model.filter.modifiedAfter)
                OFOptionalDatePicker(title: "修改至", date: $model.filter.modifiedBefore)
                Toggle("仅收藏", isOn: $model.filter.favoritesOnly).toggleStyle(.checkbox)
                Text("组合 Unicode 与大小写归一化；引号和空格按普通文本匹配。").font(.caption2).foregroundStyle(.secondary)
            }
        }.textFieldStyle(.roundedBorder).controlSize(.small)
    }
}
struct OFOptionalDatePicker: View {
    let title: String
    @Binding var date: Date?
    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(get: { date != nil }, set: { date = $0 ? Date() : nil })).toggleStyle(.checkbox)
            if date != nil { DatePicker("", selection: Binding(get: { date ?? Date() }, set: { date = $0 }), displayedComponents: .date).labelsHidden() }
        }
    }
}
struct OFFileTable: View {
    @EnvironmentObject var model: OFAppModel
    var files: [OFIndexedFile]
    var body: some View {
        Table(files, selection: $model.selection) {
            TableColumn("名称") { file in
                HStack(spacing: 8) {
                    Image(systemName: file.isSymbolicLink ? "link" : file.isDirectory ? "folder" : "doc").foregroundStyle(file.isDirectory ? Color.accentColor : .secondary)
                    Text(file.name).lineLimit(1)
                    if file.favorite { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                    if file.isCloudPlaceholder { Image(systemName: "icloud.and.arrow.down").help("仅有元数据，打开可能需要下载") }
                }.contextMenu { OFFileActions(file: file) }
                    .onTapGesture(count: 2) { model.openFile(file) }
                    .onDrag { fileProvider(file) }
            }.width(min: 180, ideal: 250)
            TableColumn("路径") { file in Text(file.relativePath).lineLimit(1).foregroundStyle(.secondary).help(file.relativePath).contextMenu { OFFileActions(file: file) } }.width(min: 180, ideal: 320)
            TableColumn("大小") { file in Text(file.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).monospacedDigit() }.width(85)
            TableColumn("修改时间") { file in Text(file.modifiedAt, format: .dateTime.year().month().day().hour().minute()).font(.caption) }.width(135)
            TableColumn("标签") { file in Text(file.userTags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }.width(min: 70, ideal: 100)
        }
    }
    func fileProvider(_ file: OFIndexedFile) -> NSItemProvider {
        do { let url = try model.index!.verifiedURL(for: file); return NSItemProvider(object: url as NSURL) }
        catch { model.status = error.localizedDescription; return NSItemProvider() }
    }
}
struct OFFileActions: View {
    @EnvironmentObject var model: OFAppModel
    let file: OFIndexedFile
    var body: some View {
        Button("打开") { model.openFile(file) }
        Button("在 Finder 显示") { model.action(file, allowSymbolicLink: true) { NSWorkspace.shared.activateFileViewerSelecting([$0]) } }
        Button("复制路径") { model.action(file) { url in NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) } }
        Divider()
        Button(file.favorite ? "取消收藏" : "收藏") { model.favorite(file) }
        Button("编辑应用内标签…") { model.tag(file) }
        Button("管理此类型默认应用") { model.associations?.mode = "type"; model.associations?.identifier = file.typeIdentifier; model.associations?.refresh(); model.section = .associations }
    }
}

struct OFRootsView: View {
    @EnvironmentObject var model: OFAppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { VStack(alignment: .leading) { Text("授权目录").font(.title2.bold()); Text("仅扫描所选范围；链接不跟随，包视为整体，隐藏与敏感目录排除。").foregroundStyle(.secondary) }; Spacer(); Button("添加目录…") { model.addRoot() } }
            if model.roots.isEmpty { ContentUnavailableView("没有授权目录", systemImage: "folder") }
            List(model.roots) { root in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Image(systemName: "folder").foregroundStyle(.tint); Text(root.displayName).font(.headline); Spacer(); Text(root.isPaused ? "已暂停" : root.status).font(.caption).foregroundStyle(.secondary) }
                    Text(root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let diagnostic = root.diagnostic { Text(diagnostic).font(.caption).foregroundStyle(.orange) }
                    HStack {
                        Button("扫描 / 续扫") { model.queueScan(root.id) }.disabled(root.isPaused)
                        if root.status == "interrupted" { Button("放弃检查点并重扫") { model.restartScan(root) } }
                        Button(root.isPaused ? "恢复监听" : "暂停监听") { model.pause(root) }
                        Button("重新授权…") { model.addRoot(suggested: URL(fileURLWithPath: root.path)) }
                        Button("移除索引…", role: .destructive) { model.removeRoot(root) }
                        Spacer(); if let date = root.lastScanAt { Text(date, format: .dateTime).font(.caption2) }
                    }.controlSize(.small)
                }.padding(.vertical, 8)
            }.listStyle(.inset)
            Text("索引只用于已明确授权的本机目录。失效书签、权限拒绝、根目录与卷身份变化会停止访问并给出诊断，不扩展到上级目录。").font(.caption).foregroundStyle(.secondary)
        }.padding(22)
    }
}
