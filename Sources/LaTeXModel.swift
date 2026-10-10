import AppKit
import Foundation

// MARK: - 诊断模型 (LaTeX Diagnostics)

public struct LaTeXDiagnostic: Identifiable, Hashable, Sendable {
    public enum Severity: String, Sendable, CaseIterable {
        case error = "错误"
        case warning = "警告"
        case info = "提示"

        public var systemImage: String {
            switch self {
            case .error: return "xmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            }
        }

        public var colorName: String {
            switch self {
            case .error: return "red"
            case .warning: return "orange"
            case .info: return "blue"
            }
        }
    }

    public let id = UUID()
    public var severity: Severity
    public var message: String
    public var file: URL?
    public var line: Int?
    public var detail: String

    public init(severity: Severity, message: String, file: URL? = nil, line: Int? = nil, detail: String = "") {
        self.severity = severity
        self.message = message
        self.file = file
        self.line = line
        self.detail = detail
    }

    public var locationDescription: String {
        var parts: [String] = []
        if let file { parts.append(file.lastPathComponent) }
        if let line { parts.append("第 \(line) 行") }
        return parts.joined(separator: " · ")
    }
}

public enum LaTeXDiagnosticParser {
    // 匹配 file:line: message 或 file:line:col: message
    private static let fileLineRegex = try? NSRegularExpression(
        pattern: #"^(.+?\.tex):(\d+):(?:\s*(\d+):)?\s*(.*)$"#,
        options: [.anchorsMatchLines]
    )
    // 匹配 l.123 错误行号标识
    private static let lineMarkRegex = try? NSRegularExpression(pattern: #"^l\.(\d+)\s*(.*)$"#, options: [.anchorsMatchLines])
    // 匹配 on input line 123
    private static let inputLineRegex = try? NSRegularExpression(pattern: #"on input line (\d+)"#)
    // 匹配 Overfull/Underfull 盒警告行号
    private static let boxLinesRegex = try? NSRegularExpression(pattern: #"(?:at lines|on input line)\s+(\d+)"#)

    public static func parse(log: String, workingDirectory: URL? = nil) -> [LaTeXDiagnostic] {
        var results: [LaTeXDiagnostic] = []
        let lines = log.components(separatedBy: .newlines)
        var i = 0

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            // 1. file:line: message
            if let fileLineRegex,
               let match = fileLineRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let ns = line as NSString
                let filePath = ns.substring(with: match.range(at: 1))
                let lineNum = Int(ns.substring(with: match.range(at: 2)))
                let msg = ns.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
                let url = resolveURL(filePath, base: workingDirectory)
                let severity: LaTeXDiagnostic.Severity = (msg.lowercased().contains("warning") || msg.lowercased().contains("overfull") || msg.lowercased().contains("underfull")) ? .warning : .error
                results.append(LaTeXDiagnostic(severity: severity, message: msg.isEmpty ? "编译问题" : msg, file: url, line: lineNum, detail: line))
                i += 1
                continue
            }

            // 2. Tectonic 风格报错: error: ...
            if line.hasPrefix("error:") {
                let rest = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                var file: URL?
                var lineNum: Int?
                var cleanMsg = rest
                // 检查 error: path/to/file.tex:12: 格式
                if let colonIdx = rest.firstIndex(of: ":") {
                    let candidatePath = String(rest[..<colonIdx])
                    let afterFirst = rest[rest.index(after: colonIdx)...]
                    if let secondColon = afterFirst.firstIndex(of: ":"),
                       let num = Int(afterFirst[..<secondColon].trimmingCharacters(in: .whitespaces)) {
                        file = resolveURL(candidatePath, base: workingDirectory)
                        lineNum = num
                        cleanMsg = String(afterFirst[afterFirst.index(after: secondColon)...]).trimmingCharacters(in: .whitespaces)
                    }
                }
                results.append(LaTeXDiagnostic(severity: .error, message: cleanMsg, file: file, line: lineNum, detail: line))
                i += 1
                continue
            }

            // 3. 经典 TeX 报错标记: 以 ! 开头
            if line.hasPrefix("!") {
                let errorMsg = String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                var lineNum: Int?
                var contextLines = [line]

                // 向后看若干行，寻找 l.<line>
                var lookAhead = i + 1
                while lookAhead < min(lines.count, i + 8) {
                    let next = lines[lookAhead]
                    contextLines.append(next)
                    if let lineMarkRegex,
                       let match = lineMarkRegex.firstMatch(in: next, range: NSRange(location: 0, length: (next as NSString).length)) {
                        let ns = next as NSString
                        lineNum = Int(ns.substring(with: match.range(at: 1)))
                        break
                    }
                    if next.hasPrefix("!") { break }
                    lookAhead += 1
                }
                results.append(LaTeXDiagnostic(severity: .error, message: errorMsg, line: lineNum, detail: contextLines.joined(separator: "\n")))
                i += 1
                continue
            }

            // 4. 警告信息: LaTeX Warning / Package Warning
            if line.contains("Warning:") || line.hasPrefix("Overfull") || line.hasPrefix("Underfull") {
                var lineNum: Int?
                if let inputLineRegex,
                   let match = inputLineRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                    lineNum = Int((line as NSString).substring(with: match.range(at: 1)))
                } else if let boxLinesRegex,
                          let match = boxLinesRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                    lineNum = Int((line as NSString).substring(with: match.range(at: 1)))
                }
                results.append(LaTeXDiagnostic(severity: .warning, message: line, line: lineNum, detail: line))
                i += 1
                continue
            }

            i += 1
        }

