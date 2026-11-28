"""Collect the native .NET Framework host for this x64 application."""

from pathlib import Path

from PyInstaller.utils.hooks import get_package_paths


_, package_path = get_package_paths("clr_loader")
native = Path("ffi/dlls/amd64")
binaries = [(str(Path(package_path) / native / "ClrLoader.dll"), f"clr_loader/{native.as_posix()}")]
