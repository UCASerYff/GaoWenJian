# 稳定 Development 签名准备（V1.10 历史记录）

当前策略（V1.11）：以下旧程序备份、资料备份及回滚保留描述已停止适用。安装只做现用资料逐文件摘要核验，不创建或保留备份；旧程序精确卸载，中间候选和私有签名收据用后清理。固定证书、Team、完整 DR 与逐组件签名要求继续适用。

本轮正式换装前采用总协调已授权身份 `A15B2B2D22B018CBC842063C9A8A589946647524`、Team `5G96498KGJ`。不更换主 Bundle ID、用户资料路径或钥匙串服务名。不是 Developer ID，不声称公证。

`Scripts/build.sh` 先在实际当前用户环境用 `Scripts/sign_bundle.py preflight` 确认签名身份，再编译。查询失败或沙箱查不到时停止，不自动改成 ad-hoc，也不更改钥匙串 ACL/partition-list、导入或导出私钥。私钥真正可用性仍以最终签名成功为准；不会把只读身份列表当作已签名。

签名对象由实际全部 Mach-O 与含执行代码的 App/framework/xpc/appex/bundle/plugin 清点形成，逐个从内到外签，宿主最后封资源。当前源分发的原生工具只有 `Contents/Resources/Tools/tectonic`；它必须单独签。新编译主程序由宿主封签，不能 `--deep` 签或统一 entitlements 扁平化覆盖。

每对象签前提取完整 requirements、原 entitlements XML/DER、flags 与 identifier。保持原 entitlements 和语义 options，不增加 get-task-allow；ad-hoc、linker-signed 两签名机制位不带入证书签名。运行版本/约束仅明确保留相应 metadata，不使用 preserve-metadata=requirements 或无列表的 preserve-metadata。新 DR 固定为 identifier + Apple generic anchor + leaf Team OU；宿主准确文本见 AGENTS.md，旧 cdhash requirement 丢弃，不用旧代码哈希伪装权限沿用。

签后逐项核精确叶证书 SHA-1、实际 Team、identifier、完整 DR 无 cdhash、entitlements/语义 flags 相等，所有 Mach-O 架构和 SHA，strict/all-architectures。主 bundle 可以用 deep 做严格验证。另作完整自生 ZIP 实际展开恢复，并核全部内容/链接/mode/uid/gid/flags/nlink/xattrs/ACL/mtime；若 ZIP 时间精度不足，仅允许用独立收据明确恢复 mtime 并记录，不能修掉内容或安全属性差异冒充原始ZIP完全等价。签名收据与 App-only 输出相邻保存，实际库存/恢复结论须以执行记录为准。

2026-11-03 静态续查已修正 `--requirements` 的字面参数前缀 `=`，并增加实际完整 designated requirement 等于固定策略的守卫。最终 App-only 导出和 DMG 源副本都另存 `copy-verification.json`，绑定原签名收据 SHA，对比副本全库存、全部 Mach-O、entitlements、语义 flags 与完整 requirements。差异阻止交付并保留证据，不修改副本来凑通过；内部暂存路径的诊断文字不当作可移植身份字段。新增命令构造、完整 DR 及副本差异逻辑使用隔离/mocked unit 验证；真实签名和恢复仍待最终槽位执行。

安装器对 V1.10 及以后新正式候选核上述稳定身份；对旧程序回滚仍可验证原 ad-hoc 签名和原备份。安装只复制并核验，不重新签名。原正式程序同卷原对象及真实资料/全部附件的安全备份与恢复，由协调换装事务另行完整保留；新候选的ZIP恢复验证不能替代旧程序/用户资料备份。

旧 V1.09 和 Organizer 阶段候选的 DR 是 ad-hoc cdhash。新代码无法保持其原身份；本次需要用户在正常系统流程确认权限，不能承诺旧 TCC/钥匙串访问权自动转授。采用稳定证书与 DR 是为了后续更新保持连续身份。

本阶段仅完成脚本、规则与静态准备，未查询私钥、未签名或重新构建任何候选。待最终客户端候选阶段统一取得构建租约，并在真实用户签名上下文执行一次；不重跑未变化的业务测试，不抢队列。

## 最新状态（2026-11-04）

上文末段为最终构建前的阶段记录。当前V1.10/build11最终候选已在实际用户环境完成固定Apple Development身份签名；全部Mach-O、完整DR、精确证书与1655项完整库存、ZIP展开恢复及DMG内App副本一致性核验已通过。DMG已卸载；本轮后续外部脚本和公开文档修正没有重编或重签最终App、CLI或DMG。

这些签名与构建结论不替代真实业务验收、安装收尾或来源退役。新搞操作OCR的真实跨应用往返仍待协调验证；当前仅准备草稿发行，不据此公开发布。签名类型仍为Apple Development，不是Developer ID或公证。
