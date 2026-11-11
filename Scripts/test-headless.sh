#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
source "$PROJECT_DIR/Scripts/require-build-lease.sh"
STAGING=$(python3 -c 'import tempfile; print(tempfile.mkdtemp(prefix="gaowenjian-headless.", suffix=".noindex", dir="/private/tmp"))')
cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT
ditto "$PROJECT_DIR/Sources" "$STAGING/Sources"
ditto "$PROJECT_DIR/Tests" "$STAGING/Tests"
python3 - "$STAGING/Sources/App.swift" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1])
text = source.read_text()
assert text.count('@main @MainActor struct') == 1
source.write_text(text.replace('@main @MainActor struct', '@MainActor struct'))
PY
TEST_SOURCES=(CoreTests OfficeRoundTripTests OfficeRecoveryTests OfficeViewerTests PDFTests PDFHandoffTests PDFFormFocusTests PDFImageHandoffTests CurrentDocumentHandoffTests OCRResultProvenanceTests OCRJSONPayloadVerifierTests OCRDispatchOptionsTests OCRProviderRoutingTests GaoActionWriterCompatibilityTests ResearchImportReceiptTests ReferenceSelectionTests EditedDocumentExportTests GaoActionFixtures GaoActionTests GaoOutgoingJournalTests HandoffSafeExportTests DocumentHandoffSafetyTests LaTeXTests StickyNotesTests HandoffProductionTests BackupRemovalTests HeadlessTestMain)
TEST_FILES=()
for name in $TEST_SOURCES; do
  [[ -f "$STAGING/Tests/$name.swift" ]] || { print -u2 "缺少无界面单元测试源码：$name.swift"; exit 1; }
  TEST_FILES+=("$STAGING/Tests/$name.swift")
done
python3 - $TEST_FILES <<'PY'
import pathlib,re,sys
for name in sys.argv[1:]:
    text=pathlib.Path(name).read_text()
    assert not re.search(r'NSApplication\s*\.\s*shared|NSWindow\s*\(|WKWebView\s*\(|NS(Open|Save)Panel\s*\(|\.runModal\s*\(',text),name
print('Audited headless test sources: no application, window, browser or modal construction')
PY
swiftc -swift-version 5 -Xfrontend -disable-sandbox -target arm64-apple-macos14.0 -module-cache-path "$STAGING/cache" \
  "$STAGING"/Sources/*.swift -framework CoreServices -lsqlite3 $TEST_FILES -o "$STAGING/headless-regression"
EVIDENCE_DIR="$STAGING/evidence"
"$STAGING/headless-regression" --data-dir "$STAGING/data" --evidence-dir "$EVIDENCE_DIR" "$@"
if [[ " ${*} " != *" --research-handoff-only "* && " ${*} " != *" --reference-selection-only "* && " ${*} " != *" --ocr-provider-routing-only "* && " ${*} " != *" --backup-removal-only "* ]]; then node "$PROJECT_DIR/Tests/MarkdownCoreTests.js"; fi
