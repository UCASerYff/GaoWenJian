#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
STAGING=$(mktemp -d /private/tmp/gaowenjian-headless.XXXXXX)
cleanup() {
  if [[ "${GAOWENJIAN_KEEP_HEADLESS_BUILD:-0}" == 1 ]]; then print "HEADLESS_BUILD=$STAGING"; else rm -rf "$STAGING"; fi
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
TEST_SOURCES=(CoreTests OfficeRoundTripTests OfficeRecoveryTests OfficeViewerTests PDFTests PDFHandoffTests PDFFormFocusTests PDFImageHandoffTests CurrentDocumentHandoffTests OCRResultProvenanceTests OCRJSONPayloadVerifierTests OCRDispatchOptionsTests GaoActionWriterCompatibilityTests ReferenceSelectionTests EditedDocumentExportTests GaoActionFixtures GaoActionTests GaoOutgoingJournalTests HandoffSafeExportTests DocumentHandoffSafetyTests LaTeXTests StickyNotesTests HandoffProductionTests DataCopyVerification HeadlessTestMain)
TEST_FILES=()
for name in $TEST_SOURCES; do TEST_FILES+=("$STAGING/Tests/$name.swift"); done
python3 - $TEST_FILES <<'PY'
import pathlib,re,sys
for name in sys.argv[1:]:
    text=pathlib.Path(name).read_text()
    assert not re.search(r'NSApplication\s*\.\s*shared|NSWindow\s*\(|WKWebView\s*\(|NS(Open|Save)Panel\s*\(|\.runModal\s*\(',text),name
print('Audited headless test sources: no application, window, browser or modal construction')
PY
swiftc -swift-version 5 -Xfrontend -disable-sandbox -target arm64-apple-macos14.0 -module-cache-path "$STAGING/cache" \
  "$STAGING"/Sources/*.swift $TEST_FILES -o "$STAGING/headless-regression"
EVIDENCE_DIR="$PROJECT_DIR/TestResults/Headless-$(date +%Y%m%d-%H%M%S)-${STAGING:t}"
"$STAGING/headless-regression" --data-dir "$STAGING/data" --evidence-dir "$EVIDENCE_DIR" "$@"
if [[ " ${*} " != *" --verify-data-copy "* ]]; then node "$PROJECT_DIR/Tests/MarkdownCoreTests.js"; fi
