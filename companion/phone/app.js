'use strict';
const P=InstrumentProtocol,$=id=>document.getElementById(id);
let device,rx,tx,pending=null,dumpWait=null,events=[],downloaded=false,replaying=false,operation=false;
const mapping=Array.from({length:24},(_,i)=>60+i);
const log=t=>{$('log').textContent=t+'\n'+$('log').textContent.slice(0,4000);};
const pause=ms=>new Promise(r=>setTimeout(r,ms));
function finishPending(error){if(pending){const p=pending;pending=null;clearTimeout(p.timer);p.reject(error);}}
function finishDump(error){if(dumpWait){const p=dumpWait;dumpWait=null;clearTimeout(p.timer);error?p.reject(error):p.resolve();}}
function resetDecoder(){decoder.bytes=[];}
function disconnected(){rx=null;tx=null;replaying=false;resetDecoder();
 const error=Error('蓝牙已断开；点击连接蓝牙重连后重新取回记录。已完整取回的文件仍可保存。');
 finishPending(error);finishDump(error);$('state').textContent='已断开，点击连接蓝牙重连';log(error.message);}
const decoder=new P.Decoder(p=>{
 if(p[1]===0xf0){log(`FPGA ${p[2].toString(16)} 状态=${p[3]} 数据=${p[4]+256*p[5]}`);
  if(pending&&pending.cmd===p[2]){const wait=pending;pending=null;clearTimeout(wait.timer);
   p[3]===0?wait.resolve(p):wait.reject(Error(['成功','不支持的指令','参数无效或音符重复','设备忙或未进入SONG','曲谱未完成/未录入'][p[3]]||'FPGA错误'));}}
 if(p[1]===0xe0&&dumpWait){const e=P.event(p);events.push(e);$('recordstate').textContent=`正在取回：${events.length}个事件，请等待完成`;}
 if(p[1]===0xe1&&dumpWait){downloaded=(p[2]+256*p[3]===events.length)&&events.every((e,i)=>e.index===i);
  $('recordstate').textContent=`取回结束：${events.length}事件，${downloaded?'数量完整':'数量不符'}${p[4]?'；录制溢出，尾部可能不完整':''}`;
  finishDump(downloaded?null:Error('记录不完整，请重新取回'));}
});
function connected(){if(!device?.gatt?.connected||!rx)throw Error('蓝牙未连接，请点击连接蓝牙');}
async function attach(){
 rx=null;tx=null;resetDecoder();
 const server=await device.gatt.connect();
 const service=await server.getPrimaryService('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
 rx=await service.getCharacteristic('6e400002-b5a3-f393-e0a9-e50e24dcca9e');
 tx=await service.getCharacteristic('6e400003-b5a3-f393-e0a9-e50e24dcca9e');
 tx.addEventListener('characteristicvaluechanged',notification);
 await tx.startNotifications();$('state').textContent='已连接 '+device.name;
}
function notification(e){const v=e.target.value;decoder.feed(new Uint8Array(v.buffer,v.byteOffset,v.byteLength));}
async function command(cmd,a=0,b=0){connected();if(pending)throw Error('上一条指令仍在等待回复');
 const response=new Promise((resolve,reject)=>{pending={cmd,resolve,reject,timer:setTimeout(()=>finishPending(Error('FPGA回复超时；检查C19回传线和烧录版本')),4000)};});
 // Attach rejection handling before a GATT write can fail or disconnect.
 const writing=Promise.resolve().then(()=>rx.writeValueWithResponse(P.frame(cmd,a,b))).catch(e=>finishPending(e));
 const result=await response;await writing;return result;
}
function action(id,fn){$(id).onclick=async()=>{if(operation){log('请等待当前操作结束');return;}operation=true;
 try{await fn();}catch(e){log(e.message);}finally{operation=false;}};}
action('connect',async()=>{
 if(!navigator.bluetooth)throw Error('请使用Android Chrome并通过HTTPS打开网页');
 if(!device){device=await navigator.bluetooth.requestDevice({filters:[{services:['6e400001-b5a3-f393-e0a9-e50e24dcca9e']}]});
 device.addEventListener('gattserverdisconnected',disconnected);}
 if(device.gatt.connected&&tx)tx.removeEventListener('characteristicvaluechanged',notification);
 await attach();await command(0xf0);log('连接及FPGA回传正常');
});
async function settings(){const mode=Number($('rhythm').value),tempo=Number($('tempo').value);
 if(![0,1].includes(mode)||!Number.isInteger(tempo)||tempo<40||tempo>200)throw Error('模式或BPM无效');
 await command(0xb1,mode);await command(0xb2,tempo);
 log(`已确认：${mode?'节奏练习':'自由练习'}，${tempo} BPM`);
}
action('settings',settings);
action('play',async()=>{await settings();await command(0xb0,Number($('song').value));log('曲目已开始');});
action('upload',async()=>{const notes=P.score($('score').value);
 // Stop a running guide before replacing its score. C0 still guards RAM writes.
 await command(0xb3);await command(0xc0,notes.length);
 try{for(const [k,d] of notes)await command(0xc1,k,d);await command(0xc2);}
 catch(e){if(device?.gatt?.connected)try{await command(0xc3);}catch{}throw e;}
 $('song').value='3';await settings();
 try{await command(0xb0,3);log('第三曲槽下载完成，已开始指引；节奏模式先等待四拍预备');}
 catch(e){log('曲谱已保存；请切到SONG页，再点开始 / 重练。'+e.message);}
});
$('scorefile').onchange=async e=>{if(e.target.files[0])$('score').value=await e.target.files[0].text();};
action('fetchscore',async()=>{const url=new URL($('scoreurl').value);if(url.protocol!=='https:')throw Error('曲谱地址须为HTTPS');
 const result=await fetch(url);if(!result.ok)throw Error('曲谱服务器返回 '+result.status);
 const text=await result.text();P.score(text);$('score').value=text;log('已读取，检查后点击发送曲谱');});
function showMapping(){const k=Number($('key').value);if(Number.isInteger(k)&&k>=1&&k<=24)$('note').value=mapping[k-1];}
$('key').onchange=showMapping;
action('map',async()=>{const k=Number($('key').value),n=Number($('note').value);
 if(!Number.isInteger(k)||k<1||k>24||!Number.isInteger(n)||n<0||n>127)throw Error('键号或音符无效');
 await command(0xd0,k,n);mapping[k-1]=n;log(`K${k} 已设为MIDI ${n}`);});
action('resetmap',async()=>{await command(0xd1);for(let i=0;i<24;i++)mapping[i]=60+i;showMapping();log('已恢复默认：K1=60至K24=83');});
action('record',async()=>{await command(0xe0);$('recordstate').textContent='正在录制，结束时松开琴键再点击停止';});
action('stop',async()=>{const p=await command(0xe1);$('recordstate').textContent=`已停止，设备有${p[4]+256*p[5]}个事件；点击取回记录`;});
action('dump',async()=>{connected();events=[];downloaded=false;
 const completion=new Promise((resolve,reject)=>{dumpWait={resolve,reject,timer:setTimeout(()=>finishDump(Error('取回超时，请重连后重试')),60000)};});
 // Listen for completion immediately, including disconnects during E2 acknowledgement.
 const acknowledged=command(0xe2).catch(e=>{finishDump(e);throw e;});
 await Promise.all([acknowledged,completion]);
});
action('query',()=>command(0xf0));
function save(data,type,name){const url=URL.createObjectURL(new Blob([data],{type}));const a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
// File export is entirely local and does not require a BLE connection.
action('json',()=>{if(!downloaded)throw Error('请先完整取回记录');save(JSON.stringify({format:'fpga-events-v1',events},null,2),'application/json','performance.json');});
action('midi',()=>{if(!downloaded)throw Error('请先完整取回记录');save(P.midi(events),'audio/midi','performance.mid');});
$('recordfile').onchange=async e=>{if(operation){log('请等待当前操作结束');return;}try{if(!e.target.files[0])return;
 const d=JSON.parse(await e.target.files[0].text());P.midi(d.events);events=d.events;downloaded=true;$('recordstate').textContent=`已载入${events.length}个事件`;}
 catch(e){log('文件无效：'+e.message);}};
action('replay',async()=>{connected();if(!downloaded)throw Error('请先取回或导入记录');replaying=true;let previous=0;const held=new Set();
 try{for(const e of events){let delay=e.time_ms-previous;
  while(delay>0&&replaying){const d=Math.min(delay,50);await pause(d);delay-=d;}if(!replaying)break;
  connected();await rx.writeValueWithResponse(P.frame(e.type===1?0x90:0x80,e.note,e.type===1?e.velocity:0));
  if(e.type===1)held.add(e.note);else held.delete(e.note);previous=e.time_ms;
 }}finally{replaying=false;for(const note of held){if(!device?.gatt?.connected||!rx)break;try{await rx.writeValueWithResponse(P.frame(0x80,note,0));}catch{break;}}}
});
$('cancel').onclick=()=>replaying=false;
showMapping();