        return results
    }

    private static func resolveURL(_ path: String, base: URL?) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed).standardizedFileURL }
        if let base {
            let dir = base.hasDirectoryPath ? base : base.deletingLastPathComponent()
            return dir.appendingPathComponent(trimmed).standardizedFileURL
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL
    }
}

// MARK: - 大纲与结构索引 (Structure & Floats)

public struct LaTeXStructureNode: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case part = "篇"
        case chapter = "章"
        case section = "节"
        case subsection = "子节"
        case subsubsection = "子子节"
        case figure = "插图"
        case table = "表格"
        case equation = "公式"
        case label = "标签"
        case citation = "文献"

        public var iconName: String {
            switch self {
            case .part: return "bookmark.fill"
            case .chapter: return "book.closed.fill"
            case .section: return "number"
            case .subsection: return "number.square"
            case .subsubsection: return "number.circle"
            case .figure: return "photo"
            case .table: return "tablecells"
            case .equation: return "function"
            case .label: return "tag"
            case .citation: return "quote.opening"
            }
        }

        public var indentLevel: Int {
            switch self {
            case .part: return 0
            case .chapter: return 1
            case .section: return 2
            case .subsection: return 3
            case .subsubsection: return 4
            default: return 1
            }
        }
    }

    public let id: String
    public var title: String
    public var kind: Kind
    public var line: Int // 1-indexed
    public var detail: String?
    public var fileURL: URL?

    public init(id: String = UUID().uuidString, title: String, kind: Kind, line: Int, detail: String? = nil, fileURL: URL? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.line = line
        self.detail = detail
        self.fileURL = fileURL
    }
}

public enum LaTeXIndexer {
    /// 识别魔术根文件指令：% !TeX root = main.tex
    public static func rootDirective(in text: String, currentURL: URL?) -> URL? {
        let pattern = #"(?i)%\s*!T[eE]X\s+root\s*=\s*([^\r\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: min((text as NSString).length, 2000))) else {
            return nil
        }
        let rawTarget = (text as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        guard !rawTarget.isEmpty else { return nil }

        if rawTarget.hasPrefix("/") {
            return URL(fileURLWithPath: rawTarget).standardizedFileURL
        }
        guard let currentURL else { return nil }
        let dir = currentURL.hasDirectoryPath ? currentURL : currentURL.deletingLastPathComponent()
        return dir.appendingPathComponent(rawTarget).standardizedFileURL
    }

