import Foundation

enum OfficeFactory {
    static func create(kind: String, to url: URL) throws {
        let files: [String: String]
        switch kind.lowercased() {
        case "docx": files = wordFiles
        case "xlsx": files = excelFiles
        case "pptx": files = presentationFiles
        default: throw OfficeFailure.message("不支持创建这种 Office 文件。")
        }
        let package = try OfficePackage(files: files)
        try package.save(to: url)
    }
    private static let packageNS = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let officeNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static func rootRelationship(_ part: String) -> String { "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"\(packageNS)\"><Relationship Id=\"rId1\" Type=\"\(officeNS)/officeDocument\" Target=\"\(part)\"/></Relationships>" }
    static let wordFiles: [String: String] = [
        "[Content_Types].xml": """
        <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
        """,
        "_rels/.rels": rootRelationship("word/document.xml"),
        "word/_rels/document.xml.rels": "<Relationships xmlns=\"\(packageNS)\"><Relationship Id=\"rId1\" Type=\"\(officeNS)/styles\" Target=\"styles.xml\"/></Relationships>",
        "word/document.xml": """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body><w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>新建文档</w:t></w:r></w:p><w:p><w:r><w:t>在这里开始写作。</w:t></w:r></w:p><w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>
        """,
        "word/styles.xml": """
        <?xml version="1.0" encoding="UTF-8"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="PingFang SC"/><w:sz w:val="24"/><w:lang w:val="zh-CN"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="正文"/><w:qFormat/></w:style><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="标题"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:rPr><w:sz w:val="44"/><w:b/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="一级标题"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="二级标题"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style></w:styles>
        """
    ]
    static let excelFiles: [String: String] = [
        "[Content_Types].xml": """
        <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
        """,
        "_rels/.rels": rootRelationship("xl/workbook.xml"),
        "xl/workbook.xml": """
        <?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView/></bookViews><sheets><sheet name="工作表1" sheetId="1" r:id="rId1"/></sheets><calcPr calcMode="auto" fullCalcOnLoad="1"/></workbook>
        """,
        "xl/_rels/workbook.xml.rels": "<Relationships xmlns=\"\(packageNS)\"><Relationship Id=\"rId1\" Type=\"\(officeNS)/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"\(officeNS)/styles\" Target=\"styles.xml\"/></Relationships>",
        "xl/worksheets/sheet1.xml": """
        <?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="A1:B3"/><sheetViews><sheetView workbookViewId="0"/></sheetViews><sheetFormatPr defaultRowHeight="18"/><cols><col min="1" max="10" width="18" customWidth="1"/></cols><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>项目</t></is></c><c r="B1" t="inlineStr"><is><t>数值</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>示例</t></is></c><c r="B2"><v>10</v></c></row><row r="3"><c r="A3" t="inlineStr"><is><t>合计</t></is></c><c r="B3"><f>SUM(B2:B2)</f><v>10</v></c></row></sheetData></worksheet>
        """,
        "xl/styles.xml": """
        <?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><sz val="11"/><name val="Arial"/><family val="2"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """
    ]
    static let blankSlide = """
    <?xml version="1.0" encoding="UTF-8"?><p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
    """
    static var presentationFiles: [String: String] {
        var files: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/></Types>
            """,
            "_rels/.rels": rootRelationship("ppt/presentation.xml"),
            "ppt/presentation.xml": """
            <?xml version="1.0" encoding="UTF-8"?><p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId2"/></p:sldMasterIdLst><p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst><p:sldSz cx="12192000" cy="6858000" type="screen16x9"/><p:notesSz cx="6858000" cy="9144000"/><p:defaultTextStyle/></p:presentation>
            """,
            "ppt/_rels/presentation.xml.rels": "<Relationships xmlns=\"\(packageNS)\"><Relationship Id=\"rId1\" Type=\"\(officeNS)/slide\" Target=\"slides/slide1.xml\"/><Relationship Id=\"rId2\" Type=\"\(officeNS)/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/></Relationships>",
            "ppt/slides/_rels/slide1.xml.rels": "<Relationships xmlns=\"\(packageNS)\"><Relationship Id=\"rId1\" Type=\"\(officeNS)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/></Relationships>",
            "ppt/slideLayouts/slideLayout1.xml": """
            <?xml version="1.0" encoding="UTF-8"?><p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1"><p:cSld name="空白"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
            """,
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels": "<Relationships xmlns=\"\(packageNS)\"><Relationship Id=\"rId1\" Type=\"\(officeNS)/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>",
            "ppt/slideMasters/_rels/slideMaster1.xml.rels": "<Relationships xmlns=\"\(packageNS)\"><Relationship Id=\"rId1\" Type=\"\(officeNS)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/><Relationship Id=\"rId2\" Type=\"\(officeNS)/theme\" Target=\"../theme/theme1.xml\"/></Relationships>",
            "ppt/slideMasters/slideMaster1.xml": """
            <?xml version="1.0" encoding="UTF-8"?><p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>
            """
        ]
        files["ppt/theme/theme1.xml"] = """
        <?xml version="1.0" encoding="UTF-8"?><a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="搞文件"><a:themeElements><a:clrScheme name="简洁"><a:dk1><a:srgbClr val="1F2937"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="374151"/></a:dk2><a:lt2><a:srgbClr val="F3F4F6"/></a:lt2><a:accent1><a:srgbClr val="4B5563"/></a:accent1><a:accent2><a:srgbClr val="6B7280"/></a:accent2><a:accent3><a:srgbClr val="9CA3AF"/></a:accent3><a:accent4><a:srgbClr val="D1D5DB"/></a:accent4><a:accent5><a:srgbClr val="2563EB"/></a:accent5><a:accent6><a:srgbClr val="059669"/></a:accent6><a:hlink><a:srgbClr val="2563EB"/></a:hlink><a:folHlink><a:srgbClr val="7C3AED"/></a:folHlink></a:clrScheme><a:fontScheme name="默认字体"><a:majorFont><a:latin typeface="Arial"/><a:ea typeface="PingFang SC"/><a:cs typeface="Arial"/></a:majorFont><a:minorFont><a:latin typeface="Arial"/><a:ea typeface="PingFang SC"/><a:cs typeface="Arial"/></a:minorFont></a:fontScheme><a:fmtScheme name="简洁"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln><a:ln w="25400"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln><a:ln w="38100"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>
        """
        files["ppt/slides/slide1.xml"] = blankSlide.replacingOccurrences(of: "</p:spTree>", with: """
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="标题"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="720000" y="720000"/><a:ext cx="10800000" cy="2160000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="zh-CN" sz="3600" b="1"/><a:t>新建演示文稿</a:t></a:r></a:p></p:txBody></p:sp></p:spTree>
        """)
        return files
    }
}
