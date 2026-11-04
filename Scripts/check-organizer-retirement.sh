#!/bin/zsh
# Narrow source-retirement checks only. The caller must supply its build lease.
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
[[ $# == 0 ]] || { print -u2 '此入口仅运行新退役门禁专项，不接收通用测试参数'; exit 2; }
python3 - "$PROJECT_DIR" <<'PY'
import json
import os
from pathlib import Path
import sys
lease_name=os.environ.get('GAOWENJIAN_BUILD_LEASE_FILE')
owner=os.environ.get('GAOWENJIAN_BUILD_LEASE_OWNER')
if not lease_name or not owner:
    raise SystemExit('必须显式设置GAOWENJIAN_BUILD_LEASE_FILE和GAOWENJIAN_BUILD_LEASE_OWNER；不自行申请或抢锁')
lease=Path(lease_name)
if not lease.is_absolute() or lease.resolve()!=lease or not lease.is_file():
    raise SystemExit('构建租约必须是现有、无路径别名的绝对文件')
value=json.loads(lease.read_text())
if value.get('owner')!=owner:
    raise SystemExit('构建租约持有者不匹配；不自行申请或抢锁')
print('Verified caller-owned build lease; token not displayed')
PY
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
cp "$PROJECT_DIR/Scripts/export-organizer-snapshot.py" "$STAGING/Scripts/export-organizer-snapshot.py"
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
