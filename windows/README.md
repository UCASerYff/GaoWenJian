# 搞文件 Windows 版

营销版本与当前 Mac 版同为 **1.11**。Windows 构建号为 **1**，关于页和 `--version` 打印 `1.11+1`。没有改 Mac 的 `CFBundleVersion`、签名身份、Bundle ID 或 Swift 源码。

## 选型

代码在 `windows/`。业务用 **Python 3.12 标准库**，PDF 读写使用纯 Python 的 **pypdf**（页面工具必须能改 PDF 结构；不引入 Electron 或 .NET）。界面是只监听 `127.0.0.1` 的本地网页，再用 **PyInstaller** 在 `windows-latest` 上打成单个 exe：

- `GaoWenJian.exe`：无控制台窗口
- `GaoWenJian-cli.exe`：带控制台，参数相同

资料目录默认是 `%APPDATA%\GaoSeries\GaoWenJian`。测试和冒烟用 `--data-dir` 指到临时目录。用户文档仍在原路径，不复制进程序目录。

## 本地运行

```powershell
cd windows
py -3.12 -m pip install -r requirements-dev.txt
py -3.12 launch.py --data-dir $env:TEMP\GaoWenJian-dev
```

不打包时也可以：

```powershell
py -3.12 -m pytest -q
powershell -ExecutionPolicy Bypass -File .\build.ps1
.\dist\GaoWenJian.exe --version
```

Linux / macOS 上同样可以跑单元测试和 `python3 launch.py --data-dir /tmp/gaowenjian-dev --no-browser`。打出来的 `.exe` 只在 Windows 构建。

常用参数：`--data-dir`、`--port`、`--no-browser`、`--open 文件`、`--inspect`、`--self-check`、`--version`。页面会话令牌放在 HTML 里，接口还要带 `X-Gao-Token`。图片预览可以把令牌放在本机 URL 查询串里。

快捷键是 Ctrl 而不是 ⌘：Ctrl+S 保存，Ctrl+1 首页，Ctrl+2 便笺。

