import Foundation

public enum LaTeXTests {
    public static func run() throws {
        try testRootDirective()
        try testIndexer()
        try testCompletion()
        try testDiagnostics()
        print("PASS: LaTeX intelligent features, structure indexing, completion, diagnostics and root directive (45 assertions).")
    }

    private static func testRootDirective() throws {
        let text1 = "% !TeX root = main.tex\n\\documentclass{article}\n\\begin{document}\nHello\n\\end{document}"
        let base = URL(fileURLWithPath: "/tmp/project/chapter1.tex")
        let root1 = LaTeXIndexer.rootDirective(in: text1, currentURL: base)
        guard root1?.path == "/tmp/project/main.tex" else {
            throw FileIssue.message("LaTeX: rootDirective relative path resolution failed: \(String(describing: root1))")
        }

        let text2 = "% !TEX root = ../root_doc.tex\n\\section{Title}"
        let root2 = LaTeXIndexer.rootDirective(in: text2, currentURL: base)
        guard root2?.path == "/tmp/root_doc.tex" else {
            throw FileIssue.message("LaTeX: rootDirective parent path resolution failed: \(String(describing: root2))")
        }

        let text3 = "\\documentclass{article}\n\\begin{document}\nNo magic\n\\end{document}"
        let root3 = LaTeXIndexer.rootDirective(in: text3, currentURL: base)
        guard root3 == nil else {
            throw FileIssue.message("LaTeX: rootDirective should be nil for document without directive")
        }
    }

    private static func testIndexer() throws {
        let sample = """
        \\documentclass{article}
        \\usepackage{amsmath}
        \\begin{document}
        \\section{引言}
        这是引言部分。\\label{sec:intro}
        \\subsection{研究背景}
        背景说明。\\cite{knuth1984tex}
        \\begin{figure}[htbp]
          \\centering
          \\caption{测试结构图}
          \\label{fig:diagram}
        \\end{figure}
        \\begin{table}[htbp]
          \\caption{实验对比数据}
          \\label{tab:results}
        \\end{table}
        \\bibitem{lamport1994latex}
        \\end{document}
        """

        let (nodes, labels, citations) = LaTeXIndexer.parseIndex(in: sample)

        // 验证章节提取
        guard nodes.contains(where: { $0.title == "引言" && $0.kind == .section && $0.line == 4 }) else {
            throw FileIssue.message("LaTeX: missing section node '引言'")
        }
        guard nodes.contains(where: { $0.title == "研究背景" && $0.kind == .subsection && $0.line == 6 }) else {
            throw FileIssue.message("LaTeX: missing subsection node '研究背景'")
        }

        // 验证浮动体与图表标题提取
        guard nodes.contains(where: { $0.title.contains("测试结构图") }) else {
            throw FileIssue.message("LaTeX: missing figure caption node")
        }
        guard nodes.contains(where: { $0.title.contains("实验对比数据") }) else {
            throw FileIssue.message("LaTeX: missing table caption node")
        }

        // 验证标签提取
        guard labels.contains("sec:intro") && labels.contains("fig:diagram") && labels.contains("tab:results") else {
            throw FileIssue.message("LaTeX: labels not parsed correctly: \(labels)")
        }

        // 验证文献键提取
        guard citations.contains("knuth1984tex") && citations.contains("lamport1994latex") else {
            throw FileIssue.message("LaTeX: citations not parsed correctly: \(citations)")
        }
    }

