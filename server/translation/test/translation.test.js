import test from 'node:test';
import assert from 'node:assert/strict';
import { createHandler, validateBody } from '../src/handler.js';
import { readConfig, LANGUAGES, MAX_BODY_BYTES } from '../src/config.js';
import { createReservation, USAGE_COLLECTION } from '../src/quota.js';
import { createAmazonTranslator } from '../src/provider.js';
const key = Buffer.alloc(32, 7).toString('base64');
const configured = { GCLOUD_PROJECT: 'demo-clrs-local', TRANSLATION_ENABLED: 'true', AWS_REGION: 'eu-central-1', TRANSLATION_CACHE_HMAC_KEY: key };
const config = () => readConfig(configured);
const signal = () => new AbortController().signal;
function request(body = { text: 'Привет 👨‍👩‍👧', targetLanguage: 'en' }, overrides = {}) {
  return { method: 'POST', headers: { 'content-type': 'application/json; charset=utf-8', authorization: 'Bearer example.jwt.signature' }, rawBody: Buffer.from(JSON.stringify(body)), ...overrides };
}
function response() {
  return { headers: {}, statusCode: null, body: null, calls: 0, set(k,v) { this.headers[k]=v; return this; }, status(n) { this.statusCode=n; return this; }, json(v) { this.body=v; this.calls++; return this; } };
}
function harness(overrides = {}) {
  const calls=[];
  const deps={ getConfig: config, auth: {
    async verifyIdToken(token, revoked) { calls.push(['verify',token,revoked]); return { uid:'u1',firebase:{sign_in_provider:'password'} }; },
    async getUser(uid) { calls.push(['user',uid]); return {uid,disabled:false,providerData:[{providerId:'password'}],emailVerified:false}; },
  }, async reserve(arg) { calls.push(['reserve',arg]); }, async translate(arg) { calls.push(['translate',arg]); return {translatedText:'Hello',detectedSourceLanguage:'ru'}; },
  cache: { getOrTranslate: arg => arg.translate(arg) }, ...overrides };
  return {calls,deps,async run(req=request()) {const res=response();await createHandler(deps)(req,res);return res;}};
}
// Atomic staged writes with serialized conflicts; does not model production rules.
class AtomicFirestore {
  constructor(profiles={u1:{}}) { this.docs=new Map(Object.entries(profiles).map(([u,d])=>['users/'+u,structuredClone(d)]));this.queue=Promise.resolve(); }
  collection(name) { return {doc:id=>({path:`${name}/${id}`})}; }
  async runTransaction(fn,options) {
    assert.equal(options.maxAttempts,3);
    const prior=this.queue;let release;this.queue=new Promise(r=>{release=r;});await prior;const writes=new Map();
    try { const result=await fn({getAll:async(...refs)=>{assert.equal(writes.size,0);return refs.map(ref=>({exists:this.docs.has(ref.path),data:()=>structuredClone(this.docs.get(ref.path))}));},set:(ref,value)=>writes.set(ref.path,structuredClone(value))});for(const [k,v] of writes)this.docs.set(k,v);return result; } finally { release(); }
  }
}
for(const language of LANGUAGES) test(`canonical contract ${language}`,async()=>{
  const h=harness();const res=await h.run(request({text:'one',targetLanguage:language}));assert.equal(res.statusCode,200);
  assert.deepEqual(res.body,{translatedText:'Hello',detectedSourceLanguage:'ru',targetLanguage:language});assert.deepEqual(h.calls.map(c=>c[0]),['verify','user','reserve','translate']);assert.equal(h.calls[0][2],true);assert.equal(res.headers['Cache-Control'],'no-store, private');
});
test('disabled/emulator configuration cannot authenticate, reserve or call provider',async()=>{
  for(const env of [{TRANSLATION_ENABLED:''},{TRANSLATION_ENABLED:'TRUE'},{FUNCTIONS_EMULATOR:'true'}]){const h=harness({getConfig:()=>readConfig({...configured,...env})});assert.equal((await h.run()).statusCode,503);assert.equal(h.calls.length,0);}
});

