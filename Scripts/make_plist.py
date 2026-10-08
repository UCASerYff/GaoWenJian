#!/usr/bin/env python3
import plistlib, sys
destination, version, build = sys.argv[1:]
types = [
    ('Markdown', ['md','markdown'], ['net.daringfireball.markdown']),
    ('LaTeX', ['tex','bib','sty','cls'], ['public.text']),
    ('PDF', ['pdf'], ['com.adobe.pdf']),
    ('Word', ['docx'], ['org.openxmlformats.wordprocessingml.document']),
    ('Excel', ['xlsx'], ['org.openxmlformats.spreadsheetml.sheet']),
    ('PPT', ['pptx'], ['org.openxmlformats.presentationml.presentation']),
    ('文本与表格', ['txt','csv','tsv','rtf'], ['public.plain-text','public.comma-separated-values-text','public.rtf']),
]
info = dict(CFBundleIdentifier='com.gaoseries.GaoWenJian', CFBundleName='搞文件', CFBundleDisplayName='搞文件', CFBundleExecutable='GaoWenJian', CFBundlePackageType='APPL', CFBundleShortVersionString=version, CFBundleVersion=build, CFBundleIconFile='AppIcon', CFBundleDevelopmentRegion='zh_CN', CFBundleLocalizations=['zh-Hans'], LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True, NSPrincipalClass='NSApplication', NSSupportsAutomaticTermination=False, NSHumanReadableCopyright='搞系列 · 搞文件')
info['CFBundleDocumentTypes'] = [dict(CFBundleTypeName=name,CFBundleTypeRole='Editor',LSHandlerRank='Alternate',CFBundleTypeExtensions=extensions,LSItemContentTypes=utis) for name,extensions,utis in types]
with open(destination,'wb') as f: plistlib.dump(info,f,sort_keys=False)
