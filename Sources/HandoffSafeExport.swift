import Foundation
import CryptoKit
import Darwin

/// Exports a normal file without ever deleting a user-selected destination first.
/// Existing destinations require an explicit digest captured when overwrite was approved.
enum HandoffSafeExport {
    enum Overwrite {
        case rejectExisting
        case replace(expectedSHA256: String)
    }
    enum Phase { case beforeRead, beforeWrite, afterCopy, afterSnapshot, beforeCommit }
    struct Hooks {
        var check: (Phase, Int64) throws -> Void = { _, _ in }
        static let none = Hooks()
    }
    struct Receipt {
        let destination: URL
        let sha256: String
        let byteCount: Int64
        let snapshotURL: URL?
    }
    enum Failure: LocalizedError {
        case sameFile, conflict, changed, invalidFile, tooLarge, io(Int32), recoveryRequired(URL)
        var errorDescription: String? {
            switch self {
            case .sameFile: return "导出位置与源文件是同一文件，请选择新的文件名。"
            case .conflict: return "目标文件已存在；请另选名称，或重新确认覆盖并保留原件快照。"
            case .changed: return "文件或目标目录在导出期间发生变化，已停止提交。"
            case .invalidFile: return "导出仅支持可读取的本机普通文件，目标不能是别名、符号链接或目录。"
            case .tooLarge: return "文件超过交接副本的大小限制，请分批处理。"
            case .io(let code): return "导出副本失败：" + String(cString: strerror(code))
            case .recoveryRequired(let url): return "目标被其他程序同时修改，已保留冲突文件，请检查：" + url.path
            }
        }
    }

    /// `hooks` injects failures into the real streaming/commit path in isolated tests.
    /// Snapshot folders are private and retained even when a later commit fails.
    static func copy(source: URL, to destination: URL, protectedOriginal: URL? = nil,
                     overwrite: Overwrite = .rejectExisting,
                     snapshotRoot: URL = FileSafety.root.appendingPathComponent("History/HandoffExports", isDirectory: true),
                     maximumBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
                     hooks: Hooks = .none) throws -> Receipt {
        guard source.isFileURL, destination.isFileURL, maximumBytes >= 0,
              source.host == nil || source.host == "" || source.host == "localhost",
              destination.host == nil || destination.host == "" || destination.host == "localhost" else { throw Failure.invalidFile }
        let sourceURL = try resolveSource(source)
        let requestedDestination = destination.standardizedFileURL
        let parentURL = try resolveSource(requestedDestination.deletingLastPathComponent())
        let name = requestedDestination.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw Failure.invalidFile }
        let targetURL = parentURL.appendingPathComponent(name)
        try verifyProtected(protectedOriginal, destination: targetURL)
        let sourceFD = try Handle(open(sourceURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK))
        let sourceState = try state(sourceFD.value)
        guard sourceState.isRegular else { throw Failure.invalidFile }
        guard sourceState.size <= maximumBytes else { throw Failure.tooLarge }
        let parentFD = try Handle(open(parentURL.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW))
        let parentState = try state(parentFD.value)

        // Resolve aliases/symlinks for identity comparison, then reject their use as targets.
        // This also catches hard links through the device/inode pair.
        if sourceURL == targetURL { throw Failure.sameFile }
        if let resolved = try? resolveSource(targetURL),
           let identity = try? pathState(resolved.path), identity.sameObject(as: sourceState) { throw Failure.sameFile }
        let oldState = try entryState(parentFD.value, name)
        let targetFD: Handle?
        let oldDigest: String?
        if let oldState {
            guard oldState.isRegular, !isAlias(targetURL) else { throw Failure.invalidFile }
            guard !oldState.sameObject(as: sourceState) else { throw Failure.sameFile }
            guard case .replace(let expected) = overwrite, validDigest(expected) else { throw Failure.conflict }
            let fd = try Handle(openat(parentFD.value, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK))
            guard try state(fd.value) == oldState else { throw Failure.changed }
            let actual = try hash(fd.value, maximumBytes: maximumBytes)
            guard actual.digest == expected, try state(fd.value) == oldState else { throw Failure.conflict }
            targetFD = fd; oldDigest = actual.digest
        } else {
            // A previously existing file disappearing is an external modification, not consent
            // to silently recreate it at an old path.
            if case .replace = overwrite { throw Failure.changed }
            targetFD = nil; oldDigest = nil
        }

        let stageName = ".gaowenjian-export-" + UUID().uuidString + ".tmp"
        let stageFD = try Handle(openat(parentFD.value, stageName, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600))
        var keepStage = false
        var cleanupObject = try state(stageFD.value)
        defer {
            // A name we created is not authority to remove a different object later installed
            // at that name. Cleanup is limited to our pinned staging inode (or verified swap).
            if !keepStage, let current = try? entryState(parentFD.value, stageName), current.sameObject(as: cleanupObject) {
                _ = unlinkat(parentFD.value, stageName, 0)
            }
        }
        let copied = try stream(from: sourceFD.value, to: stageFD.value, maximumBytes: maximumBytes, hooks: hooks)
        guard fsync(stageFD.value) == 0 else { throw Failure.io(errno) }
        let stageState = try state(stageFD.value)
        let staged = try hash(stageFD.value, maximumBytes: maximumBytes)
        guard copied == staged, try state(sourceFD.value) == sourceState else { throw Failure.changed }
        try hooks.check(.afterCopy, copied.bytes)