test('Google endpoint is independently disabled and needs no AWS region or credentials', async () => {
  const env = { GCLOUD_PROJECT: 'demo-clrs-local', TRANSLATION_CACHE_HMAC_KEY: key };
  for (const extra of [{}, { TRANSLATION_ENABLED: 'true' },
    { GOOGLE_TRANSLATION_ENABLED: 'true', FUNCTIONS_EMULATOR: 'true' }]) {
    const h = harness({ getConfig: () => readConfig({ ...env, ...extra }, 'google') });
    assert.equal((await h.run()).statusCode, 503);
    assert.equal(h.calls.length, 0);
  }
  const h = harness({ getConfig: () => readConfig({ ...env, GOOGLE_TRANSLATION_ENABLED: 'true' }, 'google') });
  const result = await h.run(request({ text: 'Привет', targetLanguage: 'sr' }));
  assert.equal(result.statusCode, 200);
  assert.deepEqual(result.body, { translatedText: 'Hello', detectedSourceLanguage: 'ru', targetLanguage: 'sr', googlePowered: true });
  assert.deepEqual(h.calls.map(call => call[0]), ['verify', 'user', 'reserve', 'translate']);
});

test('unknown provider configuration fails before identity, quota or paid work', async () => {
  const h = harness({ getConfig: () => readConfig(configured, 'unknown') });
  assert.equal((await h.run()).statusCode, 503);
  assert.equal(h.calls.length, 0);
});
test('invalid configuration/project fails closed',async()=>{
  for(const env of [{GCLOUD_PROJECT:'../other'},{AWS_REGION:'not-a-region'},{TRANSLATION_CACHE_HMAC_KEY:'bad'},{TRANSLATION_UID_DAILY_CHARS:'-1'},{TRANSLATION_GLOBAL_DAILY_CHARS:'1000001'},{TRANSLATION_UID_MINUTE_REQUESTS:'61'}]){const h=harness({getConfig:()=>readConfig({...configured,...env})});assert.equal((await h.run()).statusCode,503);assert.equal(h.calls.length,0);}
});
test('only bounded valid JSON contract accepted before paid work',async()=>{
  const bad=[null,[],{},{text:'',targetLanguage:'en'},{text:' ',targetLanguage:'en'},{text:9,targetLanguage:'en'},{text:'\ud800',targetLanguage:'en'},{text:'a\0b',targetLanguage:'en'},{text:'x',targetLanguage:'no'},{text:'x',targetLanguage:'EN'},{text:'x',targetLanguage:'en',sourceLanguage:'de'}];
  for(const input of bad){const h=harness();assert.equal((await h.run(request(input))).statusCode,400);assert.equal(h.calls.length,0);}
  for(const req of [request(undefined,{rawBody:Buffer.from('{invalid')}),request(undefined,{headers:{'content-type':'text/plain'}}),request(undefined,{headers:{'content-type':'application/json','content-encoding':'gzip'}})])assert.equal((await harness().run(req)).statusCode,400);
});
test('5000 codepoints and Amazon 10000-byte limit enforced before paid work',async()=>{
  assert.equal(validateBody(request({text:'😀'.repeat(2500),targetLanguage:'ru'})).chars,2500);
  assert.equal(validateBody(request({text:'ж'.repeat(5000),targetLanguage:'ru'})).chars,5000);
  for(const req of [request({text:'😀'.repeat(2501),targetLanguage:'ru'}),request({text:'a'.repeat(5001),targetLanguage:'ru'}),request(undefined,{rawBody:Buffer.alloc(MAX_BODY_BYTES+1)}),request(undefined,{headers:{'content-type':'application/json','content-length':'9999999'}})]){const h=harness();assert.equal((await h.run(req)).statusCode,413);assert.equal(h.calls.length,0);}
});
test('GET rejected with Allow and no work',async()=>{const h=harness();const r=await h.run(request(undefined,{method:'GET'}));assert.equal(r.statusCode,405);assert.equal(r.headers.Allow,'POST');assert.equal(h.calls.length,0);});
test('missing/malformed/expired/revoked tokens never reserve or translate',async()=>{
  for(const authorization of [undefined,'Basic secret','Bearer two tokens']){const h=harness();assert.equal((await h.run(request(undefined,{headers:{'content-type':'application/json',authorization}}))).statusCode,401);assert.equal(h.calls.length,0);}
  for(const code of ['auth/id-token-expired','auth/id-token-revoked','auth/user-disabled','auth/user-not-found']){const h=harness();h.deps.auth.verifyIdToken=async()=>{throw{code,message:'private token text'};};const r=await h.run();assert.equal(r.statusCode,401);assert.equal(JSON.stringify(r.body).includes('private'),false);assert.equal(h.calls.length,0);}
});
test('password-only Auth users with empty federated providerData are accepted',async()=>{
  const h=harness();h.deps.auth.getUser=async uid=>({uid,disabled:false,providerData:[]});
  assert.equal((await h.run()).statusCode,200);
  assert.deepEqual(h.calls.map(c=>c[0]),['verify','reserve','translate']);
});
test('anonymous/disabled/unregistered identities denied',async()=>{
  const h=harness();h.deps.auth.verifyIdToken=async()=>({uid:'u1',firebase:{sign_in_provider:'anonymous'}});assert.equal((await h.run()).statusCode,403);assert.equal(h.calls.length,0);
  for(const patch of [{disabled:true},{uid:'other'}]){const h=harness();h.deps.auth.getUser=async()=>({uid:'u1',providerData:[{}],...patch});assert.equal((await h.run()).statusCode,403);assert.equal(h.calls.some(c=>c[0]==='reserve'),false);}
});
test('Auth outage is sanitized503',async()=>{const h=harness();h.deps.auth.getUser=async()=>{throw new Error('private text token');};const r=await h.run();assert.equal(r.statusCode,503);assert.deepEqual(r.body,{error:{code:'translation_unavailable'}});});
test('missing/blocked/deleted profile prevents provider and quota writes',async()=>{
  for(const profiles of [{},{u1:{status:'blocked'}},{u1:{status:'deleted'}},{u1:{status:' DELETED '}},{u1:{deleted:true}},{u1:{registrationStatus:'deleted'}}]){const db=new AtomicFirestore(profiles);const h=harness({reserve:createReservation({db})});assert.equal((await h.run()).statusCode,403);assert.equal([...db.docs.keys()].some(k=>k.startsWith(USAGE_COLLECTION)),false);assert.equal(h.calls.some(c=>c[0]==='translate'),false);}
});
test('concurrent UID budget cannot exceed cap; stored data are counters only',async()=>{
  const db=new AtomicFirestore();const reserve=createReservation({db});const cfg={...config(),uidDailyChars:20,uidMinuteRequests:60};
  const results=await Promise.allSettled(Array.from({length:30},()=>reserve({uid:'u1',chars:4,config:cfg,signal:signal()})));assert.equal(results.filter(r=>r.status==='fulfilled').length,5);assert.ok(results.filter(r=>r.status==='rejected').every(r=>r.reason.status===429));const counters=[...db.docs].filter(([k])=>k.startsWith(USAGE_COLLECTION));assert.equal(counters.length,2);for(const [,v] of counters){assert.equal(v.chars,20);assert.deepEqual(Object.keys(v).sort(),['chars','minute','requests']);}
});
test('global budget caps concurrent different users atomically',async()=>{
  const ids=Array.from({length:30},(_,i)=>'u'+i);const db=new AtomicFirestore(Object.fromEntries(ids.map(id=>[id,{}])));const reserve=createReservation({db});const cfg={...config(),globalDailyChars:12};const results=await Promise.allSettled(ids.map(uid=>reserve({uid,chars:4,config:cfg,signal:signal()})));assert.equal(results.filter(r=>r.status==='fulfilled').length,3);assert.equal([...db.docs].find(([k])=>k.includes('/global_'))[1].chars,12);
});
test('minute limit and UTC day rollover',async()=>{
  const db=new AtomicFirestore();let now=Date.UTC(2026,8,22,23,59);const reserve=createReservation({db,now:()=>now});const cfg={...config(),uidMinuteRequests:1,uidDailyChars:3};const run=()=>reserve({uid:'u1',chars:2,config:cfg,signal:signal()});await run();await assert.rejects(run(),e=>e.status===429);now+=60000;await run();assert.equal([...db.docs.keys()].filter(k=>k.includes('/global_')).length,2);
});
test('provider failure retains charged reservation and sanitized response',async()=>{
  const db=new AtomicFirestore();const h=harness({reserve:createReservation({db}),translate:async()=>{throw new Error('private text ADC token');}});const r=await h.run(request({text:'hello',targetLanguage:'en'}));assert.equal(r.statusCode,503);assert.equal(JSON.stringify(r.body).includes('private'),false);assert.equal([...db.docs].find(([k])=>k.includes('/global_'))[1].chars,5);
});
test('timeout during late reservation cannot start provider after response',async()=>{
  let release,calls=0;const h=harness({deadlineMs:10,reserve:()=>new Promise(r=>{release=r;}),translate:async()=>{calls++;}});const r=await h.run();assert.equal(r.statusCode,503);release();await new Promise(r=>setTimeout(r,5));assert.equal(calls,0);assert.equal(r.calls,1);
});
test('timeout aborts provider, no automatic retry',async()=>{
  let calls=0,aborted=false;const h=harness({deadlineMs:10,translate:({signal})=>{calls++;return new Promise((_,reject)=>signal.addEventListener('abort',()=>{aborted=true;reject(new Error('abort'));},{once:true}));}});const r=await h.run();assert.equal(r.statusCode,503);assert.equal(calls,1);assert.equal(aborted,true);
});
function amazonHarness(factory=command=>({TranslatedText:'<not HTML>',SourceLanguageCode:'ru',TargetLanguageCode:command.input.TargetLanguageCode})){
  const requests=[];return {requests,translate:createAmazonTranslator({clientForRegion:region=>({async send(command,options){requests.push({region,input:command.input,options});return factory(command);}})})};
}
for(const targetLanguage of LANGUAGES)test(`Amazon provider ${targetLanguage}: auto source, canonical target`,async()=>{
  const h=amazonHarness();const active=signal();const output=await h.translate({text:'<private>&',targetLanguage,config:config(),signal:active});assert.equal(output.translatedText,'<not HTML>');assert.equal(h.requests.length,1);const {region,input,options}=h.requests[0];assert.equal(region,'eu-central-1');assert.deepEqual(input,{Text:'<private>&',SourceLanguageCode:'auto',TargetLanguageCode:targetLanguage==='nb'?'no':targetLanguage});assert.equal(options.abortSignal,active);
});
test('invalid/error/oversized provider response unavailable, never echoed',async()=>{
  for(const factory of [()=>{throw new Error('private diagnostic');},()=>({}),()=>({TranslatedText:'x',TargetLanguageCode:'en'}),()=>({TranslatedText:'x'.repeat(300000),SourceLanguageCode:'ru',TargetLanguageCode:'en'}),()=>({TranslatedText:'x',SourceLanguageCode:'ru',TargetLanguageCode:'de'})]){const h=amazonHarness(factory);await assert.rejects(h.translate({text:'hi',targetLanguage:'en',config:config(),signal:signal()}),e=>e.status===503&&e.code==='translation_unavailable');assert.equal(h.requests.length,1);}
});
test('detected Norwegian normalized to nb',async()=>{const h=amazonHarness(()=>({TranslatedText:'hello',SourceLanguageCode:'no',TargetLanguageCode:'en'}));assert.equal((await h.translate({text:'hei',targetLanguage:'en',config:config(),signal:signal()})).detectedSourceLanguage,'nb');});
test('corrupt counters fail closed',async()=>{const db=new AtomicFirestore();const date='2026-09-22';db.docs.set(USAGE_COLLECTION+'/global_'+date,{chars:-1});const reserve=createReservation({db,now:()=>Date.parse(date)});await assert.rejects(reserve({uid:'u1',chars:1,config:config(),signal:signal()}),e=>e.status===503);});

