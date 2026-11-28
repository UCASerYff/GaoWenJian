"""Operate only test-owned windows on an inactive, disposable Windows desktop."""

from __future__ import annotations

import ctypes as c
from ctypes import wintypes as w
import json
from pathlib import Path
from queue import Queue
import struct
import subprocess
import sys
from threading import Thread
from uuid import uuid4


WM_COPYDATA = 0x4A
WM_GETICON = 0x7F
WM_DPICHANGED = 0x02E0
DRIVER_REQUEST = 0x8000
TRAY_CLASS = "GaoWenJian.TrayWindow"
PER_MONITOR_AWARE_V2 = -4
DPI_UNAWARE = -1
LRESULT = c.c_ssize_t
WindowProc = c.WINFUNCTYPE(LRESULT, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
EnumProc = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)


class WindowClass(c.Structure):
    _fields_ = [("style", w.UINT), ("proc", WindowProc), ("clsExtra", c.c_int), ("wndExtra", c.c_int),
                ("instance", w.HINSTANCE), ("icon", w.HICON), ("cursor", w.HANDLE), ("brush", w.HBRUSH),
                ("menu", w.LPCWSTR), ("name", w.LPCWSTR)]


class StartupInfo(c.Structure):
    _fields_ = [("cb", w.DWORD), ("reserved", w.LPWSTR), ("desktop", w.LPWSTR), ("title", w.LPWSTR),
                ("x", w.DWORD), ("y", w.DWORD), ("width", w.DWORD), ("height", w.DWORD),
                ("charsX", w.DWORD), ("charsY", w.DWORD), ("fill", w.DWORD), ("flags", w.DWORD),
                ("show", w.WORD), ("reservedSize", w.WORD), ("reservedData", c.c_void_p),
                ("stdin", w.HANDLE), ("stdout", w.HANDLE), ("stderr", w.HANDLE)]


class ProcessInfo(c.Structure):
    _fields_ = [("process", w.HANDLE), ("thread", w.HANDLE), ("pid", w.DWORD), ("tid", w.DWORD)]


class ProcessEntry(c.Structure):
    _fields_ = [("size", w.DWORD), ("usage", w.DWORD), ("pid", w.DWORD), ("heap", c.c_size_t),
                ("module", w.DWORD), ("threads", w.DWORD), ("parent", w.DWORD), ("priority", w.LONG),
                ("flags", w.DWORD), ("executable", w.WCHAR * 260)]


class CopyData(c.Structure):
    _fields_ = [("kind", w.WPARAM), ("size", w.DWORD), ("data", c.c_void_p)]


class IconInfo(c.Structure):
    _fields_ = [("icon", w.BOOL), ("x", w.DWORD), ("y", w.DWORD), ("mask", w.HBITMAP), ("color", w.HBITMAP)]


class Bitmap(c.Structure):
    _fields_ = [("type", w.LONG), ("width", w.LONG), ("height", w.LONG), ("stride", w.LONG),
                ("planes", w.WORD), ("bits_per_pixel", w.WORD), ("bits", c.c_void_p)]


def bind(library, name, result, *args):
    method = getattr(library, name)
    method.restype = result
    method.argtypes = args
    return method


