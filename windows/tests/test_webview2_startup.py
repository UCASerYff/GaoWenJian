import ctypes
from pathlib import Path
import sys
from types import ModuleType, SimpleNamespace
from unittest.mock import Mock

import pytest

from gaowenjian import desktop


@pytest.mark.parametrize(
    "hresult, value, expected",
    [(-1, None, None), (0, None, None), (0, "0.0.0.0", None), (0, "invalid", None),
     (0, "158.0.4370.45", "158.0.4370.45")],
)
def test_x64_loader_requires_a_positive_version_and_releases_its_string(monkeypatch, tmp_path, hresult, value, expected):
    loader_path = tmp_path / desktop.WEBVIEW2_LOADER
    buffer = None if value is None else ctypes.create_unicode_buffer(value)

    def query(_folder, out):
        if buffer is not None:
            ctypes.cast(out, ctypes.POINTER(ctypes.c_void_p))[0] = ctypes.addressof(buffer)
        return hresult

    probe, release = Mock(side_effect=query), Mock()
    load = Mock(side_effect=[SimpleNamespace(GetAvailableCoreWebView2BrowserVersionString=probe),
                             SimpleNamespace(CoTaskMemFree=release)])
    monkeypatch.setattr(desktop.ctypes, "WinDLL", load, raising=False)
    if expected is None:
        with pytest.raises(desktop.WebView2Unavailable, match="Evergreen Runtime"):
            desktop.installed_webview2_version(loader_path)
    else:
        assert desktop.installed_webview2_version(loader_path) == expected
    assert load.call_args_list[0].args == (str(loader_path),)
    assert release.call_count == (0 if buffer is None else 1)


def test_missing_runtime_stops_before_webview_import_or_desktop_creation(monkeypatch, tmp_path):
    require_loader = Mock(side_effect=desktop.WebView2Unavailable(desktop.WEBVIEW2_ERROR))
    monkeypatch.setattr(desktop, "find_spec", lambda _: SimpleNamespace(origin=str(tmp_path / "webview/__init__.py")))
    monkeypatch.setattr(desktop, "installed_webview2_version", require_loader)
    create = Mock()
    monkeypatch.setattr(desktop, "Desktop", create)
    # Importing a module with a None entry would itself throw, before the runtime check.
    monkeypatch.setitem(sys.modules, "webview", None)
    with pytest.raises(desktop.WebView2Unavailable, match="Evergreen Runtime"):
        desktop.run_desktop(object())
    require_loader.assert_called_once_with(tmp_path / "webview" / desktop.WEBVIEW2_LOADER)
    create.assert_not_called()


@pytest.mark.parametrize("renderer", ["edgechromium", "mshtml"])
def test_backend_has_only_the_x64_loader_and_cannot_import_mshtml(monkeypatch, tmp_path, renderer):
    package = tmp_path / "webview"
    platforms = package / "platforms"
    platforms.mkdir(parents=True)
    (platforms / "mshtml.py").write_text('raise AssertionError("MSHTML initialized")', encoding="utf-8")
    webview = ModuleType("webview")
    webview.__path__ = [str(package)]
    webview.util = SimpleNamespace(interop_dll_path=Mock(return_value="managed"))
    original_lookup = webview.util.interop_dll_path
    platforms_module = ModuleType("webview.platforms")
    platforms_module.__path__ = [str(platforms)]
    guilib = ModuleType("webview.guilib")
    monkeypatch.setitem(sys.modules, "webview", webview)
    monkeypatch.setitem(sys.modules, "webview.guilib", guilib)
    monkeypatch.setitem(sys.modules, "webview.platforms", platforms_module)
    monkeypatch.setitem(sys.modules, "webview.platforms.mshtml", None)
    monkeypatch.delitem(sys.modules, "webview.platforms.mshtml")
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "_MEIPASS", str(tmp_path), raising=False)
    require_loader = Mock(return_value="158.0.4370.45")
    monkeypatch.setattr(desktop, "installed_webview2_version", require_loader)

    def initialize(selected):
        assert selected == "edgechromium"
        assert {webview.util.interop_dll_path(architecture) for architecture in ("win-x86", "win-arm64", "win-x64")} == {
            str((package / desktop.WEBVIEW2_LOADER).parent),
        }
        assert webview.util.interop_dll_path("Microsoft.Web.WebView2.Core.dll") == "managed"
        with pytest.raises(ImportError):
            from webview.platforms import mshtml  # noqa: F401
        return SimpleNamespace(renderer=renderer)

    guilib.initialize = initialize
    if renderer == "edgechromium":
        assert desktop.require_webview2() is webview
    else:
        with pytest.raises(desktop.WebView2Unavailable, match="Evergreen Runtime"):
            desktop.require_webview2()
    require_loader.assert_called_once_with(package / desktop.WEBVIEW2_LOADER)
    assert webview.util.interop_dll_path is original_lookup
