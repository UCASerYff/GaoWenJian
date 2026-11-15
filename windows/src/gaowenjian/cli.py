"""命令行入口。窗口版与命令行版共用这些参数。"""

from __future__ import annotations

import argparse
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
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--inspect", action="store_true")
    parser.add_argument("--self-check", action="store_true")
    parser.add_argument("--open", default=None)
    args = parser.parse_args(argv)
    if args.version:
        _out(VERSION_LABEL)
        return 0
    directory = default_data_dir() if not args.data_dir else Path(args.data_dir)
    try:
        workspace = Workspace(directory)
        if args.open:
            workspace.open_path(Path(args.open))
        if args.self_check:
            return _self_check(workspace)
        if args.inspect:
            _inspect(workspace)
            return 0
    except AppError as exc:
        _err(exc.message)
        return 2
    server = serve(workspace, port=args.port, open_browser=not args.no_browser and not args.inspect)
    try:
        server.shutdown_requested.wait()
    except KeyboardInterrupt:
        pass
    finally:
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
        print(message)


def _err(message: str) -> None:
    if sys.stderr:
        print(message, file=sys.stderr)
