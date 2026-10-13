# 搞文件 V1.05 验证报告

- 验证时间：2026-10-13
- 验证版本：V1.05 / build 6
- 运行环境：Apple Silicon (macOS 14+)

## 1. 自动化回归测试结果

运行 `Scripts/test.sh` 包含以下子套件，全部一次性通过：
- **CoreTests**: PASS（CSV/TSV、精确历史记录、外部修改/删除防护、损坏状态保留、空白草稿安全恢复）
- **OfficeRecoveryTests**: PASS（原子草稿 / 历史副本保留 / 外部修改冲突 / 损坏留存）
- **OfficeRoundTripTests**: PASS（Word / Excel / PPT 原样保留 / 覆盖备份 / 冲突阻断）
- **OfficeViewerTests**: PASS（只读快照、缓存值提取、旧版格式 passthrough、保留草稿导出）
- **PDFTests**: PASS（PNG 嵌入、保存/重开后外观保留、撤销/重做/崩溃恢复/页面提取、4种旋转度数、非零 CropBox、位移/缩放/删除、文字颜色与字号保持、中文/西文字形渲染比对、字节精确备份）
- **GaoActionTests**: PASS（45项断言：GaoAction V1 清单解析、固定FD传输、私有 staging 权限校验、幂等记录状态机、竞态修改阻断、过期拒绝、越界路径拒绝、未知动作拒绝、能力表发现）
- **PDFHandoffTests**: PASS（原件摘要核验、页数/页序、旋转度数、Crop/MediaBox 几何、真实文字选取、展平/旁注/页外负样本、部分页面来源、未保存独占副本导出）
- **DocumentHandoffSafetyTests**: PASS（72项断言：静态 Office 检查、UTF-8/RTF 校验、XML 外部实体与 Zip 炸弹防护、大小限制、敏感内部路径阻断）
- **LaTeXTests**: PASS（智能结构索引、自动补全、诊断跳转、魔术根文件指令 45 项断言）
- **StickyNotesTests & StickyNotesUITests**: PASS（富文本、PNG/PDF 附件、轻量元数据历史、不可变 blob、架构迁移、回收站恢复、导入导出、冲突与符号链接防护）
- **MarkdownCoreTests**: PASS（源码保留、块编辑边界、CRLF、未知宏与 HTML 宽容、公式、表格、任务列表、大纲与引用 113 项断言）
- **RTFRecoveryTests**: PASS（富文本恢复、样式保持、原件不改动、摘要冲突、草稿完整性 20 项断言）
- **IconTests**: PASS（108,000 像素无杂质纯灰底 860×860，竖排居中“文件”书法字 300×602 像素）

运行 `python3 Tests/InstallTests.py`:
- PASS: 丢失记录、初次安装、升级前备份、嵌套附件、设置迁移、回滚恢复、验证通过清理、错误 bundle 阻断、未解析数据阻断及损坏备份保护。

## 2. 跨应用交接契约核验

1. **GaoCapabilities.json 声明**：
   - 声明 `documents.open` 与 `documents.newText`；
   - 参数模式严格定义，拒绝未知参数；
   - 随 App Resources 打包分发。
2. **Info.plist 注册**：
   - 注册 `.gaoaction`（UTType `com.gaoseries.action-package`，rank Alternate，package 属性生效）；
   - 注册 `UTExportedTypeDeclarations`。
3. **入站处理交互**：
   - `FileAppDelegate` 与 `WorkspaceStore` 安全分流 `.gaoaction`；
   - 弹出模态对话框，清晰展示来源应用名称、动作类型、文件/文本大小与 OCR 来源元数据；
   - 用户取消绝无副作用；用户确认后新建未保存文档或安全打开文档。
4. **出站处理交互**：
   - 在首页、PDF 工具栏、图片查看器及主菜单提供“识别扫描件/图片 (OCR)”入口；
   - 未保存的 PDF 提供“导出副本”与“发送原件”提示；
   - 检测搞截图（`com.gaoseries.GaoJieTu`）能力；若未安装，友好提供“在访达中显示”与“导出副本…”，不破坏原件且不联网。