## 功能对齐

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| 首页层级 | 已实现 | 写作（LaTeX、Markdown）在前，PDF / Office / CSV / 文本 / 图片随后，便笺单独入口。切换时保留标签和未保存文本 |
| 标签、最近文件、文件夹浏览 | 已实现 | 文件夹最多 4 层、1500 项，跳过隐藏文件、符号链接、`node_modules`、`build`、`.git` |
| 工作区 `workspace.json` | 已实现 | 保留未知字段。损坏时只提示，不用空记录覆盖 |
| 文本恢复稿 `recovery.json` | 已实现 | 只记录未保存的 Markdown / LaTeX / CSV / 纯文本。损坏或不是数组时停止写入 |
| 覆盖保存 | 已实现 | 先核对 SHA-256。原件消失不在旧路径重建；外部修改拒绝覆盖。同目录临时文件原子替换。不写历史快照 |
| Markdown | 部分实现 | 源码、分屏预览、大纲、任务、表格、脚注、围栏代码、本地相对图片、HTML 导出。公式和 Mermaid 只显示源码，没有内置 KaTeX / Mermaid。代码没有高亮主题 |
| Markdown / 文本 PDF 导出 | 降级 | 内置 Helvetica 纯文本 PDF。非 ASCII 会变成 `?`，并在结果里标明降级。排版请导出 HTML 后用浏览器打印 |
| LaTeX 编辑 | 已实现 | `% !TeX root`、章节 / 插图 / 表格 / 公式 / 标签 / 文献大纲、命令 / 环境 / 标签 / 文献 / 宏包补全 |
| LaTeX 编译与诊断 | 降级 | 调用本机 `tectonic`、`xelatex`、`pdflatex` 或 `lualatex`。tectonic 带 `--only-cached --untrusted`，不联网拉取宏包。日志按 Mac 版规则解析并带行号。**不附带** Tectonic 和宏包缓存 |
| SyncTeX | 降级 | 只有 PATH 里有 `synctex` 时才调用。没有正反向的可视化页面 |
| PDF 阅读 | 降级 | 文字提取、搜索、书签列表、表单字段列表、页码。没有光栅缩略图、双页图像或连续滚动画布。双页是相邻两页的文字对照 |
| PDF 页面工具 | 已实现 | 旋转、裁剪 MediaBox、删除、排序、合并、提取、拆分。内存里最多 20 步撤销，不在磁盘留操作历史 |
| PDF 文字 / 图片叠加 | 降级 | 文字是 Helvetica 自由文本批注，不能嵌中文。图片接受 PNG / JPEG，叠到现有内容流上，不栅格化原页。复杂特性（对象流、可选内容、附件、JavaScript）在 pypdf 重写时可能丢失；加密 PDF 直接拒绝，原件不动 |
| PDF 表单 | 部分实现 | 能读字段名和值，也能把文本字段写回。不是完整的 AcroForm 编辑器 |
| PDF 恢复稿 | 部分实现 | Windows 稿在 `Recovery/WindowsPDF/`。能读 Mac 的 `Recovery/PDF/<摘要>/draft.pdf`，摘要对得上就载入，并且不删除 Mac 目录。损坏稿只保留 |
| Word / Excel / PPT | 降级 | 现代 OOXML 只读内容：Word 段落，Excel 单元格、公式和已保存的计算结果（不重算），PPT 文字框。宏只提示，不执行。加密包拒绝。没有 Quick Look 版式 |
| 旧版 `.doc` `.xls` `.ppt` 与 ODF | 降级 | 二进制旧格式只提示用外部程序打开。ODF 只抽 `content.xml` 的文字 |
| 旧 Office 恢复稿 | 已实现 | 识别 `Recovery/Office`。校验失败或元数据损坏时不覆盖、不删除。可把通过校验的草稿导出到新路径 |
| CSV / TSV | 已实现 | 引号、换行、前导零与 Mac 版 `DelimitedText` 一致。表格回写、按列排序、筛选，以及复制成 Markdown 表格 |
| 纯文本 | 已实现 | UTF-8、带 BOM 的 UTF-8、UTF-16、GB18030。保存沿用原编码；编不下时要求另存 UTF-8 |
| RTF | 降级 | 可见文字和粗斜体、下划线。出现图片、未知控制字或无法往返的结构时标记为有损，拒绝覆盖原件，只能另存。Windows 稿在 `Recovery/WindowsRTF/`，不写入 Mac 的 `Recovery/RTF` |
| 图片 | 降级 | PNG / JPEG / GIF / WebP / BMP / SVG 由浏览器缩放查看。单张 64 MB、8000 万像素上限。HEIC / TIFF 不转换。没有 OCR |
| 便笺 | 部分实现 | 六色、分组、搜索、置顶 / 半透明 / 折叠标记、自动保存在每次修改后、删除进回收站、恢复、TXT / RTF / RTFD 导入导出、把纯文本送入 Markdown 且保留原便笺。窗口位置存在记录里，但是同一页面里的卡片，不是独立的置顶 Win32 窗口 |
| 便笺资料保护 | 已实现 | 目录非空却没有 `notes.json`、JSON 损坏、摘要不符时只读，不用空白覆盖。未知正文包不删除 |
| 与 Mac 便笺互通 | 不兼容写入 | Mac 用 schema 2、Flat RTFD 和 Swift `JSONEncoder` 摘要。Windows 打不开就只读展示 `plainText`，**不会覆盖** `notes.json`。Windows 自己的记录带 `writer: gaowenjian-windows-1`，Mac 会因摘要不一致而拒绝加载。不要让两边同时写同一 `StickyNotes` 目录 |
| GaoAction V1 | 部分实现 | 读取 `.gaoaction` 目录或同结构 zip。支持 `documents.newText`、`documents.open`、`ocr.files` 结果里的文本和 PDF、`files.choose` 的原件引用。研究导入包可导出，回执只在对得上原请求摘要时接受。重复结果不重复打开。日志损坏则停止。正文不写进运行日志 |
| 交给搞研究 / 搞整理 / 搞截图 | 不支持在线交接 | 没有 `gaowenjian://`，也不注册 Windows URL 协议。OCR 不能在本机执行。搞整理的索引、移动计划和 UTI 关联没有移植 |
| 文件整理 | 降级 | 只有当前文件夹浏览。不会读 Organizer 数据库，也不会移动用户文件或改系统关联 |
| 设置 | 已实现 | 独立页面：浅色 / 深色 / 跟随系统，LaTeX 引擎。损坏的 `settings.json` 不覆盖 |
| 签名与公证 | 不适用 | 不使用 Mac 的 Development 证书，也不做 Authenticode。exe 未签名 |

## CI

`.github/workflows/windows.yml` 在 `windows-latest` 上执行 `windows/build.ps1`：安装依赖、`pytest`、打出两个 exe，然后启动 `GaoWenJian.exe`，确认本机页面返回含会话令牌的 HTTP 200，写入并读回一份 Markdown，再请求退出。产物 artifact 名为 `GaoWenJian-Windows-1.11`。

触发范围是拉取请求，以及推送到 `main`。功能分支上的同一次提交不再同时跑 push 和 pull_request。同一 ref 上的新运行会取消尚未结束的旧运行。不创建 GitHub Release，不安装到运行器以外的机器。

## 需要作者决定的事

- 是否在以后的 Windows 构建里附带 Tectonic 与离线宏包缓存。当前仓库里的 Mac 版 Tectonic 是 macOS 二进制，不能拿来用。
- 是否引入 PDFium / Poppler，用来做真正的页面缩略图和双页版式。现在为了保持单个 exe、避免再绑一套原生 PDF 渲染器，只做文字和结构编辑。
- 便笺要不要做成与 Mac schema 2 摘要互认。这需要逐字节对齐 Swift `JSONEncoder` 和 Flat RTFD；做不到之前，两边不能共写同一目录。
- Windows 安装包要不要 Authenticode 签名。这次没有证书，不能把未签名 exe 说成已签名。
