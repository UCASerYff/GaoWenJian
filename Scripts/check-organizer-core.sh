#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
source "$PROJECT_DIR/Scripts/require-build-lease.sh"
STAGING=$(python3 -c 'import tempfile; print(tempfile.mkdtemp(prefix="gaowenjian-organizer-core.", suffix=".noindex", dir="/private/tmp"))')
trap 'rm -rf "$STAGING"' EXIT
ditto "$PROJECT_DIR/Sources" "$STAGING/Sources"
ditto "$PROJECT_DIR/Tests" "$STAGING/Tests"
S="$STAGING/Sources"
COMMON=(-swift-version 5 -Xfrontend -disable-sandbox -target arm64-apple-macos14.0 -module-cache-path "$STAGING/cache")
if [[ "${1:-}" != "--skip-index" ]]; then
swiftc $COMMON "$S/OrganizerIndexModels.swift" "$S/OrganizerIndexStore.swift" "$STAGING/Tests/OrganizerIndexTests.swift" -lsqlite3 -o "$STAGING/index-tests"
"$STAGING/index-tests"
fi
swiftc $COMMON "$S/FileSafety.swift" "$S/OrganizerConfiguration.swift" "$S/OrganizerIndexModels.swift" "$S/OrganizerIndexStore.swift" "$S/OrganizerMoveModels.swift" "$S/OrganizerMoveEngine.swift" "$S/OrganizerAssociations.swift" "$S/OrganizerMigration.swift" "$STAGING/Tests/OrganizerMoveTests.swift" -lsqlite3 -o "$STAGING/move-tests"
"$STAGING/move-tests" --data-dir "$STAGING/MoveDataRoot"
swiftc $COMMON "$S/FileSafety.swift" "$S/OrganizerConfiguration.swift" "$S/OrganizerIndexModels.swift" "$S/OrganizerIndexStore.swift" "$S/OrganizerMoveModels.swift" "$S/OrganizerMoveEngine.swift" "$S/OrganizerAssociations.swift" "$S/OrganizerMigration.swift" "$STAGING/Tests/OrganizerAssociationTests.swift" -lsqlite3 -o "$STAGING/association-tests"
"$STAGING/association-tests"
