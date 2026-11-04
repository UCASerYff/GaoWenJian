#!/bin/zsh
# Thin production migration CLI; caller must already own Master's build lease.
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
[[ $# == 1 ]] || { print -u2 '需要一个不存在的 CLI 绝对输出路径'; exit 2; }
python3 - "$1" <<'PY'
from pathlib import Path
import os, sys
p=Path(sys.argv[1])
containers=[q for q in p.parents if q.name.endswith('.noindex') and q.is_dir()]
if not p.is_absolute() or p.resolve()!=p or os.path.lexists(p) or not p.parent.is_dir() or not containers:
    raise SystemExit('CLI输出须为实际私有.noindex容器中不存在的绝对路径')
s=containers[0].stat()
if s.st_uid!=os.getuid() or s.st_mode & 0o077:raise SystemExit('CLI容器需当前用户拥有且0700')
PY
STAGING=$(python3 -c 'import tempfile; print(tempfile.mkdtemp(prefix="gaowenjian-organizer-cli.", suffix=".noindex", dir="/private/tmp"))')
trap 'rm -rf "$STAGING"' EXIT
ditto "$PROJECT_DIR/Sources" "$STAGING/Sources"
cp "$PROJECT_DIR/Tools/OrganizerMigrationCLI.swift" "$STAGING/OrganizerMigrationCLI.swift"
S="$STAGING/Sources"
swiftc -swift-version 5 -Xfrontend -disable-sandbox -O -target arm64-apple-macos14.0 -module-cache-path "$STAGING/cache" \
 "$S/FileSafety.swift" "$S/OrganizerConfiguration.swift" "$S/OrganizerIndexModels.swift" "$S/OrganizerIndexStore.swift" \
 "$S/OrganizerMoveModels.swift" "$S/OrganizerMoveEngine.swift" "$S/OrganizerAssociations.swift" "$S/OrganizerMigration.swift" \
 "$STAGING/OrganizerMigrationCLI.swift" -lsqlite3 -o "$1"
print "CLI=$1"
