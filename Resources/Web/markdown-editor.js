/* Block-source editing deliberately avoids lossy HTML -> Markdown conversion. */
(function () {
  'use strict';
  const Core=window.GaoMDCore;
  const source=document.getElementById('source'), article=document.getElementById('document');
  const previewPane=document.getElementById('preview-pane'), outlineItems=document.getElementById('outline-items');
  const state={text:'',mode:'live',blocks:[],active:null,links:{},undo:[],redo:[],lastEdit:0,lastSelection:{start:0,end:0},renderID:0,lineEnding:'\n',initialized:false};
  const post=payload => { try { window.webkit.messageHandlers.gaoMD.postMessage(payload); } catch (_) {} };
  const normalized=value => value.replace(/\r\n?/g,'\n');
  const nativeNewlines=value => state.lineEnding==='\r\n'?normalized(value).replace(/\n/g,'\r\n'):normalized(value);
  const sourceOffset=index => nativeNewlines(source.value.slice(0,index)).length;
  const editorOffset=(raw,index) => normalized(raw.slice(0,index)).length;
  const currentSelection=() => {
    if(state.mode!=='live' && document.activeElement===source) return {start:sourceOffset(source.selectionStart),end:sourceOffset(source.selectionEnd)};
    if(state.active) { const a=state.active, value=a.editor.value; return {start:a.start+nativeNewlines(value.slice(0,a.editor.selectionStart)).length,end:a.start+nativeNewlines(value.slice(0,a.editor.selectionEnd)).length}; }
    return state.lastSelection;
  };
  const updateStatus=() => {
    document.getElementById('status').textContent=Core.wordCount(state.text).toLocaleString()+' 字 / 词 · '+state.text.split(/\r\n?|\n/).length.toLocaleString()+' 行';
    document.getElementById('mode-hint').textContent=state.mode==='live'?'点击段落编辑 · Esc 完成编辑':state.mode==='split'?'源码与预览分屏':'Markdown 源码';
  };
  function publish(value,forceBoundary=false) {
    if(value===state.text) return;
    const now=Date.now();
    if(forceBoundary || now-state.lastEdit>800) { state.undo.push({text:state.text,selection:state.lastSelection}); if(state.undo.length>100)state.undo.shift(); }
    state.lastEdit=now; state.redo=[]; state.text=value;
    updateStatus(); updateOutline(); post({kind:'change',text:state.text});
  }
  function updateOutline() {
    outlineItems.replaceChildren();
    const entries=Core.outline(state.text);
    for(const item of entries) {
      const button=document.createElement('button');button.textContent=item.title;button.title=item.title;button.style.paddingLeft=(8+(item.level-1)*11)+'px';
      button.addEventListener('click',()=>goToOffset(item.offset));outlineItems.append(button);
    }
    if(!entries.length) { const empty=document.createElement('div');empty.className='outline-empty';empty.textContent='使用 # 标题建立大纲';outlineItems.append(empty); }
  }
  let mermaidCounter=0;
  if(window.mermaid) window.mermaid.initialize({startOnLoad:false,securityLevel:'strict',suppressErrorRendering:true,theme:matchMedia('(prefers-color-scheme: dark)').matches?'dark':'default',fontFamily:'-apple-system, PingFang SC, sans-serif'});
  function attachmentURL(path) {
    if(/^data:image\//i.test(path))return path;
    if(/^[a-z][a-z\d+.-]*:/i.test(path) || path.startsWith('//'))return null;
    return 'gaomd://attachment/'+path.split('/').map(p=>encodeURIComponent(decodeURIComponentSafe(p))).join('/');
  }
  const decodeURIComponentSafe=value=>{try{return decodeURIComponent(value);}catch(_){return value;}};
  async function decorate(container,exporting=false) {
    for(const image of container.querySelectorAll('img')) {
      const original=image.getAttribute('src')||'', local=attachmentURL(original);
      if(local) { image.src=local;image.loading=exporting?'eager':'lazy';image.onerror=()=>{if(!image.isConnected)return;const error=document.createElement('span');error.className='image-placeholder';error.textContent='图片无法读取：'+(image.alt||original);image.replaceWith(error);}; }
      else { const placeholder=document.createElement('span');placeholder.className='image-placeholder';placeholder.textContent='离线模式：'+(image.alt||'外部图片');image.replaceWith(placeholder); }
    }
    for(const code of container.querySelectorAll('pre > code')) {
      if(code.classList.contains('language-mermaid') && window.mermaid) {
        const host=document.createElement('div');host.className='mermaid';code.parentElement.replaceWith(host);
        try { const result=await window.mermaid.render('gao-mermaid-'+(++mermaidCounter),code.textContent);host.innerHTML=result.svg; }
        catch(error) { host.className='mermaid-error';host.textContent='图示语法有误，请检查 Mermaid 源码。';host.title=error.message||String(error); }
      } else if(window.hljs) {
        try { const language=Array.from(code.classList).find(c=>c.startsWith('language-'))?.slice(9);if(!language || window.hljs.getLanguage(language))window.hljs.highlightElement(code); }
        catch(_) {}
      }
    }
    if(!exporting) {
      for(const checkbox of container.querySelectorAll('input[type=checkbox]')) {checkbox.disabled=state.mode==='source';checkbox.setAttribute('aria-label','切换任务完成状态');}
    }
  }
  function renderDocument() {
    state.renderID++; state.blocks=Core.blocks(state.text);state.links=Core.context(state.text);article.replaceChildren();
    for(let index=0;index<state.blocks.length;index++) {
      const block=state.blocks[index],host=document.createElement('div');host.className='md-block';host.dataset.index=String(index);host.dataset.offset=String(block.start);
      host.innerHTML=Core.render(block.raw,state.links);
      if(!host.innerHTML.trim())host.innerHTML='<div class="empty-block">'+(block.raw.length?'空白 / 引用定义（点击编辑）':'开始写作…')+'</div>';
      article.append(host);decorate(host);
    }
    if(state.mode==='live') { const add=document.createElement('button');add.className='md-new-block';add.textContent='+ 在末尾继续写作';add.onclick=()=>{finishEdit();const suffix=state.text && !/\n\s*\n$/.test(state.text)?state.lineEnding+state.lineEnding:'';publish(state.text+suffix,true);renderDocument();activateOffset(state.text.length);};article.append(add); }
    updateOutline();updateStatus();
  }
  function resize(editor) {editor.style.height='auto';editor.style.height=Math.max(42,editor.scrollHeight+4)+'px';}
  function commitInput() {
    const active=state.active;if(!active)return;
    const value=nativeNewlines(active.editor.value),previousEnd=active.end;
    publish(state.text.slice(0,active.start)+value+state.text.slice(previousEnd));active.end=active.start+value.length;state.lastSelection=currentSelection();resize(active.editor);
  }
  function finishEdit() {
    if(!state.active)return;
    commitInput();state.lastSelection=currentSelection();state.active=null;state.lastEdit=0;renderDocument();
  }
  function activateOffset(offset,selectionEnd=offset) {
    if(state.mode!=='live') {source.focus();const start=editorOffset(state.text,offset),end=editorOffset(state.text,selectionEnd);source.setSelectionRange(start,end);const line=normalized(state.text.slice(0,offset)).split('\n').length;source.scrollTop=Math.max(0,(line-5)*25);return;}
    let index=state.blocks.findIndex((b,i)=>offset>=b.start && (offset<b.end || i===state.blocks.length-1));if(index<0)index=state.blocks.length-1;
    const block=state.blocks[index],host=article.querySelector('.md-block[data-index="'+index+'"]');if(!host)return;
    host.replaceChildren();host.classList.add('editing');
    const label=document.createElement('div');label.className='block-edit-label';label.append(document.createTextNode('当前段落 · Markdown'));
    const done=document.createElement('button');done.textContent='完成（Esc）';done.onclick=finishEdit;label.append(done);
    const editor=document.createElement('textarea');editor.className='block-editor';editor.value=block.raw;editor.spellcheck=false;editor.setAttribute('aria-label','当前段落 Markdown 源码');
    host.append(label,editor);state.active={start:block.start,end:block.end,editor};state.lastEdit=0;
    editor.addEventListener('input',commitInput);editor.addEventListener('select',()=>state.lastSelection=currentSelection());editor.addEventListener('keyup',()=>state.lastSelection=currentSelection());
    editor.addEventListener('keydown',event=>{if(event.key==='Escape'){event.preventDefault();finishEdit();}else if(event.key==='Tab'){event.preventDefault();editor.setRangeText('    ',editor.selectionStart,editor.selectionEnd,'end');commitInput();}});
    editor.focus();editor.setSelectionRange(editorOffset(block.raw,Math.max(0,offset-block.start)),editorOffset(block.raw,Math.max(0,selectionEnd-block.start)));resize(editor);host.scrollIntoView({block:'nearest'});
  }
  function goToOffset(offset) {finishEdit();activateOffset(offset);}
  previewPane.addEventListener('mousedown',event=>{
    if(state.mode!=='live' || event.target.closest('a,input,button,textarea,summary'))return;
    const host=event.target.closest('.md-block');if(!host)return;
    event.preventDefault();const offset=Number(host.dataset.offset);finishEdit();activateOffset(offset);
  });
  previewPane.addEventListener('change',event=>{
    if(!event.target.matches('input[type=checkbox]'))return;
    const host=event.target.closest('.md-block');if(!host)return;
    const block=state.blocks[Number(host.dataset.index)],checkboxes=Array.from(host.querySelectorAll('input[type=checkbox]')),target=checkboxes.indexOf(event.target);let n=-1;
    const changed=block.raw.replace(/^(\s*(?:[-*+]|\d+[.)])\s+)\[([ xX])\]/gm,(whole,prefix,checked)=>++n===target?prefix+'['+(checked===' '?'x':' ')+']':whole);
    publish(state.text.slice(0,block.start)+changed+state.text.slice(block.end),true);source.value=state.text;renderDocument();
  });
  document.addEventListener('click',event=>{
    const link=event.target.closest('a');if(!link)return;event.preventDefault();
    const href=link.getAttribute('href')||'';
    if(href.startsWith('#')) {document.getElementById(decodeURIComponentSafe(href.slice(1)))?.scrollIntoView({block:'center'});}
    else post({kind:'link',href});
  });
  source.addEventListener('input',()=>{publish(nativeNewlines(source.value));state.lastSelection=currentSelection();clearTimeout(source._renderTimer);source._renderTimer=setTimeout(renderDocument,180);});
  source.addEventListener('select',()=>state.lastSelection=currentSelection());source.addEventListener('keyup',()=>state.lastSelection=currentSelection());
  source.addEventListener('scroll',()=>{if(state.mode==='split'){const ratio=source.scrollTop/Math.max(1,source.scrollHeight-source.clientHeight);previewPane.scrollTop=ratio*Math.max(0,previewPane.scrollHeight-previewPane.clientHeight);}});
  source.addEventListener('keydown',event=>{if(event.key==='Tab'){event.preventDefault();source.setRangeText('    ',source.selectionStart,source.selectionEnd,'end');publish(nativeNewlines(source.value));renderDocument();}});
  function replaceRange(start,end,insert,selectedStart,selectedEnd) {
    finishEdit();const value=state.text.slice(0,start)+insert+state.text.slice(end);publish(value,true);source.value=state.text;renderDocument();
    state.lastSelection={start:selectedStart??start+insert.length,end:selectedEnd??start+insert.length};activateOffset(state.lastSelection.start,state.lastSelection.end);
  }
  function insertSnippet(snippet) {const selection=currentSelection();replaceRange(selection.start,selection.end,nativeNewlines(snippet));}
  function format(kind) {
    const s=currentSelection(),selected=state.text.slice(s.start,s.end);const wrappers={bold:['**','**'],italic:['*','*'],strike:['~~','~~'],code:['`','`'],math:['$','$']};
    if(wrappers[kind]){const [a,b]=wrappers[kind];replaceRange(s.start,s.end,a+selected+b,s.start+a.length,s.start+a.length+selected.length);}
    else if(kind==='link'){replaceRange(s.start,s.end,'['+(selected||'链接文字')+'](地址)',s.start+(selected?selected.length+3:7),s.start+(selected?selected.length+5:9));}
  }
  function undo(redo=false) {
    finishEdit();const from=redo?state.redo:state.undo,to=redo?state.undo:state.redo;if(!from.length)return;
    to.push({text:state.text,selection:state.lastSelection});const previous=from.pop();state.text=previous.text;state.lastSelection=previous.selection||{start:0,end:0};state.lastEdit=0;source.value=state.text;renderDocument();post({kind:'change',text:state.text});activateOffset(state.lastSelection.start,state.lastSelection.end);
  }
  document.addEventListener('keydown',event=>{
    if(!(event.metaKey||event.ctrlKey))return;
    const key=event.key.toLowerCase();
    if(key==='z'){event.preventDefault();undo(event.shiftKey);}
    else if(key==='b'||key==='i'){event.preventDefault();format(key==='b'?'bold':'italic');}
  });
  function uploadImage(file) {
    if(file.size>25*1024*1024){post({kind:'error',message:'图片超过 25 MB，请使用插入图片按钮。'});return;}
    const reader=new FileReader();reader.onload=()=>post({kind:'pasteImage',data:reader.result,name:file.name||'粘贴图片.png'});reader.onerror=()=>post({kind:'error',message:'无法读取图片。'});reader.readAsDataURL(file);
  }
  document.addEventListener('paste',event=>{const file=Array.from(event.clipboardData?.files||[]).find(f=>f.type.startsWith('image/'));if(file){event.preventDefault();state.lastSelection=currentSelection();uploadImage(file);}});
  document.addEventListener('dragover',event=>{if(Array.from(event.dataTransfer?.items||[]).some(i=>i.kind==='file'))event.preventDefault();});
  document.addEventListener('drop',event=>{const files=Array.from(event.dataTransfer?.files||[]);if(files.length){event.preventDefault();state.lastSelection=currentSelection();const images=files.filter(f=>f.type.startsWith('image/'));if(images.length)images.forEach(uploadImage);else post({kind:'error',message:'Markdown 编辑区仅接受图片；其他文件请从工作区打开。'});}});
  async function prepareExport() {
    finishEdit();const host=document.createElement('article');host.className='markdown-body';host.style.cssText='position:fixed;left:-12000px;width:800px;top:0';host.innerHTML=Core.render(state.text,Core.context(state.text));document.body.append(host);
    await decorate(host,true);await document.fonts.ready;host.removeAttribute('style');const html=host.outerHTML;host.remove();return html;
  }
  window.gaoMarkdown={
    setDocument(text,mode,showOutline,refresh=false) {
      if(state.initialized && text===state.text){this.setMode(mode);this.setOutline(showOutline);if(refresh){finishEdit();renderDocument();}return;}
      clearTimeout(source._renderTimer);
      state.active=null;state.text=String(text);state.lineEnding=state.text.includes('\r\n')?'\r\n':'\n';state.undo=[];state.redo=[];state.lastSelection={start:0,end:0};state.lastEdit=0;state.initialized=true;source.value=state.text;this.setMode(mode);this.setOutline(showOutline);renderDocument();
    },
    setMode(mode) {if(mode===state.mode && state.initialized)return;clearTimeout(source._renderTimer);finishEdit();state.mode=['live','split','source'].includes(mode)?mode:'live';document.getElementById('workspace').className='mode-'+state.mode;source.value=state.text;renderDocument();},
    setOutline(visible){document.body.classList.toggle('outline-visible',!!visible);},
    getDocument(){commitInput();return state.text;},insertSnippet,format,undo,
    requestExport(kind){prepareExport().then(html=>post({kind:'exportReady',format:kind,html})).catch(error=>post({kind:'error',message:'导出失败：'+error.message}));},
    finishEdit,
    testState(){return {text:state.text,mode:state.mode,blockCount:state.blocks.length,active:!!state.active};},
    testEditBlock(index,value){finishEdit();const block=state.blocks[index];activateOffset(block.start);state.active.editor.value=value;commitInput();finishEdit();return state.text;}
  };
  updateStatus();post({kind:'ready'});
})();