// Invalid byte sequences must not silently become replacement characters.
test('invalid UTF-8 JSON rejected before authentication', async () => {
  const h=harness(); const rawBody=Buffer.concat([Buffer.from('{"text":"'),Buffer.from([0xff]),Buffer.from('","targetLanguage":"en"}')]);
  assert.equal((await h.run(request(undefined,{rawBody}))).statusCode,400); assert.equal(h.calls.length,0);
});
test('invalid Firestore UID cannot select a nested resource',async()=>{
  const h=harness();h.deps.auth.verifyIdToken=async()=>({uid:'other/nested/account',firebase:{sign_in_provider:'password'}});
  assert.equal((await h.run()).statusCode,403);assert.equal(h.calls.length,0);
});
test('global minute requests are independently capped',async()=>{
  const db=new AtomicFirestore({u1:{},u2:{}});const reserve=createReservation({db});const cfg={...config(),globalMinuteRequests:1};
  await reserve({uid:'u1',chars:1,config:cfg,signal:signal()});
  await assert.rejects(reserve({uid:'u2',chars:1,config:cfg,signal:signal()}),e=>e.status===429);
});
test('HTTP quota error gives429, Retry-After, no provider',async()=>{
  const db=new AtomicFirestore();const h=harness({reserve:createReservation({db}),getConfig:()=>({...config(),uidDailyChars:1})});
  const r=await h.run();assert.equal(r.statusCode,429);assert.equal(r.headers['Retry-After'],'60');assert.equal(h.calls.some(c=>c[0]==='translate'),false);
});

