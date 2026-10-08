#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
STAGING=$(mktemp -d /private/tmp/gaowenjian-tests.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT
ditto "$PROJECT_DIR/Sources" "$STAGING/Sources"
python3 - "$STAGING/Sources/App.swift" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('@main @MainActor struct', '@MainActor struct'))
PY
swiftc -swift-version 5 -Xfrontend -disable-sandbox -target arm64-apple-macos14.0 -module-cache-path "$STAGING/cache" \
  "$STAGING"/Sources/*.swift "$PROJECT_DIR/Tests/CoreTests.swift" "$PROJECT_DIR/Tests/OfficeRoundTripTests.swift" "$PROJECT_DIR/Tests/OfficeRecoveryTests.swift" \
  "$PROJECT_DIR/Tests/PDFTests.swift" "$PROJECT_DIR/Tests/StickyNotesTests.swift" "$PROJECT_DIR/Tests/StickyNotesUITests.swift" "$PROJECT_DIR/Tests/TestMain.swift" -o "$STAGING/tests"
"$STAGING/tests" --data-dir "$STAGING/data"
node "$PROJECT_DIR/Tests/MarkdownCoreTests.js"
swiftc -swift-version 5 -Xfrontend -disable-sandbox -target arm64-apple-macos14.0 -module-cache-path "$STAGING/cache" \
  "$PROJECT_DIR/Sources/FileSafety.swift" "$PROJECT_DIR/Sources/NativeEditors.swift" "$PROJECT_DIR/Tests/RTFRecoveryTests.swift" -o "$STAGING/rtf-tests"
"$STAGING/rtf-tests" --data-dir "$STAGING/rtf-data"
swift -module-cache-path "$STAGING/cache" "$PROJECT_DIR/Tests/IconTests.swift" "$PROJECT_DIR/Assets/AppIcon.png"
