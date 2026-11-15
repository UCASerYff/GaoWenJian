"""开发目录与 PyInstaller 解包目录里的只读资源。"""

from __future__ import annotations

import sys
from pathlib import Path


def asset_dir() -> Path:
    frozen = getattr(sys, "_MEIPASS", None)
    if frozen:
        return Path(frozen) / "gaowenjian_assets"
    return Path(__file__).resolve().parent / "assets"
