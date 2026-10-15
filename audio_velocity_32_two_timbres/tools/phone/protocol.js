// Browser + Node shared codec. NUS notification boundaries are NOT packets.
(function(root){
const frame=(cmd,a=0,b=0)=>Uint8Array.of(0xA5,cmd,a,b,0xA5^cmd^a^b);
class Decoder{
 constructor(receive){this.bytes=[];this.receive=receive;}
 feed(data){this.bytes.push(...data);while(this.bytes.length){
 if(this.bytes[0]!==0xA6){this.bytes.shift();continue;}
 if(this.bytes.length<12)return;
 const p=this.bytes.slice(0,12);
 if(p.reduce((a,b)=>a^b,0)!==0 || ![0xF0,0xE0,0xE1].includes(p[1])){this.bytes.shift();continue;}
 this.bytes.splice(0,12);this.receive(p);
 }}
}
function score(text){
 const lines=text.split(/\r?\n/).map(x=>x.split('#')[0].trim()).filter(Boolean);
 if(!lines.length || lines.length>128)throw Error('曲谱必须包含1～128项');
 return lines.map((line,i)=>{
 const parts=line.split(/[\s,]+/);if(parts.length!==2)throw Error(`第${i+1}行应为“键号 时值”`);
 const k=Number(parts[0]),d=Number(parts[1]);
 if(!Number.isInteger(k)||k<0||k>24||k===6||!Number.isInteger(d)||d<1||d>32)throw Error(`第${i+1}行超出范围或使用了K6`);
 return [k,d];
 });
}
function event(p){return {type:p[2],note:p[3],velocity:p[4],time_ms:(p[5]+p[6]*256+p[7]*65536+p[8]*16777216)>>>0,index:p[9]+p[10]*256};}
function midi(events){
 if(!Array.isArray(events)||events.length>512)throw Error('录制事件须为最多512项的数组');
 let body=[],last=0;
 function variable(n){let a=[n&127];while((n=Math.floor(n/128))>0)a.unshift((n&127)|128);return a;}
 // 1000 ticks per quarter, 1 second per quarter => 1 tick per ms.
 body.push(0,0xff,0x51,3,0x0f,0x42,0x40);
 const active=new Set();
 for(const e of events){
 if(![1,2].includes(e.type)||!Number.isInteger(e.note)||e.note<0||e.note>127||!Number.isInteger(e.velocity)||e.velocity<0||e.velocity>127||!Number.isInteger(e.time_ms)||e.time_ms<last||e.time_ms>0xffffffff)throw Error('录制事件无效或时间倒退');
 body.push(...variable(e.time_ms-last),e.type===1 ? 0x90:0x80,e.note,e.type===1?e.velocity:0);
 if(e.type===1)active.add(e.note);else active.delete(e.note);last=e.time_ms;
 }
 for(const note of active)body.push(0,0x80,note,0);
 body.push(0,0xff,0x2f,0);
 const n=body.length;
 return Uint8Array.from([77,84,104,100,0,0,0,6,0,0,0,1,3,232,77,84,114,107,(n>>>24)&255,(n>>>16)&255,(n>>>8)&255,n&255,...body]);
}
const api={frame,Decoder,score,event,midi};
if(typeof module!=='undefined'&&module.exports)module.exports=api;
else root.InstrumentProtocol=api;
})(globalThis);
