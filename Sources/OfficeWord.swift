import Foundation

struct OfficeWordParagraph: Identifiable {
    let id: UUID
    var text: String
    var style: String
    let containsObjects: Bool
    let element: XMLElement
    var textChanged = false
    var styleChanged = false
}

final class OfficeWordDocument {
    let package: OfficePackage
    private let document: XMLDocument
    private let body: XMLElement
    var paragraphs: [OfficeWordParagraph] = []
    var styles: [(id: String, name: String)] = [("Normal", "正文")]
    init(package: OfficePackage) throws {
        self.package = package
        document = try package.xml("word/document.xml")
        guard let root = document.rootElement(), let body = OfficeXML.child(root, "body") else {
            throw OfficeFailure.message("Word 文档缺少正文部件。")
        }
        self.body = body
        for p in OfficeXML.descendants(body, "p") where p.uri == body.uri && !Self.isInsideEmbeddedObject(p, before: body) {
            let text = Self.inlineNodes(p).map { node -> String in
                switch OfficeXML.local(node) { case "t": return node.stringValue ?? ""; case "tab": return "\t"; default: return "\n" }
            }.joined()
            let style = OfficeXML.child(p, "pPr").flatMap { OfficeXML.child($0, "pStyle") }.flatMap { OfficeXML.attribute($0, "val") } ?? "Normal"
            let objectNames = ["drawing", "pict", "object", "fldChar", "instrText", "hyperlink", "oMath", "br", "tab"]
            let objects = objectNames.contains { !OfficeXML.descendants(p, $0).isEmpty }
            paragraphs.append(OfficeWordParagraph(id: UUID(), text: text, style: style, containsObjects: objects, element: p))
        }
        if package.exists("word/styles.xml"), let styleRoot = try package.xml("word/styles.xml").rootElement() {
            let found = OfficeXML.children(styleRoot, "style").compactMap { style -> (String, String)? in
                guard OfficeXML.attribute(style, "type") == "paragraph", let id = OfficeXML.attribute(style, "styleId") else { return nil }
                return (id, OfficeXML.child(style, "name").flatMap { OfficeXML.attribute($0, "val") } ?? id)
            }
            if !found.isEmpty { styles = found }
        }
    }
    private static func isInsideEmbeddedObject(_ element: XMLElement, before boundary: XMLElement) -> Bool {
        var parent = element.parent
        while let node = parent, node !== boundary {
            if ["drawing", "pict", "object"].contains(OfficeXML.local(node)) { return true }
            parent = node.parent
        }
        return false
    }
    private static func inlineNodes(_ paragraph: XMLElement) -> [XMLElement] {
        let all = ["t", "br", "cr", "tab"].flatMap { OfficeXML.descendants(paragraph, $0) }
        return all.filter { node in
            guard node.uri == paragraph.uri, !isInsideEmbeddedObject(node, before: paragraph) else { return false }
            if OfficeXML.local(node) == "br", let type = OfficeXML.attribute(node, "type"), type != "textWrapping" { return false }
            var ancestor = node.parent
            while let current = ancestor, current !== paragraph {
                if OfficeXML.local(current) == "p", current.uri == paragraph.uri { return false }; ancestor = current.parent
            }
            return true
        }.sorted { left, right in
            func order(_ node: XMLNode) -> [Int] { var indices: [Int] = []; var item: XMLNode? = node; while let current = item, current !== paragraph { indices.insert(current.index, at: 0); item = current.parent }; return indices }
            return order(left).lexicographicallyPrecedes(order(right))
        }
    }
    func setText(id: UUID, text: String) { if let i = paragraphs.firstIndex(where: { $0.id == id }) { paragraphs[i].text = text; paragraphs[i].textChanged = true } }
    func setStyle(id: UUID, style: String) { if let i = paragraphs.firstIndex(where: { $0.id == id }) { paragraphs[i].style = style; paragraphs[i].styleChanged = true } }
    @discardableResult func addParagraph(after id: UUID?) -> UUID {
        let p = XMLElement(name: OfficeXML.qualified("p", like: body), uri: body.uri)
        let identity = UUID()
        let item = OfficeWordParagraph(id: identity, text: "", style: "Normal", containsObjects: false, element: p, textChanged: true)
        if let id, let index = paragraphs.firstIndex(where: { $0.id == id }), let parent = paragraphs[index].element.parent as? XMLElement {
            parent.insertChild(p, at: paragraphs[index].element.index + 1)
            paragraphs.insert(item, at: index + 1)
        } else {
            if let sect = OfficeXML.child(body, "sectPr") { body.insertChild(p, at: sect.index) } else { body.addChild(p) }
            paragraphs.append(item)
        }
        return identity
    }
    func removeParagraph(id: UUID) { if let index = paragraphs.firstIndex(where: { $0.id == id }) { paragraphs[index].element.detach(); paragraphs.remove(at: index) } }
    func apply() throws {
        for p in paragraphs {
            if p.textChanged {
                let inline = Self.inlineNodes(p.element)
                for node in inline where OfficeXML.local(node) != "t" { node.detach() }
                let textNodes = inline.filter { OfficeXML.local($0) == "t" }
                OfficeXML.replaceText(p.text, nodes: textNodes) {
                    let run = OfficeXML.append("r", to: p.element)
                    return OfficeXML.append("t", to: run)
                }
                // Encode line breaks/tabs as Word elements, rather than relying on XML whitespace rendering.
                for node in Self.inlineNodes(p.element) where OfficeXML.local(node) == "t" {
                    guard let parent = node.parent as? XMLElement, let text = node.stringValue, text.contains("\n") || text.contains("\t") else { continue }
                    var first = ""; var pending = ""; var replacements: [XMLElement] = []; var sawSeparator = false
                    for character in text {
                        if character == "\n" || character == "\t" {
                            if !sawSeparator { first = pending; sawSeparator = true }
                            else if !pending.isEmpty { replacements.append(OfficeXML.element(OfficeXML.qualified("t", like: node), uri: node.uri, text: pending)) }
                            pending = ""
                            replacements.append(OfficeXML.element(OfficeXML.qualified(character == "\n" ? "br" : "tab", like: node), uri: node.uri))
                        } else { pending.append(character) }
                    }
                    node.stringValue = first
                    if !pending.isEmpty { replacements.append(OfficeXML.element(OfficeXML.qualified("t", like: node), uri: node.uri, text: pending)) }
                    for (offset, replacement) in replacements.enumerated() { if OfficeXML.local(replacement) == "t" { OfficeXML.set(replacement, "xml:space", "preserve") }; parent.insertChild(replacement, at: node.index + offset + 1) }
                }
            }
            if p.styleChanged {
                let properties: XMLElement
                if let old = OfficeXML.child(p.element, "pPr") { properties = old }
                else { properties = XMLElement(name: OfficeXML.qualified("pPr", like: p.element), uri: p.element.uri); p.element.insertChild(properties, at: 0) }
                let style = OfficeXML.child(properties, "pStyle") ?? OfficeXML.append("pStyle", to: properties)
                let prefix = p.element.name?.contains(":") == true ? String(p.element.name!.split(separator: ":")[0]) + ":" : ""
                OfficeXML.set(style, prefix + "val", p.style)
            }
        }
        try package.write(document, path: "word/document.xml")
    }
}
