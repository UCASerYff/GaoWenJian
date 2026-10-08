/* Run with node Tests/MarkdownCoreTests.js. No network or document writes. */
const fs=require('fs'),vm=require('vm'),assert=require('assert'),path=require('path');
const root=path.resolve(__dirname,'../Resources/Web'),context=vm.createContext({console});
for(const resource of ['vendor/marked.js','vendor/katex.min.js','markdown-core.js'])vm.runInContext(fs.readFileSync(path.join(root,resource),'utf8'),context);
const Core=context.GaoMDCore;
const samples=[
  '', '# 标题\n\n正文 **加粗** $a^2$\n',
  '\r\n# CRLF\r\n\r\n正文\r\n',
  '---\r\ntitle: "原始 metadata"\r\nunknown: [a, b]\r\n---\r\n\r\n# 标题\r\n\r\n正文[^注]\r\n\r\n[^注]: 中文脚注\r\n',
  '未知 <custom-widget secret="保留">对象</custom-widget>\n\n<!-- COMMENT MUST SURVIVE -->\n',
  '```tex\n\\newcommand{\\custom}[1]{#1}\n# not a heading\n```\n\n## 真标题\n',
  '- [ ] 任务\n- [x] 完成\n  - 嵌套列表\n\n> 引用\n> 两行\n',
  '| A | B |\n| :--- | ---: |\n| 1 | 2 |\n\n$$\na^2 + b^2 = c^2\n$$\n',
  '[引用链接][ref]\n\n[ref]: relative-file.md "标题"\n',
  '\ufeff# BOM\n\n混合\r\n换行\n终点\r',
  '章节标题\n=======\n\n小标题\n-------\n',
  '前缀 $x$ 与脚注[^f] 在同一行\n\n[^f]: 脚注\n',
  '前缀 $$not-a-block$$ 后缀\n'
];
let assertions=0;
for(const sample of samples){
  const blocks=Core.blocks(sample);assert.strictEqual(blocks.map(b=>b.raw).join(''),sample);assertions++;
  let offset=0;for(const block of blocks){assert.strictEqual(block.start,offset);assert.strictEqual(sample.slice(block.start,block.end),block.raw);offset=block.end;assertions+=2;}assert.strictEqual(offset,sample.length);assertions++;
  // Editing one block changes only that raw range, including unknown constructs elsewhere.
  if(sample.length){const target=blocks[Math.floor(blocks.length/2)],edited=sample.slice(0,target.start)+'替换\n'+sample.slice(target.end);assert.strictEqual(edited.slice(0,target.start),sample.slice(0,target.start));assert(edited.endsWith(sample.slice(target.end)));assertions+=2;}
}
assert(Core.render('| A | B |\n|---|---|\n|1|2|').includes('<table>'));assertions++;
assert(Core.render('- [ ] 任务\n- [x] 完成').includes('type="checkbox"'));assertions++;
assert(Core.render('$x^2$').includes('class="katex"'));assertions++;
assert(Core.render('$$\nx^2\n$$').includes('katex-display'));assertions++;
assert(Core.render('正文[^f]\n\n[^f]: 说明').includes('class="footnote"'));assertions++;
assert.strictEqual(Core.outline(samples[5]).length,1);assertions++;
assert.strictEqual(Core.outline(samples[3])[0].title,'标题');assertions++;
assert.strictEqual(Core.outline(samples[10]).length,2);assertions++;
assert(Core.render('[引用链接][ref]',Core.context('[引用链接][ref]\n\n[ref]: local.md')).includes('href="local.md"'));assertions++;
console.log(`PASS: Markdown raw-source preservation, block edit boundaries, CRLF, unknown HTML/macros, math, tables, tasks, footnotes, outline and reference links (${assertions} assertions).`);