        var snapshotURL: URL?
        if let targetFD, let oldState, let oldDigest {
            snapshotURL = try snapshot(fd: targetFD.value, state: oldState, digest: oldDigest,
                                       name: name, root: snapshotRoot, maximumBytes: maximumBytes)
            try hooks.check(.afterSnapshot, copied.bytes)
        }
        try hooks.check(.beforeCommit, copied.bytes)
        try verifyParent(requestedDestination: requestedDestination, expectedURL: parentURL, expectedState: parentState)
        guard try state(sourceFD.value) == sourceState,
              try pathState(sourceURL.path) == sourceState,
              try entryState(parentFD.value, name) == oldState,
              try entryState(parentFD.value, stageName) == stageState,
              try hash(sourceFD.value, maximumBytes: maximumBytes) == copied else { throw Failure.changed }
        if let targetFD, let oldState, let oldDigest {
            guard try state(targetFD.value) == oldState,
                  try hash(targetFD.value, maximumBytes: maximumBytes).digest == oldDigest else { throw Failure.changed }
            try verifyParent(requestedDestination: requestedDestination, expectedURL: parentURL, expectedState: parentState)
            guard try state(sourceFD.value) == sourceState, try pathState(sourceURL.path) == sourceState,
                  try state(targetFD.value) == oldState, try entryState(parentFD.value, name) == oldState,
                  try entryState(parentFD.value, stageName) == stageState else { throw Failure.changed }
            try verifyProtected(protectedOriginal, destination: targetURL)
            // An atomic swap keeps the displaced target accessible until it is checked. Even a
            // non-cooperating writer racing this operation can never cause its bytes to be deleted.
            guard renameatx_np(parentFD.value, stageName, parentFD.value, name, UInt32(RENAME_SWAP)) == 0 else { throw Failure.io(errno) }
            do {
                guard let displaced = try entryState(parentFD.value, stageName), displaced.sameObject(as: oldState),
                      try hashAt(parentFD.value, stageName, maximumBytes: maximumBytes).digest == oldDigest else { throw Failure.changed }
                cleanupObject = displaced
            } catch {
                // Restore only while both names still identify our swap participants. If a third
                // party races again, retain the displaced file in place for explicit recovery.
                keepStage = true
                if let current = try? entryState(parentFD.value, name), current.sameObject(as: stageState),
                   renameatx_np(parentFD.value, stageName, parentFD.value, name, UInt32(RENAME_SWAP)) == 0 {
                    if let reverted = try? entryState(parentFD.value, stageName), reverted.sameObject(as: stageState) { keepStage = false }
                    throw Failure.changed
                }
                throw Failure.recoveryRequired(parentURL.appendingPathComponent(stageName))
            }
        } else {
            try verifyParent(requestedDestination: requestedDestination, expectedURL: parentURL, expectedState: parentState)
            guard try state(sourceFD.value) == sourceState, try pathState(sourceURL.path) == sourceState,
                  try entryState(parentFD.value, stageName) == stageState else { throw Failure.changed }
            try verifyProtected(protectedOriginal, destination: targetURL)
            // RENAME_EXCL makes a destination created after the last check a conflict, never an overwrite.
            guard renameatx_np(parentFD.value, stageName, parentFD.value, name, UInt32(RENAME_EXCL)) == 0 else { throw Failure.io(errno) }
        }
        // Directory durability is best effort; after a successful rename there is no destructive
        // rollback on an fsync error, and the verified old snapshot remains available.
        _ = fsync(parentFD.value)
        return Receipt(destination: targetURL, sha256: copied.digest, byteCount: copied.bytes, snapshotURL: snapshotURL)
    }

    private final class Handle {
        let value: Int32
        init(_ value: Int32) throws { guard value >= 0 else { throw Failure.io(errno) }; self.value = value }
        deinit { close(value) }
    }
    private struct State: Equatable {
        let device: dev_t, inode: ino_t, mode: mode_t, size: Int64
        let modifiedSeconds: Int, modifiedNanos: Int, changedSeconds: Int, changedNanos: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; mode = value.st_mode; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
        }
        var isRegular: Bool { mode & S_IFMT == S_IFREG }
        func sameObject(as other: State) -> Bool { device == other.device && inode == other.inode }
    }
    private struct Content: Equatable { let digest: String; let bytes: Int64 }
    private static func state(_ fd: Int32) throws -> State {
        var value = stat(); guard fstat(fd, &value) == 0 else { throw Failure.io(errno) }; return State(value)
    }
    private static func pathState(_ path: String) throws -> State {
        var value = stat(); guard lstat(path, &value) == 0 else { throw Failure.io(errno) }; return State(value)
    }
    private static func entryState(_ parent: Int32, _ name: String) throws -> State? {
        var value = stat()
        if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return State(value) }
        if errno == ENOENT { return nil }
        throw Failure.io(errno)
    }
    private static func isAlias(_ url: URL) -> Bool {
        // NSURLIsAliasFile also reports some system symlinks as aliases. Those are
        // resolved by the path resolver, not by the Finder-bookmark resolver.
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT != S_IFLNK else { return false }
        return (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) == true
    }
    private static func resolveSource(_ url: URL) throws -> URL {
        var result = URL(fileURLWithPath: "/", isDirectory: true)
        var aliasCount = 0
        // Resolve intermediate Finder directory aliases as well as the final file alias.
        // Nonexistent trailing components remain lexical, so deleted original locations
        // are still protected instead of being treated as an unrestricted new filename.
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            result = result.appendingPathComponent(component).resolvingSymlinksInPath()
            while isAlias(result) {
                aliasCount += 1
                guard aliasCount <= 16 else { throw Failure.invalidFile }
                result = try URL(resolvingAliasFileAt: result, options: [.withoutUI, .withoutMounting]).standardizedFileURL.resolvingSymlinksInPath()
            }
        }
        return result
    }
    private static func sameLocation(_ first: URL, _ second: URL) -> Bool {
        if first.standardizedFileURL == second.standardizedFileURL { return true }
        let leftParent = first.deletingLastPathComponent(), rightParent = second.deletingLastPathComponent()
        guard let left = try? pathState(leftParent.path), let right = try? pathState(rightParent.path),
              left.sameObject(as: right) else { return false }
        let caseSensitive = (try? leftParent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
        return first.lastPathComponent.compare(second.lastPathComponent, options: caseSensitive ? [] : [.caseInsensitive]) == .orderedSame
    }
    private static func verifyProtected(_ original: URL?, destination: URL) throws {
        guard let original else { return }
        guard original.isFileURL, original.host == nil || original.host == "" || original.host == "localhost" else { throw Failure.invalidFile }
        let protectedURL = try resolveSource(original)
        // A private outbound snapshot has a different inode from the user's original.
        // Preserve the selected original's location even if that original was deleted.
        if sameLocation(destination, protectedURL) { throw Failure.sameFile }
        if let protectedState = try? pathState(protectedURL.path),
           let resolvedTarget = try? resolveSource(destination),
           let targetState = try? pathState(resolvedTarget.path), targetState.sameObject(as: protectedState) { throw Failure.sameFile }
    }
    private static func validDigest(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) } }
    private static func verifyParent(requestedDestination: URL, expectedURL: URL, expectedState: State) throws {
        let parent = try resolveSource(requestedDestination.deletingLastPathComponent())
        guard parent == expectedURL, try pathState(parent.path).sameObject(as: expectedState) else { throw Failure.changed }
    }
    private static func stream(from input: Int32, to output: Int32?, maximumBytes: Int64, hooks: Hooks) throws -> Content {
        guard lseek(input, 0, SEEK_SET) >= 0 else { throw Failure.io(errno) }
        var hasher = SHA256(), total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try hooks.check(.beforeRead, total)
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw Failure.io(errno) }
            if count == 0 { break }
            guard Int64(count) <= maximumBytes - total else { throw Failure.tooLarge }
            hasher.update(data: Data(buffer.prefix(count)))
            if let output {
                try hooks.check(.beforeWrite, total)
                var offset = 0
                while offset < count {
                    let wrote = buffer.withUnsafeBytes { bytes in Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset) }
                    if wrote < 0 { if errno == EINTR { continue }; throw Failure.io(errno) }
                    guard wrote > 0 else { throw Failure.io(EIO) }; offset += wrote
                }
            }
            total += Int64(count)
        }
        return Content(digest: hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes: total)
    }
    private static func hash(_ fd: Int32, maximumBytes: Int64) throws -> Content {
        try stream(from: fd, to: nil, maximumBytes: maximumBytes, hooks: .none)
    }
    private static func hashAt(_ parent: Int32, _ name: String, maximumBytes: Int64) throws -> Content {
        let handle = try Handle(openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK))
        guard try state(handle.value).isRegular else { throw Failure.invalidFile }
        return try hash(handle.value, maximumBytes: maximumBytes)
    }
    private static func snapshot(fd: Int32, state expected: State, digest: String, name: String, root: URL, maximumBytes: Int64) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(name)
        var completed = false
        defer { if !completed { try? manager.removeItem(at: folder) } }
        let output = try Handle(open(url.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600))
        let copied = try stream(from: fd, to: output.value, maximumBytes: maximumBytes, hooks: .none)
        guard fsync(output.value) == 0 else { throw Failure.io(errno) }
        guard copied.digest == digest, try hash(output.value, maximumBytes: maximumBytes) == copied,
              try state(fd) == expected else { throw Failure.changed }
        completed = true
        return url
    }
}
