'use strict';
// Presentation only: all device commands remain in app.js and protocol.js.
(()=>{
 const by=id=>document.getElementById(id);
 const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const names=['C','C♯','D','D♯','E','F','F♯','G','G♯','A','A♯','B'];
 const noteName=n=>names[n%12]+(Math.floor(n/12)-1);
 function scorePreview(){
  try{
   const notes=P.score(by('score').value),units=notes.reduce((n,x)=>n+x[1],0),bpm=Number(by('tempo').value)||80;
   by('score-summary').textContent=`${notes.length} 项 · 约 ${Math.round(units*30/bpm)} 秒`;
   by('score-preview').innerHTML=notes.map(([k,d])=>`<span class="score-note ${k?'':'rest'}" title="${k?'K'+k:'休止'} · ${d}个八分音符">${k?'K'+k:'休'}<small>×${d}</small></span>`).join('');
  }catch(e){by('score-summary').textContent='待检查';by('score-preview').innerHTML=`<span class="error-text">${esc(e.message)}</span>`;}
 }
 for(let i=1;i<=24;i++){
  const b=document.createElement('button');b.type='button';b.dataset.key=i;b.title=`选择K${i}`;
  b.addEventListener('click',()=>{by('key').value=i;showMapping();refreshMapping();});by('key-grid').appendChild(b);
 }
 function refreshMapping(){
  const k=Number(by('key').value);
  [...by('key-grid').children].forEach((b,i)=>{b.classList.toggle('selected',i+1===k);b.setAttribute('aria-pressed',String(i+1===k));b.innerHTML=`${i+1}<small>${noteName(mapping[i])}</small>`;});
 }
 let lastScore='',lastMap='',lastEvents='',lastState='';
 function refresh(){
  const state=by('state').textContent,isConnected=!!device?.gatt?.connected&&!!rx;
  if(lastState!==state){lastState=state;by('connection-label').textContent=isConnected?'设备已连接':'未连接设备';by('connection-dot').parentElement.classList.toggle('connected',isConnected);}
  by('mode-overview').textContent=by('rhythm').value==='1'?'节奏练习':'自由练习';by('tempo-overview').textContent=by('tempo').value||'—';
  const score=by('score').value+'|'+by('tempo').value;if(lastScore!==score){lastScore=score;scorePreview();}
  const map=mapping.join(',')+'|'+by('key').value;if(lastMap!==map){lastMap=map;refreshMapping();}
  const stamp=events.length+'|'+downloaded+'|'+(events.at(-1)?.time_ms||0)+'|'+by('recordstate').textContent;
  if(lastEvents!==stamp){lastEvents=stamp;renderTimeline();}
 }
 function renderTimeline(){
  if(!events.length){by('event-summary').textContent='等待记录';by('timeline').innerHTML='<span>暂无记录</span>';return;}
  const ons=events.filter(e=>e.type===1),end=Math.max(1,...events.map(e=>e.time_ms));
  by('event-summary').textContent=`${events.length} 事件 · ${(end/1000).toFixed(1)} 秒${downloaded?' · 已完整载入':' · 接收中'}`;
  const active=new Map(),bars=[];let low=Math.min(...events.map(e=>e.note)),high=Math.max(low+12,...events.map(e=>e.note));
  function bar(e,stop){const x=8+e.time_ms/end*984,w=Math.max(3,(stop-e.time_ms)/end*984),y=126-(e.note-low)/(high-low)*112;bars.push(`<rect x="${x}" y="${y}" width="${w}" height="6" rx="2" fill="#3264eb" opacity="${.35+e.velocity/127*.65}"/>`);}
  for(const e of events){if(e.type===1){if(active.has(e.note))bar(active.get(e.note),e.time_ms);active.set(e.note,e);}else if(active.has(e.note)){bar(active.get(e.note),e.time_ms);active.delete(e.note);}}
  active.forEach(e=>bar(e,end));
  by('timeline').innerHTML=`<svg viewBox="0 0 1000 145" role="img" aria-label="${ons.length}次起音，横轴为时间，纵轴为MIDI音高">${bars.join('')}</svg>`;
 }
 by('score').addEventListener('input',scorePreview);by('tempo').addEventListener('input',refresh);
 refresh();setInterval(refresh,350);
})();