    /// 提取文档中的所有大纲章节、图表、标签与文献
    public static func parseIndex(in text: String, fileURL: URL? = nil) -> (structure: [LaTeXStructureNode], labels: [String], citations: [String]) {
        var nodes: [LaTeXStructureNode] = []
        var labels: [String] = []
        var citations: [String] = []

        let lines = text.components(separatedBy: .newlines)

        // 正则表达式预编译
        let sectionRegex = try? NSRegularExpression(
            pattern: #"\\(part|chapter|section|subsection|subsubsection)\*?(?:\[[^\]]*\])?\{([^}]+)\}"#
        )
        let floatRegex = try? NSRegularExpression(
            pattern: #"\\begin\{(figure\*?|table\*?)\}"#
        )
        let captionRegex = try? NSRegularExpression(
            pattern: #"\\caption(?:\[[^\]]*\])?\{([^}]+)\}"#
        )
        let labelRegex = try? NSRegularExpression(
            pattern: #"\\label\{([^}]+)\}"#
        )
        let bibRegex = try? NSRegularExpression(
            pattern: #"(?:\\(?:cite|citep|citet|parencite|autocite)\{([^}]+)\}|\\bibitem\{([^}]+)\}|@\w+\s*[\{\(]\s*([^,\s\}]+))"#
        )

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("%") && !trimmed.contains("!TeX") { continue }
            let nsLine = line as NSString
            let lineRange = NSRange(location: 0, length: nsLine.length)

            // 1. 匹配章节
            if let sectionRegex,
               let match = sectionRegex.firstMatch(in: line, range: lineRange) {
                let cmd = nsLine.substring(with: match.range(at: 1))
                let title = nsLine.substring(with: match.range(at: 2))
                let kind: LaTeXStructureNode.Kind
                switch cmd {
                case "part": kind = .part
                case "chapter": kind = .chapter
                case "section": kind = .section
                case "subsection": kind = .subsection
                case "subsubsection": kind = .subsubsection
                default: kind = .section
                }
                nodes.append(LaTeXStructureNode(
                    id: "\(lineNumber):\(cmd):\(title)",
                    title: title,
                    kind: kind,
                    line: lineNumber,
                    fileURL: fileURL
                ))
            }

            // 2. 匹配浮动体与标题
            if let floatRegex,
               let match = floatRegex.firstMatch(in: line, range: lineRange) {
                let env = nsLine.substring(with: match.range(at: 1))
                let isFig = env.hasPrefix("figure")
                nodes.append(LaTeXStructureNode(
                    id: "\(lineNumber):\(env)",
                    title: isFig ? "插图 (figure)" : "表格 (table)",
                    kind: isFig ? .figure : .table,
                    line: lineNumber,
                    fileURL: fileURL
                ))
            } else if let captionRegex,
                      let match = captionRegex.firstMatch(in: line, range: lineRange) {
                let captionText = nsLine.substring(with: match.range(at: 1))
                nodes.append(LaTeXStructureNode(
                    id: "\(lineNumber):caption:\(captionText)",
                    title: "标题：\(captionText)",
                    kind: .figure,
                    line: lineNumber,
                    detail: "caption",
                    fileURL: fileURL
                ))
            }

            // 3. 匹配标签 \label{...}
            if let labelRegex {
                let matches = labelRegex.matches(in: line, range: lineRange)
                for m in matches {
                    let labelName = nsLine.substring(with: m.range(at: 1))
                    if !labels.contains(labelName) { labels.append(labelName) }
                    nodes.append(LaTeXStructureNode(
                        id: "\(lineNumber):label:\(labelName)",
                        title: labelName,
                        kind: .label,
                        line: lineNumber,
                        detail: "label",
                        fileURL: fileURL
                    ))
                }
            }

            // 4. 匹配文献键 \cite{...} 或 \bibitem{...} 或 @article{...}
            if let bibRegex {
                let matches = bibRegex.matches(in: line, range: lineRange)
                for m in matches {
                    var rawKey = ""
                    if m.range(at: 1).location != NSNotFound {
                        rawKey = nsLine.substring(with: m.range(at: 1))
                    } else if m.range(at: 2).location != NSNotFound {
                        rawKey = nsLine.substring(with: m.range(at: 2))
                    } else if m.range(at: 3).location != NSNotFound {
                        rawKey = nsLine.substring(with: m.range(at: 3))
                    }
                    let splitKeys = rawKey.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    for key in splitKeys {
                        if !citations.contains(key) { citations.append(key) }
                        nodes.append(LaTeXStructureNode(
                            id: "\(lineNumber):bib:\(key)",
                            title: key,
                            kind: .citation,
                            line: lineNumber,
                            detail: "citation",
                            fileURL: fileURL
                        ))
                    }
                }
            }
        }