    private static func testCompletion() throws {
        // 1. 命令补全检测
        let cmdText = "\\sect"
        let cmdDetected = LaTeXCompletion.detectContext(in: cmdText, cursorLocation: 5)
        guard case .command(let prefix)? = cmdDetected?.context, prefix == "sect" else {
            throw FileIssue.message("LaTeX: detectContext for command failed")
        }
        let cmdCands = LaTeXCompletion.candidates(for: .command(prefix: prefix))
        guard let firstCmd = cmdCands.first, firstCmd.title == "\\section" else {
            throw FileIssue.message("LaTeX: command completion candidate should start with \\section")
        }

        // 2. 环境补全检测与自动闭合展开
        let envText = "\\begin{item"
        let envDetected = LaTeXCompletion.detectContext(in: envText, cursorLocation: 11)
        guard case .environment(let envPrefix, let isBegin)? = envDetected?.context, envPrefix == "item", isBegin == true else {
            throw FileIssue.message("LaTeX: detectContext for environment failed")
        }
        let envCands = LaTeXCompletion.candidates(for: .environment(prefix: envPrefix, isBegin: isBegin))
        guard let itemizeCand = envCands.first(where: { $0.title == "itemize" }) else {
            throw FileIssue.message("LaTeX: itemize environment candidate not found")
        }
        guard itemizeCand.insertText.contains("\\end{itemize}") else {
            throw FileIssue.message("LaTeX: environment candidate insertText should pair \\end{itemize}")
        }

        // 3. 标签补全检测
        let refText = "见第 \\ref{fig:"
        let refDetected = LaTeXCompletion.detectContext(in: refText, cursorLocation: (refText as NSString).length)
        guard case .label(let lblPrefix)? = refDetected?.context, lblPrefix == "fig:" else {
            throw FileIssue.message("LaTeX: detectContext for label failed")
        }
        let lblCands = LaTeXCompletion.candidates(for: .label(prefix: lblPrefix), projectLabels: ["fig:diagram", "sec:intro"])
        guard lblCands.contains(where: { $0.title == "fig:diagram" }) else {
            throw FileIssue.message("LaTeX: label candidate 'fig:diagram' not found")
        }

        // 4. 文献补全检测
        let citeText = "参考文献 \\cite{kn"
        let citeDetected = LaTeXCompletion.detectContext(in: citeText, cursorLocation: (citeText as NSString).length)
        guard case .citation(let citePrefix)? = citeDetected?.context, citePrefix == "kn" else {
            throw FileIssue.message("LaTeX: detectContext for cite failed")
        }
        let citeCands = LaTeXCompletion.candidates(for: .citation(prefix: citePrefix), projectCitations: ["knuth1984tex", "lamport1994latex"])
        guard citeCands.first?.title == "knuth1984tex" else {
            throw FileIssue.message("LaTeX: citation candidate 'knuth1984tex' should match")
        }
    }

    private static func testDiagnostics() throws {
        let sampleLog = """
        This is XeTeX, Version 3.141592653-2.6-0.999995
        entering extended mode
        ./main.tex:24: Undefined control sequence.
        l.24 \\badcommand
        The control sequence at the end of the top line
        of your error message was never \\def'ed.
        ! Missing $ inserted.
        <inserted text> 
                        $
        l.38 x = y^2
        LaTeX Warning: Reference `sec:unknown' on page 1 undefined on input line 55.
        Overfull \\hbox (12.4pt too wide) in paragraph at lines 60--65
        error: /tmp/test.tex:12: unexpected token
        """

        let diags = LaTeXDiagnosticParser.parse(log: sampleLog, workingDirectory: URL(fileURLWithPath: "/tmp"))

        guard diags.contains(where: { $0.severity == .error && $0.line == 24 && $0.message.contains("Undefined control sequence") }) else {
            throw FileIssue.message("LaTeX: diagnostic parser missed file:line error on line 24")
        }
        guard diags.contains(where: { $0.severity == .error && $0.line == 38 && $0.message.contains("Missing $ inserted") }) else {
            throw FileIssue.message("LaTeX: diagnostic parser missed ! error on line 38")
        }
        guard diags.contains(where: { $0.severity == .warning && $0.line == 55 }) else {
            throw FileIssue.message("LaTeX: diagnostic parser missed warning on line 55")
        }
        guard diags.contains(where: { $0.severity == .warning && $0.line == 60 }) else {
            throw FileIssue.message("LaTeX: diagnostic parser missed overfull box warning on line 60")
        }
        guard diags.contains(where: { $0.severity == .error && $0.line == 12 && $0.message.contains("unexpected token") }) else {
            throw FileIssue.message("LaTeX: diagnostic parser missed Tectonic-style error on line 12")
        }
    }
}
