"""Collect the pywebview JavaScript bridge and x64 Edge host only."""

from pathlib import Path

from PyInstaller.utils.hooks import copy_metadata, get_package_paths


_, package_path = get_package_paths("webview")
package = Path(package_path)
native = Path("lib/runtimes/win-x64/native")
datas = [(str(package / "js"), "webview/js"), *copy_metadata("pywebview")]
binaries = [
    (str(package / "lib" / name), "webview/lib")
    for name in ("Microsoft.Web.WebView2.Core.dll", "Microsoft.Web.WebView2.WinForms.dll")
]
binaries.append((str(package / native / "WebView2Loader.dll"), f"webview/{native.as_posix()}"))
hiddenimports = ["webview.platforms.winforms", "webview.platforms.win32", "webview.platforms.edgechromium"]
