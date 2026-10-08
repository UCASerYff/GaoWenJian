import Foundation

struct OfficeCell: Identifiable {
    var id: String { address }
    let address: String
    var input: String
    var display: String
    var formula: String?
    var computed: Double?
    var error: String?
    var literalKind: String
    var changed = false
    var element: XMLElement?
}

struct OfficeSheet: Identifiable {
    let id: String
    var name: String
    let path: String
    let document: XMLDocument
    var cells: [String: OfficeCell]
    var hidden: Bool
    var maxRow: Int { cells.keys.compactMap { OfficeWorkbook.coordinates($0)?.row }.max() ?? 1 }
    var maxColumn: Int { cells.keys.compactMap { OfficeWorkbook.coordinates($0)?.column }.max() ?? 1 }
}

final class OfficeWorkbook {
    let package: OfficePackage
    private let workbook: XMLDocument
    private let relationships: XMLDocument
    private let contentTypes: XMLDocument
    var sheets: [OfficeSheet] = []
    private var sharedStrings: [String] = []
    init(package: OfficePackage) throws {
        self.package = package
        workbook = try package.xml("xl/workbook.xml")
        relationships = try package.xml("xl/_rels/workbook.xml.rels")
        contentTypes = try package.xml("[Content_Types].xml")
        guard let root = workbook.rootElement(), let list = OfficeXML.child(root, "sheets"), let relRoot = relationships.rootElement() else {
            throw OfficeFailure.message("Excel 文档缺少工作表信息。")
        }
        if package.exists("xl/sharedStrings.xml"), let root = try package.xml("xl/sharedStrings.xml").rootElement() {
            sharedStrings = OfficeXML.children(root, "si").map { OfficeXML.descendants($0, "t").map { $0.stringValue ?? "" }.joined() }
        }
        for sheet in OfficeXML.children(list, "sheet") {
            guard let relationId = OfficeXML.attribute(sheet, "id"), let relation = OfficeXML.children(relRoot, "Relationship").first(where: { OfficeXML.attribute($0, "Id") == relationId }), let target = OfficeXML.attribute(relation, "Target") else { continue }
            guard OfficeXML.attribute(relation, "TargetMode") != "External" else { continue }
            let path = try package.resolve(target, relativeTo: "xl/workbook.xml")
            let document = try package.xml(path)
            guard let worksheet = document.rootElement(), OfficeXML.local(worksheet) == "worksheet" else { continue }
            var cells: [String: OfficeCell] = [:]
            for cell in OfficeXML.descendants(worksheet, "c") {
                guard let address = OfficeXML.attribute(cell, "r"), Self.coordinates(address) != nil else { continue }
                let type = OfficeXML.attribute(cell, "t") ?? "n"
                let raw = OfficeXML.child(cell, "v")?.stringValue ?? ""
                let formula = OfficeXML.child(cell, "f")?.stringValue
                let value: String
                if type == "s", let index = Int(raw), sharedStrings.indices.contains(index) { value = sharedStrings[index] }
                else if type == "inlineStr" { value = OfficeXML.child(cell, "is").map { OfficeXML.descendants($0, "t").map { $0.stringValue ?? "" }.joined() } ?? "" }
                else if type == "b" { value = raw == "1" ? "TRUE" : "FALSE" }
                else { value = raw }
                cells[address] = OfficeCell(address: address, input: formula.map { "=" + $0 } ?? value, display: value, formula: formula, computed: formula == nil ? nil : Double(raw), error: nil, literalKind: type, element: cell)
            }
            sheets.append(OfficeSheet(id: relationId, name: OfficeXML.attribute(sheet, "name") ?? "工作表", path: path, document: document, cells: cells, hidden: (OfficeXML.attribute(sheet, "state") ?? "visible") != "visible"))
        }
        guard !sheets.isEmpty else { throw OfficeFailure.message("Excel 文档没有可编辑的工作表。图表工作表不提供单元格编辑。") }
        recalculate()
    }
    static func columnName(_ number: Int) -> String {
        var n = number; var result = ""
        while n > 0 { n -= 1; result = String(UnicodeScalar(65 + n % 26)!) + result; n /= 26 }
        return result
    }
    static func coordinates(_ reference: String) -> (row: Int, column: Int)? {
        let address = reference.uppercased().replacingOccurrences(of: "$", with: "")
        let letters = address.prefix(while: { $0.isASCII && $0.isLetter })
        let digits = address.dropFirst(letters.count)
        guard !letters.isEmpty, !digits.isEmpty, digits.allSatisfy({ $0.isNumber }), let row = Int(digits), row > 0, row <= 1048576 else { return nil }
        let column = letters.reduce(0) { $0 * 26 + Int($1.asciiValue! - 64) }
        guard column <= 16384 else { return nil }
        return (row, column)
    }
    func cell(sheet: Int, address: String) -> OfficeCell? { guard sheets.indices.contains(sheet) else { return nil }; return sheets[sheet].cells[address.uppercased().replacingOccurrences(of: "$", with: "")] }
    func set(sheet: Int, address: String, input: String) throws {
        guard sheets.indices.contains(sheet), Self.coordinates(address) != nil else { throw OfficeFailure.message("请输入有效单元格地址，例如 A1。") }
        let key = address.uppercased().replacingOccurrences(of: "$", with: "")
        if let root = sheets[sheet].document.rootElement(), let coordinate = Self.coordinates(key) {
            for formula in OfficeXML.descendants(root, "f") {
                guard let type = OfficeXML.attribute(formula, "t"), ["shared", "array", "dataTable"].contains(type), let range = OfficeXML.attribute(formula, "ref") else { continue }
                let endpoints = range.split(separator: ":").map(String.init)
                if let start = endpoints.first.flatMap(Self.coordinates), let end = endpoints.last.flatMap(Self.coordinates), coordinate.row >= start.row, coordinate.row <= end.row, coordinate.column >= start.column, coordinate.column <= end.column {
                    throw OfficeFailure.message("这个单元格属于共享、数组或数据表公式区域，请在 LibreOffice 中编辑。")
                }
            }
        }
        if let existing = sheets[sheet].cells[key]?.element, let f = OfficeXML.child(existing, "f"), let type = OfficeXML.attribute(f, "t"), ["shared", "array", "dataTable"].contains(type) {
            throw OfficeFailure.message("这个单元格属于共享、数组或数据表公式，请在 LibreOffice 中编辑，避免破坏关联公式。")
        }
        let formula = input.hasPrefix("=") ? String(input.dropFirst()) : nil
        let kind = Self.literalNumber(input) != nil ? "n" : ["TRUE", "FALSE"].contains(input.uppercased()) ? "b" : "inlineStr"
        sheets[sheet].cells[key] = OfficeCell(address: key, input: input, display: formula == nil ? input : "", formula: formula, computed: nil, error: nil, literalKind: kind, changed: true, element: sheets[sheet].cells[key]?.element)
        recalculate()
    }
    func renameSheet(index: Int, name: String) throws {
        guard sheets.indices.contains(index), !name.isEmpty, name.count <= 31, !name.contains(where: { "[]:*?/\\".contains($0) }), !sheets.enumerated().contains(where: { $0.offset != index && $0.element.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw OfficeFailure.message("工作表名称须为 1–31 个字符且唯一，不能包含 [] : * ? / \\。")
        }
        // Renaming a referenced sheet needs a full formula parser; keep all references intact instead.
        let old = sheets[index].name
        if let files = FileManager.default.enumerator(at: package.directory, includingPropertiesForKeys: nil) {
            for case let file as URL in files where file.pathExtension.lowercased() == "xml" {
                if let text = try? String(contentsOf: file, encoding: .utf8), text.localizedCaseInsensitiveContains(old + "!") || text.localizedCaseInsensitiveContains("'" + old.replacingOccurrences(of: "'", with: "''") + "'!") {
                    throw OfficeFailure.message("公式、图表或定义名称引用此工作表，请在 LibreOffice 中重命名，以同步更新引用。")
                }
            }
        }
        if sheets.contains(where: { $0.cells.values.contains(where: { ($0.formula ?? "").localizedCaseInsensitiveContains(old + "!") || ($0.formula ?? "").localizedCaseInsensitiveContains("'" + old.replacingOccurrences(of: "'", with: "''") + "'!") }) }) {
            throw OfficeFailure.message("有公式引用此工作表，请在 LibreOffice 中重命名，以同步更新所有引用。")
        }
        guard let root = workbook.rootElement(), let list = OfficeXML.child(root, "sheets"), let node = OfficeXML.children(list, "sheet").first(where: { OfficeXML.attribute($0, "id") == sheets[index].id }) else { return }
        OfficeXML.set(node, "name", name); sheets[index].name = name
    }
    @discardableResult func addSheet() throws -> Int {
        guard let root = workbook.rootElement(), let list = OfficeXML.child(root, "sheets"), let relRoot = relationships.rootElement(), let types = contentTypes.rootElement() else { throw OfficeFailure.message("工作簿结构不完整。") }
        var number = 1
        while package.exists("xl/worksheets/sheet\(number).xml") || sheets.contains(where: { $0.path == "xl/worksheets/sheet\(number).xml" }) { number += 1 }
        let path = "xl/worksheets/sheet\(number).xml"
        let id = "rIdGFW" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var nameNumber = sheets.count + 1
        while sheets.contains(where: { $0.name == "工作表\(nameNumber)" }) { nameNumber += 1 }
        let name = "工作表\(nameNumber)"
        let document = try XMLDocument(xmlString: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData/></worksheet>", options: [])
        let node = OfficeXML.append("sheet", to: list)
        OfficeXML.set(node, "name", name)
        OfficeXML.set(node, "sheetId", String((OfficeXML.children(list, "sheet").compactMap { Int(OfficeXML.attribute($0, "sheetId") ?? "") }.max() ?? 0) + 1))
        OfficeXML.set(node, "r:id", id)
        let relation = OfficeXML.append("Relationship", to: relRoot)
        OfficeXML.set(relation, "Id", id); OfficeXML.set(relation, "Type", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"); OfficeXML.set(relation, "Target", "worksheets/sheet\(number).xml")
        let type = OfficeXML.append("Override", to: types)
        OfficeXML.set(type, "PartName", "/" + path); OfficeXML.set(type, "ContentType", "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml")
        sheets.append(OfficeSheet(id: id, name: name, path: path, document: document, cells: [:], hidden: false))
        return sheets.count - 1
    }
    func recalculate() {
        var cache: [String: Double] = [:]; var visiting: Set<String> = []
        func evaluate(_ index: Int, _ address: String) throws -> Double {
            let key = "\(index):\(address)"
            if let value = cache[key] { return value }
            guard !visiting.contains(key) else { throw OfficeFormulaError.code("#CYCLE!") }
            guard let cell = sheets[index].cells[address] else { return 0 }
            guard let formula = cell.formula else {
                if cell.literalKind == "e" { throw OfficeFormulaError.code(cell.display) }
                if cell.input.uppercased() == "TRUE" { return 1 }; if cell.input.uppercased() == "FALSE" { return 0 }
                if cell.input.isEmpty { return 0 }
                guard let number = Double(cell.input) else { throw OfficeFormulaError.code("#VALUE!") }; return number
            }
            if let f = cell.element.flatMap({ OfficeXML.child($0, "f") }), OfficeXML.attribute(f, "t") != nil { throw OfficeFormulaError.unsupported }
            visiting.insert(key); defer { visiting.remove(key) }
            func locate(_ reference: String) throws -> (Int, String) {
                let parts = reference.split(separator: "!", maxSplits: 1, omittingEmptySubsequences: false)
                var target = index; var address = reference
                if parts.count == 2 {
                    var name = String(parts[0]); if name.hasPrefix("'"), name.hasSuffix("'") { name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
                    guard let found = self.sheets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw OfficeFormulaError.code("#REF!") }
                    target = found; address = String(parts[1])
                }
                address = address.uppercased().replacingOccurrences(of: "$", with: "")
                guard Self.coordinates(address) != nil else { throw OfficeFormulaError.unsupported }
                return (target, address)
            }
            var parser = OfficeFormulaParser(formula: formula, reference: { reference in
                let (target, address) = try locate(reference); return try evaluate(target, address)
            }, aggregateReference: { reference in
                let (target, address) = try locate(reference)
                guard let cell = self.sheets[target].cells[address] else { return nil }
                if cell.formula == nil {
                    if cell.literalKind == "e" { throw OfficeFormulaError.code(cell.display) }
                    return cell.literalKind == "n" ? Double(cell.input) : nil
                }
                return try evaluate(target, address)
            })
            let value = try parser.parse()
            guard value.isFinite else { throw OfficeFormulaError.code("#NUM!") }
            cache[key] = value; return value
        }
        for sheetIndex in sheets.indices {
            for key in sheets[sheetIndex].cells.keys.sorted() where sheets[sheetIndex].cells[key]?.formula != nil {
                do {
                    let value = try evaluate(sheetIndex, key)
                    sheets[sheetIndex].cells[key]?.computed = value
                    sheets[sheetIndex].cells[key]?.display = Self.numberText(value)
                    sheets[sheetIndex].cells[key]?.error = nil
                } catch OfficeFormulaError.code(let code) {
                    sheets[sheetIndex].cells[key]?.computed = nil; sheets[sheetIndex].cells[key]?.display = code; sheets[sheetIndex].cells[key]?.error = code
                } catch {
                    // Unknown formulas keep their existing cached value; never overwrite with a guessed result.
                    sheets[sheetIndex].cells[key]?.computed = nil; sheets[sheetIndex].cells[key]?.error = "暂不支持此公式，保留已有缓存"
                    if sheets[sheetIndex].cells[key]?.display.isEmpty == true { sheets[sheetIndex].cells[key]?.display = "待重算" }
                }
            }
        }
    }
    static func numberText(_ number: Double) -> String { String(format: "%.15g", number) }
    private static func literalNumber(_ text: String) -> Double? {
        guard let number = Double(text), number.isFinite, !(text.hasPrefix("0") && text.count > 1 && !text.hasPrefix("0.")), !text.hasPrefix("'") else { return nil }
        return number
    }
    func apply() throws {
        for sheetIndex in sheets.indices {
            let sheet = sheets[sheetIndex]
            guard let root = sheet.document.rootElement() else { continue }
            let data = OfficeXML.child(root, "sheetData") ?? OfficeXML.append("sheetData", to: root)
            for cell in sheet.cells.values.sorted(by: { $0.address < $1.address }) where cell.changed || (cell.formula != nil && (cell.computed != nil || cell.error?.hasPrefix("#") == true)) {
                guard let coordinate = Self.coordinates(cell.address) else { continue }
                let element: XMLElement
                if let existing = cell.element { element = existing }
                else {
                    let row = OfficeXML.children(data, "row").first(where: { OfficeXML.attribute($0, "r") == String(coordinate.row) }) ?? {
                        let node = XMLElement(name: OfficeXML.qualified("row", like: data), uri: data.uri); OfficeXML.set(node, "r", String(coordinate.row))
                        if let next = OfficeXML.children(data, "row").first(where: { (Int(OfficeXML.attribute($0, "r") ?? "") ?? 0) > coordinate.row }) { data.insertChild(node, at: next.index) } else { data.addChild(node) }
                        return node
                    }()
                    element = XMLElement(name: OfficeXML.qualified("c", like: row), uri: row.uri); OfficeXML.set(element, "r", cell.address)
                    if let next = OfficeXML.children(row, "c").first(where: { (Self.coordinates(OfficeXML.attribute($0, "r") ?? "")?.column ?? 0) > coordinate.column }) { row.insertChild(element, at: next.index) } else { row.addChild(element) }
                    sheets[sheetIndex].cells[cell.address]?.element = element
                }
                if let formula = cell.formula {
                    if cell.changed {
                        OfficeXML.remove(element, "f"); OfficeXML.remove(element, "is"); OfficeXML.remove(element, "v"); element.removeAttribute(forName: "t")
                        OfficeXML.append("f", to: element).stringValue = formula
                    }
                    if let result = cell.computed {
                        OfficeXML.remove(element, "v"); element.removeAttribute(forName: "t"); OfficeXML.append("v", to: element).stringValue = Self.numberText(result)
                    } else if let error = cell.error, error.hasPrefix("#") {
                        OfficeXML.remove(element, "v"); OfficeXML.set(element, "t", "e"); OfficeXML.append("v", to: element).stringValue = error
                    }
                } else if cell.changed {
                    OfficeXML.remove(element, "f"); OfficeXML.remove(element, "is"); OfficeXML.remove(element, "v"); element.removeAttribute(forName: "t")
                    if !cell.input.isEmpty {
                        if Self.literalNumber(cell.input) != nil {
                            OfficeXML.append("v", to: element).stringValue = cell.input
                        } else if ["TRUE", "FALSE"].contains(cell.input.uppercased()) {
                            OfficeXML.set(element, "t", "b"); OfficeXML.append("v", to: element).stringValue = cell.input.uppercased() == "TRUE" ? "1" : "0"
                        } else {
                            OfficeXML.set(element, "t", "inlineStr"); let inline = OfficeXML.append("is", to: element); let text = OfficeXML.append("t", to: inline)
                            text.stringValue = cell.input.hasPrefix("'") ? String(cell.input.dropFirst()) : cell.input; OfficeXML.set(text, "xml:space", "preserve")
                        }
                    }
                }
            }
            if let dimension = OfficeXML.child(root, "dimension") { OfficeXML.set(dimension, "ref", "A1:\(Self.columnName(sheet.maxColumn))\(sheet.maxRow)") }
            try package.write(sheet.document, path: sheet.path)
        }
        if let root = workbook.rootElement() {
            let calc = OfficeXML.child(root, "calcPr") ?? OfficeXML.append("calcPr", to: root)
            OfficeXML.set(calc, "calcMode", "auto"); OfficeXML.set(calc, "fullCalcOnLoad", "1"); OfficeXML.set(calc, "forceFullCalc", "1")
        }
        if let root = relationships.rootElement() {
            for rel in OfficeXML.children(root, "Relationship") where (OfficeXML.attribute(rel, "Type") ?? "").hasSuffix("/calcChain") {
                if let target = OfficeXML.attribute(rel, "Target") { try package.remove(package.resolve(target, relativeTo: "xl/workbook.xml")) }; rel.detach()
            }
        }
        if let root = contentTypes.rootElement() {
            for type in OfficeXML.children(root, "Override") where (OfficeXML.attribute(type, "ContentType") ?? "").contains("calcChain") { type.detach() }
        }
        try package.write(workbook, path: "xl/workbook.xml"); try package.write(relationships, path: "xl/_rels/workbook.xml.rels"); try package.write(contentTypes, path: "[Content_Types].xml")
    }
}

enum OfficeFormulaError: Error { case unsupported; case code(String) }

struct OfficeFormulaParser {
    let characters: [Character]
    var position = 0
    let reference: (String) throws -> Double
    let aggregateReference: (String) throws -> Double?
    init(formula: String, reference: @escaping (String) throws -> Double, aggregateReference: @escaping (String) throws -> Double?) { characters = Array(formula); self.reference = reference; self.aggregateReference = aggregateReference }
    mutating func parse() throws -> Double { let value = try comparison(); spaces(); guard position == characters.count else { throw OfficeFormulaError.unsupported }; return value }
    mutating func spaces() { while position < characters.count && characters[position].isWhitespace { position += 1 } }
    mutating func consume(_ character: Character) -> Bool { spaces(); if position < characters.count && characters[position] == character { position += 1; return true }; return false }
    mutating func comparison() throws -> Double {
        var value = try addition(); spaces()
        if position < characters.count, "=<>".contains(characters[position]) {
            let first = characters[position]; position += 1
            var op = String(first); if position < characters.count && "=>".contains(characters[position]) { op.append(characters[position]); position += 1 }
            let right = try addition()
            let yes: Bool
            switch op { case "=": yes = value == right; case "<>": yes = value != right; case "<": yes = value < right; case ">": yes = value > right; case "<=": yes = value <= right; case ">=": yes = value >= right; default: throw OfficeFormulaError.unsupported }
            value = yes ? 1 : 0
        }
        return value
    }
    mutating func addition() throws -> Double {
        var value = try multiplication()
        while true { if consume("+") { value += try multiplication() } else if consume("-") { value -= try multiplication() } else { return value } }
    }
    mutating func multiplication() throws -> Double {
        var value = try power()
        while true {
            if consume("*") { value *= try power() }
            else if consume("/") { let denominator = try power(); guard denominator != 0 else { throw OfficeFormulaError.code("#DIV/0!") }; value /= denominator }
            else { return value }
        }
    }
    mutating func power() throws -> Double { var value = try primary(); if consume("^") { value = Foundation.pow(value, try power()) }; if consume("%") { value /= 100 }; return value }
    mutating func primary() throws -> Double {
        spaces()
        if consume("+") { return try primary() }; if consume("-") { return -(try primary()) }
        if consume("(") { let result = try comparison(); guard consume(")") else { throw OfficeFormulaError.unsupported }; return result }
        guard position < characters.count else { throw OfficeFormulaError.unsupported }
        if characters[position].isNumber || characters[position] == "." {
            let start = position
            while position < characters.count && (characters[position].isNumber || characters[position] == ".") { position += 1 }
            if position < characters.count && "eE".contains(characters[position]) { position += 1; if position < characters.count && "+-".contains(characters[position]) { position += 1 }; while position < characters.count && characters[position].isNumber { position += 1 } }
            guard let number = Double(String(characters[start..<position])) else { throw OfficeFormulaError.unsupported }; return number
        }
        let token = try identifier()
        if consume("(") {
            // Unsupported functions are left untouched, including their cached results.
            guard ["SUM", "AVERAGE", "MIN", "MAX", "COUNT", "ABS", "ROUND"].contains(token.uppercased()) else { throw OfficeFormulaError.unsupported }
            let aggregate = ["SUM", "AVERAGE", "MIN", "MAX", "COUNT"].contains(token.uppercased())
            var args: [Double] = []
            if !consume(")") {
                while true {
                    let start = position
                    if aggregate, let range = try rangeArgument() { args.append(contentsOf: range) }
                    else { position = start; args.append(try comparison()) }
                    if consume(")") { break }
                    guard consume(",") || consume(";") else { throw OfficeFormulaError.unsupported }
                }
            }
            switch token.uppercased() {
            case "SUM": return args.reduce(0, +)
            case "AVERAGE": guard !args.isEmpty else { throw OfficeFormulaError.code("#DIV/0!") }; return args.reduce(0, +) / Double(args.count)
            case "MIN": return args.min() ?? 0
            case "MAX": return args.max() ?? 0
            case "COUNT": return Double(args.count)
            case "ABS": guard args.count == 1 else { throw OfficeFormulaError.unsupported }; return abs(args[0])
            case "ROUND": guard args.count == 2, abs(args[1]) <= 15 else { throw OfficeFormulaError.unsupported }; let factor = Foundation.pow(10, args[1].rounded(.towardZero)); return (args[0] * factor).rounded() / factor
            default: throw OfficeFormulaError.unsupported
            }
        }
        if token.uppercased() == "TRUE" { return 1 }; if token.uppercased() == "FALSE" { return 0 }
        return try reference(token)
    }
    mutating func identifier() throws -> String {
        spaces(); let start = position
        if position < characters.count && characters[position] == "'" {
            position += 1
            while position < characters.count {
                if characters[position] == "'" {
                    position += 1; if position < characters.count && characters[position] == "'" { position += 1; continue }; break
                }; position += 1
            }
            guard position < characters.count && characters[position] == "!" else { throw OfficeFormulaError.unsupported }; position += 1
        }
        while position < characters.count && (characters[position].isLetter || characters[position].isNumber || "_$!.".contains(characters[position])) { position += 1 }
        guard position > start else { throw OfficeFormulaError.unsupported }; return String(characters[start..<position])
    }
    mutating func rangeArgument() throws -> [Double]? {
        let start = position
        guard let first = try? identifier() else { position = start; return nil }
        if !consume(":") {
            spaces()
            guard position < characters.count, [",", ";", ")"].contains(characters[position]), OfficeWorkbook.coordinates(String(first.split(separator: "!").last ?? "")) != nil else { position = start; return nil }
            return try aggregateReference(first).map { [$0] } ?? []
        }
        let last = try identifier()
        let parts = first.split(separator: "!", maxSplits: 1)
        let prefix = parts.count == 2 ? String(parts[0]) + "!" : ""
        guard let from = OfficeWorkbook.coordinates(String(parts.last!)), let to = OfficeWorkbook.coordinates(last), from.row <= to.row, from.column <= to.column, (to.row - from.row + 1) * (to.column - from.column + 1) <= 100000 else { throw OfficeFormulaError.unsupported }
        var results: [Double] = []
        for row in from.row...to.row { for column in from.column...to.column { if let value = try aggregateReference(prefix + OfficeWorkbook.columnName(column) + String(row)) { results.append(value) } } }
        return results
    }
}
