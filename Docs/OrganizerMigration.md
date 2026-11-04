# 搞整理资料迁入搞文件

迁移为显式操作：用户先从搞整理的完整停写快照导出，再在搞文件整理模块选择“导入搞整理核验快照”。不会在启动时扫描或读取旧应用真实资料。新资料根为 `FileSafety.root/Organizer`；导入成功仅表示准备完成，不代表已获得运行写入权威。编辑工作区、未保存稿和便笺根不参与此事务。

## 导出契约

`Scripts/export-organizer-snapshot.py --source <完整资料根> --preferences <源偏好plist> --output <不存在的快照.noindex> [--retiring-path <将退役路径>]`

调用者须明确传入源偏好文件，独立初始化键 `GaoZhengLi.initialized.v1` 必须为真。缺库、缺初始化记录、摘要冲突、过新版本、符号链接、特殊对象、硬链接、异主对象或未下载占位文件均停止；不当空库处理。源应用已有 `.app.lock` 以只读文件描述符取得非阻塞排他锁；不创建或改写源锁。导出前后完整源文件、目录身份和偏好清单必须相同，外部待恢复实物也需前后相同。

SQLite 不在源路径打开：先复制完整数据库及 WAL/SHM 到 `SourceRaw`，另建私有 SQLite 工作副本，在工作副本上执行 SQLite online backup，得到合并 WAL 的独立 `Data/metadata.sqlite`；检查 `quick_check`、外键、schema 1/2 及 `databaseID` 与独立 marker。工作副本完成即清理，原始 `SourceRaw` 不被 SQLite 打开。源目录的其余文件、附件、书签、关联历史、MovePlans、旧交接记录全部保留。源偏好保存在快照，不自动应用到搞文件偏好域。

快照包括 `snapshot.json`、其摘要 `VERIFIED`、逐文件大小/SHA-256/模式/扩展属性清单及真实文件系统恢复演练 `RestoreReport.json`。恢复演练将完整快照复制至新的带所有权标记的 `/private/tmp/*.noindex`，再次逐对象比较并验证恢复数据库，完成后只清理该演练目录。读取或复制扩展属性失败不会降级为空属性；BSD flags/ACL 的逐对象完整迁移认证不由现有便携清单冒称覆盖。

普通已索引用户目录不是私有附件，不复制整盘原件。旧书签归档但不继续使用。将退役路径以内的既有文件引用、以及未完成移动所需的现存来源/目标实物会纳入自包含引用副本；缺失的必需恢复实物阻止导出。普通外部用户原件维持原绝对路径。快照须置于来源项目与资料之外，验收前由总协调临时保护；按2026-11-03新策略，最终验收并解除依赖后由总协调精确删除来源旧件/资料/专属备份，不长期保留可恢复旧副本。导出结果本身不授予删除权限。

## Swift 接口与提交

```swift
OrganizerMigration.importSnapshot(url: snapshotURL, destination: FileSafety.root.appendingPathComponent("Organizer"))
```

同步 `throws`，无 NSApp/自动初始化，可在 `Task.detached` 中调用。配置、关联记录和 MovePlan 还会用移植核心的实际 Codable 类型解码，避免导入器接受而运行控制器无法读取。返回 `OrganizerMigrationReport`（Codable、Sendable）：`snapshotID`、`sourceDatabaseID`、`destinationPath`、`importedRoots`、`importedFiles`、`preservedObjects`、`needsAuthorization`、`alreadyImported`、`recoveryRequiresReview`。

只接受新目标；已有未知目录、缺损迁移账本、错误初始化标记一律停止。完整来源快照保存在目标 `SourceArchive`。`MigrationLedger.json` 使用 schema 1、payload 与 SHA-256 保护封套；账本摘要或策略损坏时停止，不能当作幂等成功。同一快照成功后再次导入，仅核对不可变来源归档及专属迁移记录并返回幂等结果，不用旧数据库或旧文件覆盖迁移后新增的用户资料。不同快照不能覆盖原目标。

准备在同卷 `.organizer-migration-<snapshotID>.noindex` 事务目录内进行。持久化 intent、排他锁、独立 attempt、核验后的 Ready 目录和最终排他原子改名分阶段提交。准备中断保留 attempt，显式重试建立新 attempt；不删除未知中断资料。最终 Organizer 已提交而父 marker 尚未写入时，只有同一快照、完整专属账本与不可变归档核验后才能补写 `Organizer.initialized` 的 `schema=1\n`；不能从未知非空目录猜测迁移完成。旧 intent 和中断材料保留供精确清理，不纳入发行包。

