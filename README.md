# 搞文件 V1.03

macOS 本地文件编辑工作台，适用于 Apple Silicon、macOS 14 及以上。当前版本 **1.03 / build 4**，初始版本为 1.00。账户、联网同步和 AI 功能暂不开发。

| 文件 | 当前可用能力 |
| --- | --- |
| 便笺 | 富文本和图片/PDF 附件、六色、分组/搜索、自动保存、回收站恢复、TXT/RTF/RTFD 导入导出；独立桌面窗口、置顶、半透明、折叠、排列及位置恢复；支持顶部一键返回首页 |
| Markdown | 即时块编辑、源码/分屏、大纲、表格、任务、脚注、公式、Mermaid、代码高亮、本地图片、HTML/PDF 导出 |
| LaTeX | 智能主文件与 `% !TeX root = ...` 识别、章节/插图/表格/标签/文献大纲导航、命令/环境/标签/文献智能补全；结构化诊断与错误点击跳转；SyncTeX 源码与 PDF 双向定位（正向定位/⌘-点击反向定位）；增强型 PDF 缩放、快捷公式与环境工具栏；内置 Tectonic 离线编译与本机 XeLaTeX/pdfLaTeX/LuaLaTeX 引擎支持 |
| PDF | 阅读、搜索、目录、缩略图、双页；高亮/下划线/删除线、便签、文字、表单；页面旋转、裁剪、排序、删除、合并、提取、拆分；撤销与保存 |
| Word / Excel / PPT | 新建与原生基础编辑、原格式保存、另存副本；本机 LibreOffice 提供分页 PDF 导出、旧格式转换及高级编辑 |
| CSV / TSV | 源码/表格、筛选、排序、增行列、复制为 Markdown 表格，支持引号、换行及前导零 |
| RTF / 文本 / 图片 | 富文本编辑与字体；文本编辑和查找；图片缩放查看 |

采用原生窗口、标签页、文件夹浏览、最近文件与独立设置窗口。用户文档保留原路径，覆盖前留存并校验原件快照；外部修改或删除会阻止覆盖。文本、PDF、Office、RTF 有本地恢复机制；损坏草稿保留并报错。

V1.03 全面升级 LaTeX 模块：支持魔术注释 `% !TeX root = ...` 自动识别主文件；左侧折叠面板提供篇、章、节、子节及插图、表格、标签与文献大纲，点击即时跳转行；支持命令、环境（自动配对闭合）、标签与文献补全；编译日志结构化诊断卡片并支持点击跳转出错行；支持 SyncTeX 正向与 ⌘-点击反向双向定位；PDF 预览增加缩放与快捷公式工具栏。

V1.02 在便笺中心顶部加入“返回首页”按钮。返回首页会保留已经打开的文件标签和未保存编辑，点击原标签即可继续。

V1.01 新增便笺中心与桌面便条，参考本机 macOS 便笺的使用方式，并补充集中搜索、分组、回收站和保存冲突保护。正文和附件保存在内部 `StickyNotes` 目录；关闭浮窗仅隐藏，删除移入回收站，不永久清空。支持将文字送入 Markdown 编辑器，原便笺继续保留；附件和完整富文本请导出 RTFD。不会自动读取或迁移系统便笺私人资料；需要迁移时先从系统便笺导出，再手动导入。详见 [便笺说明](Docs/StickyNotes.md)。

首版的 Office 为基础编辑，复杂对象保留在原文件但不完整渲染。PDF 不提供原文重排、OCR 或安全涂黑。涉及账户或联网的协作与同步暂不包含。不要把现有基础能力理解为完整 Microsoft Office、Typora 或 Overleaf 的等价替代。

具体范围见 [OfficeSupport](Docs/OfficeSupport.md)、[MarkdownDependencies](Docs/MarkdownDependencies.md)、[RTFRecovery](Docs/RTFRecovery.md)。

## 安装与运行

安装包在 `Release/GaoWenJian-1.03.dmg`，也可从 [GitHub Releases](https://github.com/UCASerYff/GaoWenJian/releases) 下载。打开后将“搞文件”拖入 Applications。当前版本采用本地签名，未公证。默认安装位置 `/Applications/搞文件.app`。

快捷键：⌘O 打开、⌘N 新 Markdown、⇧⌘N 新桌面便笺、⌘2 便笺中心、⌘S 保存、⇧⌘S 文本另存 UTF-8、⌘F 文本查找、⌘B 当前 LaTeX 编译、⌘W 关闭当前标签或浮窗、⌘, 设置。

默认内部资料路径：`~/Library/Application Support/GaoSeries/GaoWenJian`。原件在用户选择的位置；设置“导出工作区备份”不包含目录外的文档原件，需要一起备份项目文件夹。安装安全备份另保存在本项目 `安全备份` 中，不随升级删除，不上传。

## 构建与验证

需要 Xcode 命令行工具。所有运行时 Web 依赖、Tectonic 和基础宏包已随资源提供，应用不联网获取依赖。

```sh
Scripts/test.sh
python3 Tests/InstallTests.py
Scripts/build.sh
```

构建临时目录自动清理。`Scripts/build.sh --app-only /private/tmp/新的测试程序.app` 可生成隔离测试 App；`--data-dir /private/tmp/隔离资料` 指定测试资料位置；`--show-notes` 直接显示便笺中心。

安全安装：

```sh
Scripts/install.sh --app /绝对路径/搞文件.app --defer-cleanup
Scripts/finalize-install.sh --manifest /返回的绝对路径/manifest.json --verified
# 验收失败：退出新程序后用 --rollback 代替 --verified
```

先备份并逐文件核验本应用资料和设置（含便笺格式及全部附件），再安装、运行主要功能，最后确认验收并删除旧程序。后续正式版本每次 **+0.01**、构建号 **+1**。只保留最新本地发行包、源码、用户资料及安全备份；只处理本应用系统登记。

用户已批准在 [公开仓库](https://github.com/UCASerYff/GaoWenJian) 发布程序与源码。仓库排除个人文档、便笺、私有附件、设置、备份和凭据；安装包通过 Release 分发。第三方组件的许可及对应源材料保留在 `Docs/Licenses` 和 `Resources/Web/vendor`，不对第三方材料统一重新授权。
