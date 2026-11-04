import AppKit
import Foundation
import SwiftUI

/// The organizer is lazy: opening the writing workbench never creates a replacement
/// library before the user has a chance to import their verified old snapshot.
@MainActor final class OrganizerHostController: ObservableObject {
    @Published private(set) var model: OFAppModel?
    @Published var error: String?
    @Published private(set) var importing = false
    @Published private(set) var requiresMigrationResume = false
    @Published private(set) var migrationSummary: String?
    var validateMoveSources: (([URL]) throws -> Void)?
    var isMoving: Bool { model?.moving ?? false }
    var blocksQuit: Bool { model.map{$0.moving || $0.backingUp || $0.associations?.busy == true} ?? false }
    private var opener: ((URL) -> Void)?
    static var directory: URL { FileSafety.root.appendingPathComponent("Organizer", isDirectory:true) }

    func configure(openDocument: @escaping (URL) -> Void) { opener = openDocument }
    func loadExisting() {
        guard model == nil, !importing else { return }
        if detectUnfinishedMigration() { return }
        let fm = FileManager.default
        if fm.fileExists(atPath:Self.directory.path) || fm.fileExists(atPath:FileSafety.root.appendingPathComponent("Organizer.initialized").path) { start() }
    }
    @discardableResult func start() -> OFAppModel? {
        guard !importing else { return nil }
        if let model { return model }
        if detectUnfinishedMigration() || !verifyMigrationAuthority() { return nil }
        let created = OFAppModel(openDocument:{ [weak self] url in self?.opener?(url) })
        created.validateMoveSources = { [weak self] urls in
            guard let validate=self?.validateMoveSources else {throw FileIssue.message("宿主文档保护尚未连接，不能物理整理。 ")}
            try validate(urls)
        }
        model = created
        return created
    }
    private func verifyMigrationAuthority() -> Bool {
        guard FileManager.default.fileExists(atPath:Self.directory.path) else{return true}
        do {try OrganizerMigration.requireActiveAuthority(directory:Self.directory);return true}
        catch {requiresMigrationResume=true;migrationSummary="迁移资料已保留，等待协调流程冻结来源并核验写入权切换。";self.error=error.localizedDescription;return false}
    }
    private func detectUnfinishedMigration() -> Bool {
        let fm=FileManager.default
        let marker=FileSafety.root.appendingPathComponent("Organizer.initialized")
        if fm.fileExists(atPath:marker.path) {requiresMigrationResume=false;return false}
        do {
            let entries = fm.fileExists(atPath:FileSafety.root.path) ? try fm.contentsOfDirectory(atPath:FileSafety.root.path) : []
            let hasStage=entries.contains{$0.hasPrefix(".organizer-migration-") && $0.hasSuffix(".noindex")}
            let hasReceipt=fm.fileExists(atPath:Self.directory.appendingPathComponent("MigrationLedger.json").path)
            requiresMigrationResume=hasStage || hasReceipt
            if requiresMigrationResume {migrationSummary="检测到中断的迁移，未建立空资料库。请重新选择同一核验快照继续；原资料和事务证据保留。"}
            return requiresMigrationResume
        } catch {self.error="无法核对迁移事务，未建立空资料库："+error.localizedDescription;requiresMigrationResume=true;return true}
    }
    func importSnapshotPanel() {
        guard model == nil, !importing else { error="整理资料库已打开。导入不会覆盖现有资料；请先保留并核验完整资料库，再由迁移流程处理。";return }
        let panel=NSOpenPanel();panel.title="导入搞整理核验快照";panel.message="选择由快照导出工具生成的完整目录。不会修改来源，也不会自动继承目录权限或重新应用默认关联。";panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        importing=true;error=nil
        let destination=Self.directory
        Task {
            do {
                let report=try await Task.detached(priority:.utility){try OrganizerMigration.importSnapshot(url:url,destination:destination)}.value
                importing=false
                migrationSummary="已迁移 \(report.importedRoots) 个目录、\(report.importedFiles) 个索引项。原书签与事务证据已归档；访问原件前请重新授权目录。"
                // Preparing a snapshot is not permission to create two writable
                // authorities. Only the coordinator's verified freeze/activation
                // transaction can enable the imported runtime library.
                _=start()
            } catch { importing=false;self.error=error.localizedDescription }
        }
    }
    func shutdown() { model?.shutdown() }
}

struct OrganizerHostView: View {
    @ObservedObject var host: OrganizerHostController
    let openDocument:(URL)->Void
    let goHome:()->Void
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Label("文件整理 / 查找",systemImage:"folder.badge.gearshape").font(.headline)
                Spacer()
                Button("返回写作首页",action:goHome)
            }.padding(12)
            if let summary=host.migrationSummary {Text(summary).font(.caption).foregroundStyle(.secondary).padding(.horizontal,12)}
            Divider()
            if let model=host.model { OFMainView(model:model) }
            else {
                VStack(alignment:.leading,spacing:18) {
                    Text("建立本地整理资料库").font(.title2)
                    Text("索引文件名与元数据，在虚拟工作区中分类；物理整理另有预览和确认。写作标签和未保存稿会继续保留。")
                    Text("已有搞整理资料时，先导出完整核验快照再导入。导入包括工作区、收藏、查询、关联历史和移动恢复记录；不会自动转授旧目录权限。")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("导入搞整理快照…",action:host.importSnapshotPanel).buttonStyle(.borderedProminent)
                        Button("新建整理资料库"){_=host.start()}.disabled(host.requiresMigrationResume)
                    }.disabled(host.importing)
                    if host.importing {ProgressView("正在校验和迁移，请保留来源与快照…")}
                }.frame(maxWidth:650,alignment:.leading).padding(32).frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }
        .onAppear {host.configure(openDocument:openDocument);host.loadExisting()}
        .alert("整理资料未改变",isPresented:Binding(get:{host.error != nil},set:{if !$0{host.error=nil}})){Button("好"){host.error=nil}}message:{Text(host.error ?? "")}
    }
}