## 权限、历史和物理恢复边界

- 根 ID 与文件 ID 在全新的整理命名空间中保留，数据库 `organizer_migration_ids` 明确记录来源/目标映射；配置的根引用须存在。配置、标签、收藏、搜索与虚拟工作区保留。
- 全部迁入根 `status=needsAuthorization`、`paused=1`、活动 `bookmark` 清空；旧书签仅留 `SourceArchive`。自动监控关闭，旧扫描中间输入仅留归档。核心的 accessLease 和恢复监控必须经过重新授权，不能仅取消暂停绕过。
- 关联历史保留，`pending` 标记 `interrupted`；导入器不调用系统关联 API，也不重新应用历史配置。历史应用路径可已不存在，不是自动可用的关联授权。
- 旧 Exchange 全留 SourceArchive，不进入新提供方运行目录，旧请求/nonce/prepared 结果不重放。
- 未完成物理整理如涉及将退役来源的私有路径，导入在写目标之前明确拒绝：复制件不继承原 inode，不能当成原对象安全回滚。总协调必须继续保留原同 inode 实物和来源，先单独恢复或实施可核验的实体迁移，不能仅靠“needsRecovery”放行退役。
- 尚在普通用户位置的待恢复对象保留原 URL、原 MoveSnapshot 和父目录身份；归档副本不替代原件，也不会自动执行/回滚。实际恢复仍需用户新授权、身份复核和原位置不被后来资料占用。失败不覆盖后来文件。

## 验证范围

`Tests/OrganizerMigrationTests.swift` 提供合成隔离实际导出→真实恢复演练→Swift 导入、WAL 已提交数据、幂等新增资料保护、非空目标、初始化缺失、过新 schema、符号链接及私有 pending 原 inode 保留拒绝测试。另有 `beforePublish`、`afterPublishBeforeAnchor` 两个仅限隔离根的真实故障注入点，测试显式重试并确认提交后新增文件不被旧快照覆盖。实际 OF 配置、索引、关联假系统和物理日志初始化均纳入测试源码。运行由主任务持唯一构建租约安排；Swift 测试源码存在不代表已经执行或通过。默认不跑冒烟、不启动应用，不触碰真实源/目标 Library 数据，不改系统关联或权限。

实现过程中仅独立运行过 Python 导出器的纯合成完整导出/真实文件系统恢复及 WAL 已提交数据测试，源清单保持一致，全部带所有权标记的临时根已回收。尚未将此等同于 Swift 导入或真人 GUI 验证。

## 最终停写切换与 CLI

生产使用同一引擎，`Tools/OrganizerMigrationCLI.swift` 仅薄封装，编译与临时输出由总协调持唯一构建租约安排。命令必须显式指定绝对路径，没有真实 Library 默认值；不启动 NSApp：

```
organizer-migration import --snapshot /exact/Snapshot.noindex --destination /exact/Organizer
organizer-migration activate --destination /exact/Organizer --authority-receipt /exact/SourceFreeze.json
organizer-migration verify --destination /exact/Organizer
organizer-migration finalize-source-retirement --destination /exact/Organizer
```

`import` 不激活。`OrganizerMigration.requireActiveAuthority(directory:)` 必须在 OFAppLocations.prepare 与宿主开始初始化前执行：迁入根包含 MigrationLedger 时，缺少/损坏激活凭据即拒绝写入；存在归档/激活遗留但账本缺失时同样拒绝，不能假装新库。普通新建而非迁移的空资料库不需要来源收据。

总协调完成实际最终来源停写、最后清单核验与权威唯一切换后，才能生成独立 0600、同用户、nlink=1、无符号链接的正式 JSON 收据并显式调用 `activate`。字段：`schemaVersion=1`、`kind=GaoSeriesSourceWriteFreeze`、`sourceBundleID=com.gaoseries.GaoZhengLi`、`targetBundleID=com.gaoseries.GaoWenJian`、`sourceDataRoot`、`targetDataRoot`（精确 Organizer 目标）、`snapshotID`、`manifestSHA256`、`sourceInventorySHA256`、`sourcePreferencesSHA256`、`writersStopped=true`、`sourceFrozen=true`、ISO-8601 `issuedAt`。所有来源/快照摘要字段必须与 SourceArchive/snapshot.json 完全一致，SourceDataBaseline 等预备收据不能激活。

