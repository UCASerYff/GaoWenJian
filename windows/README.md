# 搞文件 1.11 · Windows x64

安装文件为 `GaoWenJian-Windows-1.11-build8-x64-Setup.exe`，旁附同名 `.sha256`。安装器针对 Windows 10/11 x64，默认按当前用户安装。通过开始菜单启动“搞文件”，或在安装目录用 `GaoWenJian.exe --open 文件路径` 打开文档。主窗口、设置和桌面便笺使用 Microsoft Edge WebView2 Runtime。命令行版为 `GaoWenJian-cli.exe`，版本号输出 `1.11+8`。Windows 安装器和程序未做 Authenticode 签名。

用户资料仍位于 `%APPDATA%\GaoSeries\GaoWenJian`。卸载移除程序，用户资料和原路径文档继续保留。`--data-dir` 可指定隔离资料目录，`--no-browser` 启动仅监听 `127.0.0.1` 的本机接口。每个资料目录同时只允许一个写入进程。`--self-check` 在自动清理的临时目录运行。工作区、恢复稿、便笺和设置记录在原目录读取，兼容已存在的 Windows 记录。遇到损坏或冲突时保留现有记录。

## 通知区域

正常启动会在 Windows 通知区域显示搞文件图标。关掉工作台后，图标仍在表示应用继续在后台运行。单击图标、选择「打开 搞文件」或再次从开始菜单启动，都可回到同一资料目录的工作台。Windows 也可能把图标显示在任务栏的隐藏图标菜单中。命令行、只读检查和隐藏测试入口无需托盘。

安装器、快捷方式、运行中的窗口和通知区使用同源多尺寸图标。构建 7 将灰色底板扩到 Windows 图标画布边缘并保留透明圆角，为 100% 到 200% 桌面缩放提供 48、60、72、84、96 像素帧。窗口按 Windows 请求的 DPI 选择尺寸，通知区按任务栏所在显示器的 DPI 更新，Explorer 重建任务栏后会重新注册图标。

通过托盘或工作台菜单选择「退出」可完整关闭应用。若有未保存的文档，工作台会提示保存。取消退出会保留未保存内容和托盘图标。工作台原先处于后台时会继续隐藏，原先可见时可继续编辑。退出时会保存桌面便笺的正文和位置，已放到桌面的便笺会在下次启动时恢复。

## 工作流

| 入口 | Windows 行为 |
| --- | --- |
| 工作台 | 首页提供最近文件和新建入口。文件浏览按需打开，窄窗收起导航标签。标签页标记未保存文档。设置可切换浅色、深色和系统主题。Ctrl+1 返回工作台，Ctrl+2 打开便笺，Ctrl+3 打开整理，Ctrl+, 打开设置。 |
| 写作项目 | 从首页或导航打开写作项目。项目保存目录、主文件、打开的文档和 PDF 阅读位置。切换时可先保存、保留草稿再切换，或取消。恢复遇到缺失文件会列出原因。 |
| Markdown | 即时渲染、源码、分屏、大纲、格式操作、代码高亮、KaTeX 和 Mermaid。保存后插入本机相对图片。导出可离线打开的 HTML，或者从主窗口导出排版 PDF。 |
| LaTeX | 随包提供官方 Tectonic 0.16.9 x64 和离线宏包与字体缓存。支持 `% !TeX root`、日志诊断、结构导航、局部完成、PDF 页预览、正向和反向 SyncTeX。Ctrl+B 编译。可选本机安装的其他引擎。 |
| PDF | 阅读栏提供翻页、缩放和布局。缩略图、搜索、书签、编辑和表单按需展开。可填写文本、单选、复选、选项字段，叠加文字与图像，旋转、裁剪、删除、重排、合并、提取和拆分页面。覆盖保存检查原件身份和 SHA-256。 |
| Office | Word、Excel、PowerPoint 只读。简版版式和内容模式共享导航，搜索显示匹配位置。Excel 读取公式和保存的计算结果。可查阅、导出通过校验的旧恢复稿。 |
| 便笺 | 便笺中心支持富文本、六色、分组、排序、搜索、附件、回收站和恢复。桌面便笺优先显示正文和常用格式，菜单提供置顶、半透明、折叠和导出。支持 TXT、RTF 与 RTFD 文件夹交换，可送入 Markdown。 |
| 整理与权限 | 由用户授权本机目录，之后扫描、查找、收藏和创建虚拟工作区。移动经预览和确认，Windows 下支持同一卷。默认打开方式由用户在 Windows 设置确认。 |
| 交接 | 搞操作审核并完成 OCR 后，匹配本机请求的回传可出现在原文档和「OCR 与交接」的待审核区。核对来源、页码和摘要后可接收 TXT、Markdown、JSON 和可搜索 PDF 副本。也可手工接收 GaoAction 包。 |

