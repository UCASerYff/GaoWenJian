"""Prepare Windows metadata, branded icon, and licenses from the build venv."""

import importlib.metadata
import shutil
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageOps

sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))
from gaowenjian.version import MARKETING_VERSION, WINDOWS_BUILD


# Cover 16 px notification, 24 px taskbar, 32 px large window and 48 px desktop icons at 100–200%.
WINDOWS_ICON_SIZES = (16, 20, 24, 28, 30, 32, 36, 40, 42, 48, 56, 60, 64, 72, 84, 96, 128, 256)
ICON_GRAY = 119  # The neutral gray used by Scripts/ComposeIcon.swift.
PLATE_RADIUS_PERCENT = 20


def plate_alpha(size: int) -> Image.Image:
    # Use the same edge-to-edge rounded square as the GaoSeries Windows shortcuts.
    # Supersampling keeps rounded corners smooth even in the 16 px frame.
    sample_size = size * 8
    mask = Image.new("L", (sample_size, sample_size))
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, sample_size - 1, sample_size - 1),
        radius=round(sample_size * PLATE_RADIUS_PERCENT / 100),
        fill=255,
    )
    return mask.resize((size, size), Image.Resampling.BOX)


def write_windows_icon(source: Path, destination: Path) -> None:
    with Image.open(source) as artwork:
        master = artwork.convert("RGBA")
    bounds = master.getchannel("A").getbbox()
    if master.width != master.height or not bounds:
        raise ValueError("The application icon must have square, non-empty artwork.")
    face = master.crop(bounds)
    if face.width != face.height:
        raise ValueError("The application icon face must be square.")

    # Extract the original calligraphy from its 860 px plate without the Mac canvas inset.
    # Preserve the size and aspect of the lettering relative to its plate.
    alpha = face.getchannel("A")
    from_gray = [max(0, round(255 * (value - ICON_GRAY) / (255 - ICON_GRAY))) for value in range(256)]
    lettering = ImageChops.multiply(ImageOps.grayscale(face).point(from_gray), alpha)
    small_ink = [round(255 * ((value - 5) / 250) ** 0.8) if value > 5 else 0 for value in range(256)]
    frames = []
    for size in WINDOWS_ICON_SIZES:
        extent = (size, size)
        strokes = lettering.resize(extent, Image.Resampling.LANCZOS)
        if size <= 32:
            # Give the fine brush strokes a little more contrast at shell sizes.
            strokes = strokes.point(small_ink)
        shade = Image.composite(Image.new("L", extent, 255), Image.new("L", extent, ICON_GRAY), strokes)
        frames.append(Image.merge("RGBA", (shade, shade, shade, plate_alpha(size))))

    frames[-1].save(destination, format="ICO", sizes=[frame.size for frame in frames], append_images=frames[:-1])


def generate(stage: Path) -> None:
    stage.mkdir(parents=True, exist_ok=True)
    icon = Path(__file__).resolve().parents[1] / "Assets" / "AppIcon.png"
    write_windows_icon(icon, stage / "app.ico")
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