test('delayed old-minute transaction cannot reset a newer minute bucket',async()=>{
  const db=new AtomicFirestore();const runTransaction=db.runTransaction.bind(db);let release;let calls=0;
  db.runTransaction=async(fn,options)=>{calls++;if(calls===1)await new Promise(resolve=>{release=resolve;});return runTransaction(fn,options);};
  let now=Date.UTC(2026,8,22,12,0);const reserve=createReservation({db,now:()=>now});
  const cfg={...config(),uidMinuteRequests:1,globalMinuteRequests:1};
  const run=()=>reserve({uid:'u1',chars:1,config:cfg,signal:signal()});
  const delayed=run();now+=60000;await run();release();
  await assert.rejects(delayed,e=>e.status===429);
  await assert.rejects(run(),e=>e.status===429);
  const counter=[...db.docs].find(([key])=>key.includes('/global_'))[1];
  assert.deepEqual(counter,{chars:1,requests:1,minute:Math.floor(now/60000)});
});
test('clock regression cannot move persisted minute backwards or replenish requests',async()=>{
  const db=new AtomicFirestore();let now=Date.UTC(2026,8,22,12,1);const reserve=createReservation({db,now:()=>now});
  const cfg={...config(),uidMinuteRequests:1,globalMinuteRequests:1};
  const run=()=>reserve({uid:'u1',chars:1,config:cfg,signal:signal()});
  await run();now-=60000;await assert.rejects(run(),e=>e.status===429);now+=60000;await assert.rejects(run(),e=>e.status===429);
  const counter=[...db.docs].find(([key])=>key.includes('/global_'))[1];assert.equal(counter.requests,1);assert.equal(counter.chars,1);
});
test('crossing UTC midnight during quota reads fails closed without yesterday reservation',async()=>{
  const db=new AtomicFirestore();let ticks=0;const midnight=Date.UTC(2026,8,23);
  const reserve=createReservation({db,now:()=>++ticks===1?midnight-1:midnight});
  await assert.rejects(reserve({uid:'u1',chars:1,config:config(),signal:signal()}),e=>e.status===503);
  assert.equal([...db.docs.keys()].some(key=>key.startsWith(USAGE_COLLECTION)),false);
});
