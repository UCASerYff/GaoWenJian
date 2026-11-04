# OCR 客户端提供方切换（V1.10 未交付）

本轮范围扩展为搞截图整体并入搞操作。搞文件的新 `ocr.files` 请求只向 `com.gaoseries.GaoCaoZuo` 发现能力和显式递交，保持原 `outputs` 参数与 text/markdown/json/searchablePDF 结果、逐输入/逐页摘要映射和用户确认语义。此客户端不自行提供或伪造 OCR。

`OCRHandoffDispatcher.providerBundleID` 同时供请求 target、outgoing journal expectedTarget 与真实已安装能力查找使用。发送前仍核对实际应用 Bundle/版本/能力表，且当前 provider 必须匹配本次 session target 与 `ocr.files` 动作；能力不存在、不兼容或发送失败不报告识别完成。发送成功仅为 dispatched，仍需对方真实处理和用户确认结果。

旧持久会话的 `targetBundleID`、私有请求与 `manifestSHA256` 不迁改，不重签包，不自动重放或转发。结果仍必须满足 `sourceBundleID == session.targetBundleID`。旧截图 owner 的历史会话不会被新搞操作结果接管，新请求也不会接收旧截图 owner 冒充的结果。历史 IncomingDocument 的“搞截图”标签保留；新的搞操作来源显示其真实名称。

## 后续协调验证

仅语法与静态核对已执行。新聚焦逻辑检查入口：`Scripts/test-headless.sh --ocr-provider-routing-only`，须在Root安排的后段构建租约内执行。它使用本机合成图像、生产prepare/writer/transport/journal，并断言双向错误owner拒绝、旧会话/私有请求不变、新旧owner各自的 pending 回执仍可持久化且不伪造完成、NSApp始终nil；不启动真实提供方，也不运行Organizer或通用smoke。

2026-11-03 静态复核修正了专项fixture的回包暂存根，使其使用同一隔离Exchange的Staging，符合生产journal的完整性边界；生产journal未为测试放宽。PDF扫描件按钮提示同步改为搞操作。专项运行仍待构建槽位，不能将这些静态准备记作运行通过。

实际新搞操作 OCR 生产bridge及能力表就绪后，再由协调流程进行相应提供方对照和真人业务验收。不能把旧截图bridge输出改一个sourceBundleID来充当新宿主实装。

当前Organizer阶段候选不包含本次OCR客户端切换，不能当新增12项范围的最终包。版本继续1.10/build11，最终客户端重编译由Root排后段；真实资料、系统权限、安装和发布本次均未改动。

## 最新状态（2026-11-04）

以上“待构建槽位”和“Organizer阶段候选”是当时的阶段记录。当前V1.10/build11最终客户端已包含本次OCR提供方切换，11项聚焦OCR逻辑断言实际通过；最终Development签名、完整库存、ZIP恢复及DMG副本一致性已核验。之后的外部导出、安装收尾及公共打包脚本修正没有重编或重签这些产物。

本机整理资料已由协调流程迁入并完成实际扫描、查找、筛选、排序和重命名预览/取消验收。新搞操作的实际OCR请求、处理及结果往返仍待对应新版接力验证，不能用逻辑断言代替，也不因此提前完成来源退役或公开发布。通用冒烟未运行。
