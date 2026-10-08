/* 搞文件 Markdown core. Raw source is always authoritative. */
(function (global) {
  'use strict';
  const escapeHTML = value => String(value).replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
  const footnoteID = key => 'fn-' + Array.from(String(key)).map(c => c.codePointAt(0).toString(16)).join('-');
  const mathHTML = (text, display) => {
    try { return global.katex.renderToString(text, {displayMode:display, throwOnError:false, trust:false, strict:'ignore'}); }
    catch (_) { return '<code class="math-error">' + escapeHTML(text) + '</code>'; }
  };
  if (global.marked) {
    global.marked.use({gfm:true, breaks:false, extensions:[
      {
        name:'gaoMathBlock', level:'block', start:src => { const cap=/(?:^|\n) {0,3}(?:\$\$|\\\[)/.exec(src);return cap?cap.index+(cap[0][0]==='\n'?1:0):undefined; },
        tokenizer(src) {
          const cap = /^ {0,3}\$\$[ \t]*(?:\n)?([\s\S]*?)\$\$[ \t]*(?:\n|$)/.exec(src) || /^ {0,3}\\\[[ \t]*(?:\n)?([\s\S]*?)\\\][ \t]*(?:\n|$)/.exec(src);
          if (cap) return {type:'gaoMathBlock', raw:cap[0], text:cap[1].trim()};
        }, renderer:token => '<div class="math-block">' + mathHTML(token.text, true) + '</div>'
      },
      {
        name:'gaoMathInline', level:'inline', start:src => { const a=src.indexOf('$'), b=src.indexOf('\\('); return a<0?b:b<0?a:Math.min(a,b); },
        tokenizer(src) {
          const cap = /^\$(?!\$)([^\n$]+?)\$(?!\$)/.exec(src) || /^\\\(([^\n]*?)\\\)/.exec(src);
          if (cap) return {type:'gaoMathInline', raw:cap[0], text:cap[1]};
        }, renderer:token => mathHTML(token.text, false)
      },
      {
        name:'gaoFootnoteDefinition', level:'block', start:src => { const cap=/(?:^|\n)\[\^[^\]\n]+\]:/.exec(src);return cap?cap.index+(cap[0][0]==='\n'?1:0):undefined; },
        tokenizer(src) {
          const cap = /^\[\^([^\]\n]+)\]:[ \t]*([^\n]*(?:\n(?: {2,}|\t)[^\n]*)*)(?:\n|$)/.exec(src);
          if (cap) return {type:'gaoFootnoteDefinition', raw:cap[0], key:cap[1], text:cap[2].replace(/\n(?: {2,}|\t)/g,'\n')};
        }, renderer:token => '<aside class="footnote" id="' + footnoteID(token.key) + '"><span class="footnote-key">' + escapeHTML(token.key) + '</span>' + global.marked.parse(token.text) + '</aside>'
      },
      {
        name:'gaoFootnoteReference', level:'inline', start:src => src.indexOf('[^'),
        tokenizer(src) { const cap=/^\[\^([^\]\n]+)\]/.exec(src); if(cap) return {type:'gaoFootnoteReference',raw:cap[0],key:cap[1]}; },
        renderer:token => '<sup><a class="footnote-reference" href="#' + footnoteID(token.key) + '">' + escapeHTML(token.key) + '</a></sup>'
      },
      {
        name:'gaoFrontMatter', level:'block',
        tokenizer(src) { const cap=/^---[ \t]*\n([\s\S]*?)\n(?:---|\.\.\.)[ \t]*(?:\n|$)/.exec(src); if(cap) return {type:'gaoFrontMatter',raw:cap[0],text:cap[1]}; },
        renderer:token => '<details class="frontmatter"><summary>文档元数据</summary><pre>' + escapeHTML(token.text) + '</pre></details>'
      }
    ]});
  }

  // Map Marked's normalized CRLF offsets back into the original string, preserving every byte-equivalent character.
  function normalizationMap(source) {
    let normalized='', positions=[0];
    for (let i=0;i<source.length;i++) {
      if(source[i]==='\r') { if(source[i+1]==='\n') i++; normalized+='\n'; }
      else normalized+=source[i];
      positions.push(i+1);
    }
    return {normalized,positions};
  }
  function blocks(source) {
    if (!source.length) return [{start:0,end:0,raw:'',type:'paragraph'}];
    const mapped=normalizationMap(source);
    let tokens;
    try { tokens=global.marked.lexer(mapped.normalized); }
    catch (_) { return [{start:0,end:source.length,raw:source,type:'paragraph'}]; }
    // The safe fallback handles any extension whose lexer does not expose a complete raw token stream.
    if(tokens.map(t=>t.raw||'').join('')!==mapped.normalized) return [{start:0,end:source.length,raw:source,type:'paragraph'}];
    const output=[]; let offset=0;
    for(const token of tokens) {
      const start=mapped.positions[offset]; offset+=token.raw.length; const end=mapped.positions[offset];
      if(token.type==='space' && output.length) { output[output.length-1].end=end; output[output.length-1].raw=source.slice(output[output.length-1].start,end); }
      else if(token.type==='space' && !output.length) output.push({start,end,raw:source.slice(start,end),type:'space'});
      else output.push({start,end,raw:source.slice(start,end),type:token.type});
    }
    return output.length?output:[{start:0,end:source.length,raw:source,type:'paragraph'}];
  }
  function context(source) {
    try { return global.marked.lexer(source).links || {}; } catch(_) { return {}; }
  }
  function render(source,links) {
    try {
      // Inline reference resolution happens during lexing, so supply document-wide definitions before lexing a block.
      const definitions=links?Object.entries(links).map(([key,value])=>'['+key.replace(/\]/g,'\\]')+']: <'+value.href.replace(/>/g,'%3E')+'>'+(value.title?' "'+value.title.replace(/"/g,'\\"')+'"':'')).join('\n'):'';
      const tokens=global.marked.lexer(source+(definitions?'\n\n'+definitions:''));
      const html=global.marked.parser(tokens);
      return global.DOMPurify ? global.DOMPurify.sanitize(html, {FORBID_TAGS:['script','style','iframe','object','embed','form','button','video','audio'],FORBID_ATTR:['srcdoc'],ADD_ATTR:['target']}) : html;
    } catch (error) { return '<pre class="render-error">' + escapeHTML(source) + '</pre>'; }
  }
  function outline(source) {
    const result=[];
    // The lexer reliably excludes headings that occur inside fenced code or metadata.
    for(const block of blocks(source)) {
      if(block.type!=='heading') continue;
      const match=/^ {0,3}(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*(?:\r?\n|$)/.exec(block.raw);
      if(match) result.push({level:match[1].length,title:match[2].replace(/[*_`]/g,''),offset:block.start});
      else { const lines=block.raw.trim().split(/\r?\n/); if(lines.length>1) result.push({level:/^=/.test(lines[1])?1:2,title:lines[0],offset:block.start}); }
    }
    return result;
  }
  function wordCount(source) {
    const han=(source.match(/[\u3400-\u9fff]/g)||[]).length;
    const other=source.replace(/[\u3400-\u9fff]/g,' ').match(/[\p{L}\p{N}]+(?:['’-][\p{L}\p{N}]+)*/gu)||[];
    return han+other.length;
  }
  global.GaoMDCore={escapeHTML,blocks,render,context,outline,wordCount,normalizationMap};
})(typeof window!=='undefined'?window:globalThis);
