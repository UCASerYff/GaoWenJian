"""Win32 notification icon and local desktop activation for one workspace profile."""

from __future__ import annotations

import ctypes as c
import ctypes.wintypes as w
import hashlib
import os
import queue
import threading
import time
from pathlib import Path

from gaowenjian.errors import AppError
from gaowenjian.icons_win import destroy_icon, load_app_icon, small_icon_size, window_dpi
from gaowenjian.version import APP_NAME

WINDOW_CLASS = "GaoWenJian.TrayWindow"
ICON_ID = 1
TRAY_CALLBACK = 0x8001
STOP_TRAY = 0x8002
OPEN_WORKSPACE, EXIT_APPLICATION = 1, 2
WM_COPYDATA, WM_COMMAND, WM_TIMER = 0x004A, 0x0111, 0x0113
WM_SETTINGCHANGE, WM_DISPLAYCHANGE, WM_DPICHANGED = 0x001A, 0x007E, 0x02E0
WM_LBUTTONUP, WM_RBUTTONUP, WM_CONTEXTMENU = 0x0202, 0x0205, 0x007B
NIN_SELECT, NIN_KEYSELECT = 0x0400, 0x0401
NIM_ADD, NIM_MODIFY, NIM_DELETE, NIM_SETFOCUS, NIM_SETVERSION = 0, 1, 2, 3, 4
NIF_MESSAGE, NIF_ICON, NIF_TIP, NIF_SHOWTIP = 0x01, 0x02, 0x04, 0x80
ICON_TIMER = 1
ACTIVATE_WORKSPACE = 0x47414F57
MAX_PATH_BYTES = 131072

kernel = c.WinDLL("kernel32", use_last_error=True)
user = c.WinDLL("user32", use_last_error=True)
shell = c.WinDLL("shell32", use_last_error=True)


def _bind(dll, name, result, *parameters):
    function = getattr(dll, name)
    function.restype = result
    function.argtypes = parameters
    return function


