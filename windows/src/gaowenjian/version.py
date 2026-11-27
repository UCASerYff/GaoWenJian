"""营销版本与当前 Mac 版 VERSION / CFBundleShortVersionString 对齐。

Windows 构建号独立递增，不改 Mac 的 CFBundleVersion。
"""

MARKETING_VERSION = "1.11"
WINDOWS_BUILD = "3"
VERSION_LABEL = f"{MARKETING_VERSION}+{WINDOWS_BUILD}"
APP_NAME = "搞文件"
BUNDLE_ID = "com.gaoseries.GaoWenJian"
WINDOW_TITLE = f"搞文件 V{MARKETING_VERSION}"
