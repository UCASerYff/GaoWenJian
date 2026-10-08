# 搞文件 V1.00 第三方许可与源码资料

本目录适用于随应用原样分发的 Tectonic 0.16.9，以及离线 TeX 资源缓存。搞文件未修改这些上游文件。组件的版权和许可属于原作者；不能将整个 TeX 缓存一概标为 MIT 或 LPPL。本说明和本目录须随应用及安装包保留。

## 可核验清单

- `BundledResources-SHA256.tsv`：实际 Tectonic 可执行文件及全部缓存文件的路径、大小、SHA256。
- `TeXCache-Text-SHA256.tsv`、`TeXCache-Copyright-Notices.txt`：缓存文本文件校验值及原始版权、许可声明。
- `RustCrates-Inventory.tsv` / `.json`：Tectonic 0.16.9 官方 Cargo.lock 的 423 个 registry 依赖版本、许可、作者、官方源码地址及锁定 SHA256。这是含开发和其他平台依赖的保守超集，不表示 423 个依赖都链接进 macOS 可执行文件。
- `RustCrates/`：精确版本原包的 LICENSE、COPYING、COPYRIGHT、NOTICE 等原文；`RustCrates-Copyright-Headers.txt` 保留源码版权声明。所有下载 crate 均通过 Cargo.lock SHA256 校验；MIT/Apache 等依赖的完整源码下载包已清理，原始地址仍在清单中。

## 引擎及其静态依赖