        return (nodes, labels, citations)
    }
}

// MARK: - 智能自动补全 (LaTeX Completion)

public enum LaTeXCompletion {
    public enum Context: Equatable, Sendable {
        case command(prefix: String)
        case environment(prefix: String, isBegin: Bool)
        case label(prefix: String)
        case citation(prefix: String)
        case package(prefix: String)
    }

    public struct CompletionCandidate: Identifiable, Hashable, Sendable {
        public let id = UUID()
        public var title: String
        public var subtitle: String?
        public var insertText: String
        public var caretOffsetFromEnd: Int = 0 // 插入后光标距文本末尾向前回退的字符数

        public init(title: String, subtitle: String? = nil, insertText: String, caretOffsetFromEnd: Int = 0) {
            self.title = title
            self.subtitle = subtitle
            self.insertText = insertText
            self.caretOffsetFromEnd = caretOffsetFromEnd
        }
    }

    public static let standardCommands: [String] = [
        "section", "subsection", "subsubsection", "paragraph", "chapter", "part",
        "textbf", "textit", "texttt", "textsc", "textsf", "underline", "emph",
        "frac", "sqrt", "sum", "int", "prod", "lim", "infty",
        "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta",
        "iota", "kappa", "lambda", "mu", "nu", "xi", "pi", "rho", "sigma", "tau",
        "upsilon", "phi", "chi", "psi", "omega",
        "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Phi", "Psi", "Omega",
        "leq", "geq", "neq", "approx", "equiv", "times", "div", "pm", "cdot",
        "in", "notin", "subset", "subseteq", "cup", "cap", "forall", "exists",
        "label", "ref", "eqref", "pageref", "cite", "citep", "citet",
        "usepackage", "documentclass", "input", "include", "includegraphics",
        "newcommand", "renewcommand", "def", "vspace", "hspace", "centering",
        "tableofcontents", "maketitle", "newpage", "clearpage", "bibliography"
    ]

    public static let standardEnvironments: [String] = [
        "document", "equation", "equation*", "align", "align*", "gather", "gather*",
        "multline", "multline*", "split", "cases",
        "itemize", "enumerate", "description",
        "figure", "table", "tabular",
        "matrix", "pmatrix", "bmatrix", "vmatrix", "Vmatrix",
        "proof", "theorem", "lemma", "corollary", "definition", "example", "remark",
        "verbatim", "lstlisting", "minted", "center", "flushleft", "flushright", "minipage"
    ]

    public static let standardPackages: [String] = [
        "amsmath", "amssymb", "amsfonts", "graphicx", "hyperref", "xcolor",
        "geometry", "booktabs", "tikz", "float", "caption", "subcaption",
        "xeCJK", "ctex", "fontspec", "biblatex", "natbib", "listings", "microtype",
        "array", "siunitx", "algorithm2e", "fancyhdr", "multicol", "titlesec"
    ]

