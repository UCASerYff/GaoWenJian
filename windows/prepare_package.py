"""Prepare Windows metadata, branded icon, and licenses from the build venv."""

import importlib.metadata
import shutil
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))
from gaowenjian.version import MARKETING_VERSION, WINDOWS_BUILD


def generate(stage: Path) -> None:
    stage.mkdir(parents=True, exist_ok=True)
    icon = Path(__file__).resolve().parents[1] / "Assets" / "AppIcon.png"
    with Image.open(icon) as source:
        source.save(stage / "app.ico", sizes=[(size, size) for size in (16, 24, 32, 48, 64, 96, 128, 256)])
    major, minor = map(int, MARKETING_VERSION.split("."))
    number = (major, minor, int(WINDOWS_BUILD), 0)
    stage.joinpath("file-version.txt").write_text(f"""# coding: utf-8
VSVersionInfo(ffi=FixedFileInfo(filevers={number}, prodvers={number}, mask=0x3f, flags=0, OS=0x40004,
fileType=1, subtype=0, date=(0,0)), kids=[StringFileInfo([StringTable('080404b0',[
StringStruct('CompanyName','GaoSeries'), StringStruct('FileDescription','搞文件'),
StringStruct('ProductName','搞文件'), StringStruct('FileVersion','{MARKETING_VERSION}.{WINDOWS_BUILD}.0'),
StringStruct('ProductVersion','{MARKETING_VERSION}')])]), VarFileInfo([VarStruct('Translation',[2052,1200])])])
""", encoding="utf-8")

    destination = stage / "third-party"
    destination.mkdir(exist_ok=True)
    python_license = Path(sys.base_prefix) / "LICENSE.txt"
    if python_license.is_file():
        shutil.copyfile(python_license, destination / "Python-LICENSE.txt")
    for package in ("pypdf", "pypdfium2", "Pillow", "pywebview", "pythonnet", "clr-loader", "cffi", "pycparser", "cryptography", "bottle", "proxy-tools", "typing-extensions", "pyinstaller"):
        dist = importlib.metadata.distribution(package)
        package_dir = destination / f"{package}-{dist.version}"
        package_dir.mkdir(exist_ok=True)
        metadata = dist.read_text("METADATA") or ""
        package_dir.joinpath("METADATA.txt").write_text(metadata, encoding="utf-8")
        for file in dist.files or []:
            if file.name.lower().startswith(("license", "copying", "notice", "copyright")) and dist.locate_file(file).is_file():
                shutil.copyfile(dist.locate_file(file), package_dir / "-".join(file.parts[-2:]))


if __name__ == "__main__":
    generate(Path(sys.argv[1]))
