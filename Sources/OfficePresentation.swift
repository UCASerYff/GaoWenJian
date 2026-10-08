import Foundation

struct OfficeSlideText: Identifiable {
    let id: String
    var name: String
    var text: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    let element: XMLElement
    var textChanged = false
    var geometryChanged = false
}
struct OfficeSlide: Identifiable {
    let id: String
    let path: String
    let document: XMLDocument
    var texts: [OfficeSlideText]
    var title: String { texts.first?.text.split(separator: "\n").first.map(String.init) ?? "空白幻灯片" }
}
final class OfficePresentation {
    let package: OfficePackage
    private let presentation: XMLDocument
    private let relationships: XMLDocument
    private let contentTypes: XMLDocument
    var slides: [OfficeSlide] = []
    var width: Double = 33.867
    var height: Double = 19.05
    init(package: OfficePackage) throws {
        self.package = package
        presentation = try package.xml("ppt/presentation.xml")
        relationships = try package.xml("ppt/_rels/presentation.xml.rels")
        contentTypes = try package.xml("[Content_Types].xml")
        guard let root = presentation.rootElement(), let list = OfficeXML.child(root, "sldIdLst"), let relRoot = relationships.rootElement() else { throw OfficeFailure.message("演示文稿缺少幻灯片信息。") }
        if let size = OfficeXML.child(root, "sldSz") { width = (Double(OfficeXML.attribute(size, "cx") ?? "") ?? 12192000) / 360000; height = (Double(OfficeXML.attribute(size, "cy") ?? "") ?? 6858000) / 360000 }
        for slide in OfficeXML.children(list, "sldId") {
            guard let id = OfficeXML.attribute(slide, "id"), let relationshipID = slide.attribute(forName: "r:id")?.stringValue ?? slide.attributes?.first(where: { $0.name?.contains(":") == true && OfficeXML.local($0) == "id" })?.stringValue, let relation = OfficeXML.children(relRoot, "Relationship").first(where: { OfficeXML.attribute($0, "Id") == relationshipID }), let target = OfficeXML.attribute(relation, "Target"), OfficeXML.attribute(relation, "TargetMode") != "External" else { continue }
            let path = try package.resolve(target, relativeTo: "ppt/presentation.xml")
            let document = try package.xml(path)
            let texts = Self.readTexts(document)
            slides.append(OfficeSlide(id: id, path: path, document: document, texts: texts))
        }
        guard !slides.isEmpty else { throw OfficeFailure.message("演示文稿没有幻灯片。") }
    }
    private static func readTexts(_ document: XMLDocument) -> [OfficeSlideText] {
        guard let root = document.rootElement() else { return [] }
        return OfficeXML.descendants(root, "sp").compactMap { shape in
            guard let body = OfficeXML.child(shape, "txBody") else { return nil }
            let nonVisual = OfficeXML.child(shape, "nvSpPr").flatMap { OfficeXML.child($0, "cNvPr") }
            let text = OfficeXML.children(body, "p").map { OfficeXML.descendants($0, "t").map { $0.stringValue ?? "" }.joined() }.joined(separator: "\n")
            let transform = OfficeXML.child(shape, "spPr").flatMap { OfficeXML.child($0, "xfrm") }
            let offset = transform.flatMap { OfficeXML.child($0, "off") }; let extent = transform.flatMap { OfficeXML.child($0, "ext") }
            return OfficeSlideText(id: nonVisual.flatMap { OfficeXML.attribute($0, "id") } ?? UUID().uuidString, name: nonVisual.flatMap { OfficeXML.attribute($0, "name") } ?? "文本框", text: text, x: (Double(offset.flatMap { OfficeXML.attribute($0, "x") } ?? "") ?? 360000) / 360000, y: (Double(offset.flatMap { OfficeXML.attribute($0, "y") } ?? "") ?? 360000) / 360000, width: (Double(extent.flatMap { OfficeXML.attribute($0, "cx") } ?? "") ?? 10080000) / 360000, height: (Double(extent.flatMap { OfficeXML.attribute($0, "cy") } ?? "") ?? 2160000) / 360000, element: shape)
        }
    }
    func setText(slide: Int, id: String, text: String) { guard slides.indices.contains(slide), let index = slides[slide].texts.firstIndex(where: { $0.id == id }) else { return }; slides[slide].texts[index].text = text; slides[slide].texts[index].textChanged = true }
    func setGeometry(slide: Int, id: String, x: Double? = nil, y: Double? = nil, width: Double? = nil, height: Double? = nil) {
        guard slides.indices.contains(slide), let index = slides[slide].texts.firstIndex(where: { $0.id == id }) else { return }
        if let x, x.isFinite { slides[slide].texts[index].x = max(-100, min(100, x)) }
        if let y, y.isFinite { slides[slide].texts[index].y = max(-100, min(100, y)) }
        if let width, width.isFinite { slides[slide].texts[index].width = max(0.1, min(100, width)) }
        if let height, height.isFinite { slides[slide].texts[index].height = max(0.1, min(100, height)) }
        slides[slide].texts[index].geometryChanged = true
    }
    @discardableResult func addText(slide: Int) throws -> String {
        guard slides.indices.contains(slide), let root = slides[slide].document.rootElement(), let tree = OfficeXML.child(root, "cSld").flatMap({ OfficeXML.child($0, "spTree") }) else { throw OfficeFailure.message("幻灯片结构不完整。") }
        let allIds = OfficeXML.descendants(root, "cNvPr").compactMap { Int(OfficeXML.attribute($0, "id") ?? "") }
        let id = String((allIds.max() ?? 1) + 1)
        let fragment = "<p:sp xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"文本框 \(id)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"720000\" y=\"720000\"/><a:ext cx=\"7200000\" cy=\"1800000\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr wrap=\"square\"/><a:lstStyle/><a:p><a:r><a:rPr lang=\"zh-CN\" sz=\"2400\"/><a:t>新文本框</a:t></a:r></a:p></p:txBody></p:sp>"
        let shape = try XMLElement(xmlString: fragment); tree.addChild(shape)
        if let added = Self.readTexts(slides[slide].document).first(where: { $0.id == id }) { slides[slide].texts.append(added) }
        return id
    }
    @discardableResult func addSlide() throws -> Int {
        guard let root = presentation.rootElement(), let list = OfficeXML.child(root, "sldIdLst"), let relRoot = relationships.rootElement(), let types = contentTypes.rootElement() else { throw OfficeFailure.message("演示文稿结构不完整。") }
        var number = 1
        while package.exists("ppt/slides/slide\(number).xml") || slides.contains(where: { $0.path == "ppt/slides/slide\(number).xml" }) { number += 1 }
        let path = "ppt/slides/slide\(number).xml"
        let id = String(max(255, OfficeXML.children(list, "sldId").compactMap { Int($0.attribute(forName: "id")?.stringValue ?? "") }.max() ?? 255) + 1)
        let relationshipId = "rIdGFW" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let node = OfficeXML.append("sldId", to: list); OfficeXML.set(node, "id", id); OfficeXML.set(node, "r:id", relationshipId)
        let relation = OfficeXML.append("Relationship", to: relRoot); OfficeXML.set(relation, "Id", relationshipId); OfficeXML.set(relation, "Type", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide"); OfficeXML.set(relation, "Target", "slides/slide\(number).xml")
        let type = OfficeXML.append("Override", to: types); OfficeXML.set(type, "PartName", "/" + path); OfficeXML.set(type, "ContentType", "application/vnd.openxmlformats-officedocument.presentationml.slide+xml")
        let doc = try XMLDocument(xmlString: OfficeFactory.blankSlide, options: [])
        // A new slide uses the existing first layout when one is present.
        if let first = slides.first {
            let relPath = (first.path as NSString).deletingLastPathComponent + "/_rels/" + (first.path as NSString).lastPathComponent + ".rels"
            if package.exists(relPath), let old = try package.xml(relPath).rootElement(), let layout = OfficeXML.children(old, "Relationship").first(where: { (OfficeXML.attribute($0, "Type") ?? "").hasSuffix("/slideLayout") }), let target = OfficeXML.attribute(layout, "Target") {
                let part = try package.resolve(target, relativeTo: first.path)
                let relationXML = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"/\(part)\"/></Relationships>"
                try package.write(XMLDocument(xmlString: relationXML, options: []), path: "ppt/slides/_rels/slide\(number).xml.rels")
            }
        }
        slides.append(OfficeSlide(id: id, path: path, document: doc, texts: []))
        return slides.count - 1
    }
    func apply() throws {
        for slide in slides {
            for text in slide.texts {
                if text.textChanged, let body = OfficeXML.child(text.element, "txBody") {
                    let lines = text.text.components(separatedBy: "\n")
                    var paragraphs = OfficeXML.children(body, "p")
                    while paragraphs.count < lines.count {
                        let p = XMLElement(name: "a:p", uri: "http://schemas.openxmlformats.org/drawingml/2006/main"); body.addChild(p); paragraphs.append(p)
                    }
                    for (index, paragraph) in paragraphs.enumerated() {
                        OfficeXML.replaceText(index < lines.count ? lines[index] : "", nodes: OfficeXML.descendants(paragraph, "t")) {
                            let run = OfficeXML.append("r", to: paragraph); return OfficeXML.append("t", to: run)
                        }
                    }
                }
                if text.geometryChanged {
                    let properties = OfficeXML.child(text.element, "spPr") ?? OfficeXML.append("spPr", to: text.element)
                    let transform: XMLElement
                    if let old = OfficeXML.child(properties, "xfrm") { transform = old }
                    else { transform = XMLElement(name: "a:xfrm", uri: "http://schemas.openxmlformats.org/drawingml/2006/main"); properties.insertChild(transform, at: 0) }
                    let offset = OfficeXML.child(transform, "off") ?? OfficeXML.append("off", to: transform)
                    let extent = OfficeXML.child(transform, "ext") ?? OfficeXML.append("ext", to: transform)
                    OfficeXML.set(offset, "x", String(Int64(text.x * 360000))); OfficeXML.set(offset, "y", String(Int64(text.y * 360000)))
                    OfficeXML.set(extent, "cx", String(Int64(text.width * 360000))); OfficeXML.set(extent, "cy", String(Int64(text.height * 360000)))
                }
            }
            try package.write(slide.document, path: slide.path)
        }
        try package.write(presentation, path: "ppt/presentation.xml"); try package.write(relationships, path: "ppt/_rels/presentation.xml.rels"); try package.write(contentTypes, path: "[Content_Types].xml")
    }
}
