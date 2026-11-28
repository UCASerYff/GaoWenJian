from pathlib import Path
from runpy import run_path

from PIL import Image, ImageChops


def test_windows_icon_has_crisp_square_frames(tmp_path):
    root = Path(__file__).resolve().parents[2]
    write_icon = run_path(str(root / "windows" / "prepare_package.py"))["write_windows_icon"]
    target = tmp_path / "app.ico"
    write_icon(root / "Assets" / "AppIcon.png", target)

    sizes = (16, 20, 24, 28, 30, 32, 36, 40, 42, 48, 56, 60, 64, 72, 84, 96, 128, 256)
    with Image.open(target) as icon:
        assert icon.ico.sizes() == {(size, size) for size in sizes}
        for size in sizes:
            frame = icon.ico.getimage((size, size))
            assert frame.mode == "RGBA"
            center = size // 2
            alpha = frame.getchannel("A")
            plate = alpha.point(lambda value: 255 if value >= 128 else 0)
            assert plate.getbbox() == (0, 0, size, size)
            assert alpha.crop((0, center, size, center + 1)).tobytes() == b"\xff" * size
            assert alpha.crop((center, 0, center + 1, size)).tobytes() == b"\xff" * size
            assert frame.getpixel((0, center)) == (119, 119, 119, 255)
            assert all(alpha.getpixel(corner) < 32 for corner in
                       ((0, 0), (0, size - 1), (size - 1, 0), (size - 1, size - 1)))
            if size == 48:
                assert 0.95 <= plate.histogram()[255] / (size * size) <= 0.98

            opaque = alpha.point(lambda value: 255 if value == 255 else 0)
            bright = frame.convert("L").point(lambda value: 255 if value >= 169 else 0)
            lettering = ImageChops.multiply(opaque, bright)
            left, top, right, bottom = lettering.getbbox()
            assert abs((left + right) / 2 - center) <= 1
            assert abs((top + bottom) / 2 - center) <= 1
            assert bottom - top >= size * 0.6
            if size == 48:
                assert 31 <= bottom - top <= 36
