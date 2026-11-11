#!/bin/zsh
# Narrow source-retirement checks, under the canonical workspace build lease.
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
source "$PROJECT_DIR/Scripts/require-build-lease.sh"
[[ $# == 0 ]] || { print -u2 '此入口仅运行新退役门禁专项，不接收通用测试参数'; exit 2; }
STAGING=$(python3 -c 'import tempfile; print(tempfile.mkdtemp(prefix="gaowenjian-organizer-retirement.", suffix=".noindex", dir="/private/tmp"))')
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Sources" "$STAGING/Tests" "$STAGING/Scripts"
CORE=(FileSafety OrganizerConfiguration OrganizerIndexModels OrganizerIndexStore OrganizerMoveModels OrganizerMoveEngine OrganizerAssociations OrganizerMigration)
SOURCE_FILES=()
for name in $CORE; do
  cp "$PROJECT_DIR/Sources/$name.swift" "$STAGING/Sources/$name.swift"
  SOURCE_FILES+=("$STAGING/Sources/$name.swift")
done
cp "$PROJECT_DIR/Tests/OrganizerMigrationTests.swift" "$STAGING/Tests/OrganizerMigrationTests.swift"
cp "$PROJECT_DIR/Tests/OrganizerMigrationFixture.py" "$STAGING/Tests/OrganizerMigrationFixture.py"
cat > "$STAGING/RetirementMain.swift" <<'SWIFT'
import AppKit
import Foundation
import Darwin

@main struct OrganizerRetirementMain {
    @MainActor static func main() {
        do {
            guard NSApp == nil,
                  let index = CommandLine.arguments.firstIndex(of: "--data-dir"),
                  index + 1 < CommandLine.arguments.count else {
                throw OrganizerMigrationFailure("Retirement harness requires explicit isolated data and NSApp=nil")
            }
            let root = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            guard root.path.hasPrefix("/private/tmp/gaowenjian-organizer-retirement."),
                  root.deletingLastPathComponent().lastPathComponent.hasSuffix(".noindex") else {
                throw OrganizerMigrationFailure("Unsafe retirement harness root")
            }
            try OrganizerMigrationTests.runRetirementOnly(in: root)
            guard NSApp == nil else { throw OrganizerMigrationFailure("Unexpected App initialization") }
            print("PASS focused Organizer retirement harness; NSApp remained nil; no old suite or smoke")
        } catch {
            FileHandle.standardError.write(Data(("FAIL focused Organizer retirement: " + error.localizedDescription + "\n").utf8))
            Darwin.exit(1)
        }
    }
}
SWIFT
swiftc -swift-version 5 -Xfrontend -disable-sandbox -target arm64-apple-macos14.0 -module-cache-path "$STAGING/cache" \
  $SOURCE_FILES "$STAGING/Tests/OrganizerMigrationTests.swift" "$STAGING/RetirementMain.swift" \
  -framework AppKit -framework CoreServices -lsqlite3 -o "$STAGING/retirement-tests"
"$STAGING/retirement-tests" --data-dir "$STAGING/DataRoot"