自动 OCR 回传通过当前用户的 `%LOCALAPPDATA%\GaoSeries\GaoAction\OcrReturns-v1` 交换。请求生成后两分钟内可自动回传。工作台可见且有等待请求时检查回传，回到工作台时立即检查一次。已显示的自动回包按传输时效从待审列表移出，已接收的草稿和 PDF 副本继续保留。`--open` 打开交接包的审核页，接收需要用户确认。旧版搞操作、逾期或核验失败时可继续手工导出和接收结果包。

## 验证边界

Windows 桌面需要 x64 Microsoft Edge WebView2 Evergreen Runtime。若运行时缺失，启动时会提示安装或修复。`--no-browser` 的本机 API 可独立运行。Windows 界面使用 Segoe UI 和 Windows 文件对话框。系统控件、文字字形和少数布局细节与 SwiftUI 存在可见差异。Office 简版查看覆盖 Word 正文和表格、Excel 网格、PowerPoint 文本框。旧二进制 Office、复杂母版、图片、页眉页脚和完整分页依赖外部办公软件。PDF 的动态 XFA、嵌入操作、签名字段和加密文档限于读取，签名文档编辑须另存。中文 FreeText 批注保留文字，显示外观以位图保存。HEIC 可经提供方识别，内置图片查看器可直接读常见栅格图及 TIFF。macOS Flat RTFD 记录以只读方式展示可读正文。整理使用独立 Windows 索引与手动扫描，Mac 索引和安全书签需要重新授权。除直接唤起搞操作 OCR 外，其他应用之间使用手动交换 GaoAction 包。

## 构建与隔离验收

在 Windows x64 的干净 CPython 3.12 环境中执行。安装器使用 Inno Setup 6，脚本自动下载并验证固定 SHA-256 的 Windows Tectonic 压缩包，或接受预先下载且符合固定摘要的 `-TectonicExe`。`-InnoCompiler` 可指定 `ISCC.exe`。输出在仓库 `Release/`，包括安装器和校验文件。

```powershell
.\windows\build.ps1 -InnoCompiler 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
python .\windows\tests\install_smoke.py .\Release\GaoWenJian-Windows-1.11-build8-x64-Setup.exe --previous .\Release\GaoWenJian-Windows-1.11-build7-x64-Setup.exe --native --tray
```

`install_smoke.py` 使用隔离安装和合成资料，核验 SHA-256、版本、离线编译、保存和卸载。提供 `--previous` 可将上一版原地升级并核验恢复稿、设置、便笺和附件。`--native` 通过 Node.js 24 验证隐藏的设置窗口、桌面便笺和 LaTeX PDF 阅读窗口。`--tray` 在非活动的私有桌面上运行已安装的 GUI，用测试通知区接收真实的 `Shell_NotifyIconW` 调用并验证关窗留驻、恢复、取消退出和最终清理。Explorer 的图标显示位置需在日常桌面另行查看。浏览器回归检查浅深色、窄窗、项目恢复与 OCR 审核。`ocr_interop_smoke.py` 可传入搞操作安装包和搞文件命令行程序实测离线 OCR，`--automatic` 检查新版提供方的自动回传。
