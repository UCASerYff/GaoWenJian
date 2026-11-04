# 搞文件

- 独立 macOS 本地文件编辑工作台，初版 V1.00 / build 1。后续正式更新版本 +0.01、构建号 +1，同次交付前修复不增号。
- 当前定位：LaTeX、Markdown 写作与编译为核心，PDF 提供文字/图片叠加编辑及页面工具；Word、Excel、PowerPoint 只读查看；便笺为附加工具。首页与导航保持该层级。调整入口时保留已打开编辑器和未保存状态；不可因改为 Office 查看器删除旧编辑恢复稿。
- 目前无需账户、不提供联网或 AI 功能；所有编辑、编译和转换在本机完成。允许开发时获取并随应用分发必要的本地依赖。
- 仅修改本目录及本应用安装路径；不修改其他搞系列应用。
- 图标与搞系列书法字风格一致，均匀纯灰底、白色竖排“文件”，不得添加底纹、噪点或杂质。1024 画布保持不裁切；以其他 10 款实际文字中位数约 602 px 高、文字占色块约 70% 为准，灰色色块 860×860，字形资产等比绘制 660×660 并补偿其内部留白，实际字形居中。
- 原生 macOS 界面；主窗口系统标题“搞文件 V<当前版本>”；设置使用独立窗口，⌘, 打开。
- Bundle identifier 为 com.gaoseries.GaoWenJian。安装目标 /Applications/搞文件.app。
- 源码、资源、使用说明、测试和当前安装包全部保存在本目录。用户真实文档原路径保存，不将用户文件复制到发行包。
- 工作区状态、恢复草稿和历史默认 ~/Library/Application Support/GaoSeries/GaoWenJian；损坏或无法读取时禁止以空资料覆盖。
- 任何覆盖保存必须保留原件快照。无法无损处理的格式须明确提示并提供另存，不得静默删除未知对象或宏。
- 发布与安装前安全备份、核验本应用资料和设置；新版本成功验证后精确删除本项目旧程序、旧安装包和中间构建；保留源码、最新版发行包、用户资料和安全备份。失败恢复旧程序。
- 用户于本轮批准新建公开 GitHub 仓库发布搞文件及 Release；后续按工作区规则更新对应仓库。只上传程序、源码、资源和许可，严禁上传安全备份、个人便笺、文档、附件、设置或凭据。
- 便笺资料独立存于同一内部资料路径下的 StickyNotes 子目录；富文本和附件需整体核验，损坏、摘要冲突、过新格式或主记录缺失时不得空白覆盖。关闭桌面便笺仅隐藏，删除进入回收站；未保存时不得静默退出。
- 正式候选使用已授权的 Apple Development 签名（下节），不声称 Developer ID 或公证；身份不可用就停止，禁止降为 ad-hoc。
- 正式测试使用隔离临时资料路径，禁止拿真实用户文档执行修改测试。

## 稳定 Development 签名（2026-11-02 总协调已授权）

- 正式构建固定签名身份SHA-1 `A15B2B2D22B018CBC842063C9A8A589946647524`，Team `5G96498KGJ`；主 Bundle ID `com.gaoseries.GaoWenJian`、资料路径、Keychain服务名全部保持。
- `Scripts/sign_bundle.py` 是唯一生产签名入口，build预检必须在实际用户上下文确认身份。沙箱security空结果/失败不能当无证书，更不能自动降签；真实私钥不能使用时停止报告，不修改钥匙串ACL/partition-list，不导入或导出私钥。
- 固定主DR：`designated => identifier "com.gaoseries.GaoWenJian" and anchor apple generic and certificate leaf[subject.OU] = "5G96498KGJ"`；每个嵌套对象按原identifier使用相同Team约束。tectonic固定identifier `com.gaoseries.GaoWenJian.tectonic`。旧cdhash requirement不保留。以后更新沿用该证书/Team/完整DR，证书轮换另核。
- 先逐个嵌套代码/框架/扩展inside-out签，宿主最后封资源，绝不 `--deep` 签。逐对象提取、保留并核对原entitlements和语义flags；ad-hoc/linker-signed两机制位随证书签名消失，不是业务权限。无原entitlements就不额外加调试或其他权限。不得统一entitlements覆盖框架/扩展。
- `--timestamp=none`，不用网络时间戳。签后核每个MachO架构/SHA、精确叶证书SHA、实际Team、完整DR及strict/all-architectures，主bundle再deep严格验证（仅验证可deep）。记录全库存与实际ZIP展开恢复核验；旧正式程序的原对象/安全备份仍由安装协调流程保留。安装器只复制/验签，不再deep重签。
- 旧V1.09及Organizer阶段候选是ad-hoc且DR绑定cdhash，新代码不能等价沿用旧TCC身份。本次用户需在实际系统流程正常确认权限，不承诺自动转授；稳定Development用于减少今后反复改变身份，不代表已公证。

## 整理来源退役后的现用数据（2026-11-03）

- 依根AGENTS最新策略，来源最终验收后不长期保留旧件/旧资料/专属备份。仅总协调显式运行生产CLI `finalize-source-retirement --destination <精确Organizer>`，核原迁移/权威和现用schema/身份并原子写入精简完成凭据；App不自动执行。
- 入口只解除对SourceArchive的生产依赖并返回精确三路径白名单，不自行删除。删除仍由总协调在最终验收后执行；现用配置、索引/收藏/工作区、关联历史、MovePlans、稿、待恢复原inode、用户文件以及当前精简权威凭据保留。无合法finalized凭据删除旧归档仍须停写保护。
