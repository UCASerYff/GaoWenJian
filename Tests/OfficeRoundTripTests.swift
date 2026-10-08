import Foundation

/// Called by the application's isolated test runner; no production entry point.
func runOfficeRoundTripTests() throws {
    guard CommandLine.arguments.contains("--data-dir") else { throw OfficeFailure.message("Office 测试必须使用 --data-dir 指定隔离资料目录。") }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("GaoWenJian-OfficeTests-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    func expect(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        if !condition() { throw OfficeFailure.message("Office 测试失败：" + description) }
    }
    let unknown = Data([0, 1, 2, 255, 10, 42])
    // Word: replacement text, styles, paragraph insertion and untouched attachment survive a real ZIP save/reopen.
    let wordURL = root.appendingPathComponent("word.docx")
    var wordFiles = OfficeFactory.wordFiles
    wordFiles["word/document.xml"] = wordFiles["word/document.xml"]!.replacingOccurrences(of: "</w:body>", with: "<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>复杂</w:t></w:r><w:r><w:t>段落</w:t><w:drawing><unsupported value=\"preserve-me\"/><w:txbxContent><w:p><w:r><w:t>内嵌对象正文</w:t></w:r></w:p></w:txbxContent></w:drawing></w:r></w:p></w:body>")
    let wordPackage = try OfficePackage(files: wordFiles)
    let attachment = try wordPackage.location("word/media/unknown.bin")
    try fm.createDirectory(at: attachment.deletingLastPathComponent(), withIntermediateDirectories: true)
    try unknown.write(to: attachment)
    try wordPackage.save(to: wordURL)
    let word = try OfficeWordDocument(package: wordPackage)
    let paragraphID = word.paragraphs[0].id
    word.setText(id: paragraphID, text: "中文测试 & <安全> 😀")
    word.setStyle(id: paragraphID, style: "Heading1")
    let addition = word.addParagraph(after: paragraphID); word.setText(id: addition, text: "新增正文\n换行\t制表")
    let complexID = word.paragraphs.last!.id; word.setText(id: complexID, text: "复杂内容更新")
    try word.apply(); try wordPackage.save(to: wordURL)
    try word.apply(); try wordPackage.save(to: wordURL)
    let reopenedWordPackage = try OfficePackage(url: wordURL)
    let reopenedWord = try OfficeWordDocument(package: reopenedWordPackage)
    try expect(reopenedWord.paragraphs[0].text == "中文测试 & <安全> 😀", "Word Unicode 和 XML 转义往返")
    try expect(reopenedWord.paragraphs[0].style == "Heading1", "Word 样式保存")
    try expect(reopenedWord.paragraphs[1].text == "新增正文\n换行\t制表", "Word 段落插入、换行和制表符")
    try expect(reopenedWord.paragraphs.last!.text == "复杂内容更新", "Word 分布式文本运行修改")
    let retainedDocument = try reopenedWordPackage.xml("word/document.xml")
    try expect(OfficeXML.descendants(retainedDocument.rootElement()!, "unsupported").count == 1, "Word 未知内联对象保留")
    try expect(retainedDocument.xmlString.contains("内嵌对象正文"), "编辑父段落不修改内嵌对象文本")
    let retainedAttachment = try Data(contentsOf: reopenedWordPackage.location("word/media/unknown.bin"))
    try expect(retainedAttachment == unknown, "Word 附件逐字节保留")
    try expect((try? FileSafety.snapshots(for: wordURL).count) ?? 0 >= 2, "重复覆盖保存前原件快照")

    // Excel: cached formula updates, blank/text range semantics, cross-sheet references, repeated save and sparse cells.
    let excelURL = root.appendingPathComponent("excel.xlsx")
    try OfficeFactory.create(kind: "xlsx", to: excelURL)
    let excelPackage = try OfficePackage(url: excelURL)
    let workbook = try OfficeWorkbook(package: excelPackage)
    try workbook.set(sheet: 0, address: "A1", input: "2")
    try workbook.set(sheet: 0, address: "A2", input: "4")
    try workbook.set(sheet: 0, address: "A3", input: "文字")
    try workbook.set(sheet: 0, address: "A4", input: "")
    try workbook.set(sheet: 0, address: "C1", input: "=SUM(A1:A4)")
    try workbook.set(sheet: 0, address: "C2", input: "=AVERAGE(A1:A4)")
    try workbook.set(sheet: 0, address: "C3", input: "=COUNT(A1:A4)")
    try workbook.set(sheet: 0, address: "C4", input: "=ROUND((A1+A2)/3,2)")
    try workbook.set(sheet: 0, address: "D1", input: "=1/0")
    try workbook.set(sheet: 0, address: "D2", input: "=A3+1")
    try workbook.set(sheet: 0, address: "E1", input: "=E2+1")
    try workbook.set(sheet: 0, address: "E2", input: "=E1+1")
    try workbook.set(sheet: 0, address: "F1", input: "00123")
    try workbook.set(sheet: 0, address: "F2", input: "4")
    try workbook.set(sheet: 0, address: "F3", input: "'3")
    try workbook.set(sheet: 0, address: "G1", input: "=SUM(F1:F3)")
    try workbook.set(sheet: 0, address: "G2", input: "=SUM(D1:D1)")
    try workbook.set(sheet: 0, address: "Z1000", input: "远端")
    let second = try workbook.addSheet()
    try workbook.set(sheet: second, address: "A1", input: "7")
    try workbook.set(sheet: 0, address: "C5", input: "='工作表2'!A1+A1")
    try expect(workbook.cell(sheet: 0, address: "C1")?.computed == 6, "SUM 忽略文字和空白")
    try expect(workbook.cell(sheet: 0, address: "C2")?.computed == 3, "AVERAGE 忽略文字和空白")
    try expect(workbook.cell(sheet: 0, address: "C3")?.computed == 2, "COUNT 仅统计数值")
    try expect(workbook.cell(sheet: 0, address: "C4")?.computed == 2, "运算优先级和 ROUND")
    try expect(workbook.cell(sheet: 0, address: "C5")?.computed == 9, "带引号跨工作表公式")
    try expect(workbook.cell(sheet: 0, address: "D1")?.error == "#DIV/0!", "除零错误")
    try expect(workbook.cell(sheet: 0, address: "D2")?.error == "#VALUE!", "文本算术错误")
    try expect(workbook.cell(sheet: 0, address: "E1")?.error == "#CYCLE!", "循环引用检测")
    try expect(workbook.cell(sheet: 0, address: "G1")?.computed == 4, "聚合不误算数字文本")
    try expect(workbook.cell(sheet: 0, address: "G2")?.error == "#DIV/0!", "聚合传播引用错误")
    try workbook.apply(); try excelPackage.save(to: excelURL)
    try workbook.set(sheet: 0, address: "A1", input: "3"); try workbook.apply(); try excelPackage.save(to: excelURL)
    let reopenedExcelPackage = try OfficePackage(url: excelURL)
    let reopenedWorkbook = try OfficeWorkbook(package: reopenedExcelPackage)
    try expect(reopenedWorkbook.sheets.count == 2, "新增工作表关系有效")
    try expect(reopenedWorkbook.cell(sheet: 0, address: "C1")?.computed == 7, "修改后依赖公式重算并往返")
    try expect(reopenedWorkbook.cell(sheet: 0, address: "F1")?.display == "00123", "前导零作为文本保留（\(reopenedWorkbook.cell(sheet: 0, address: "F1")?.display ?? "nil")）")
    try expect(reopenedWorkbook.cell(sheet: 0, address: "Z1000")?.display == "远端", "稀疏单元格保存")
    let sheetDocument = try reopenedExcelPackage.xml("xl/worksheets/sheet1.xml")
    let a1s = OfficeXML.descendants(sheetDocument.rootElement()!, "c").filter { OfficeXML.attribute($0, "r") == "A1" }
    try expect(a1s.count == 1, "重复保存不产生重复单元格")

    // PPT: editing a shape preserves run formatting, new shapes/slides and geometry survive reopening.
    let pptURL = root.appendingPathComponent("slides.pptx")
    try OfficeFactory.create(kind: "pptx", to: pptURL)
    let pptPackage = try OfficePackage(url: pptURL)
    let presentation = try OfficePresentation(package: pptPackage)
    let titleID = presentation.slides[0].texts[0].id
    presentation.setText(slide: 0, id: titleID, text: "演示标题\n第二行 😀")
    presentation.setGeometry(slide: 0, id: titleID, x: 3.5, y: 2, width: 20, height: 5)
    let addedID = try presentation.addText(slide: 0); presentation.setText(slide: 0, id: addedID, text: "第二文本框")
    let addedSlide = try presentation.addSlide(); let thirdID = try presentation.addText(slide: addedSlide); presentation.setText(slide: addedSlide, id: thirdID, text: "第二张幻灯片")
    try presentation.apply(); try pptPackage.save(to: pptURL)
    let reopenedPPT = try OfficePresentation(package: OfficePackage(url: pptURL))
    try expect(reopenedPPT.slides.count == 2, "PPT 新幻灯片关系有效")
    try expect(reopenedPPT.slides[0].texts[0].text == "演示标题\n第二行 😀", "PPT 多行文本往返")
    try expect(abs(reopenedPPT.slides[0].texts[0].x - 3.5) < 0.00001, "PPT 文本框厘米位置保存")
    try expect(reopenedPPT.slides[0].texts.count == 2, "PPT 新文本框保存")
    try expect(reopenedPPT.slides[1].texts[0].text == "第二张幻灯片", "PPT 第二页内容保存")

    // Unknown formula cache is preserved, external mutation blocks overwrite without touching new disk contents.
    var unsupportedFiles = OfficeFactory.excelFiles
    unsupportedFiles["xl/worksheets/sheet1.xml"] = unsupportedFiles["xl/worksheets/sheet1.xml"]!.replacingOccurrences(of: "SUM(B2:B2)", with: "UNSUPPORTED_FN(B2)").replacingOccurrences(of: "<f>UNSUPPORTED_FN(B2)</f><v>10</v>", with: "<f>UNSUPPORTED_FN(B2)</f><v>123</v>")
    let unsupportedURL = root.appendingPathComponent("unknown.xlsx")
    let unsupportedPackage = try OfficePackage(files: unsupportedFiles); try unsupportedPackage.save(to: unsupportedURL)
    let unsupportedWorkbook = try OfficeWorkbook(package: unsupportedPackage)
    try expect(unsupportedWorkbook.cell(sheet: 0, address: "B3")?.display == "123", "未知公式沿用已有缓存")
    try unsupportedWorkbook.set(sheet: 0, address: "A1", input: "更新其他单元格"); try unsupportedWorkbook.apply(); try unsupportedPackage.save(to: unsupportedURL)
    let unknownAfter = try OfficeWorkbook(package: OfficePackage(url: unsupportedURL))
    try expect(unknownAfter.cell(sheet: 0, address: "B3")?.display == "123", "保存时保留未知公式缓存")
    let externallyChanged = Data("外部更新，不可覆盖".utf8); try externallyChanged.write(to: wordURL)
    var blocked = false
    do { try wordPackage.save(to: wordURL) } catch { blocked = true }
    try expect(blocked, "外部修改阻止覆盖")
    let afterConflict = try Data(contentsOf: wordURL)
    try expect(afterConflict == externallyChanged, "阻止后外部内容完整")
    try runOfficeRecoveryTests()
    print("Office round-trip tests: PASS (Word / Excel / PPT / preservation / backups / conflict protection)")
}
