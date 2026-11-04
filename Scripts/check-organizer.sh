#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
STAGING=$(python3 -c 'import tempfile; print(tempfile.mkdtemp(prefix="gaowenjian-organizer.", suffix=".noindex", dir="/private/tmp"))')
trap 'rm -rf "$STAGING"' EXIT
ditto "$PROJECT_DIR/Sources" "$STAGING/Sources"
python3 - "$STAGING/Sources/App.swift" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);text=p.read_text();assert text.count('@main @MainActor struct')==1
p.write_text(text.replace('@main @MainActor struct','@MainActor struct'))
PY
if [[ "${1:-}" != "--compile-checks-types" ]]; then
swiftc -swift-version 5 -Xfrontend -disable-sandbox -target arm64-apple-macos14.0 -module-cache-path "$STAGING/cache" -typecheck "$STAGING"/Sources/*.swift -framework CoreServices -lsqlite3
print 'PASS full integrated target typecheck; no app/window launched'
fi
swiftc -swift-version 5 -Xfrontend -disable-sandbox -target arm64-apple-macos14.0 -module-cache-path "$STAGING/cache" "$STAGING"/Sources/*.swift "$PROJECT_DIR/Tests/OrganizerHostIntegrationTests.swift" "$PROJECT_DIR/Tests/OrganizerActionProviderTests.swift" "$PROJECT_DIR/Tests/OrganizerMigrationTests.swift" -framework CoreServices -lsqlite3 -o "$STAGING/host-tests"
"$STAGING/host-tests" --data-dir "$STAGING/DataRoot"