| 组件 | 随附许可/声明 | 官方来源 |
| --- | --- | --- |
| Tectonic 0.16.9、XeTeX 派生引擎 | `Tectonic-MIT.txt`、`Tectonic-Upstream-Notices/`、`Tectonic-Upstream-Copyright-Headers.txt`；引擎内部文件各自保留版权 | [精确发行版本](https://github.com/tectonic-typesetting/tectonic/releases/tag/tectonic%400.16.9) |
| FreeType | `FreeType-FTL.txt`，采用 FreeType License 选项；使用和感谢 FreeType 团队的成果 | [FreeType 许可](https://freetype.org/license.html) |
| HarfBuzz | `HarfBuzz-Exact/` 为 Tectonic 精确子模块 `894a1f72ee93a1fd8dc1d9218cb3fd8f048be29a` 的版权/许可；另附 `HarfBuzz-COPYING.txt` | [精确上游源码](https://github.com/harfbuzz/harfbuzz/tree/894a1f72ee93a1fd8dc1d9218cb3fd8f048be29a) |
| Graphite2 1.3.14 | `Graphite2-COPYING.txt` 提供 MPL / LGPL / GPL 替代许可；本次采用 Mozilla Public License 选项，随附 `MPL-2.0.txt`、历史 `MPL-1.1.txt` 和完整对应源。`Graphite2-LICENSE.txt` 保留上游随包 LGPL 文本，未删除原声明 | [精确上游源码](https://github.com/silnrsi/graphite/tree/92f59dcc52f73ce747f1cdc831579ed2546884aa) |
| ICU、Fontconfig、Expat、libpng、Brotli、zlib | 各自同名 LICENSE/COPYING 文件；上游版权保留，许可分别依原文 | [ICU](https://github.com/unicode-org/icu)、[Fontconfig](https://gitlab.freedesktop.org/fontconfig/fontconfig)、[Expat](https://github.com/libexpat/libexpat)、[libpng](https://github.com/pnggroup/libpng)、[Brotli](https://github.com/google/brotli)、[zlib](https://zlib.net/zlib_license.html) |
| Rust 依赖 | `RustCrates/` 和逐版本清单，MIT/Apache 双许可采用许可允许的选项；Unicode/ISC/BSD 等附加条件依原文 | [crates.io](https://crates.io/)；逐包 immutable 下载链接见清单 |

macOS 系统框架不属于本目录第三方再分发源码。LibreOffice 是用户本机可选工具，应用未内嵌或重新分发其程序。

## 离线 TeX 文件与字体

缓存 bundle 指纹为 `6ffe055852f8faf66c0acbe1a7fb27f87b869a90bad1204f3bf4d9683f597c7c`。所有源文件名、注释与版权保持上游原样；只选取所需文件，并未改名为本产品作品。`Sources/AsDistributed-TeX-source.zip` 保留实际随附的 257 个文本源文件，包括较旧版本，不能用最新下载包替代这些实际版本的许可。

| 类别 | 许可及保留材料 |
| --- | --- |
| LaTeX base、graphics、l3kernel/l3packages/l3backend、fontspec、CTeX/xeCJK、atbegshi/atveryend 等宏与支持文件 | 依各文件头通常为 LPPL 1.3c 或 later；随附 `LPPL-1.3c.txt`。完整原作和 `.dtx` / `.ins` 获取路径见下文；缓存不是完整 TeX Live 发行版 |
| CJKfntef.sty 4.8.5 | GPL 2 或 later；随附 GPL 全文及 CJK 4.8.5 完整官方源包，源包中该文件已与缓存逐字节核对 |
| hyph-utf8 多语言断词表 | 逐文件许可不同。`hyph-cs`、`hyph-id`、缓存版本 `hyph-sk` 为 GPL2 或 later；`hyph-hu`、`hyph-lv` 提供 GPL/MPL/LGPL 等替代项，本分发选 GPL2；`hyph-mk` 按文件头 GPL；`hyph-hy` 为 LGPL3，并附 Ruby 生成源。其余 MIT、LPPL、BSD 和作者自有宽松声明均完整保留，不能统一重授权 |
| Latin Modern 字体 | GUST Font License 1.0，基于 LPPL 1.3c 或 later；随附 `GUST-FONT-LICENSE.txt`、作者原始 `LatinModern-README.txt` 和完整 CTAN `lm.zip` 发布包。缓存 9 个 OTF 均与完整包逐字节一致；没有修改或替换字体名 |
| AMS 字体宏、Computer Modern / Blue Sky 字体 | AMS 宏依原文允许未修改复制，修改需改名；字体依上游授权/公共领域声明，原始声明不变。来源见下文 |
| Adobe glyphlist、Unicode 数据及其派生字形表 | Apache2、Unicode 数据许可及各原文；随附 `Apache-2.0.txt`、`Unicode-License.txt`。保留所有缓存版本源文本及声明 |
| texglyphlist.txt (LCDF Typetools 2.95) | 随附 `LCDF-2.95/` 原版权/许可及完整 2.95 源包，避免仅提供表格而缺少 GPL 源码资料 |
| 德语实验断词、Plain TeX 断词及其他小型支持文件 | 分别按原始 MIT、作者宽松分发或未修改/改名条件；实际原文见 `TeXCache-Copyright-Notices.txt` 及源 ZIP |

## 完整原作与对应源码获取

`Sources/` 保留 CJK、hyph-utf8、Graphite2、LCDF 完整源码，Latin Modern 完整发布包及 Tectonic 精确版本源码。源归档保持官方原始字节，没有构建目录或用户文档。`SOURCE-AVAILABILITY.md` 记录下载地址、版本差异和重建资料；`SourceArchives-SHA256.tsv` 可核验所有归档。尤其 LGPL 的 Armenian 表生成脚本已保留在 hyph-utf8 原包，不能只分发生成表。旧 `hyph-sk` 的 GPL 源在实际源 ZIP 内完整保留，最新 CTAN 原包已将其许可改为 MIT，不将该新许可套用到旧缓存。

LPPL 完整 Work / 原始源可从以下长期官方入口获取；这是未修改子集分发所附的完整原作获取信息，版本以实际文件头为准：

- [LaTeX base](https://ctan.org/pkg/latex-base)、[LaTeX 官方源仓库及历史 release](https://github.com/latex3/latex2e)、[graphics](https://ctan.org/pkg/graphics)。缓存内核为 2021 年版本，graphics 为 2021/03/04。
- [l3kernel](https://ctan.org/pkg/l3kernel)、[l3packages](https://ctan.org/pkg/l3packages)、[l3backend](https://ctan.org/pkg/l3backend)、[LaTeX3 历史源仓库](https://github.com/latex3/latex3)。缓存 l3kernel 日期 2022-02-24。
- [fontspec](https://ctan.org/pkg/fontspec)、[fontspec 历史源仓库](https://github.com/latex3/fontspec)，缓存为 2.8a / 2022-01-15。
- [CTeX](https://ctan.org/pkg/ctex)、[xeCJK](https://ctan.org/pkg/xecjk)、[CTeX 历史源仓库](https://github.com/CTeX-org/ctex-kit)，缓存 CTeX 为 2.5.8，xeCJK 源 Id 日期 2021-12-12。
- [atbegshi](https://ctan.org/pkg/atbegshi)、[atveryend](https://ctan.org/pkg/atveryend)、[AMSFonts](https://ctan.org/pkg/amsfonts)、[AMS-LaTeX](https://ctan.org/pkg/amsmath)、[Computer Modern](https://ctan.org/pkg/cm)、[Blue Sky 字体公开分发](https://ctan.org/pkg/cmps)。
- [hyph-utf8](https://ctan.org/pkg/hyph-utf8)、[断词项目官方源](https://github.com/hyphenation/tex-hyphen)、[德语实验断词](https://ctan.org/pkg/dehyph-exptl)。
- [Latin Modern 完整包](https://ctan.org/pkg/lm)、[作者官方页面](https://www.gust.org.pl/projects/e-foundry/latin-modern)。随附原作者 README 另列 MetaType1 字体生成源信息；不声称 CTAN 发布 ZIP 含 MetaType1 工具或全部生成脚本。
- [TeX Live 许可](https://tug.org/texlive/copying.html)、[TeX Live 历史完整发行版](https://tug.org/historic/systems/texlive/)、[Tectonic 官方 bundle 源配置](https://github.com/tectonic-typesetting/tectonic-texlive-bundles)。

本目录只记录开发时取得的开源许可资料；应用运行和本地编译无需为读取这些声明联网。
