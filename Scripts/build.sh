#!/bin/zsh
set -euo pipefail
PROJECT_DIR=${0:A:h:h}
validate_app_destination() {
  python3 - "$1" <<'PY'
import os
from pathlib import Path
import sys

destination = Path(sys.argv[1])
if not destination.is_absolute() or destination.suffix != '.app' or os.path.lexists(destination):
    raise SystemExit('需要不存在的绝对 .app 目标')
destination = destination.resolve()
if not any(parent.name.endswith('.noindex') and parent.is_dir() for parent in destination.parents):
    raise SystemExit('App 导出目标必须位于实际存在的 .noindex 目录中')
print(destination)
PY
}
APP_ONLY_DESTINATION=''
if [[ "${1:-}" == '--app-only' ]]; then
  [[ $# == 2 ]] || { print -u2 '需要 --app-only 和一个目标路径'; exit 1; }
  APP_ONLY_DESTINATION=$(validate_app_destination "$2")
elif [[ $# != 0 ]]; then
  print -u2 '仅支持无参数打包或 --app-only 目标路径'; exit 1
fi
APP_VERSION=$(tr -d '\n' < "$PROJECT_DIR/VERSION")
BUILD_NUMBER=$(tr -d '\n' < "$PROJECT_DIR/BUILD")
[[ "$APP_VERSION" =~ '^[0-9]+\.[0-9]{2}$' && "$BUILD_NUMBER" =~ '^[0-9]+$' ]] || { print -u2 '版本或构建号无效'; exit 1; }
STAGING=$(python3 -c 'import tempfile; print(tempfile.mkdtemp(prefix="gaowenjian-build.", suffix=".noindex", dir="/private/tmp"))')
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/搞文件.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SDK=$(xcrun --sdk macosx --show-sdk-path)
ditto "$PROJECT_DIR/Sources" "$STAGING/Sources"
if [[ "$PROJECT_DIR/Assets/Lettering.png" -nt "$PROJECT_DIR/Assets/AppIcon.png" || "$PROJECT_DIR/Scripts/ComposeIcon.swift" -nt "$PROJECT_DIR/Assets/AppIcon.png" ]]; then
  swift -module-cache-path "$STAGING/cache" "$PROJECT_DIR/Scripts/ComposeIcon.swift" "$PROJECT_DIR/Assets/Lettering.png" "$PROJECT_DIR/Assets/AppIcon.png"
fi
swiftc -swift-version 5 -Xfrontend -disable-sandbox -O -target arm64-apple-macos14.0 -sdk "$SDK" -module-cache-path "$STAGING/cache" \
  "$STAGING"/Sources/*.swift -framework AppKit -framework SwiftUI -framework PDFKit -framework WebKit \
  -framework UniformTypeIdentifiers -framework CryptoKit -o "$APP/Contents/MacOS/GaoWenJian"
if [[ ! -f "$PROJECT_DIR/Assets/AppIcon.icns" || "$PROJECT_DIR/Assets/AppIcon.png" -nt "$PROJECT_DIR/Assets/AppIcon.icns" ]]; then
  swift -module-cache-path "$STAGING/cache" "$PROJECT_DIR/Scripts/MakeIcon.swift" "$PROJECT_DIR/Assets/AppIcon.png" "$PROJECT_DIR/Assets/AppIcon.icns"
fi
ditto "$PROJECT_DIR/Resources" "$APP/Contents/Resources"
cp "$PROJECT_DIR/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Assets/AppIcon.png" "$APP/Contents/Resources/AppIcon.png"
[[ ! -f "$PROJECT_DIR/使用说明.txt" ]] || cp "$PROJECT_DIR/使用说明.txt" "$APP/Contents/Resources/使用说明.txt"
ditto "$PROJECT_DIR/Docs" "$APP/Contents/Resources/Docs"
python3 "$PROJECT_DIR/Scripts/make_plist.py" "$APP/Contents/Info.plist" "$APP_VERSION" "$BUILD_NUMBER"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - --identifier com.gaoseries.GaoWenJian.tectonic "$APP/Contents/Resources/Tools/tectonic"
codesign --force --sign - --identifier com.gaoseries.GaoWenJian "$APP"
codesign --verify --deep --strict "$APP"
if [[ -n "$APP_ONLY_DESTINATION" ]]; then
  APP_ONLY_DESTINATION=$(validate_app_destination "$APP_ONLY_DESTINATION")
  ditto "$APP" "$APP_ONLY_DESTINATION"; print "APP=$APP_ONLY_DESTINATION"; exit 0
fi
mkdir -p "$STAGING/disk" "$PROJECT_DIR/Release"
ditto "$APP" "$STAGING/disk/搞文件.app"
ln -s /Applications "$STAGING/disk/Applications"
[[ ! -f "$PROJECT_DIR/使用说明.txt" ]] || cp "$PROJECT_DIR/使用说明.txt" "$STAGING/disk/使用说明.txt"
hdiutil create -quiet -volname "搞文件 V$APP_VERSION" -srcfolder "$STAGING/disk" -format UDZO "$STAGING/GaoWenJian-$APP_VERSION.dmg"
hdiutil verify -quiet "$STAGING/GaoWenJian-$APP_VERSION.dmg"
mv "$STAGING/GaoWenJian-$APP_VERSION.dmg" "$PROJECT_DIR/Release/GaoWenJian-$APP_VERSION.dmg"
(cd "$PROJECT_DIR/Release" && shasum -a 256 "GaoWenJian-$APP_VERSION.dmg" > "GaoWenJian-$APP_VERSION.dmg.sha256")
print "完成：$PROJECT_DIR/Release/GaoWenJian-$APP_VERSION.dmg"
