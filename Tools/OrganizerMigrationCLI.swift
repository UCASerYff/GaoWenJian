import Foundation
import Darwin

/// Compile with the same production OrganizerMigration and OF model sources.
/// No default paths, app initialization, source discovery, or parallel engine.
@main struct OrganizerMigrationCLI {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["--help"] {
                print("organizer-migration import --snapshot PATH --destination PATH | activate --destination PATH --authority-receipt PATH | verify --destination PATH | finalize-source-retirement --destination PATH")
                return
            }
            guard let mode = arguments.first, ["import", "activate", "verify", "finalize-source-retirement"].contains(mode) else {
                throw OrganizerMigrationFailure("Usage: organizer-migration import --snapshot PATH --destination PATH | activate --destination PATH --authority-receipt PATH | verify --destination PATH | finalize-source-retirement --destination PATH")
            }
            var options: [String: String] = [:]
            var i = 1
            while i < arguments.count {
                guard ["--snapshot", "--destination", "--authority-receipt"].contains(arguments[i]), i + 1 < arguments.count,
                      options[arguments[i]] == nil, !arguments[i + 1].isEmpty else { throw OrganizerMigrationFailure("Unknown, duplicate or incomplete argument") }
                options[arguments[i]] = arguments[i + 1]; i += 2
            }
            guard let destinationPath = options["--destination"], destinationPath.hasPrefix("/") else { throw OrganizerMigrationFailure("Explicit absolute --destination required; no default Library access") }
            let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
            switch mode {
            case "import":
                guard let snapshot = options["--snapshot"], snapshot.hasPrefix("/"), options.count == 2 else { throw OrganizerMigrationFailure("import requires only --snapshot and --destination") }
                let result = try OrganizerMigration.importSnapshot(url: URL(fileURLWithPath: snapshot, isDirectory: true), destination: destination)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                print(String(decoding: try encoder.encode(result), as: UTF8.self))
                print("IMPORTED_PENDING_EXPLICIT_SOURCE_WRITE_FREEZE_ACTIVATION; no runtime authority transferred")
            case "activate":
                guard let receipt = options["--authority-receipt"], receipt.hasPrefix("/"), options.count == 2 else { throw OrganizerMigrationFailure("activate requires only --destination and --authority-receipt") }
                let result = try OrganizerMigration.activate(destination: destination, authorityReceipt: URL(fileURLWithPath: receipt))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                print(String(decoding: try encoder.encode(result), as: UTF8.self))
                print("ACTIVATED: exact local source-freeze receipt verified; OS directory authorization remains required")
            case "finalize-source-retirement":
                guard options.count == 1 else { throw OrganizerMigrationFailure("finalize-source-retirement requires only --destination; call explicitly only after final migration/business acceptance") }
                let result = try OrganizerMigration.finalizeSourceRetirement(destination: destination)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                print(String(decoding: try encoder.encode(result), as: UTF8.self))
                print("FINALIZED_SOURCE_RETIREMENT: authority dependency released; nothing deleted. Only coordinator may delete the exact returned allowlist after acceptance; current business data and originals remain.")
            default:
                guard options.count == 1 else { throw OrganizerMigrationFailure("verify requires only --destination") }
                guard ["MigrationLedger.json", "SourceRetirementFinalized.json"].contains(where: { FileManager.default.fileExists(atPath: destination.appendingPathComponent($0).path) }) else { throw OrganizerMigrationFailure("verify expects a migrated destination with migration or finalized authority evidence") }
                try OrganizerMigration.requireActiveAuthority(directory: destination)
                print("VERIFIED_ACTIVE: local migration or finalized authority bindings valid; no source lookup or GUI")
            }
        } catch {
            FileHandle.standardError.write(Data(("Migration stopped: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
