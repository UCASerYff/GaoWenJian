"""Windows host for the local workspace and its independent child windows."""

from __future__ import annotations

import json
import threading
from urllib.parse import urlencode

from gaowenjian.errors import AppError
from gaowenjian.version import WINDOW_TITLE

FILE_TYPES = {
    "latex": ("LaTeX (*.tex;*.ltx;*.bib)",),
    "markdown": ("Markdown (*.md;*.markdown;*.mdown;*.mkd)",),
    "pdf": ("PDF (*.pdf)",),
    "office": ("Office (*.doc;*.docx;*.docm;*.xls;*.xlsx;*.xlsm;*.ppt;*.pptx;*.pptm;*.odt;*.ods;*.odp)",),
    "word": ("Word (*.doc;*.docx;*.docm;*.odt)",),
    "spreadsheet": ("Excel (*.xls;*.xlsx;*.xlsm;*.ods)",),
    "presentation": ("PowerPoint (*.ppt;*.pptx;*.pptm;*.odp)",),
    "ocr-inputs": ("PDF / image (*.pdf;*.png;*.jpg;*.jpeg;*.tif;*.tiff;*.gif;*.webp;*.heic;*.heif)",),
    "note-import": ("Text / RTF (*.txt;*.rtf)",),
}


def run_desktop(server, *, activate: bool = False, hidden: bool = False) -> None:
    import webview

    desktop = Desktop(webview, server, hidden=hidden)
    desktop.start(activate)


class WindowActions:
    def __init__(self, desktop, note_id: str = ""):
        self._desktop = desktop
        self._note_id = note_id
        self._window = None

    def file_dialog(self, mode: str, name: str = ""):
        kind = self._desktop.webview.FileDialog
        dialog_type = kind.SAVE if mode == "save" else kind.FOLDER if mode == "folder" else kind.OPEN
        selected = self._window.create_file_dialog(
            dialog_type, save_filename=name, allow_multiple=mode == "ocr-inputs",
            file_types=FILE_TYPES.get(mode, ()) + ("All files (*.*)",),
        )
        if mode == "ocr-inputs":
            return list(selected or ())
        return selected[0] if selected else ""

    def show_settings(self):
        self._desktop.show_settings()

    def focus_workspace(self):
        if not self._desktop.hidden:
            self._desktop.main.show()

    def show_note(self, note_id: str):
        self._desktop.show_note(note_id)

    def restore_notes(self):
        self._desktop.restore_notes()

    def arrange_notes(self):
        self._desktop.arrange_notes()

    def hide_notes(self):
        for window in list(self._desktop.notes.values()):
            window.hide()

    def apply_note_style(self):
        if self._note_id:
            self._desktop.apply_style(self._note_id, self._window)

    def close_note(self):
        if self._note_id:
            self._desktop.close_note(self._note_id)

    def close_workspace(self, allow_dirty: bool = False):
        return self._desktop.close_workspace(allow_dirty)

    def print_markdown(self, tab_id: str, destination: str, rendered: str):
        return self._desktop.print_markdown(self._window, tab_id, destination, rendered)

    def show_latex_pdf(self, tab_id: str):
        self._desktop.show_latex_pdf(tab_id)


