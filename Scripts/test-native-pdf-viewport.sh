#!/bin/zsh
set -euo pipefail
DRAFT_DIR=${0:A:h}
PROJECT_DIR=${DRAFT_DIR:h}
source "$PROJECT_DIR/Scripts/require-build-lease.sh"
STAGING=$(mktemp -d /private/tmp/gaowenjian-tests.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
ditto "$PROJECT_DIR/Sources" "$STAGING/Sources"
python3 - "$STAGING/Sources/App.swift" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
source = p.read_text()
needle = '@main @MainActor struct'
if source.count(needle) != 1:
    raise SystemExit('Could not find the single application entry point')
p.write_text(source.replace(needle, '@MainActor struct'))
PY
swiftc -swift-version 5 -Xfrontend -disable-sandbox -target arm64-apple-macos14.0 \
  -module-cache-path "$STAGING/cache" "$STAGING"/Sources/*.swift -framework CoreServices -lsqlite3 \
  "$PROJECT_DIR/Tests/NativePDFViewportTests.swift" -o "$STAGING/pdf-viewport-tests"
"$STAGING/pdf-viewport-tests" --data-dir "$STAGING/data"
