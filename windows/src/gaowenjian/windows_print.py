"""Print paginated Markdown with the native WebView2 used by the Windows host."""

from __future__ import annotations

import threading
import tempfile
from pathlib import Path
from urllib.parse import unquote, urlsplit

from gaowenjian.errors import AppError


def print_in_webview(window, document: str) -> bytes:
    from Microsoft.Web.WebView2.WinForms import WebView2
    from System import Action, Uri
    from System.Drawing import Point
    from System.Windows.Forms import Timer

    native = window.native
    if native is None:
        raise AppError("排版窗口尚未准备好。", "export")

    with tempfile.TemporaryDirectory(prefix="gao-markdown-print-") as temporary:
        root = Path(temporary)
        source = root / "document.html"
        output = root / "document.pdf"
        source.write_text(document, encoding="utf-8")
        finished = threading.Event()
        resources = {}
        result = {"printed": False, "error": ""}

        def dispose():
            if timer := resources.get("timer"):
                timer.Stop()
                timer.Dispose()
            if control := resources.get("control"):
                native.Controls.Remove(control)
                control.Dispose()

        def complete(success=False, error=""):
            result["printed"] = success
            result["error"] = error
            dispose()
            finished.set()

        def initialize():
            try:
                control = resources["control"] = WebView2()
                control.Location = Point(-8, -8)
                control.Width = 2
                control.Height = 2
                native.Controls.Add(control)
                environment = native.webview.CoreWebView2.Environment
                state = {"navigation": None, "fonts": None, "print": None}
                init = control.EnsureCoreWebView2Async(environment)

                def navigation_starting(sender, event):
                    entered = urlsplit(event.Uri)
                    relative = unquote(entered.path).removeprefix("/")
                    if entered.scheme != "file" or entered.netloc or Path(relative) != source:
                        event.Cancel = True

                def navigation_completed(sender, event):
                    state["navigation"] = bool(event.IsSuccess)

                def block_new_window(sender, event):
                    event.Handled = True

                def advance(sender, event):
                    try:
                        if not init.IsCompleted:
                            return
                        if init.IsFaulted or init.IsCanceled:
                            complete(error=str(init.Exception) if init.IsFaulted else "初始化已取消。")
                            return
                        if state["navigation"] is False:
                            complete(error="临时排版页面无法加载。")
                            return
                        core = control.CoreWebView2
                        if "started" not in state:
                            state["started"] = True
                            core.Settings.IsWebMessageEnabled = False
                            core.Settings.AreDefaultScriptDialogsEnabled = False
                            core.Settings.AreHostObjectsAllowed = False
                            core.NavigationStarting += navigation_starting
                            core.NavigationCompleted += navigation_completed
                            core.NewWindowRequested += block_new_window
                            control.Source = Uri(source.as_uri())
                            return
                        if state["navigation"] is not True:
                            return
                        if state["print"] is not None:
                            task = state["print"]
                            if task.IsCompleted:
                                complete(not task.IsFaulted and not task.IsCanceled and bool(task.Result))
                            return
                        if state["fonts"] is None:
                            state["fonts"] = core.ExecuteScriptAsync("document.fonts.status")
                            return
                        task = state["fonts"]
                        if task.IsCompleted:
                            if task.IsFaulted or task.IsCanceled:
                                complete()
                            elif str(task.Result) == '"loaded"':
                                settings = core.Environment.CreatePrintSettings()
                                settings.PageWidth = 210 / 25.4
                                settings.PageHeight = 297 / 25.4
                                settings.MarginTop = settings.MarginBottom = 15 / 25.4
                                settings.MarginLeft = settings.MarginRight = 14 / 25.4
                                settings.ShouldPrintBackgrounds = True
                                settings.ShouldPrintHeaderAndFooter = False
                                state["print"] = core.PrintToPdfAsync(str(output), settings)
                            else:
                                state["fonts"] = None
                    except Exception as exc:
                        complete(error=str(exc))

                timer = resources["timer"] = Timer()
                timer.Interval = 75
                timer.Tick += advance
                timer.Start()
            except Exception as exc:
                complete(error=str(exc))

        native.Invoke(Action(initialize))
        if not finished.wait(40):
            native.Invoke(Action(dispose))
            raise AppError("Markdown 排版超过等待时间，未写入目标文件。", "export")
        if not result["printed"] or not output.is_file():
            raise AppError("WebView2 未能生成 Markdown PDF。" + result["error"], "export")
        data = output.read_bytes()
        if not data.startswith(b"%PDF-"):
            raise AppError("排版引擎生成的 PDF 无法校验。", "export")
        return data
