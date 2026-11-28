"""DPI-specific, owned HICONs for the WinForms windows and notification area."""

from __future__ import annotations

import ctypes as c
from ctypes import wintypes as w
from pathlib import Path
import sys


_user = c.WinDLL("user32", use_last_error=True)
_controls = c.WinDLL("comctl32", use_last_error=True)
_lresult = c.c_ssize_t
_subclass_proc = c.WINFUNCTYPE(_lresult, w.HWND, w.UINT, w.WPARAM, w.LPARAM, c.c_size_t, c.c_size_t)


def _bind(dll, name, result, *arguments):
    api = getattr(dll, name, None)
    if api is not None:
        api.restype = result
        api.argtypes = arguments
    return api


_set_awareness = _bind(_user, "SetProcessDpiAwarenessContext", w.BOOL, w.HANDLE)
_get_window_dpi = _bind(_user, "GetDpiForWindow", w.UINT, w.HWND)
_get_system_dpi = _bind(_user, "GetDpiForSystem", w.UINT)
_get_metric = _bind(_user, "GetSystemMetricsForDpi", c.c_int, c.c_int, w.UINT)
_load_image = _bind(_user, "LoadImageW", w.HANDLE, w.HINSTANCE, w.LPCWSTR, w.UINT, c.c_int, c.c_int, w.UINT)
_destroy = _bind(_user, "DestroyIcon", w.BOOL, w.HICON)
_send = _bind(_user, "SendMessageW", _lresult, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
_attach = _bind(_controls, "SetWindowSubclass", w.BOOL, w.HWND, _subclass_proc, c.c_size_t, c.c_size_t)
_detach = _bind(_controls, "RemoveWindowSubclass", w.BOOL, w.HWND, _subclass_proc, c.c_size_t)
_forward = _bind(_controls, "DefSubclassProc", _lresult, w.HWND, w.UINT, w.WPARAM, w.LPARAM)

_WM_SETICON = 0x0080
_WM_GETICON = 0x007F
_WM_NCDESTROY = 0x0082
_WM_DPICHANGED = 0x02E0
_SMALL, _BIG, _SMALL2 = 0, 1, 2
_SUBCLASS_ID = 1
_windows: dict[int, _WindowIcons] = {}


def enable_per_monitor_dpi() -> None:
    # pywebview's later SetProcessDPIAware call leaves a configured awareness unchanged.
    if _set_awareness and not _set_awareness(-4):  # PER_MONITOR_AWARE_V2
        if c.get_last_error() != 5:  # an existing process awareness cannot be replaced
            _set_awareness(-3)  # PER_MONITOR_AWARE on older Windows 10


def window_dpi(hwnd: int) -> int:
    return (_get_window_dpi(hwnd) if _get_window_dpi and hwnd else 0) or (_get_system_dpi() if _get_system_dpi else 0) or 96


def _icon_size(dpi: int, width_metric: int, height_metric: int, base: int) -> tuple[int, int]:
    fallback = (base * dpi + 48) // 96
    if _get_metric:
        return _get_metric(width_metric, dpi) or fallback, _get_metric(height_metric, dpi) or fallback
    return fallback, fallback


def small_icon_size(dpi: int) -> tuple[int, int]:
    return _icon_size(dpi, 49, 50, 16)  # SM_CXSMICON / SM_CYSMICON


def large_icon_size(dpi: int) -> tuple[int, int]:
    return _icon_size(dpi, 11, 12, 32)  # SM_CXICON / SM_CYICON


def load_app_icon(width: int, height: int) -> int:
    if getattr(sys, "frozen", False):
        path = Path(sys._MEIPASS) / "gao_app_icon" / "app.ico"
        return _load_image(None, str(path), 1, width, height, 0x0010) or 0  # IMAGE_ICON, LR_LOADFROMFILE
    return 0


def destroy_icon(handle: int) -> None:
    _destroy(handle)


class _WindowIcons:
    def __init__(self, hwnd: int):
        self.hwnd = hwnd
        self.dpi = 0
        self.handles: dict[tuple[int, int], int] = {}

    def get(self, kind: int, dpi: int) -> int:
        size = large_icon_size(dpi) if kind == _BIG else small_icon_size(dpi)
        if size not in self.handles:
            if len(self.handles) >= 48 and dpi != self.dpi:
                return self.get(kind, self.dpi)
            self.handles[size] = load_app_icon(*size)
        return self.handles[size]

    def update(self, dpi: int) -> None:
        if self.dpi != dpi:
            self.dpi = dpi
            for kind in (_SMALL, _BIG):
                if icon := self.get(kind, dpi):
                    _send(self.hwnd, _WM_SETICON, kind, icon)

    def release(self) -> None:
        for icon in self.handles.values():
            if icon:
                destroy_icon(icon)


@_subclass_proc
def _icon_messages(hwnd, message, wparam, lparam, subclass_id, _reference):
    icons = _windows.get(hwnd)
    if icons is None:
        return _forward(hwnd, message, wparam, lparam)
    if message == _WM_GETICON and wparam in (_SMALL, _BIG, _SMALL2):
        dpi = lparam if 96 <= lparam <= 768 else icons.dpi
        if icon := icons.get(wparam, dpi):
            return icon
    if message == _WM_NCDESTROY:
        _detach(hwnd, _icon_messages, subclass_id)
        _windows.pop(hwnd, None)
        result = _forward(hwnd, message, wparam, lparam)
        icons.release()
        return result
    result = _forward(hwnd, message, wparam, lparam)
    if message == _WM_DPICHANGED and hwnd in _windows:
        icons.update((wparam & 0xFFFF) or window_dpi(hwnd))
    return result


def set_window_icons(hwnd: int) -> None:
    """Install on the thread that owns the native window, before it is shown."""
    if hwnd and hwnd not in _windows and _attach(hwnd, _icon_messages, _SUBCLASS_ID, 0):
        icons = _WindowIcons(hwnd)
        _windows[hwnd] = icons
        icons.update(window_dpi(hwnd))
