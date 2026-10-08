# 对应源码、出处与构建说明

归档均按官方原包未修改保存，日期 2026-10-08。校验值见 `SourceArchives-SHA256.tsv`。获取过程中没有上传用户文件、凭据或个人数据。

| 本地归档 | 官方下载地址 | 用途/版本 |
| --- | --- | --- |
| `Sources/Tectonic-0.16.9-source.tar.gz` | https://codeload.github.com/tectonic-typesetting/tectonic/tar.gz/refs/tags/tectonic%400.16.9 | 可执行文件的精确版本引擎源；附 Cargo.lock 和平台构建配置 |
| `Sources/CJK-4.8.5-source.tar.gz` | https://download.savannah.nongnu.org/releases/cjk/cjk-4.8.5.tar.gz | CJK GPL 对应完整源码；texinput/CJKfntef.sty 与缓存一致 |
| `Sources/hyph-utf8-upstream.zip` | https://mirrors.ctan.org/language/hyph-utf8.zip | 完整断词项目及生成源；包含 Armenian 的 `source/languages/hy/generate_patterns_hy.rb` |
| `Sources/AsDistributed-TeX-source.zip` | 实际未修改资源文件的逐字节副本 | 全部 257 个缓存文本源；保留旧 GPL hyph-sk 原许可；清单记录原始缓存校验值 |
| `Sources/Graphite2-1.3.14-source.tar.gz` | https://codeload.github.com/silnrsi/graphite/tar.gz/92f59dcc52f73ce747f1cdc831579ed2546884aa | Graphite2 MPL 完整对应源、构建脚本、原始版权 |
| `Sources/LatinModern-upstream.zip` | https://mirrors.ctan.org/fonts/lm.zip | Latin Modern 2.005 原始完整 CTAN 发布包，包含作者 README、MANIFEST、GUST 许可及全部发布字体；缓存 OTF 与之相同 |
| `Sources/lcdf-typetools-2.95-source.tar.gz` | https://www.lcdf.org/type/lcdf-typetools-2.95.tar.gz | texglyphlist 2.95 的完整上游 GPL 源码 |

hyph-cs、hyph-hu、hyph-hy、hyph-id、hyph-lv、hyph-mk 已与完整 CTAN 原包逐字节一致核对。hyph-sk 当前 CTAN 包只有许可头更新为 MIT；本次仍使用缓存所带 GPL2+，并在实际源 ZIP 保留完整原文件。其余表版本/作者见逐文件声明，未宣称当前 CTAN 原包等于所有缓存旧版。

Tectonic 官方平台依赖使用 vcpkg commit `a62ce77d56ee07513b4b67de1ec2daeaebfae51a`。本目录的 `Graphite2-portfile.cmake`、`Graphite2-vcpkg.json`、`Graphite2-vcpkg-disable-tests.patch` 来自该精确版本，保留其上游构建改动：禁用测试，以及静态库构建的 `GRAPHITE2_STATIC` 配置。搞文件未再修改该库。

Tectonic 源归档的 Git 子模块内容应按以下固定提交获取，不应把 GitHub 顶层 tarball 误认为含所有子模块：

- HarfBuzz：`894a1f72ee93a1fd8dc1d9218cb3fd8f048be29a`，https://github.com/harfbuzz/harfbuzz/tree/894a1f72ee93a1fd8dc1d9218cb3fd8f048be29a 。精确版本版权已随附 `HarfBuzz-Exact/`，它为宽松许可，不要求随 App 保存完整源码归档。
- 引擎参考生成源仓库：`70dbe0603c4b27f17b3b4dcb25a85e9da3050fe9`，https://github.com/tectonic-typesetting/tectonic-staging/tree/70dbe0603c4b27f17b3b4dcb25a85e9da3050fe9 。主引擎用于构建的 C/C++ / Rust 源已在精确版本归档内。
- Rust 完整源码逐包不可变下载链接和官方 checksum 见 `RustCrates-Inventory.tsv`；下载全部校验通过后，仅保留许可、NOTICE、COPYRIGHT 和作者/版本清单。

其他 LPPL 原作完整源获取信息见 `README.md` 的官方 CTAN、历史源仓库和 TeX Live 历史发行入口。产品发行应将本目录随程序保留，尤其本地对应源码归档不可遗漏或替换为仅网络链接。
