"""命令行入口。窗口版与命令行版共用这些参数。"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from gaowenjian.errors import AppError
from gaowenjian.safety import default_data_dir
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
    parser.add_argument("--inspect", action="store_true")
    parser.add_argument("--self-check", action="store_true")
    parser.add_argument("--open", default=None)
    args = parser.parse_args(argv)
    if args.version:
        _out(VERSION_LABEL)
        return 0
    directory = default_data_dir() if not args.data_dir else Path(args.data_dir)
    tray = None
    try:
        if os.name == "nt" and not (args.no_browser or args.serve or args.hidden or args.self_check or args.inspect):
            from gaowenjian.tray_win import DesktopTray

            tray = DesktopTray(directory)
            is_gui = not getattr(sys, "frozen", False) or Path(sys.executable).stem.casefold() != "gaowenjian-cli"
            if not tray.claim_or_forward(args.open, show_icon=is_gui):
                return 0
        return _run(args, directory, tray)
    except (AppError, OSError) as exc:
        _err(str(exc))
        if tray and not sys.stderr:
            from ctypes import windll

            windll.user32.MessageBoxW(None, str(exc), "搞文件", 0x10)
        return 2
    finally:
        if tray:
            tray.close()


def _run(args, directory, tray) -> int:
    try:
        workspace = Workspace(directory)
        if args.open:
            path = Path(args.open).expanduser()
            if path.suffix.lower() in {".gaoaction", ".gaoresult"}:
                workspace.launch_handoff = str(path.absolute())
            else:
                workspace.open_path(path)
        if args.self_check:
            return _self_check(workspace)
        if args.inspect:
            _inspect(workspace)
            return 0
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


def _inspect(workspace: Workspace) -> None:
    _out(f"version={VERSION_LABEL}")
    _out(f"tabs={len(workspace.tabs)}")
    _out(f"dirty={workspace.dirty_count()}")
    _out(f"notes={len(workspace.notes.notes)}")
    _out(f"data={workspace.data_dir}")


def _out(message: str) -> None:
    if sys.stdout:
        print(message, flush=True)


def _err(message: str) -> None:
    if sys.stderr:
        print(message, file=sys.stderr)
