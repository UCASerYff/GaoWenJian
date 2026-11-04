// Organizer module port; source application is not a runtime dependency.
import Foundation
import CryptoKit

extension OFAppModel {
    func createBackup() async {
        guard !backingUp, !moving, associations?.busy != true, !hasPendingAssociation, let index, let directory else { status = "请等待当前操作结束后再备份。"; return }
        backingUp = true; monitorForBackupStop()
        defer { backingUp = false; configureMonitor() }
        while scanning { try? await Task.sleep(nanoseconds: 100_000_000) }
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.00"
            let target = OFAppLocations.backups.appendingPathComponent("\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString)", isDirectory: true)
            try await Task.detached(priority: .utility) {
                try OFBackupEngine.create(index: index, directory: directory, target: target, version: version, initializationMarker: OFAppLocations.initializationMarker)
            }.value
            status = "备份已生成并逐文件核对：\(target.lastPathComponent)"
        } catch { status = "备份未通过核验：" + error.localizedDescription }
    }
    func monitorForBackupStop() { stopForBackup() }
}