user = c.WinDLL("user32", use_last_error=True)
kernel = c.WinDLL("kernel32", use_last_error=True)
gdi = c.WinDLL("gdi32", use_last_error=True)
create_desktop = bind(user, "CreateDesktopW", w.HANDLE, w.LPCWSTR, w.LPCWSTR, c.c_void_p, w.DWORD, w.DWORD, c.c_void_p)
thread_desktop = bind(user, "GetThreadDesktop", w.HANDLE, w.DWORD)
set_desktop = bind(user, "SetThreadDesktop", w.BOOL, w.HANDLE)
close_desktop = bind(user, "CloseDesktop", w.BOOL, w.HANDLE)
enum_windows = bind(user, "EnumWindows", w.BOOL, EnumProc, w.LPARAM)
owner = bind(user, "GetWindowThreadProcessId", w.DWORD, w.HWND, c.POINTER(w.DWORD))
class_name = bind(user, "GetClassNameW", c.c_int, w.HWND, w.LPWSTR, c.c_int)
window_title = bind(user, "GetWindowTextW", c.c_int, w.HWND, w.LPWSTR, c.c_int)
is_visible = bind(user, "IsWindowVisible", w.BOOL, w.HWND)
post = bind(user, "PostMessageW", w.BOOL, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
send_timeout = bind(user, "SendMessageTimeoutW", LRESULT, w.HWND, w.UINT, w.WPARAM, w.LPARAM,
                    w.UINT, w.UINT, c.POINTER(c.c_size_t))
dpi_for_window = bind(user, "GetDpiForWindow", w.UINT, w.HWND)
metric_for_dpi = bind(user, "GetSystemMetricsForDpi", c.c_int, c.c_int, w.UINT)
get_icon_info = bind(user, "GetIconInfo", w.BOOL, w.HICON, c.POINTER(IconInfo))
get_window_rect = bind(user, "GetWindowRect", w.BOOL, w.HWND, c.POINTER(w.RECT))
set_dpi_context = bind(user, "SetThreadDpiAwarenessContext", w.HANDLE, w.HANDLE)
get_object = bind(gdi, "GetObjectW", c.c_int, w.HGDIOBJ, c.c_int, c.c_void_p)
delete_object = bind(gdi, "DeleteObject", w.BOOL, w.HGDIOBJ)
post_thread = bind(user, "PostThreadMessageW", w.BOOL, w.DWORD, w.UINT, w.WPARAM, w.LPARAM)
register_message = bind(user, "RegisterWindowMessageW", w.UINT, w.LPCWSTR)
register_class = bind(user, "RegisterClassW", w.ATOM, c.POINTER(WindowClass))
unregister_class = bind(user, "UnregisterClassW", w.BOOL, w.LPCWSTR, w.HINSTANCE)
create_window = bind(user, "CreateWindowExW", w.HWND, w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD,
                     c.c_int, c.c_int, c.c_int, c.c_int, w.HWND, w.HMENU, w.HINSTANCE, c.c_void_p)
destroy_window = bind(user, "DestroyWindow", w.BOOL, w.HWND)
default_proc = bind(user, "DefWindowProcW", LRESULT, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
get_message = bind(user, "GetMessageW", c.c_int, c.POINTER(w.MSG), w.HWND, w.UINT, w.UINT)
dispatch = bind(user, "DispatchMessageW", LRESULT, c.POINTER(w.MSG))
module = bind(kernel, "GetModuleHandleW", w.HINSTANCE, w.LPCWSTR)
thread_id = bind(kernel, "GetCurrentThreadId", w.DWORD)
create_process = bind(kernel, "CreateProcessW", w.BOOL, w.LPCWSTR, w.LPWSTR, c.c_void_p, c.c_void_p,
                      w.BOOL, w.DWORD, c.c_void_p, w.LPCWSTR, c.POINTER(StartupInfo), c.POINTER(ProcessInfo))
wait = bind(kernel, "WaitForSingleObject", w.DWORD, w.HANDLE, w.DWORD)
exit_code = bind(kernel, "GetExitCodeProcess", w.BOOL, w.HANDLE, c.POINTER(w.DWORD))
terminate = bind(kernel, "TerminateProcess", w.BOOL, w.HANDLE, w.UINT)
close_handle = bind(kernel, "CloseHandle", w.BOOL, w.HANDLE)
open_process = bind(kernel, "OpenProcess", w.HANDLE, w.DWORD, w.BOOL, w.DWORD)
snapshot = bind(kernel, "CreateToolhelp32Snapshot", w.HANDLE, w.DWORD, w.DWORD)
first_process = bind(kernel, "Process32FirstW", w.BOOL, w.HANDLE, c.POINTER(ProcessEntry))
next_process = bind(kernel, "Process32NextW", w.BOOL, w.HANDLE, c.POINTER(ProcessEntry))


def checked(result):
    if not result:
        raise c.WinError(c.get_last_error())
    return result


def reply(**result):
    print(json.dumps(result), flush=True)


def icon_pixels(handle):
    if not handle:
        return None
    info = IconInfo()
    if not get_icon_info(handle, c.byref(info)):
        return None
    try:
        bitmap = Bitmap()
        source = info.color or info.mask
        if not info.icon or not source or not get_object(source, c.sizeof(bitmap), c.byref(bitmap)):
            return None
        height = bitmap.height if info.color else bitmap.height // 2
        return [bitmap.width, height]
    finally:
        for bitmap_handle in (info.color, info.mask):
            if bitmap_handle:
                delete_object(bitmap_handle)


def icon_metrics(dpi):
    return {"small": [metric_for_dpi(i, dpi) for i in (49, 50)], "large": [metric_for_dpi(i, dpi) for i in (11, 12)]}


def attached_icons(hwnd, requested_dpi):
    icons = {}
    for name, kind in (("small", 0), ("large", 1)):
        handle = c.c_size_t()
        checked(send_timeout(hwnd, WM_GETICON, kind, requested_dpi, 0x0002, 500, c.byref(handle)))
        icons[name] = icon_pixels(handle.value)
    return icons


def window_icons(hwnd, dpis):
    native_dpi = checked(dpi_for_window(hwnd))
    requested = list(dict.fromkeys([native_dpi, *dpis]))
    if any(type(dpi) is not int or not 72 <= dpi <= 768 for dpi in requested):
        raise ValueError("Invalid DPI for icon sampling")
    native = {"dpi": native_dpi, "expected": icon_metrics(native_dpi), "icons": attached_icons(hwnd, 0)}
    samples = [{"dpi": dpi, "expected": icon_metrics(dpi), "icons": attached_icons(hwnd, dpi)} for dpi in requested]
    return {"native": native, "samples": samples}


def process_tree(root):
    """Include the real CPython process when a venv launches its Windows redirector."""
    handle = snapshot(2, 0)
    if handle == c.c_void_p(-1).value:
        raise c.WinError(c.get_last_error())
    children = {}
    try:
        process = ProcessEntry(size=c.sizeof(ProcessEntry))
        present = first_process(handle, c.byref(process))
        while present:
            children.setdefault(process.parent, []).append(process.pid)
            present = next_process(handle, c.byref(process))
    finally:
        close_handle(handle)
    related = [root]
    for pid in related:
        related.extend(child for child in children.get(pid, ()) if child not in related)
    return related


class Driver:
    def __init__(self, executable: Path):
        self.executable = executable
        self.desktop_name = "GaoWenJianTraySmoke-" + uuid4().hex
        self.processes = {}
        self.commands = Queue()
        self.events = []
        self.icons = set()
        self.window_proc = WindowProc(self.shell_proc)
        self.instance = checked(module(None))
        self.parent_desktop = checked(thread_desktop(thread_id()))
        self.desktop = checked(create_desktop(self.desktop_name, None, None, 0, 0x01FF, None))
        self.shell = None

    def create_shell(self, dpi_context=PER_MONITOR_AWARE_V2):
        previous = checked(set_dpi_context(c.c_void_p(dpi_context)))
        try:
            return checked(create_window(0, "Shell_TrayWnd", "GaoWenJian test shell", 0, 0, 0, 0, 0,
                                         None, None, self.instance, None))
        finally:
            checked(set_dpi_context(previous))

    def shell_proc(self, hwnd, message, wparam, lparam):
        if message != WM_COPYDATA:
            return default_proc(hwnd, message, wparam, lparam)
        if not lparam:
            return 0
        package = CopyData.from_address(lparam)
        if package.kind != 1 or not package.data or not 24 <= package.size <= 4096:
            return 0
        # Shell_NotifyIcon emits a cross-process packet containing the operation and a marshaled notification record.
        raw = c.string_at(package.data, package.size)
        signature, event, _, window, icon_id, flags = struct.unpack_from("<6I", raw)
        if signature != 0x34753423:
            return 0
        marker = (window, icon_id)
        if event == 0:
            self.icons.add(marker)
        elif event == 2:
            self.icons.discard(marker)
        observed = {"event": event, "icon": icon_id}
        if event in {0, 1} and flags & 2:
            # The shell packet uses a packed 32-bit notification prefix even on x64.
            observed["pixels"] = icon_pixels(struct.unpack_from("<I", raw, 28)[0]) if len(raw) >= 32 else None
        self.events.append(observed)
        return int(event != 1 or marker in self.icons)

    def notify_tray_dpi(self, hwnd, request):
        before = checked(dpi_for_window(self.shell))
        if request.get("change_shell"):
            # Keep logical tray entries while giving the replacement test HWND a different awareness.
            # On a 96-dpi monitor both test HWNDs report 96, so leave the current shell in place.
            replacement = self.create_shell(DPI_UNAWARE)
            if checked(dpi_for_window(replacement)) == before:
                checked(destroy_window(replacement))
            else:
                checked(destroy_window(self.shell))
                self.shell = replacement
        after = checked(dpi_for_window(self.shell))
        dpi = request.get("dpi", after if before != after else (144 if after != 144 else 96))
        if type(dpi) is not int or not 72 <= dpi <= 768:
            raise ValueError("Invalid synthetic DPI")
        rectangle = w.RECT()
        checked(get_window_rect(hwnd, c.byref(rectangle)))
        result = c.c_size_t()
        # The system message requires a synchronous send. Only the tray receives it here.
        checked(send_timeout(hwnd, WM_DPICHANGED, dpi << 16 | dpi, c.addressof(rectangle), 0x0002, 1000, c.byref(result)))
        return {"beforeDpi": before, "afterDpi": after, "messageDpi": dpi, "expected": icon_metrics(after)["small"]}

    def windows(self, pid):
        result = []
        owned = set(process_tree(pid))

        @EnumProc
        def collect(hwnd, _):
            process_id = w.DWORD()
            owner(hwnd, c.byref(process_id))
            if process_id.value in owned:
                kind, title = c.create_unicode_buffer(256), c.create_unicode_buffer(256)
                class_name(hwnd, kind, len(kind))
                window_title(hwnd, title, len(title))
                result.append({"hwnd": hwnd, "class": kind.value, "title": title.value, "visible": bool(is_visible(hwnd))})
            return 1

        checked(enum_windows(collect, 0))
        return result

    def start_process(self, args):
        launch = StartupInfo(cb=c.sizeof(StartupInfo), desktop=self.desktop_name)
        process = ProcessInfo()
        command_line = c.create_unicode_buffer(subprocess.list2cmdline([str(self.executable), *args]))
        checked(create_process(str(self.executable), command_line, None, None, False, 0x08000000, None,
                               str(self.executable.parent), c.byref(launch), c.byref(process)))
        close_handle(process.thread)
        self.processes[process.pid] = process.process
        return process.pid

    def status(self, pid):
        handle = self.processes[pid]
        if wait(handle, 0) == 0:
            result = w.DWORD()
            checked(exit_code(handle, c.byref(result)))
            return {"exit": result.value, "windows": []}
        return {"exit": None, "windows": self.windows(pid)}

    def handle_command(self, request):
        command = request["op"]
        if command == "start":
            return self.start_process(request["args"])
        if command == "status":
            return self.status(request["pid"])
        if command == "shell":
            dpi = checked(dpi_for_window(self.shell))
            return {"events": list(self.events), "icons": len(self.icons), "dpi": dpi, "expected": icon_metrics(dpi)["small"]}
        pid = request["pid"]
        hwnd = request["hwnd"]
        window = next((item for item in self.windows(pid) if item["hwnd"] == hwnd), None) if pid in self.processes else None
        if window is None:
            raise ValueError("Target is not a window owned by the test process")
        if command == "window-icons":
            return window_icons(hwnd, request.get("dpis", []))
        if command in {"tray-dpi-notification", "restart-shell"} and window["class"] != TRAY_CLASS:
            raise ValueError("Expected the test process tray window")
        if command == "tray-dpi-notification":
            return self.notify_tray_dpi(hwnd, request)
        if command == "restart-shell":
            checked(destroy_window(self.shell))
            self.icons.clear()
            self.shell = self.create_shell()
            checked(post(hwnd, checked(register_message("TaskbarCreated")), 0, 0))
            return True
        if command == "post":
            return bool(checked(post(hwnd, request["message"], request.get("wparam", 0), request.get("lparam", 0))))
        raise ValueError("Unknown Win32 test operation")

    def run(self):
        checked(set_desktop(self.desktop))
        checked(register_class(c.byref(WindowClass(proc=self.window_proc, instance=self.instance, name="Shell_TrayWnd"))))
        self.shell = self.create_shell()
        main_thread = thread_id()

        def read_commands():
            for line in sys.stdin:
                request = json.loads(line)
                self.commands.put(request)
                post_thread(main_thread, DRIVER_REQUEST, 0, 0)
                if request["op"] == "stop":
                    return
            self.commands.put({"op": "stop"})
            post_thread(main_thread, DRIVER_REQUEST, 0, 0)

        Thread(target=read_commands, daemon=True).start()
        reply(ready=True)
        try:
            message = w.MSG()
            while get_message(c.byref(message), None, 0, 0) > 0:
                if not message.hWnd and message.message == DRIVER_REQUEST:
                    request = self.commands.get()
                    if request["op"] == "stop":
                        return
                    try:
                        reply(id=request["id"], result=self.handle_command(request))
                    except (OSError, ValueError) as error:
                        reply(id=request["id"], error=str(error))
                else:
                    dispatch(c.byref(message))
        finally:
            for pid, handle in self.processes.items():
                if wait(handle, 0) != 0:
                    for child in reversed(process_tree(pid)[1:]):
                        owned = open_process(0x00100001, False, child)
                        if owned:
                            terminate(owned, 2)
                            close_handle(owned)
                    terminate(handle, 2)
                    wait(handle, 5000)
                close_handle(handle)
            destroy_window(self.shell)
            unregister_class("Shell_TrayWnd", self.instance)
            set_desktop(self.parent_desktop)
            close_desktop(self.desktop)


if __name__ == "__main__":
    Driver(Path(sys.argv[1]).resolve(strict=True)).run()
