# Markdown 本地组件与依赖

`MarkdownWorkspace(text:baseURL:onError:)` 接受外层 `Binding<String>`。源码为唯一权威；即时编辑采用块级 Markdown 原文编辑，点击段落进入源码编辑，完成后呈现格式。分屏与纯源码模式共用同一份原文，不执行 HTML 转 Markdown。未知 HTML、注释、自定义语法及未编辑块的换行保持原样。

`baseURL` 可传当前 Markdown 文件 URL 或其目录。相对图片在该目录内解析；插入、粘贴和拖拽图片保存到旁边 `.assets`，不覆盖原图。未保存文档需要先保存后插入附件。所有资源经本地 `gaomd` scheme 读取，校验标准化路径与符号链接，拒绝目录外资源；应用不请求 HTTP/HTTPS。

支持 GFM 表格和任务列表、公式、Mermaid、脚注、Front Matter、大纲、代码高亮。本地 HTML 导出内嵌字体和图片，Mermaid 导出为 SVG。PDF 通过 macOS 打印引擎生成分页 A4 文件。覆盖导出调用 `FileSafety` 创建原件快照。

| 依赖 | 固定版本 | 许可证 | 源码来源 |
| --- | --- | --- | --- |
| Marked | 18.1.0 | MIT | https://github.com/markedjs/marked |
| KaTeX（含本地 WOFF2 字体） | 0.19.0 | MIT | https://github.com/KaTeX/KaTeX |
| Mermaid | 12.1.0 | MIT | https://github.com/mermaid-js/mermaid |
| DOMPurify | 3.4.16 | MPL-2.0 OR Apache-2.0（采用 Apache-2.0 许可选项） | https://github.com/cure53/DOMPurify |
| highlight.js | 11.12.0 | BSD-3-Clause | https://github.com/highlightjs/highlight.js |

原始许可证位于 `Resources/Web/vendor/*.LICENSE`，随应用分发。依赖在开发时从 npm registry 或固定版本的 jsDelivr 获取；运行时全部随 App 离线加载。Mermaid/Marked 使用原始官方发行 bundle，未修改其内容。

验证命令：

```sh
node Tests/MarkdownCoreTests.js
xcrun swiftc -module-cache-path /private/tmp/gaomd-module-cache -target arm64-apple-macos14.0 -swift-version 5 Sources/FileSafety.swift Sources/MarkdownWorkspace.swift Tests/MarkdownWebSmoke.swift -o /private/tmp/gao-md-web-smoke
/private/tmp/gao-md-web-smoke
```

WKWebView 冒烟测试只操作随机临时目录和测试窗口，不修改真实用户文档。
