#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  print -u2 'Use an arm64 macOS host, such as the GitHub macos-15 runner.'
  exit 1
}
source "$PROJECT_DIR/Scripts/require-build-lease.sh"

STAGING=$(mktemp -d /private/tmp/gaowenjian-candidate.XXXXXX)
trap 'rm -rf -- "$STAGING"' EXIT
SDK=$(xcrun --sdk macosx --show-sdk-path)
cd "$PROJECT_DIR"
xcrun --sdk macosx swiftc -swift-version 5 -Xfrontend -disable-sandbox -O \
  -target arm64-apple-macos14.0 -sdk "$SDK" -module-cache-path "$STAGING/cache" \
  Sources/*.swift -framework AppKit -framework SwiftUI -framework PDFKit -framework WebKit \
  -framework UniformTypeIdentifiers -framework CryptoKit -framework Security -framework CoreServices \
  -lsqlite3 -o "$STAGING/GaoWenJian"
xcrun lipo -verify_arch arm64 "$STAGING/GaoWenJian"

# The production generator can update a neighboring capabilities resource. Give it a private copy.
mkdir -p "$STAGING/Scripts" "$STAGING/Contents/Resources"
cp Scripts/make_plist.py "$STAGING/Scripts/"
cp Resources/GaoCapabilities.json "$STAGING/Contents/Resources/"
python3 "$STAGING/Scripts/make_plist.py" "$STAGING/Contents/Info.plist" "$(< VERSION)" "$(< BUILD)"
plutil -lint "$STAGING/Contents/Info.plist"
python3 - "$STAGING/Contents" "$(< VERSION)" "$(< BUILD)" <<'PY'
import json
import pathlib
import plistlib
import sys

root, version, build = sys.argv[1:]
root = pathlib.Path(root)
with (root / "Info.plist").open("rb") as handle:
    plist = plistlib.load(handle)
capabilities = json.loads((root / "Resources" / "GaoCapabilities.json").read_text(encoding="utf-8"))
assert plist["CFBundleIdentifier"] == capabilities["bundleID"] == "com.gaoseries.GaoWenJian"
assert plist["CFBundleShortVersionString"] == capabilities["appVersion"] == version
assert plist["CFBundleVersion"] == build
print(f"PASS: arm64 production-mode executable and Info.plist {version} ({build})")
PY

/bin/zsh "$PROJECT_DIR/Scripts/test-headless.sh" "$@"
