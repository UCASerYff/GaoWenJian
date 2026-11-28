from pathlib import Path
import os

from PyInstaller.utils.hooks import collect_data_files, collect_dynamic_libs

here = Path(SPECPATH)
repo = here.parent
build = Path(os.environ["GAOWENJIAN_BUILD_STAGE"])
tectonic = Path(os.environ["GAOWENJIAN_TECTONIC"])
version = str(build / "file-version.txt")
icon = str(build / "app.ico")

data = [
    (here / "src/gaowenjian/assets", "gaowenjian_assets"),
    (repo / "Assets/AppIcon.png", "gao_app_icon"),
    (build / "app.ico", "gao_app_icon"),
    (repo / "Resources/Web", "gaowenjian_markdown"),
    (repo / "Resources/TeXCache", "gaowenjian_tex_seed"),
    (here / "tex-extra", "gaowenjian_tex_extra"),
    (repo / "Docs/Licenses", "Licenses/Tectonic"),
    (build / "third-party", "Licenses/Windows"),
]
a = Analysis(
    [str(here / "launch.py")],
    pathex=[str(here / "src")],
    binaries=[(str(tectonic), "gaowenjian_tex")] + collect_dynamic_libs("pypdfium2_raw") + collect_dynamic_libs("pythonnet"),
    datas=[(str(source), target) for source, target in data] + collect_data_files("pypdfium2_raw") + collect_data_files("pypdfium2"),
    hiddenimports=["clr"],
    hookspath=[str(here / "hooks")],
    excludes=["IPython", "matplotlib", "numpy", "pandas", "scipy",
              "webview.platforms.android", "webview.platforms.cef", "webview.platforms.cocoa",
              "webview.platforms.gtk", "webview.platforms.mshtml", "webview.platforms.qt"],
)
pyz = PYZ(a.pure)
gui = EXE(pyz, a.scripts, [], exclude_binaries=True, name="GaoWenJian", console=False, icon=icon, version=version, upx=False)
cli = EXE(pyz, a.scripts, [], exclude_binaries=True, name="GaoWenJian-cli", console=True, icon=icon, version=version, upx=False)
release = COLLECT(gui, cli, a.binaries, a.datas, name="GaoWenJian", upx=False)
