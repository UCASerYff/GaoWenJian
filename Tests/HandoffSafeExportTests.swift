import Foundation
import Darwin

enum HandoffSafeExportTests {
    /// Pure file-system regression: no NSApplication, windows, real documents or providers.
    static func run(in parent: URL) throws {
        let fm = FileManager.default
        let root = parent.appendingPathComponent("SafeExport-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let history = root.appendingPathComponent("history", isDirectory: true)
        let bytes = Data(("中文 e\u{301} 😀\r\n第二页\u{000C}\n" + String(repeating: "abcdef", count: 40_000)).utf8)
        let original = root.appendingPathComponent("源 文件.txt")
        try bytes.write(to: original, options: .withoutOverwriting)
        let beforeDate = try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw FileIssue.message("安全导出测试失败：" + label) }; checks += 1
        }
        func rejects(_ label: String, _ action: () throws -> Void) throws {
            var refused = false
            do { try action() } catch { refused = true }
            try check(refused, label)
        }
        func write(_ name: String, _ content: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(content.utf8).write(to: url, options: .withoutOverwriting)
            return url
        }
        func export(_ target: URL, _ overwrite: HandoffSafeExport.Overwrite = .rejectExisting,
                    hooks: HandoffSafeExport.Hooks = .none) throws -> HandoffSafeExport.Receipt {
            try HandoffSafeExport.copy(source: original, to: target, overwrite: overwrite,
                                       snapshotRoot: history, hooks: hooks)
        }
        func noStages(_ folder: URL = root) throws {
            let found = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".gaowenjian-export-") }
            try check(found.isEmpty, "失败或成功后无未归属同目录暂存")
        }

        let output = root.appendingPathComponent("新 副本.txt")
        let receipt = try export(output)
        try check(try Data(contentsOf: output) == bytes, "完整Unicode/换行/页分隔按原字节复制")
        try check(receipt.sha256 == FileSafety.digest(bytes) && receipt.byteCount == Int64(bytes.count), "回执摘要与长度正确")
        try check(receipt.snapshotURL == nil, "新文件无伪造快照")
        try check(try mode(output) == 0o600, "副本0600")
        try noStages()

        try rejects("完全相同路径拒绝") { _ = try export(original) }
        let dotted = root.appendingPathComponent("dummy/../" + original.lastPathComponent)
        try rejects("规范路径等价拒绝") { _ = try export(dotted) }
        let hardlink = root.appendingPathComponent("硬链接.txt")
        try fm.linkItem(at: original, to: hardlink)
        try rejects("同inode硬链接拒绝") { _ = try export(hardlink, .replace(expectedSHA256: FileSafety.digest(bytes))) }
        let symlink = root.appendingPathComponent("符号链接.txt")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: original)
        try rejects("符号链接指向源拒绝") { _ = try export(symlink) }
        let alias = root.appendingPathComponent("Finder别名")
        let bookmark = try original.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        try rejects("Finder别名指向源拒绝") { _ = try export(alias) }
        let aliasCopy = root.appendingPathComponent("从别名读取.txt")
        _ = try HandoffSafeExport.copy(source: alias, to: aliasCopy, snapshotRoot: history)
        try check(try Data(contentsOf: aliasCopy) == bytes, "作为源的Finder别名解析到普通文件")
        let directoryLink = root.appendingPathComponent("目录符号链接")
        try fm.createSymbolicLink(at: directoryLink, withDestinationURL: root)
        try rejects("目录符号链接下的同源拒绝") { _ = try export(directoryLink.appendingPathComponent(original.lastPathComponent)) }
        let privateSourceCopy = root.appendingPathComponent("已发出的私有快照.txt")
        try fm.copyItem(at: original, to: privateSourceCopy)
        let directoryAlias = root.appendingPathComponent("Finder目录别名")
        try URL.writeBookmarkData(try root.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil), to: directoryAlias)
        for protectedDestination in [original, dotted, hardlink, symlink, alias,
                                     directoryLink.appendingPathComponent(original.lastPathComponent),
                                     directoryAlias.appendingPathComponent(original.lastPathComponent)] {
            try rejects("私有快照导出仍拒绝原件位置/链接：\(protectedDestination.lastPathComponent)") {
                _ = try HandoffSafeExport.copy(source: privateSourceCopy, to: protectedDestination, protectedOriginal: original,
                                               overwrite: .replace(expectedSHA256: FileSafety.digest(bytes)), snapshotRoot: history)
            }
            try check(try Data(contentsOf: original) == bytes, "独立快照导出不能改写受保护原件")
        }
        let protectedCopyOutput = root.appendingPathComponent("受保护导出新文件.txt")
        _ = try HandoffSafeExport.copy(source: privateSourceCopy, to: protectedCopyOutput, protectedOriginal: original, snapshotRoot: history)
        try check(try Data(contentsOf: protectedCopyOutput) == bytes, "受保护原件不阻止导出独立新副本")
        let deletedOriginal = try write("已删除原件.txt", "deleted original")
        let deletedOriginalCopy = try write("已删除原件的私有快照.txt", "deleted original")
        try fm.removeItem(at: deletedOriginal)
        for oldLocation in [deletedOriginal, directoryLink.appendingPathComponent(deletedOriginal.lastPathComponent),
                            directoryAlias.appendingPathComponent(deletedOriginal.lastPathComponent)] {
            try rejects("原件删除后仍拒绝在其旧位置导出") {
                _ = try HandoffSafeExport.copy(source: deletedOriginalCopy, to: oldLocation, protectedOriginal: deletedOriginal, snapshotRoot: history)
            }
            try check(!fm.fileExists(atPath: deletedOriginal.path), "已删除原件不被静默重建")
        }
        let deletedCase = try write("deleted-case-original.txt", "case-sensitive fixture")
        try fm.removeItem(at: deletedCase)
        if (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) != true {
            let variant = root.appendingPathComponent("DELETED-CASE-ORIGINAL.TXT")
            try rejects("大小写不敏感卷保护已删除原件的大小写等价旧位置") {
                _ = try HandoffSafeExport.copy(source: deletedOriginalCopy, to: variant, protectedOriginal: deletedCase, snapshotRoot: history)
            }
            try check(!fm.fileExists(atPath: variant.path), "大小写变体旧位置仍不存在")
        }
        let fifo = root.appendingPathComponent("命名管道.txt")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw FileIssue.message("无法创建隔离FIFO") }
        try rejects("FIFO快速拒绝且不阻塞") { _ = try HandoffSafeExport.copy(source: fifo, to: root.appendingPathComponent("fifo-out.txt"), snapshotRoot: history) }

        let existing = try write("已有目标.txt", "original target\n")
        let oldBytes = try Data(contentsOf: existing)
        let oldHash = FileSafety.digest(oldBytes)
        try rejects("已有目标默认冲突") { _ = try export(existing) }
        try check(try Data(contentsOf: existing) == oldBytes, "冲突不删除已有目标")
        try rejects("覆盖摘要不符拒绝") { _ = try export(existing, .replace(expectedSHA256: String(repeating: "0", count: 64))) }
        try check(try Data(contentsOf: existing) == oldBytes, "摘要冲突保留目标")
        let overwritten = try export(existing, .replace(expectedSHA256: oldHash))
        guard let snapshot = overwritten.snapshotURL else { throw FileIssue.message("缺原件快照") }
        try check(try Data(contentsOf: existing) == bytes, "显式覆盖以完整副本原子提交")
        try check(try Data(contentsOf: snapshot) == oldBytes, "覆盖前原件完整快照校验")
        try check(try mode(snapshot) == 0o600 && mode(snapshot.deletingLastPathComponent()) == 0o700, "快照及文件夹私有权限")
        try noStages()
        let absent = root.appendingPathComponent("已删除目标.txt")
        try rejects("覆盖意图目标已失踪不静默重建") { _ = try export(absent, .replace(expectedSHA256: oldHash)) }
        try check(!fm.fileExists(atPath: absent.path), "已删除目标保持不存在")
        let other = try write("其他原件.txt", "untouched\n")
        let otherLink = root.appendingPathComponent("其他原件符号链接.txt")
        try fm.createSymbolicLink(at: otherLink, withDestinationURL: other)
        try rejects("不替换其他文件符号链接") { _ = try export(otherLink, .replace(expectedSHA256: FileSafety.digest(Data("untouched\n".utf8)))) }
        try check(try String(contentsOf: other) == "untouched\n", "其他符号链接目标保持")
        let otherAlias = root.appendingPathComponent("其他原件别名")
        try URL.writeBookmarkData(try other.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil), to: otherAlias)
        try rejects("不替换其他文件Finder别名") { _ = try export(otherAlias, .replace(expectedSHA256: FileSafety.digest(Data("untouched\n".utf8)))) }

        for code in [EACCES, ENOSPC, EIO] {
            let target = try write("写入故障-\(code).txt", "keep this target")
            let old = try Data(contentsOf: target)
            let hooks = HandoffSafeExport.Hooks { phase, progress in
                if phase == .beforeWrite && (code != EIO || progress > 0) { throw HandoffSafeExport.Failure.io(code) }
            }
            try rejects("真实流复制注入错误\(code)") { _ = try export(target, .replace(expectedSHA256: FileSafety.digest(old)), hooks: hooks) }
            try check(try Data(contentsOf: target) == old, "写入故障\(code)保持原目标")
            try check(try Data(contentsOf: original) == bytes, "写入故障\(code)保持源")
            try noStages()
        }
        let failedNew = root.appendingPathComponent("新副本磁盘满.txt")
        try rejects("新文件写入中途磁盘满") {
            _ = try export(failedNew, hooks: .init { phase, progress in
                if phase == .beforeWrite && progress > 0 { throw HandoffSafeExport.Failure.io(ENOSPC) }
            })
        }
        try check(!fm.fileExists(atPath: failedNew.path), "中途磁盘满不留下半份公开副本")
        try noStages()

        let readonlyFolder = root.appendingPathComponent("只读目录", isDirectory: true)
        try fm.createDirectory(at: readonlyFolder, withIntermediateDirectories: false)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readonlyFolder.path)
        if geteuid() != 0 {
            try rejects("真实目录权限拒绝") { _ = try export(readonlyFolder.appendingPathComponent("禁止写.txt")) }
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readonlyFolder.path)

        let lateTarget = root.appendingPathComponent("并发创建.txt")
        try rejects("暂存后目标被创建时拒绝") {
            _ = try export(lateTarget, hooks: .init { phase, _ in
                if phase == .beforeCommit { try Data("external created".utf8).write(to: lateTarget, options: .withoutOverwriting) }
            })
        }
        try check(try String(contentsOf: lateTarget) == "external created", "并发新目标未被覆盖")
        try noStages()
        let lateChanged = try write("并发修改.txt", "baseline")
        let baseline = FileSafety.digest(Data("baseline".utf8))
        try rejects("快照后目标内容被改时拒绝") {
            _ = try export(lateChanged, .replace(expectedSHA256: baseline), hooks: .init { phase, _ in
                if phase == .beforeCommit { try Data("external newer".utf8).write(to: lateChanged) }
            })
        }
        try check(try String(contentsOf: lateChanged) == "external newer", "并发修改目标保留最新外部内容")
        try noStages()
        let lateReplaced = try write("并发替换.txt", "baseline")
        try rejects("目标同名不同inode替换时拒绝") {
            _ = try export(lateReplaced, .replace(expectedSHA256: baseline), hooks: .init { phase, _ in
                if phase == .beforeCommit { try Data("external replacement".utf8).write(to: lateReplaced, options: .atomic) }
            })
        }
        try check(try String(contentsOf: lateReplaced) == "external replacement", "并发新inode目标保留")
        try noStages()

        let movingParent = root.appendingPathComponent("移动目录", isDirectory: true)
        let movedParent = root.appendingPathComponent("目录旧址", isDirectory: true)
        try fm.createDirectory(at: movingParent, withIntermediateDirectories: false)
        let movedTarget = movingParent.appendingPathComponent("副本.txt")
        try rejects("提交前目标目录同名换inode时拒绝") {
            _ = try export(movedTarget, hooks: .init { phase, _ in
                if phase == .beforeCommit {
                    try fm.moveItem(at: movingParent, to: movedParent)
                    try fm.createDirectory(at: movingParent, withIntermediateDirectories: false)
                    try Data("new directory file".utf8).write(to: movedTarget, options: .withoutOverwriting)
                }
            })
        }
        try check(try String(contentsOf: movedTarget) == "new directory file", "目录身份变化不写新目录")
        try noStages(movingParent); try noStages(movedParent)

        let failureAfterSnapshot = try write("快照后失败.txt", "snapshot original")
        let failureHash = FileSafety.digest(Data("snapshot original".utf8))
        let historyBefore = try snapshotFiles(history)
        try rejects("快照之后故障停止提交") {
            _ = try export(failureAfterSnapshot, .replace(expectedSHA256: failureHash), hooks: .init { phase, _ in
                if phase == .afterSnapshot { throw HandoffSafeExport.Failure.io(EIO) }
            })
        }
        try check(try String(contentsOf: failureAfterSnapshot) == "snapshot original", "快照后故障目标保持")
        let addedSnapshots = try snapshotFiles(history).subtracting(historyBefore)
        try check(addedSnapshots.count == 1, "提交失败仍保留校验过快照")
        try check(try Data(contentsOf: addedSnapshots.first!) == Data("snapshot original".utf8), "失败快照内容完整")
        try noStages()

        let sourceChanging = try write("可变源.txt", "original")
        let sourceChangingTarget = root.appendingPathComponent("源变化不导出.txt")
        try rejects("源在暂存后修改时拒绝") {
            _ = try HandoffSafeExport.copy(source: sourceChanging, to: sourceChangingTarget, snapshotRoot: history, hooks: .init { phase, _ in
                if phase == .afterCopy { try Data("new source content".utf8).write(to: sourceChanging) }
            })
        }
        try check(!fm.fileExists(atPath: sourceChangingTarget.path), "变化的源不发布过期副本")
        try check(try String(contentsOf: sourceChanging) == "new source content", "保留外部更新源")
        let sourceReplaced = try write("同名换源.txt", "original")
        try rejects("源被同名换inode时拒绝") {
            _ = try HandoffSafeExport.copy(source: sourceReplaced, to: root.appendingPathComponent("不导出换源.txt"), snapshotRoot: history,
                                           hooks: .init { phase, _ in if phase == .beforeCommit { try Data("replacement".utf8).write(to: sourceReplaced, options: .atomic) } })
        }
        try check(try String(contentsOf: sourceReplaced) == "replacement", "同名换源保持外部新内容")
        try noStages()
        let replacedStageTarget = root.appendingPathComponent("暂存换inode不导出.txt")
        var replacementStage: URL?
        try rejects("暂存路径被第三方替换时拒绝且不误删") {
            _ = try export(replacedStageTarget, hooks: .init { phase, _ in
                if phase == .afterCopy {
                    let stages = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                        .filter { $0.lastPathComponent.hasPrefix(".gaowenjian-export-") }
                    guard let stage = stages.first else { throw FileIssue.message("缺暂存fixture") }
                    try fm.moveItem(at: stage, to: root.appendingPathComponent("移动过的自建暂存.tmp"))
                    try Data("foreign replacement".utf8).write(to: stage, options: .withoutOverwriting)
                    replacementStage = stage
                }
            })
        }
        try check(!fm.fileExists(atPath: replacedStageTarget.path), "第三方换暂存不提交")
        try check(try String(contentsOf: replacementStage!) == "foreign replacement", "清理不删除被换成第三方inode的暂存路径")
        // The test owns this foreign fixture; production deliberately leaves unfamiliar objects alone.
        try fm.removeItem(at: replacementStage!)
        try noStages()
        try rejects("有界复制在打开普通文件后检查体积") {
            _ = try HandoffSafeExport.copy(source: original, to: root.appendingPathComponent("超限不导出.txt"), snapshotRoot: history, maximumBytes: 1)
        }
        try check(try Data(contentsOf: original) == bytes, "所有导出和失败不改写源")
        try check(try original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == beforeDate, "源修改时间保持")
        try noStages()
        print("PASS: safe handoff export \(checks) checks; source/alias/hard-link identity, atomic new/overwrite, verified snapshots, directory/target/source races, EACCES/ENOSPC/EIO and partial-copy preservation")
    }

    private static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
    private static func snapshotFiles(_ root: URL) throws -> Set<URL> {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { throw FileIssue.message("快照枚举失败") }
        return Set(try enumerator.compactMap { object -> URL? in
            guard let url = object as? URL else { return nil }
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true ? url : nil
        })
    }
}