class Desktop:
    def __init__(self, webview, server, *, hidden=False):
        self.webview = webview
        self.server = server
        self.hidden = hidden
        self.main = None
        self.settings = None
        self.notes = {}
        self.readers = {}
        self.frames = {}
        self.closing_notes = set()
        self.closing = False

    def _create(self, title, endpoint="", note_id="", **options):
        actions = WindowActions(self, note_id)
        window = self.webview.create_window(title, self.server.url + endpoint, js_api=actions, hidden=self.hidden, text_select=True, **options)
        actions._window = window
        return window

    def start(self, activate):
        self.webview.settings["OPEN_EXTERNAL_LINKS_IN_BROWSER"] = True
        self.main = self._create(WINDOW_TITLE, "?view=editor" if activate else "", width=1160, height=820, min_size=(770, 560))
        self.main.events.closing += self._request_workspace_close
        self.main.events.loaded += self._attach_file_drop
        self.webview.start(gui="edgechromium", private_mode=True)

    def _attach_file_drop(self):
        from webview.dom import DOMEventHandler

        document = self.main.dom.document
        document.events.drop += DOMEventHandler(self._open_dropped_files, prevent_default=True)

    def _open_dropped_files(self, event):
        files = event.get("dataTransfer", {}).get("files", [])
        paths = [item["pywebviewFullPath"] for item in files if item.get("pywebviewFullPath")]
        if paths:
            self.main.run_js(f"openDroppedFiles({json.dumps(paths)})")

    def _request_workspace_close(self):
        if self.closing:
            return True
        threading.Thread(target=self.main.run_js, args=("workspaceExit().catch(fail)",), daemon=True).start()
        return False

    def print_markdown(self, window, tab_id, destination, rendered):
        from pathlib import Path
        from gaowenjian.safety import safe_replace
        from gaowenjian.windows_print import print_in_webview

        path = Path(destination)
        if path.exists():
            raise AppError("导出目标已存在，请换一个新路径。", "export")
        with self.server.lock:
            workspace = self.server.workspace
            tab = workspace._tab(tab_id)
            if tab.kind != "markdown":
                raise AppError("当前文档不是 Markdown。", "export")
            document = workspace._markdown_document(tab, rendered)
        data = print_in_webview(window, document)
        if path.exists():
            raise AppError("导出期间目标文件已被创建，请另存。", "export")
        safe_replace(path, data, None)
        return str(path)

    def show_latex_pdf(self, tab_id: str):
        with self.server.lock:
            workspace = self.server.workspace
            tab = workspace._tab(tab_id)
            workspace.latex_pdf(tab_id)
            title = tab.title.rsplit(".", 1)[0] + ".pdf"
        if window := self.readers.get(tab_id):
            window.show()
            return
        query = urlencode({"tab": tab_id, "token": self.server.token})
        window = self._create(title, "api/latex/document?" + query, width=850, height=900, min_size=(480, 400))
        self.readers[tab_id] = window
        window.events.closed += lambda: self.readers.pop(tab_id, None)

    def close_workspace(self, allow_dirty):
        with self.server.lock:
            if self.server.workspace.dirty_count() and not allow_dirty:
                return False
        for note_id, window in list(self.notes.items()):
            if window.events.loaded.is_set():
                complete = threading.Event()
                outcome = []

                def finished(value):
                    outcome.append(value)
                    complete.set()

                window.evaluate_js("flushNoteEdit()", callback=finished)
                if not complete.wait(8) or not outcome[0]:
                    return False
            self._save_frame(note_id)
        self.closing = True
        for window in list(self.notes.values()):
            window.destroy()
        for window in list(self.readers.values()):
            window.destroy()
        if self.settings:
            self.settings.destroy()
        self.main.destroy()
        return True

    def show_settings(self):
        if self.settings:
            if not self.hidden:
                self.settings.show()
            return
        window = self._create("搞文件设置", "settings", width=595, height=545, min_size=(480, 460))
        self.settings = window
        window.events.closed += self._settings_closed

    def _settings_closed(self):
        self.settings = None

    def _note(self, note_id):
        with self.server.lock:
            return dict(self.server.workspace.notes._live(note_id))

    def restore_notes(self):
        with self.server.lock:
            note_ids = [item["id"] for item in self.server.workspace.notes.snapshot()["notes"]
                        if item["isOnDesktop"] and item["editable"]]
        for note_id in note_ids:
            self.show_note(note_id)

    def show_note(self, note_id):
        note = self._note(note_id)
        if note_id in self.notes:
            if not self.hidden:
                self.notes[note_id].show()
            return
        frame = note.get("frame") or {}
        collapsed = note.get("isCollapsed") is True
        width, height = max(270, int(frame.get("width", 360))), max(150, int(frame.get("height", 300)))
        x, y = self._visible_position(int(frame.get("x", 180)), int(frame.get("y", 180)), width, height)
        title = note.get("title") or "未命名便笺"
        window = self._create(title, "note?" + urlencode({"id": note_id}), note_id=note_id, x=x, y=y,
                              width=width, height=56 if collapsed else height, min_size=(270, 56),
                              on_top=bool(note.get("isPinned")), frameless=True, easy_drag=False)
        self.notes[note_id] = window
        window.events.closing += lambda: self._request_note_close(note_id, window)
        window.events.closed += lambda: self.notes.pop(note_id, None)
        window.events.resized += lambda width, height: self._schedule_frame(note_id)
        window.events.moved += lambda x, y: self._schedule_frame(note_id)
        window.events.loaded += lambda: self.apply_style(note_id, window)

    def _visible_position(self, x, y, width, height):
        screens = self.webview.screens
        if not screens:
            return x, y
        screen = next((item for item in screens if item.x <= x < item.x + item.width and item.y <= y < item.y + item.height), screens[0])
        return max(screen.x, min(x, screen.x + screen.width - width)), max(screen.y, min(y, screen.y + screen.height - height))

    def arrange_notes(self):
        self.restore_notes()
        x = 24
        y = 24
        for note_id, window in list(self.notes.items()):
            target_x, target_y = self._visible_position(x, y, window.width, window.height)
            if target_x != x:
                x, y = 24, y + 46
                target_x, target_y = self._visible_position(x, y, window.width, window.height)
            window.move(target_x, target_y)
            self._save_frame(note_id)
            x += window.width + 16

    def _request_note_close(self, note_id, window):
        if self.closing or note_id in self.closing_notes:
            return True
        threading.Thread(target=window.run_js, args=("hideDesktopNote().catch(fail)",), daemon=True).start()
        return False

    def close_note(self, note_id):
        window = self.notes.get(note_id)
        if window:
            self.closing_notes.add(note_id)
            try:
                window.destroy()
            finally:
                self.closing_notes.discard(note_id)

    def apply_style(self, note_id, window):
        try:
            note = self._note(note_id)
        except AppError:
            self.close_note(note_id)
            return
        if not note.get("isOnDesktop"):
            self.close_note(note_id)
            return
        expected = 56 if note.get("isCollapsed") else max(150, int(note["frame"]["height"]))
        native = window.native
        if native is not None:
            from System import Action

            def adjust():
                if native.IsDisposed:
                    return
                native.TopMost = bool(note.get("isPinned"))
                native.Opacity = .82 if note.get("isTranslucent") else 1.0
                if (window.height <= 75) != (expected == 56):
                    native.Height = round(native.Height * expected / max(1, window.height))

            if not native.IsDisposed:
                native.BeginInvoke(Action(adjust))

    def _schedule_frame(self, note_id):
        previous = self.frames.pop(note_id, None)
        if previous:
            previous.cancel()
        timer = threading.Timer(.35, self._save_frame, args=(note_id,))
        timer.daemon = True
        self.frames[note_id] = timer
        timer.start()

    def _save_frame(self, note_id):
        window = self.notes.get(note_id)
        if not window:
            return
        try:
            x, y, width, height = window.x, window.y, window.width, window.height
            with self.server.lock:
                store = self.server.workspace.notes
                note = store._live(note_id)
                saved = note["frame"]
                frame = {"x": x, "y": y, "width": max(270, width),
                         "height": saved["height"] if note.get("isCollapsed") else max(150, height)}
                if frame != saved:
                    store.metadata(note_id, {"frame": frame})
        except AppError as exc:
            if not self.closing and note_id in self.notes:
                window.run_js(f"fail(new Error({json.dumps(exc.message)}))")
