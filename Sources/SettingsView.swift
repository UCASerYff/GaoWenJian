import AppKit
import SwiftUI

struct FileSettings: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var stickyNotes: StickyNotesStore
    @AppStorage("editorFontSize") private var fontSize = 15.0
    @AppStorage("wrapLines") private var wrap = true
    @AppStorage("appAppearance") private var appearance = "system"

    var body: some View {
        TabView {
            Form {
                Section("写作习惯") {
                    HStack {
                        Text("源码字号")
                        Slider(value: $fontSize, in: 11...24, step: 1)
                        Text("\(Int(fontSize)) pt").monospacedDigit().frame(width: 45)
                    }
                    Toggle("源码自动换行", isOn: $wrap)
                }
                Section("外观") {
                    Picker("主题", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色纸面").tag("light")
                        Text("深色石墨").tag("dark")
                    }.onChange(of: appearance) { _, value in
                        NSApp.appearance = value == "system" ? nil : NSAppearance(named: value == "dark" ? .darkAqua : .aqua)
                    }
                }
                Section("常用快捷键") {
                    shortcut("新建 Markdown", key: "⌘N")
                    shortcut("打开文件", key: "⌘O")
                    shortcut("保存文档", key: "⌘S")
                    shortcut("编译 LaTeX", key: "⌘B")
                }
            }.formStyle(.grouped).tabItem { Label("写作", systemImage: "text.cursor") }

            Form {
                Section("LaTeX 编译") {
                    LabeledContent("内置 Tectonic", value: LocalTools.tectonic == nil ? "未找到" : "可用 · 离线编译")
                    ForEach(["xelatex", "pdflatex", "lualatex", "latexmk"], id: \.self) { name in
                        LabeledContent(name, value: LocalTools.executable(name) == nil ? "未安装" : "可用")
                    }
                    Text("基础宏包随应用提供。未缓存的宏包会明确报错，不会联网下载。也可使用本机安装的完整 TeX Live。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Office 阅读") {
                    LabeledContent("版式预览", value: "macOS Quick Look")
                    Text("Word、Excel 和 PowerPoint 以只读方式查看。需要修改时，可交给本机办公软件处理。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("工具", systemImage: "wrench.and.screwdriver") }

            Form {
                Section("文档与草稿") {
                    Text("文档保存在你选择的位置。文本编辑每 4 秒更新一份当前恢复稿，供意外退出后继续编辑；原文档由保存操作更新。")
                    Text("检测到其他程序修改原文件时，会停止覆盖。资料无法读取时，也不会用空记录替换。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("便笺") {
                    LabeledContent("现用便笺", value: "\(stickyNotes.notes.filter { $0.deletedAt == nil }.count) 条")
                    Text("正文、格式和附件保存在本机。关闭桌面便笺只会隐藏；删除会进入便笺回收站。保存失败时保留修改，并阻止直接退出。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("资料位置") {
                    Text(FileSafety.root.path).font(.caption.monospaced()).textSelection(.enabled)
                    Button("在 Finder 中打开") { NSWorkspace.shared.open(FileSafety.root) }
                    Text("此目录包含工作区、恢复稿、便笺与整理索引。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("本地资料", systemImage: "internaldrive") }

            VStack(spacing: 15) {
                if let icon = NSImage(named: "AppIcon") { Image(nsImage: icon).resizable().frame(width: 88, height: 88) }
                Text("搞文件").font(.system(size: 27, weight: .medium, design: .serif))
                Text("V" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.00"))
                    .font(.caption.monospaced()).foregroundStyle(WorkspaceStyle.muted)
                Text("给想法，一张纸。").font(.title3)
                Text("LaTeX 与 Markdown 写作 · PDF 编辑\nOffice 阅读 · 文件整理 · 便笺")
                    .font(.callout).multilineTextAlignment(.center).lineSpacing(6).foregroundStyle(.secondary)
                Label("无需账户，本机处理", systemImage: "internaldrive")
                    .font(.caption).foregroundStyle(WorkspaceStyle.accent).padding(.top, 8)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .tabItem { Label("关于", systemImage: "info.circle") }
        }.padding(18).background(WorkspaceStyle.canvas).tint(WorkspaceStyle.accent)
    }

    private func shortcut(_ title: String, key: String) -> some View {
        LabeledContent { Text(key).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) } label: { Text(title) }
    }
}