    /// 分析当前光标位置的触发上下文
    public static func detectContext(in text: String, cursorLocation: Int) -> (context: Context, replaceRange: NSRange)? {
        let ns = text as NSString
        let loc = min(max(0, cursorLocation), ns.length)
        if loc == 0 { return nil }

        // 获取当前行和前面的前缀
        var lineStart = loc
        while lineStart > 0 && ns.character(at: lineStart - 1) != 10 && ns.character(at: lineStart - 1) != 13 {
            lineStart -= 1
        }
        let prefixOnLine = ns.substring(with: NSRange(location: lineStart, length: loc - lineStart))

        // 1. 检查是否在 \begin{ 或 \end{ 后
        if let match = prefixOnLine.range(of: #"\\(begin|end)\{([A-Za-z0-9_\*]*)$"#, options: .regularExpression) {
            let matchedStr = String(prefixOnLine[match])
            let isBegin = matchedStr.hasPrefix("\\begin")
            let braceIdx = matchedStr.firstIndex(of: "{")!
            let envPrefix = String(matchedStr[matchedStr.index(after: braceIdx)...])
            let replaceStart = loc - envPrefix.utf16.count
            return (.environment(prefix: envPrefix, isBegin: isBegin), NSRange(location: replaceStart, length: envPrefix.utf16.count))
        }

        // 2. 检查是否在 \ref{, \eqref{ 后
        if let match = prefixOnLine.range(of: #"\\(ref|eqref|pageref|autoref|cref|Cref)\{([A-Za-z0-9_\-:]*)$"#, options: .regularExpression) {
            let matchedStr = String(prefixOnLine[match])
            let braceIdx = matchedStr.firstIndex(of: "{")!
            let labelPrefix = String(matchedStr[matchedStr.index(after: braceIdx)...])
            let replaceStart = loc - labelPrefix.utf16.count
            return (.label(prefix: labelPrefix), NSRange(location: replaceStart, length: labelPrefix.utf16.count))
        }

        // 3. 检查是否在 \cite{ 后
        if let match = prefixOnLine.range(of: #"\\(cite|citep|citet|parencite|textcite)\{([A-Za-z0-9_\-:]*)$"#, options: .regularExpression) {
            let matchedStr = String(prefixOnLine[match])
            let braceIdx = matchedStr.firstIndex(of: "{")!
            let citePrefix = String(matchedStr[matchedStr.index(after: braceIdx)...])
            let replaceStart = loc - citePrefix.utf16.count
            return (.citation(prefix: citePrefix), NSRange(location: replaceStart, length: citePrefix.utf16.count))
        }

        // 4. 检查是否在 \usepackage{ 后
        if let match = prefixOnLine.range(of: #"\\usepackage(?:\[[^\]]*\])?\{([A-Za-z0-9_\-]*)$"#, options: .regularExpression) {
            let matchedStr = String(prefixOnLine[match])
            let braceIdx = matchedStr.lastIndex(of: "{")!
            let pkgPrefix = String(matchedStr[matchedStr.index(after: braceIdx)...])
            let replaceStart = loc - pkgPrefix.utf16.count
            return (.package(prefix: pkgPrefix), NSRange(location: replaceStart, length: pkgPrefix.utf16.count))
        }

        // 5. 检查普通命令补全：\abc
        if let match = prefixOnLine.range(of: #"\\([A-Za-z@]*)$"#, options: .regularExpression) {
            let matchedStr = String(prefixOnLine[match])
            let cmdPrefix = String(matchedStr.dropFirst()) // 去掉反斜杠
            let replaceStart = loc - cmdPrefix.utf16.count
            return (.command(prefix: cmdPrefix), NSRange(location: replaceStart, length: cmdPrefix.utf16.count))
        }

        return nil
    }

    /// 获取针对上下文的补全候选列表
    public static func candidates(for context: Context, projectLabels: [String] = [], projectCitations: [String] = []) -> [CompletionCandidate] {
        switch context {
        case .command(let prefix):
            let needle = prefix.lowercased()
            return standardCommands
                .filter { needle.isEmpty || $0.lowercased().contains(needle) }
                .sorted { a, b in
                    let aStarts = a.lowercased().hasPrefix(needle)
                    let bStarts = b.lowercased().hasPrefix(needle)
                    if aStarts != bStarts { return aStarts }
                    return a < b
                }
                .prefix(16)
                .map { cmd in
                    CompletionCandidate(title: "\\\(cmd)", subtitle: "LaTeX 命令", insertText: cmd)
                }

        case .environment(let prefix, let isBegin):
            let needle = prefix.lowercased()
            return standardEnvironments
                .filter { needle.isEmpty || $0.lowercased().contains(needle) }
                .sorted { a, b in
                    let aStarts = a.lowercased().hasPrefix(needle)
                    let bStarts = b.lowercased().hasPrefix(needle)
                    if aStarts != bStarts { return aStarts }
                    return a < b
                }
                .prefix(16)
                .map { env in
                    if isBegin {
                        let fullInsert = "\(env)}\n    \n\\end{\(env)}"
                        return CompletionCandidate(
                            title: env,
                            subtitle: "环境 · 自动配对",
                            insertText: fullInsert,
                            caretOffsetFromEnd: ("\n\\end{\(env)}").utf16.count
                        )
                    } else {
                        return CompletionCandidate(title: env, subtitle: "结束环境", insertText: "\(env)}")
                    }
                }

        case .label(let prefix):
            let needle = prefix.lowercased()
            return projectLabels
                .filter { needle.isEmpty || $0.lowercased().contains(needle) }
                .prefix(20)
                .map { lbl in
                    CompletionCandidate(title: lbl, subtitle: "标签 (Label)", insertText: "\(lbl)}")
                }

        case .citation(let prefix):
            let needle = prefix.lowercased()
            return projectCitations
                .filter { needle.isEmpty || $0.lowercased().contains(needle) }
                .prefix(20)
                .map { cite in
                    CompletionCandidate(title: cite, subtitle: "文献引用 (Bib)", insertText: "\(cite)}")
                }

        case .package(let prefix):
            let needle = prefix.lowercased()
            return standardPackages
                .filter { needle.isEmpty || $0.lowercased().contains(needle) }
                .prefix(16)
                .map { pkg in
                    CompletionCandidate(title: pkg, subtitle: "常用宏包", insertText: "\(pkg)}")
                }
        }
    }
}