激活只新增原始 `SourceAuthorityReceipt.json` 与摘要封套 `ActivationReceipt.json`，不重写既有目标业务资料。相同原始收据幂等只读返回；不同收据拒绝覆盖。写原始收据后中断可凭相同正式收据显式重试；损坏/冲突则保留现场停止。运行期 gate 只验证本地账本、不可变归档和凭据绑定，不重新读来源库、查询来源进程或复用其授权，适应来源退役。此为总协调停写声明的本地完整性验证，不是数字签名认证或操作系统授权转授；实际冻结责任仍由总协调完成。书签根仍必须重新授权。

隔离测试还覆盖：导入后 gate 拒绝；预备/错误来源摘要收据拒绝；正式合成停写收据激活；相同收据幂等、不改后来资料；本地激活封套损坏停止；不同正式收据拒绝覆盖。真实来源冻结和真实生产激活不能用合成测试代替。

物理整理源目录与三份账本/初始化文件必须已经满足实际 OFMoveEngine 的私有权限（目录及文件无 group/other 权限）；导出在创建输出前验证，导入独立复核，不静默 chmod 来源或来源归档。合成测试由真实 OFMoveEngine 建立空账本，另测 0644 来源账本拒绝且源不被“修复”；runner 逐阶段即时输出定位。

## 验收后的显式来源收尾（2026-11-03）

`finalize-source-retirement` 只由总协调在实际迁移、业务及调用者验收完成后显式执行；正常启动、导入和激活均不自动调用。命令本身表示协调方已完成验收的本地声明，不是数字认证或替代实际验收。调用前须正常关闭整理模块/宿主，现有 `.app.lock` 与 `MovePlans/.lock` 必须存在、归属和私有权限正确且可排他取得；不能创建新空锁绕过仍在运行的写者。

首次收尾严格验证原完整 `SourceArchive`、原迁移账本、冻结/激活收据以及当前 production 的配对初始化、databaseID、MovePlans storeID、schema 和实际 typed 配置/关联/移动账本可读。现用 SQLite 使用普通只读一致事务，读取已提交 WAL；只对导出的独立快照使用 immutable。索引根和移动操作的实际 URL（包括规范化路径与符号链接别名）仍指向待删归档时拒绝。自由搜索文字和历史关联说明不当作活动附件，也不被改写。

收尾仅原子持久化 `SourceRetirementFinalized.json`：0600、schema/payload/SHA 封套，含来源/目标ID、精确目标、快照ID、数据库/MovePlans身份、原账本/权威/激活摘要、支持schema版本、字段语义与时间；不嵌入旧raw数据、书签、数据库行、偏好或附件。完整pending文件fsync后用排他rename提交并fsync目录。提交前中断仍依赖完整旧归档，显式重试须重新核验；提交后中断可幂等读取同一完成回执，不覆盖后续业务资料。

成功返回的精确白名单只有当前目标下的 `SourceArchive`、`MigrationLedger.json`、`SourceIDMapping.json`。入口不删除它们；总协调须在同一停写窗口核对结果后执行精确清理。其他位置的来源旧资料、专属备份仍由总协调依各自身份另行处理。当前 `SourceAuthorityReceipt.json`、`ActivationReceipt.json` 和精简 finalized 回执为现用权威元数据，保留；配置、索引/收藏/工作区、关联历史、MovePlans、PreservedReferences、宿主草稿、待恢复原inode和用户原文件均不在白名单。

之后生产优先严格核finalized与保留权威、当前schema及库身份，不再读取SourceArchive，也不以旧内容摘要冻结可编辑资料。无finalized凭据而丢归档仍停止；坏/未来schema、未来时间或串源/串目标凭据不回退，删除finalized也不能把已有激活资料降级为新库。已完成后使用verify和幂等finalize，不重新import/activate旧快照。

新窄检查入口 `Scripts/check-organizer-retirement.sh` 只编生产核心和 `runRetirementOnly`，覆盖缺档/锁/原子中断、精确白名单后可用、WAL与合法后续编辑、坏/未来/串源凭据、活动归档引用、现用稿和原inode保留；不重跑旧整套，不启动应用。调用方先取得统一构建租约，再显式设置 `GAOWENJIAN_BUILD_LEASE_FILE`（租约owner.json绝对路径）与 `GAOWENJIAN_BUILD_LEASE_OWNER`（本次持有者）；缺失、路径别名或owner不匹配均拒绝，不内置私人会话编号和协调目录。当前仅代码/静态准备，实际编译运行与更新CLI摘要等最终构建槽位，不能记作通过。
