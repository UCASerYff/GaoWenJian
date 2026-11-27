# 搞文件 1.11 · Windows x64

安装文件为 `GaoWenJian-Windows-1.11-x64-Setup.exe`，旁附同名 `.sha256`。安装器针对 Windows 10/11 x64，默认按当前用户安装。通过开始菜单启动“搞文件”，或在安装目录用 `GaoWenJian.exe --open 文件路径` 打开文档。主窗口、设置和桌面便笺使用 Microsoft Edge WebView2 Runtime。命令行版为 `GaoWenJian-cli.exe`，版本号输出 `1.11+2`。Windows 安装器和程序未做 Authenticode 签名。

用户资料仍位于 `%APPDATA%\GaoSeries\GaoWenJian`。卸载移除程序，用户资料和原路径文档继续保留。`--data-dir` 可指定隔离资料目录，`--no-browser` 启动仅监听 `127.0.0.1` 的本机接口。工作区、恢复稿、便笺和设置记录在原目录读取，兼容已存在的 Windows 记录。遇到损坏或冲突时保留现有记录。

## 工作流

| 入口 | Windows 行为 |
| --- | --- |
| 工作台 | 暖白与深石墨，切换浅色、深色和系统主题。左侧是写作、文档工具、最近文件和便笺。Ctrl+1 返回工作台，Ctrl+2 打开便笺，Ctrl+3 打开整理，Ctrl+, 打开设置。|
| Markdown | 即时渲染、源码、分屏、大纲、格式操作、代码高亮、KaTeX 和 Mermaid。保存后插入本机相对图片。导出可离线打开的 HTML，或者从主窗口导出排版 PDF。 |
| LaTeX | 随包提供官方 Tectonic 0.16.9 x64 和离线宏包与字体缓存。支持 `% !TeX root`、日志诊断、结构导航、局部完成、PDF 页预览、正向和反向 SyncTeX。Ctrl+B 编译。可选本机安装的其他引擎。 |
| PDF | PDFium 页面预览、缩略图、连续与双页、书签和搜索。可填写文本、单选、复选、选项字段，叠加文字与图像，旋转、裁剪、删除、重排、合并、提取和拆分页面。覆盖保存检查原件身份和 SHA-256。 |
| Office | Word、Excel、PowerPoint 只读。提供简版版式与可搜索内容，Excel 读取公式和保存的计算结果。可查阅、导出通过校验的旧恢复稿。 |
| 便笺 | 单独桌面便笺窗口可置顶、半透明、折叠和恢复位置。便笺中心支持富文本、六色、分组、排序、搜索、附件、回收站和恢复。支持 TXT、RTF 与 RTFD 文件夹交换，可送入 Markdown。 |
| 整理与权限 | 由用户授权本机目录，之后扫描、查找、收藏和创建虚拟工作区。移动经预览和确认，Windows 下支持同一卷。默认打开方式由用户在 Windows 设置确认。 |
| 交接 | 审核并接收 GaoAction 包。OCR 由搞操作 Windows 版执行，支持从工作台发起、在提供方审核、导入 TXT、Markdown、JSON 和可搜索 PDF，校验原请求、来源、页面映射和摘要。 |

## 验证边界

Windows 使用 WebView2、Segoe UI 和 Windows 文件对话框。系统控件、文字字形和少数布局细节与 SwiftUI 存在可见差异。Office 简版查看覆盖 Word 正文和表格、Excel 网格、PowerPoint 文本框。旧二进制 Office、复杂母版、图片、页眉页脚和完整分页依赖外部办公软件。PDF 的动态 XFA、嵌入操作、签名字段和加密文档限于读取，签名文档编辑须另存。中文 FreeText 批注保留文字，显示外观以位图保存。HEIC 可经提供方识别，内置图片查看器可直接读常见栅格图及 TIFF。macOS Flat RTFD 记录以只读方式展示可读正文。整理使用独立 Windows 索引与手动扫描，Mac 索引和安全书签需要重新授权。除直接唤起搞操作 OCR 外，其他应用之间使用手动交换 GaoAction 包。

## 构建与隔离验收

在 Windows x64 的干净 CPython 3.12 环境中执行。安装器使用 Inno Setup 6，脚本自动下载并验证固定 SHA-256 的 Windows Tectonic 压缩包，或接受预先下载且符合固定摘要的 `-TectonicExe`。`-InnoCompiler` 可指定 `ISCC.exe`。输出在仓库 `Release/`，包括安装器和校验文件。

```powershell
.\windows\build.ps1 -InnoCompiler 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
python .\windows\tests\install_smoke.py .\Release\GaoWenJian-Windows-1.11-x64-Setup.exe
```

`install_smoke.py` 使用隔离安装和旧版合成资料，核验 SHA-256、版本、资料继续可读、离线编译、保存和卸载。`native_desktop_smoke.mjs` 用 Node.js 24 在隐藏的原生窗口里验证独立设置和便笺及排版 PDF。`organizer_browser_smoke.mjs` 用 Edge 测试两个尺寸和缩放，`ocr_interop_smoke.py` 可传入两款应用的安装后程序做真实 OCR 往返。日常使用请通过开始菜单启动。