// MARK: - SyncTeX 服务 (双向跳转支持)

public enum SyncTeXService {
    public struct ForwardResult: Sendable {
        public var page: Int
        public var point: CGPoint
        public var width: CGFloat
        public var height: CGFloat

        public init(page: Int, point: CGPoint, width: CGFloat = 0, height: CGFloat = 0) {
            self.page = page
            self.point = point
            self.width = width
            self.height = height
        }
    }

    public struct InverseResult: Sendable {
        public var file: URL
        public var line: Int
        public var column: Int

        public init(file: URL, line: Int, column: Int = 1) {
            self.file = file
            self.line = line
            self.column = column
        }
    }

    public static var executableURL: URL? {
        let candidates = [
            "/Library/TeX/texbin/synctex",
            "/usr/texbin/synctex",
            "/opt/homebrew/bin/synctex",
            "/usr/local/bin/synctex"
        ]
        return candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// 正向定位：由源码行 -> PDF 位置
    public static func forward(line: Int, column: Int = 1, source: URL, pdf: URL) async -> ForwardResult? {
        guard let tool = executableURL else { return nil }
        let args = ["view", "-i", "\(line):\(column):\(source.path)", "-o", pdf.path]
        do {
            let result = try await LocalTools.run(tool, args: args, directory: source.deletingLastPathComponent())
            guard result.code == 0, result.output.contains("SyncTeX result begin") else { return nil }
            return parseForwardOutput(result.output)
        } catch {
            return nil
        }
    }

    /// 反向定位：由 PDF 点击位置 -> 源码文件与行号
    public static func inverse(page: Int, point: CGPoint, pdf: URL) async -> InverseResult? {
        guard let tool = executableURL else { return nil }
        let args = ["edit", "-o", "\(page):\(Int(point.x)):\(Int(point.y)):\(pdf.path)"]
        do {
            let result = try await LocalTools.run(tool, args: args, directory: pdf.deletingLastPathComponent())
            guard result.code == 0, result.output.contains("SyncTeX result begin") else { return nil }
            return parseInverseOutput(result.output)
        } catch {
            return nil
        }
    }

    private static func parseForwardOutput(_ output: String) -> ForwardResult? {
        var page = 1
        var x: CGFloat = 0
        var y: CGFloat = 0
        var w: CGFloat = 0
        var h: CGFloat = 0

        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let val = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "Page": if let p = Int(val) { page = p }
            case "x": if let d = Double(val) { x = CGFloat(d) }
            case "y": if let d = Double(val) { y = CGFloat(d) }
            case "W": if let d = Double(val) { w = CGFloat(d) }
            case "H": if let d = Double(val) { h = CGFloat(d) }
            default: break
            }
        }
        return ForwardResult(page: page, point: CGPoint(x: x, y: y), width: w, height: h)
    }

    private static func parseInverseOutput(_ output: String) -> InverseResult? {
        var fileURL: URL?
        var line = 1
        var col = 1

        for l in output.components(separatedBy: .newlines) {
            let parts = l.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let val = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "Input": fileURL = URL(fileURLWithPath: val).standardizedFileURL
            case "Line": if let n = Int(val) { line = n }
            case "Column": if let n = Int(val) { col = n }
            default: break
            }
        }
        guard let fileURL else { return nil }
        return InverseResult(file: fileURL, line: line, column: col)
    }
}
