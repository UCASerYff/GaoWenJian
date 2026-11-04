# 文件整理/查找 GaoAction（V1.10）

`com.gaoseries.GaoWenJian` 是 `files.search`、`files.choose`、`files.reveal`、`associations.manage` 的接收与结果提供方。旧提供方 `com.gaoseries.GaoZhengLi` 不再被本应用发现或启动。协议仍为 GaoAction V1、120 秒请求有效期、严格参数字段和本机包副本核验。发送者 Bundle ID 和 nonce 是声明与关联字段，不是身份认证。

| 动作 | 输入 | 实际行为与完成语义 |
| --- | --- | --- |
| `files.search` | 必填非空 `query`；最多一个 directory reference；无附件 | 查询当前宿主独立授权的真实 SQLite 索引，最多展示100条普通文件候选，显式勾选“发送勾选引用”才返回。更多筛选分页在主模块。无命中或没有可用授权会失败，绝不以普通文件选择器冒充索引搜索。 |
| `files.choose` | `allowedUTIs?`、`multiple?`；最多一个 directory reference；无附件 | 搞文件内置本机选择器，按钮明确为发送所选引用；取消返回 `cancelled`。只返回所选普通文件，应用包、目录、软链接、不符合类型或范围的选择失败。 |
| `files.reveal` | 恰好一个 file/directory/application reference；无附件和参数 | 本机选择面板独立核对路径与身份；匹配后调用系统 Finder 定位 API。回执 `workflowState=revealed`、`identityVerified=true`、`revealRequestIssued=true` 表示已发出定位请求，不宣称调用方已处理结果或 Finder 的视觉验收。 |
| `associations.manage` | 可选 `uti`，无附件和引用 | 进入真实类型关联管理；打开界面只在本机记为等待，ledger保持 `executing`，不发送伪完成回执。用户明确修改、系统读回一致后才返回 `completed`，含 `workflowState=changed`、`readBackVerified=true`、实际 `uti`。取消返回 `cancelled`，错误返回 `failed`。迁移历史不自动重放系统关联。 |

搜索与选择成功结果没有正文附件，返回 `references`，`provenance` 为 `workflowState=selected`、`selectionCount`、`accessRequiresReceiverVerification=true`。引用保留本机 file URL、device/inode/byteCount/小数秒 modifiedAt；不导出书签或读取权限。接收方必须自行核验原件身份并在需要时正常取得权限。目录引用只限制选择范围，不授权索引或文件读取。

## 宿主接线与初次请求

`OrganizerActionProvider.indexSearch` 绑定 `OFAppModel.providerSearch(query:scope:)`，返回 `OrganizerSearchLease`。它持有当前独立授权根的访问 scope，直至显式选择和引用身份核对完毕再释放。迁入书签标为待重新授权，不能靠旧书签或旧进程权限直接变成可用根。

`OrganizerActionProvider.manageAssociations` 绑定 `OFAppModel.requestAssociation(uti:completion:)`，真实 `OF...AssociationController.change` 读回后完成或明确取消。重复 completion 只处理一次。期间其他文档交接可继续，最终回调重新打开 durable ledger，再更新该请求行，不能用早期内存世代覆盖较新的其他行。

外部请求首次到达时宿主惰性加载**已存在且完整核验的**整理资料；不会为接请求自动建立新空根，避免占掉旧库迁移位置。尚未建库/迁移、损坏或未授权时明确失败并提示进入模块处理，不自动清空或把缺失当空白。

内部“选择文档”直接调用本机选择器并 `WorkspaceStore.open`，不创建发给自己的 `files.choose` 包。通用发送器也拒绝本应用四个整理动作的 self handoff，避免递归。

## 历史与恢复边界

所有新请求使用搞文件原有私有接收副本、摘要和 `ProcessedRequests` ledger；同ID同摘要为重复，不重新执行；同ID不同摘要拒绝。关联未完成时不自动重放。进程重启后旧 `executing` 请求仅保留审计事实，需要用户核对实际系统状态后另发新请求。来源应用的旧 Exchange 记录只能归档，不能导入本 ledger 当待执行动作。

现有文档、OCR、研究交接仍使用原有验证、原件/副本选择和未保存稿保护。历史来源显示 `com.gaoseries.GaoZhengLi` 保留为历史“搞整理”，不会据此启动旧程序。

## 验证

`Tests/OrganizerActionProviderTests.swift` 以合成文件和注入的呈现层调用生产选择验证、transport、provider dispatcher 与 durable ledger，覆盖中文命中选择、空索引不回退、scope/UTI/数量/软链接拒绝、取消与重复、关联 pending/系统读回回执/重复回调、等待期间交错 ledger 更新及未保存稿/原件保护。不会初始化 NSApp、改变实际系统默认关联或启动旧应用。编译与执行由主代理持本轮唯一构建租约统一进行；此文档不将编译或合成逻辑测试当成实际 GUI 验收通过。

无窗口环境中，普通文件已通过逐路径 `O_NOFOLLOW` 固定可读 FD 后，系统可能不给出 LaunchServices 类型元数据。仅 OSStatus `kLSDataUnavailableErr(-10813)`（或 Cocoa `NSFileReadUnknownError` 包裹该明确错误）可使用扩展名 `UTType` 兜底；权限、I/O 和其他错误照常失败。扩展名已知包类型、系统 `isPackage=true` 或 `UTType.package` 均拒绝，不会把包当普通文件返回。定向测试保留真实合成文件选择，并另覆盖该明确元数据故障、权限/未知错误不吞与包扩展名拒绝；不初始化 NSApp 或 LaunchServices。

进一步的无窗口类型边界：明确 `-10813` 时的兜底采用有限的框架标准常量（txt/md/tex等纯文本、CSV/TSV/RTF/HTML/XML/JSON、PDF、PNG/JPEG/TIFF/GIF/HEIC/HEIF），不依赖再次查询扩展名注册表。`allowedUTIs` 中这些标准identifier也直接映射同一常量；其他identifier仍必须由系统解析为真实非dynamic类型，否则拒绝。未知扩展名没有自造具体UTI，保守按普通data或系统真实映射处理；不会注册新类型、初始化App或启动LaunchServices来让测试通过。
