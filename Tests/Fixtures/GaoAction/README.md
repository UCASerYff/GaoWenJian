# GaoAction V1 公共测试样例

此目录的 JSON 是跨应用契约样例，不是生产请求。固定测试时间为 `2026-10-12T12:00:00Z`；有效期至 `12:02:00Z`，测试 nonce 为 32 个零字节。生产发送方使用安全随机 nonce，并以发送时刻重新计时。

`input.txt` 的内容严格为 UTF-8 `hello` 加一个 LF，共 6 字节，SHA256 为 `5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03`。

可执行样例由 `Tests/GaoActionFixtures.swift` 的 `GaoActionFixtures.generate(in:)` 在隔离临时目录中生成。它创建 8 个同名 `.gaoaction` 包，设置私有权限，补入测试临时目录的真实身份及一份真实两页测试 PDF 的摘要。公开样例中的目录 URL 和 OCR 原件摘要是占位值，不代表用户授权，也不能作为真实原件身份使用。测试不发布临时目录的实际路径。

| 样例 | 预期结果 |
| --- | --- |
| v1-documents-newText | 接收 UTF-8 副本；经用户确认后创建未保存文档 |
| v1-storage-directory | V1 传输结构通过；搞文件分派返回 unsupported，不执行目录检查 |
| v1-ocr-partial | 接收 partial 状态并保留 inReplyTo；逐页失败不能伪称全成功 |
| v1-duplicate-request | 同一包再次接收只返回已有状态，不重放动作 |
| v1-expired | 拒绝过期 |
| v1-path-traversal | 拒绝附件路径越界 |
| v1-unknown-action | 拒绝未知动作 |
| v2-unsupported | 拒绝过新 schema |

`GaoActionTests.run(in:)` 还覆盖绝对路径、symlink、hardlink、FIFO、manifest 超限、项目超限、摘要不符、UTF-8 错误、并发内容变化、错误 target、参数白名单、原件引用身份变化、崩溃后幂等记录、损坏/过新历史保留及能力表身份和版本核对。这里只证明适配器与样例兼容；真实双方 OCR/选择文件联调需要实际安装的提供方和用户确认。
