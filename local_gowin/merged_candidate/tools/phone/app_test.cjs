const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const P=require('./protocol.js');
const elements=new Map(),writes=[],saved=[];let notify,disconnect,connects=0,failDump=false;
const el=id=>{if(!elements.has(id))elements.set(id,{value:'',textContent:'',files:[],click(){saved.push(this.download);}});return elements.get(id);};
for(const [id,value] of Object.entries({key:'1',note:'84',rhythm:'0',tempo:'80',song:'1'}))el(id).value=value;
function packet(kind,payload){const p=[0xa6,kind,...payload];while(p.length<11)p.push(0);p.push(p.reduce((a,b)=>a^b,0));return p;}
function feed(p){const u=Uint8Array.from(p);notify({target:{value:new DataView(u.buffer)}});}
const tx={addEventListener(_,fn){notify=fn;},removeEventListener(){},async startNotifications(){}};
const device={name:'Mock',gatt:{connected:false,async connect(){connects++;this.connected=true;return {async getPrimaryService(){return {async getCharacteristic(id){return id.startsWith('6e400002')?rx:tx;}};}};}},addEventListener(_,fn){disconnect=fn;}};
const rx={async writeValueWithResponse(p){writes.push([...p]);if(!device.gatt.connected)throw Error('stale GATT');
 if(p[1]===0xe2&&failDump){device.gatt.connected=false;disconnect();return;}
 feed(packet(0xf0,[p[1],0,0,0]));
 if(p[1]===0xe2)setImmediate(()=>{feed(packet(0xe0,[1,60,100,0,0,0,0,0,0]));feed(packet(0xe1,[1,0,0]));});
}};
const context=vm.createContext({InstrumentProtocol:P,document:{getElementById:el,createElement:()=>({click(){saved.push(this.download);}})},
 navigator:{bluetooth:{async requestDevice(){return device;}}},setTimeout,clearTimeout,Uint8Array,DataView,URL:{createObjectURL:()=>'',revokeObjectURL(){}},Blob,console});
vm.runInContext(fs.readFileSync(__dirname+'/app.js','utf8'),context);
const click=id=>el(id).onclick();
(async()=>{
 await click('connect');assert.equal(connects,1);
 el('note').value='84';await click('map');await click('resetmap');assert.equal(Number(el('note').value),60);
 el('key').value='24';el('key').onchange();assert.equal(Number(el('note').value),83);
 writes.length=0;await click('play');assert.deepEqual(writes.map(p=>[p[1],p[2]]),[[0xb1,0],[0xb2,80],[0xb0,1]]);
 el('rhythm').value='1';writes.length=0;await click('play');assert.equal(writes[0][2],1);
 failDump=true;await click('dump');assert.match(el('state').textContent,/已断开/);
 failDump=false;await click('connect');assert.equal(connects,2);
 await click('dump');assert.match(el('recordstate').textContent,/数量完整/);
 device.gatt.connected=false;disconnect();await click('json');await click('midi');assert.deepEqual(saved,['performance.json','performance.mid']);
 assert.equal(vm.runInContext('pending===null&&dumpWait===null&&!operation',context),true);
 console.log('PASS: map reset UI, explicit free/rhythm start, disconnect while dumping, fresh GATT reconnect, complete dump, offline JSON/MIDI export');
})().catch(e=>{console.error(e);process.exitCode=1;});
