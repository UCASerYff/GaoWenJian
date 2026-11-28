"""命令行入口。窗口版与命令行版共用这些参数。"""

from __future__ import annotations

import argparse
import os
import stat
import sys
from contextlib import contextmanager
from pathlib import Path
from tempfile import TemporaryDirectory

from gaowenjian.errors import AppError
from gaowenjian.safety import GuardedJSON, default_data_dir
from gaowenjian.version import VERSION_LABEL
from gaowenjian.web import serve
from gaowenjian.workspace import Workspace


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="GaoWenJian", description="搞文件 Windows 版")
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--data-dir", default=None)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--hidden", action="store_true", help="start the native Windows windows hidden for smoke tests")
    parser.add_argument("--port", type=int, default=0)
    tools = parser.add_mutually_exclusive_group()
    tools.add_argument("--inspect", action="store_true")
    tools.add_argument("--self-check", action="store_true")
    parser.add_argument("--open", default=None)
    args = parser.parse_args(argv)
    if args.version:
        _out(VERSION_LABEL)
        return 0
    if args.open is not None and (args.inspect or args.self_check):
        parser.error("--inspect 和 --self-check 不支持与 --open 同时使用。")
    ordinary_desktop = os.name == "nt" and not (args.no_browser or args.serve or args.hidden)
    instance = None
    try:
        if args.self_check:
            with TemporaryDirectory(prefix="GaoWenJian-self-check-") as isolated:
                return _self_check(Workspace(Path(isolated)))
        directory = default_data_dir() if not args.data_dir else Path(args.data_dir)
        if args.inspect:
            _inspect(directory)
            return 0
        if os.name == "nt":
            from gaowenjian.icons_win import enable_per_monitor_dpi
            from gaowenjian.tray_win import DesktopTray

            if not args.no_browser:
                enable_per_monitor_dpi()
            instance = DesktopTray(directory)
            is_gui = not getattr(sys, "frozen", False) or Path(sys.executable).stem.casefold() != "gaowenjian-cli"
            if not instance.claim_or_forward(args.open, show_icon=is_gui, activate=ordinary_desktop,
                                             forward=ordinary_desktop and args.port == 0):
                return 0
            return _run(args, directory, instance if ordinary_desktop else None)
        with _lock_workspace(directory):
            return _run(args, directory, None)
    except (AppError, OSError) as exc:
        _err(str(exc))
        if instance and ordinary_desktop and not sys.stderr:
            from ctypes import windll

            windll.user32.MessageBoxW(None, str(exc), "搞文件", 0x10)
        return 2
    finally:
        if instance:
            instance.close()


@contextmanager
def _lock_workspace(directory):
    """The source launcher also permits a browser workspace on POSIX."""
    import fcntl

    directory.mkdir(parents=True, exist_ok=True)
    path = directory / ".workspace.lock"
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid():
            raise AppError("无法安全锁定资料目录。", "instance")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise AppError("资料目录正在由另一个搞文件进程使用。", "instance") from exc
        yield
    finally:
        os.close(fd)


def _run(args, directory, tray) -> int:
    try:
        workspace = Workspace(directory)
        if args.open:
            path = Path(args.open).expanduser()
            if path.suffix.lower() in {".gaoaction", ".gaoresult"}:
                workspace.launch_handoff = str(path.absolute())
            else:
                workspace.open_path(path)
    except AppError as exc:
        _err(exc.message)
        return 2
    server = serve(workspace, port=args.port, open_browser=False)
    if args.no_browser:
        _out(server.url)
    try:
        if args.no_browser:
            server.shutdown_requested.wait()
        elif os.name == "nt":
            from gaowenjian.desktop import run_desktop

            run_desktop(server, activate=args.open is not None, hidden=args.hidden, tray=tray)
        else:
            import webbrowser

            webbrowser.open(server.url + ("?view=editor" if args.open else ""))
            server.shutdown_requested.wait()
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        _err(f"无法打开 Windows 工作台：{exc}")
        if os.name == "nt" and not args.no_browser and not args.hidden:
            from ctypes import windll

            windll.user32.MessageBoxW(None, "无法启动搞文件窗口。请确认 Microsoft Edge WebView2 Runtime 可用。\n\n" + str(exc), "搞文件", 0x10)
        return 2
    finally:
        server.shutdown()
        server.server_close()
    return 0


def _self_check(workspace: Workspace) -> int:
    tab = workspace.new_text("markdown", "CI self check\n")
    if "CI self check" not in tab.text:
        _err("self-check did not keep text")
        return 2
    preview = workspace.preview(tab.id)
    if "<p>" not in preview["html"]:
        _err("self-check preview failed")
        return 2
    _out("self-check ok")
    return 0


def _inspect(directory: Path) -> None:
    from gaowenjian.notes import NotesStore

    recovery = GuardedJSON(directory / "recovery.json")
    entries = recovery.data
    drafts = len(entries) if recovery.readable and isinstance(entries, list) and all(isinstance(item, dict) for item in entries) else 0
    notes = NotesStore(directory / "StickyNotes")
    _out(f"version={VERSION_LABEL}")
    _out(f"tabs={drafts}")
    _out(f"dirty={drafts}")
    _out(f"notes={len(notes.notes)}")
    _out(f"data={directory}")


def _out(message: str) -> None:
    if sys.stdout:
        print(message, flush=True)


def _err(message: str) -> None:
    if sys.stderr:
        print(message, file=sys.stderr)
