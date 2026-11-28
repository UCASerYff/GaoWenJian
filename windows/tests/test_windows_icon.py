from pathlib import Path
from runpy import run_path

from PIL import Image, ImageChops


def test_windows_icon_has_crisp_square_frames(tmp_path):
    root = Path(__file__).resolve().parents[2]
    write_icon = run_path(str(root / "windows" / "prepare_package.py"))["write_windows_icon"]
    target = tmp_path / "app.ico"
    write_icon(root / "Assets" / "AppIcon.png", target)

    sizes = (16, 20, 24, 28, 30, 32, 36, 40, 42, 48, 56, 64, 96, 128, 256)
    with Image.open(target) as icon:
        assert icon.ico.sizes() == {(size, size) for size in sizes}
        for size in sizes:
            frame = icon.ico.getimage((size, size))
            assert frame.mode == "RGBA"
            padding = round(size * 82 / 1024)
            center = size // 2
            alpha = frame.getchannel("A")
            assert alpha.getbbox() == (padding, padding, size - padding, size - padding)
            edge = alpha.crop((0, center, size, center + 1))
            assert edge.tobytes() == bytes(padding) + b"\xff" * (size - 2 * padding) + bytes(padding)
            assert frame.getpixel((padding, center)) == (119, 119, 119, 255)
            assert alpha.getpixel((padding, padding)) < 32

            opaque = alpha.point(lambda value: 255 if value == 255 else 0)
            bright = frame.convert("L").point(lambda value: 255 if value >= 169 else 0)
            lettering = ImageChops.multiply(opaque, bright)
            left, top, right, bottom = lettering.getbbox()
            assert abs((left + right) / 2 - center) <= 1
            assert abs((top + bottom) / 2 - center) <= 1
            assert bottom - top >= (size - 2 * padding) * 0.6
