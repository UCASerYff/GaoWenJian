#!/usr/bin/env python3
import plistlib, sys
destination, version, build = sys.argv[1:]
types = [
    ('Markdown', ['md','markdown'], ['net.daringfireball.markdown']),
    ('LaTeX', ['tex','bib','sty','cls'], ['public.text']),
    ('PDF', ['pdf'], ['com.adobe.pdf']),
    ('Word', ['doc','docx','docm','dotx','dotm','odt'], ['com.microsoft.word.doc','org.openxmlformats.wordprocessingml.document','org.oasis-open.opendocument.text']),
    ('Excel', ['xls','xlsx','xlsm','xltx','xltm','ods'], ['com.microsoft.excel.xls','org.openxmlformats.spreadsheetml.sheet','org.oasis-open.opendocument.spreadsheet']),
    ('PPT', ['ppt','pptx','pptm','potx','potm','pps','ppsx','odp'], ['com.microsoft.powerpoint.ppt','org.openxmlformats.presentationml.presentation','org.oasis-open.opendocument.presentation']),
    ('文本与表格', ['txt','csv','tsv','rtf'], ['public.plain-text','public.comma-separated-values-text','public.rtf']),
]
# These non-system types need extension tags as well as document-role entries:
# LSItemContentTypes takes precedence over CFBundleTypeExtensions on macOS.
# Reuse the Office/OpenDocument identifiers declared by the local LibreOffice
# installation. Use app-scoped identifiers for the two slideshow variants.
office_imports = [
    ('Word', 'docm', 'org.openxmlformats.wordprocessingml.document.macroEnabled', 'Word 启用宏的文档', 'application/vnd.ms-word.document.macroEnabled.12'),
    ('Word', 'dotx', 'org.openxmlformats.wordprocessingml.template', 'Word 模板', 'application/vnd.openxmlformats-officedocument.wordprocessingml.template'),
    ('Word', 'dotm', 'org.openxmlformats.wordprocessingml.template.macroEnabled', 'Word 启用宏的模板', 'application/vnd.ms-word.template.macroEnabled.12'),
    ('Word', 'odt', 'org.oasis-open.opendocument.text', 'OpenDocument 文本文档', 'application/vnd.oasis.opendocument.text'),
    ('Excel', 'xlsm', 'org.openxmlformats.spreadsheetml.sheet.macroEnabled', 'Excel 启用宏的工作簿', 'application/vnd.ms-excel.sheet.macroEnabled.12'),
    ('Excel', 'xltx', 'org.openxmlformats.spreadsheetml.template', 'Excel 模板', 'application/vnd.openxmlformats-officedocument.spreadsheetml.template'),
    ('Excel', 'xltm', 'org.openxmlformats.spreadsheetml.template.macroEnabled', 'Excel 启用宏的模板', 'application/vnd.ms-excel.template.macroEnabled.12'),
    ('Excel', 'ods', 'org.oasis-open.opendocument.spreadsheet', 'OpenDocument 电子表格', 'application/vnd.oasis.opendocument.spreadsheet'),
    ('PPT', 'pptm', 'org.openxmlformats.presentationml.presentation.macroEnabled', 'PowerPoint 启用宏的演示', 'application/vnd.ms-powerpoint.presentation.macroEnabled.12'),
    ('PPT', 'potx', 'org.openxmlformats.presentationml.template', 'PowerPoint 模板', 'application/vnd.openxmlformats-officedocument.presentationml.template'),
    ('PPT', 'potm', 'org.openxmlformats.presentationml.template.macroEnabled', 'PowerPoint 启用宏的模板', 'application/vnd.ms-powerpoint.template.macroEnabled.12'),
    ('PPT', 'pps', 'com.gaoseries.GaoWenJian.office.pps', 'PowerPoint 放映', 'application/vnd.ms-powerpoint'),
    ('PPT', 'ppsx', 'com.gaoseries.GaoWenJian.office.ppsx', 'PowerPoint Open XML 放映', 'application/vnd.openxmlformats-officedocument.presentationml.slideshow'),
    ('PPT', 'odp', 'org.oasis-open.opendocument.presentation', 'OpenDocument 演示', 'application/vnd.oasis.opendocument.presentation'),
]
for name, extension, identifier, description, mime in office_imports:
    identifiers = next(utis for type_name, _, utis in types if type_name == name)
    if identifier not in identifiers:
        identifiers.append(identifier)
info = dict(CFBundleIdentifier='com.gaoseries.GaoWenJian', CFBundleName='搞文件', CFBundleDisplayName='搞文件', CFBundleExecutable='GaoWenJian', CFBundlePackageType='APPL', CFBundleShortVersionString=version, CFBundleVersion=build, CFBundleIconFile='AppIcon', CFBundleDevelopmentRegion='zh_CN', CFBundleLocalizations=['zh-Hans'], LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True, NSPrincipalClass='NSApplication', NSSupportsAutomaticTermination=False, NSHumanReadableCopyright='搞系列 · 搞文件')
info['CFBundleDocumentTypes'] = [dict(CFBundleTypeName=name,CFBundleTypeRole='Viewer' if name in ('Word','Excel','PPT') else 'Editor',LSHandlerRank='Alternate',CFBundleTypeExtensions=extensions,LSItemContentTypes=utis) for name,extensions,utis in types]
info['UTImportedTypeDeclarations'] = [dict(
    UTTypeIdentifier=identifier,
    UTTypeDescription=description,
    UTTypeConformsTo=['public.data', 'public.presentation' if name == 'PPT' else 'public.composite-content'],
    UTTypeTagSpecification={'public.filename-extension': [extension], 'public.mime-type': [mime]},
) for name, extension, identifier, description, mime in office_imports]
with open(destination,'wb') as f: plistlib.dump(info,f,sort_keys=False)
