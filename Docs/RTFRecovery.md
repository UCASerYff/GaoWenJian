# RTF 本地恢复

富文本每次编辑后将 RTF 内容、原件路径、原件 SHA-256 摘要和草稿校验摘要保存到应用资料目录的 `Recovery/RTF`。写入使用原子替换，不修改原件。

重新打开时，只有原件摘要仍匹配才将未保存内容恢复到编辑器，并显示恢复提示。原件变化、草稿损坏、校验不一致或草稿被外部改动时，打开可读取的原件并保留旧草稿，停止覆盖旧草稿。无法读取的原件禁止保存。

正常保存仍经过 `FileSafety` 原件快照与外部修改检查；成功后清理该文档的有效恢复草稿。用户明确选择丢弃关闭时，根工作区发送 `GaoWenJian.discardDraft` 通知，`object` 为该文档路径，精确删除对应草稿。

测试只能使用隔离目录：

```sh
xcrun swiftc -module-cache-path /private/tmp/gaomd-module-cache -target arm64-apple-macos14.0 -swift-version 5 Sources/FileSafety.swift Sources/NativeEditors.swift Tests/RTFRecoveryTests.swift -o /private/tmp/gao-rtf-recovery-tests
/private/tmp/gao-rtf-recovery-tests --data-dir /private/tmp/gao-rtf-recovery-isolated
```

验证覆盖 RTF 字体格式保留、恢复时原件不改、外部原件摘要变化、损坏和校验失败草稿、正常保存快照、精确丢弃通知及不可读取原件保护，共 20 个断言。