_find_window = _bind(user, "FindWindowW", w.HWND, w.LPCWSTR, w.LPCWSTR)
_post_message = _bind(user, "PostMessageW", w.BOOL, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
_close_handle = _bind(kernel, "CloseHandle", w.BOOL, w.HANDLE)
_wndproc = c.WINFUNCTYPE(c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)


class _CopyData(c.Structure):
    _fields_ = [("kind", c.c_size_t), ("length", w.DWORD), ("bytes", c.c_void_p)]


class _WindowClass(c.Structure):
    _fields_ = [("style", w.UINT), ("procedure", _wndproc), ("class_extra", c.c_int), ("window_extra", c.c_int),
                ("instance", w.HINSTANCE), ("icon", w.HICON), ("cursor", w.HANDLE), ("background", w.HBRUSH),
                ("menu", w.LPCWSTR), ("name", w.LPCWSTR)]


class _NotifyIcon(c.Structure):
    _fields_ = [("size", w.DWORD), ("window", w.HWND), ("id", w.UINT), ("flags", w.UINT),
                ("message", w.UINT), ("icon", w.HICON), ("tip", w.WCHAR * 128), ("state", w.DWORD),
                ("state_mask", w.DWORD), ("info", w.WCHAR * 256), ("version", w.UINT),
                ("info_title", w.WCHAR * 64), ("info_flags", w.DWORD), ("guid", c.c_ubyte * 16),
                ("balloon", w.HICON)]


_notify = _bind(shell, "Shell_NotifyIconW", w.BOOL, w.DWORD, c.POINTER(_NotifyIcon))


class DesktopTray:
    def __init__(self, profile: Path):
        # Distinct test profiles stay independent. The ordinary path always maps to the same name.
        identity = os.path.normcase(str(profile.resolve())).encode("utf-8", errors="surrogatepass")
        self._name = "GaoWenJian-" + hashlib.sha256(identity).hexdigest()
        self._mutexes = []
        self._owns_mutexes = False
        self._window = None
        self._thread = None
        self._ready = threading.Event()
        self._stopping = threading.Event()
        self._show_icon = False
        self.available = False
        self.events = queue.SimpleQueue()

    def claim_or_forward(self, path: str | None, *, show_icon: bool = True, activate: bool = True,
                         forward: bool = True) -> bool:
        """True runs a workspace. False means the existing workspace accepted the launch."""
        create = _bind(kernel, "CreateMutexW", w.HANDLE, w.LPVOID, w.BOOL, w.LPCWSTR)
        wait = _bind(kernel, "WaitForMultipleObjects", w.DWORD, w.DWORD, c.POINTER(w.HANDLE), w.BOOL, w.DWORD)
        # Global blocks additional sessions. Local also respects an older desktop in this session.
        for namespace in ("Global\\", "Local\\"):
            mutex = create(None, False, namespace + self._name)
            if not mutex:
                raise c.WinError(c.get_last_error())
            self._mutexes.append(mutex)
        handles = (w.HANDLE * len(self._mutexes))(*self._mutexes)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            result = wait(len(handles), handles, True, 75 if forward else 0)
            if result in {0, 1, 0x80, 0x81}:  # WAIT_OBJECT_0 or WAIT_ABANDONED_0 plus handle index.
                self._owns_mutexes = True
                if activate:
                    self._show_icon = show_icon
                    self._thread = threading.Thread(target=self._message_loop, name="GaoWenJian activation window", daemon=True)
                    self._thread.start()
                    self._ready.wait(5)
                return True
            if result != 0x102:  # WAIT_TIMEOUT
                raise c.WinError(c.get_last_error())
            if not forward:
                break
            if self._forward(path):
                return False
        raise AppError("资料目录正在由另一个搞文件进程使用。请关闭原窗口或停止原服务后重试。", "instance")

    def _forward(self, path):
        hwnd = _find_window(WINDOW_CLASS, self._name)
        if not hwnd:
            return False
        owner = w.DWORD()
        _bind(user, "GetWindowThreadProcessId", w.DWORD, w.HWND, c.POINTER(w.DWORD))(hwnd, c.byref(owner))
        if owner.value:
            _bind(user, "AllowSetForegroundWindow", w.BOOL, w.DWORD)(owner.value)
        payload = os.path.abspath(path).encode("utf-16-le", errors="surrogatepass") if path else b""
        buffer = c.create_string_buffer(payload)
        data = _CopyData(ACTIVATE_WORKSPACE, len(payload), c.addressof(buffer))
        handled = c.c_size_t()
        send = _bind(user, "SendMessageTimeoutW", c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM,
                     w.UINT, w.UINT, c.POINTER(c.c_size_t))
        return bool(send(hwnd, WM_COPYDATA, 0, c.addressof(data), 0x23, 1000, c.byref(handled)) and handled.value)

    def stop_accepting(self):
        self._stopping.set()

    def close(self):
        self.stop_accepting()
        self.events.put(None)
        if self._window:
            _post_message(self._window, STOP_TRAY, 0, 0)
        if self._thread:
            self._thread.join(timeout=5)
        release = _bind(kernel, "ReleaseMutex", w.BOOL, w.HANDLE)
        for mutex in reversed(self._mutexes):
            if self._owns_mutexes:
                release(mutex)
            _close_handle(mutex)
        self._mutexes.clear()

    def _receive(self, pointer):
        if self._stopping.is_set() or not pointer:
            return False
        data = _CopyData.from_address(pointer)
        if data.kind != ACTIVATE_WORKSPACE or data.length > MAX_PATH_BYTES or data.length % 2:
            return False
        if data.length and not data.bytes:
            return False
        path = c.string_at(data.bytes, data.length).decode("utf-16-le", errors="surrogatepass") if data.length else ""
        if path and ("\x00" in path or not os.path.isabs(path)):
            return False
        self.events.put((OPEN_WORKSPACE, path))
        return True

    def _message_loop(self):
        instance = _bind(kernel, "GetModuleHandleW", w.HMODULE, w.LPCWSTR)(None)
        taskbar_created = _bind(user, "RegisterWindowMessageW", w.UINT, w.LPCWSTR)("TaskbarCreated")
        default = _bind(user, "DefWindowProcW", c.c_ssize_t, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
        timer = _bind(user, "SetTimer", c.c_size_t, w.HWND, c.c_size_t, w.UINT, w.LPVOID)
        post_quit = _bind(user, "PostQuitMessage", None, c.c_int)
        data = _NotifyIcon()
        registered = version4 = owns_icon = False
        size = None

        def sync_icon():
            nonlocal registered, version4, owns_icon, size
            if not self._show_icon or self._stopping.is_set() or not data.window:
                return
            # The activation window stays hidden and can be on a different monitor than the taskbar.
            taskbar = _find_window("Shell_TrayWnd", None)
            wanted_size = small_icon_size(window_dpi(taskbar or data.window))
            if wanted_size != size:
                replacement, owns_replacement = _load_icon(*wanted_size)
                if replacement:
                    update = _NotifyIcon(size=data.size, window=data.window, id=data.id, flags=NIF_ICON, icon=replacement)
                    if registered and not _notify(NIM_MODIFY, c.byref(update)):
                        if owns_replacement:
                            destroy_icon(replacement)
                        return
                    if owns_icon:
                        destroy_icon(data.icon)
                    data.icon, owns_icon, size = replacement, owns_replacement, wanted_size
            if not registered and data.icon:
                registered = bool(_notify(NIM_ADD, c.byref(data)))
                if registered:
                    self.available = True  # Keep hide-to-tray available during Explorer restart.
                    version4 = bool(_notify(NIM_SETVERSION, c.byref(data)))

        @_wndproc
        def procedure(hwnd, message, first, second):
            nonlocal registered, version4
            if message == STOP_TRAY:
                _bind(user, "EndMenu", w.BOOL)()
                post_quit(0)
                return 0
            if taskbar_created and message == taskbar_created:
                if registered:
                    _notify(NIM_DELETE, c.byref(data))
                registered = version4 = False
                sync_icon()
                return 0
            if message == WM_TIMER and first == ICON_TIMER:
                sync_icon()  # Retry registration and catch taskbar monitor changes between broadcasts.
                return 0
            if message in {WM_DPICHANGED, WM_DISPLAYCHANGE, WM_SETTINGCHANGE}:
                sync_icon()
            if message == WM_COPYDATA:
                return int(self._receive(second))
            if self._stopping.is_set():
                return default(hwnd, message, first, second)
            if message == TRAY_CALLBACK:
                event = second & 0xFFFF
                icon_id = (second >> 16) & 0xFFFF if version4 else first
                if icon_id != ICON_ID:
                    return 0
                if event == WM_LBUTTONUP or (version4 and event in {NIN_SELECT, NIN_KEYSELECT}):
                    self.events.put((OPEN_WORKSPACE, ""))
                elif (version4 and event == WM_CONTEXTMENU) or (not version4 and event == WM_RBUTTONUP):
                    if not _tray_menu(hwnd, first if version4 else None) and registered:
                        _notify(NIM_SETFOCUS, c.byref(data))
                return 0
            if message == WM_COMMAND and first in {OPEN_WORKSPACE, EXIT_APPLICATION} and not second:
                self.events.put((first, ""))
                return 0
            return default(hwnd, message, first, second)

        descriptor = _WindowClass(0, procedure, 0, 0, instance, None, None, None, None, WINDOW_CLASS)
        atom = _bind(user, "RegisterClassW", w.ATOM, c.POINTER(_WindowClass))(c.byref(descriptor))
        try:
            if not atom or self._stopping.is_set():
                return
            create = _bind(user, "CreateWindowExW", w.HWND, w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD, c.c_int, c.c_int,
                           c.c_int, c.c_int, w.HWND, w.HMENU, w.HINSTANCE, w.LPVOID)
            self._window = create(0, WINDOW_CLASS, self._name, 0, 0, 0, 0, 0, None, None, instance, None)
            if not self._window or self._stopping.is_set():
                return
            data.size, data.window, data.id = c.sizeof(data), self._window, ICON_ID
            data.flags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP
            data.message, data.tip, data.version = TRAY_CALLBACK, APP_NAME, 4
            if self._show_icon:
                sync_icon()
                timer(self._window, ICON_TIMER, 2000, None)  # Explorer may have yet to start when we first launch.
            self._ready.set()
            get_message = _bind(user, "GetMessageW", w.BOOL, c.POINTER(w.MSG), w.HWND, w.UINT, w.UINT)
            dispatch = _bind(user, "DispatchMessageW", c.c_ssize_t, c.POINTER(w.MSG))
            message = w.MSG()
            while not self._stopping.is_set() and get_message(c.byref(message), None, 0, 0) > 0:
                dispatch(c.byref(message))
        finally:
            self._ready.set()
            self.available = False
            if registered:
                _notify(NIM_DELETE, c.byref(data))
            if self._window:
                _bind(user, "DestroyWindow", w.BOOL, w.HWND)(self._window)
                self._window = None
            if data.icon and owns_icon:
                destroy_icon(data.icon)
            if atom:
                _bind(user, "UnregisterClassW", w.BOOL, w.LPCWSTR, w.HINSTANCE)(WINDOW_CLASS, instance)


def _load_icon(width: int, height: int) -> tuple[int, bool]:
    if icon := load_app_icon(width, height):
        return icon, True
    load_default = _bind(user, "LoadIconW", w.HICON, w.HINSTANCE, c.c_void_p)
    return load_default(None, 32512) or 0, False  # IDI_APPLICATION is shared.


def _tray_menu(hwnd, anchor):
    menu = _bind(user, "CreatePopupMenu", w.HMENU)()
    if not menu:
        return 0
    try:
        append = _bind(user, "AppendMenuW", w.BOOL, w.HMENU, w.UINT, c.c_size_t, w.LPCWSTR)
        if not (append(menu, 0, OPEN_WORKSPACE, "打开 " + APP_NAME) and append(menu, 0, EXIT_APPLICATION, "退出")):
            return 0
        _bind(user, "SetMenuDefaultItem", w.BOOL, w.HMENU, w.UINT, w.UINT)(menu, OPEN_WORKSPACE, 0)
        point = w.POINT(-1, -1) if anchor is None else w.POINT(c.c_short(anchor).value, c.c_short(anchor >> 16).value)
        if (point.x, point.y) == (-1, -1):
            _bind(user, "GetCursorPos", w.BOOL, c.POINTER(w.POINT))(c.byref(point))
        _bind(user, "SetForegroundWindow", w.BOOL, w.HWND)(hwnd)
        track = _bind(user, "TrackPopupMenuEx", w.BOOL, w.HMENU, w.UINT, c.c_int, c.c_int, w.HWND, w.LPVOID)
        handled = track(menu, 0x0002, point.x, point.y, hwnd, None)  # TPM_RIGHTBUTTON, sends WM_COMMAND
        _post_message(hwnd, 0, 0, 0)  # Let the menu dismiss when its owner loses focus.
        return handled
    finally:
        _bind(user, "DestroyMenu", w.BOOL, w.HMENU)(menu)
