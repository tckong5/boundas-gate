import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { shutdownProfile, stopOwnedHelper } from '../../Resources/Gateway/app-shutdown.mjs';
import { embeddedLocation } from '../../Resources/Tailscale/embedded.mjs';

function fixture(fn) {
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'app-quit-'));
 const mainID='012345abc678', sideID='abcdef123456';
 const records=[{id:'folder-source',c2cID:sideID,path:path.join(root,'folder'),sideGateAdded:true}];
 const config={id:mainID,transport:'embedded',sharedIngress:true,desiredRunning:true,stableMCPURL:'https://same.tail.ts.net/mcp'};
 const directory=path.join(root,'gateway'),stateDir=path.join(root,'c2c');
 const registry={directory,read:()=>config,addedFolders:()=>records};
 for(const [file,value] of [[path.join(directory,'config.json'),config],[path.join(directory,'auth.json'),{tokens:['preserve']}],
   [path.join(root,'workspaces.json'),records],[path.join(stateDir,'side-gates',sideID,'config.json'),{id:sideID,desiredRunning:true}],
   [path.join(directory,'embedded','identity','tailscaled.state'),{machine:'same'}],
   [path.join(stateDir,'auth',sideID+'.json'),{clients:['preserve']} ]]) {
  fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,JSON.stringify(value));
 }
 const files=()=>[path.join(directory,'config.json'),path.join(directory,'auth.json'),path.join(root,'workspaces.json'),
  path.join(stateDir,'side-gates',sideID,'config.json'),path.join(directory,'embedded','identity','tailscaled.state'),path.join(stateDir,'auth',sideID+'.json')].map(f=>fs.readFileSync(f).toString());
 return Promise.resolve().then(()=>fn({root,registry,stateDir,records,config,files,mainID,sideID})).finally(()=>fs.rmSync(root,{recursive:true,force:true}));
}

test('Quit shuts Side then Main then helpers, preserving all intent/auth/identity bytes',()=>fixture(async f=>{
 const before=f.files(),events=[],active=new Set([f.sideID,f.mainID]);
 const runtimes=new Map([[f.sideID,{workspaceId:f.sideID,workspaceRoot:f.records[0].path,instanceID:'a'.repeat(64),port:1111,adminToken:'side'}],
  [f.mainID,{workspaceId:f.mainID,instanceID:'b'.repeat(64),port:2222,adminToken:'main'}]]);
 const report=await shutdownProfile({...f,observe:async(_file,{gateID})=>active.has(gateID)?{state:'healthy',runtime:runtimes.get(gateID)}:{state:'stopped'},
  inspect:async()=>true,fetcher:async(url,{headers})=>{
   const id=url.includes(':1111/')?f.sideID:f.mainID;
   assert.equal(headers.Authorization,'Bearer '+runtimes.get(id).adminToken);
   events.push([id,new URL(url).pathname]);
   if(url.endsWith('/shutdown'))active.delete(id);
   return {ok:true,json:async()=>({ok:true})};
  },helper:async registry=>{events.push(['helper',registry.read().id]);return true;}});
 assert.equal(report.ok,true);assert.deepEqual([...active],[]);
 assert.deepEqual(events,[[f.sideID,'/control/tunnel/stop'],[f.sideID,'/control/shutdown'],[f.mainID,'/control/tunnel/stop'],[f.mainID,'/control/shutdown'],['helper',f.sideID],['helper',f.mainID]]);
 assert.deepEqual(f.files(),before);assert.equal(f.config.desiredRunning,true);
 // Restart opens the existing identity path and hostname; Quit never writes them.
 assert.equal(embeddedLocation(f.registry).identity,path.join(f.registry.directory,'embedded'));
 assert.equal(f.registry.read().stableMCPURL,'https://same.tail.ts.net/mcp');
}));

test('Unverified/another-profile runtime is never controlled; failures are explicit',()=>fixture(async f=>{
 const calls=[];
 const report=await shutdownProfile({...f,observe:async()=>({state:'unknown',reason:'Wrong profile/nonce'}),
  fetcher:async()=>{calls.push('unexpected');},helper:async()=>false});
 assert.equal(report.ok,false);assert.equal(report.failures.length,2);assert.deepEqual(calls,[]);
}));

test('Daemon nonce/process verification and Side Folder ownership are mandatory',()=>fixture(async f=>{
 let controls=0;
 const result=await shutdownProfile({...f,observe:async(_file,{gateID})=>({state:'healthy',runtime:{workspaceId:gateID,workspaceRoot:'/wrong',instanceID:'a'.repeat(64)}}),
  inspect:async()=>false,fetcher:async()=>{controls++;},helper:async()=>false});
 assert.equal(controls,0);assert.equal(result.ok,false);
}));

test('Shutdown deadline bounds non-acknowledging runtime; no destructive fallback',()=>fixture(async f=>{
 let time=0,calls=0;
 const result=await shutdownProfile({...f,budgetMs:500,now:()=>time,wait:async ms=>{time+=ms;},
  observe:async(_file,{gateID})=>({state:'healthy',runtime:{workspaceId:gateID,workspaceRoot:f.records[0].path,instanceID:'a'.repeat(64),port:1111,adminToken:'fixture'}}),
  inspect:async()=>true,fetcher:async()=>{calls++;return {ok:true,json:async()=>({ok:true})};},helper:async()=>{assert.fail('No remaining budget');}});
 assert.equal(result.ok,false);assert.equal(calls,2);assert.ok(time<=600);assert.ok(result.failures.some(f=>f.message.includes('timed out')));
}));

function helperFixture(f,{wrongPath=false,wrongGate=false,wrongExecutable=false,neverStops=false}={}) {
 const binary=path.join(f.root,'boundas-tunnel');fs.writeFileSync(binary,'fixture');
 const other=path.join(f.root,'other-binary');fs.writeFileSync(other,'fixture');
 let signalled=false,time=0,signals=[];
 const status={pid:12345,gatewayID:wrongGate?'othergate':f.mainID};
 return {signals,options:{binary,now:()=>time,deadline:500,wait:async ms=>{time+=ms;},alive:()=>neverStops || !signalled,
  request:async()=>{if(signalled&&!neverStops)throw Object.assign(Error('Stopped'),{code:'ENOENT'});return status;},
  execute:async(_exe,args)=>args.at(-1)==='uid='?String(os.userInfo().uid):args.at(-1)==='comm='?(wrongExecutable?other:binary):`${binary} --state-dir ${wrongPath?path.join(f.root,'another-profile'):embeddedLocation(f.registry).identity} --gateway-id ${f.mainID}`,
  signal:(pid,value)=>{signals.push([pid,value]);signalled=true;}}};
}
test('Only exact bundled executable/profile/Gate helper receives SIGTERM',()=>fixture(async f=>{
 const helper=helperFixture(f);
 assert.equal(await stopOwnedHelper(f.registry,helper.options),true);
 assert.deepEqual(helper.signals,[[12345,'SIGTERM']]);
}));
for(const mismatch of ['wrongPath','wrongGate','wrongExecutable'])test(`Helper ${mismatch} fails closed without any signal`,()=>fixture(async f=>{
 const helper=helperFixture(f,{[mismatch]:true});
 await assert.rejects(stopOwnedHelper(f.registry,helper.options));assert.deepEqual(helper.signals,[]);
}));
test('Verified helper timeout never escalates to process-name/SIGKILL fallback',()=>fixture(async f=>{
 const helper=helperFixture(f,{neverStops:true});
 await assert.rejects(stopOwnedHelper(f.registry,helper.options),/timed out/);
 assert.deepEqual(helper.signals,[[12345,'SIGTERM']]);
}));
test('Shutdown command requires explicit profile and never guesses production paths',async()=>{
 const {execFile}=await import('node:child_process');const {promisify}=await import('node:util');
 const env={...process.env};delete env.BOUNDAS_GATEWAY_DIR;delete env.C2C_STATE_DIR;delete env.BOUNDAS_WORKSPACES_FILE;
 await assert.rejects(promisify(execFile)(process.execPath,['Resources/Gateway/app-shutdown.mjs'],{env}),e=>e.stdout.includes('Explicit app profile'));
});

test('All Side runtimes are stopped, including previously closed/removing membership; false intent stays false',()=>fixture(async f=>{
 const second='012345abcdef';
 f.records.push({id:'second-source',c2cID:second,path:path.join(f.root,'second'),sideGateAdded:true,sideGateRemovalState:'failed'});
 f.config.desiredRunning=false;
 const active=new Set([f.sideID,second,f.mainID]),order=[];
 const report=await shutdownProfile({...f,
  observe:async(_file,{gateID})=>active.has(gateID)?{state:'healthy',runtime:{workspaceId:gateID,
   workspaceRoot:f.records.find(r=>r.c2cID===gateID)?.path,instanceID:gateID.repeat(6).slice(0,64),port:gateID===f.mainID?3000:gateID===second?2000:1000,adminToken:'fixture'}}:{state:'stopped'},
  inspect:async()=>true,fetcher:async url=>{
   if(url.endsWith('/shutdown')){const id=url.includes(':1000/')?f.sideID:url.includes(':2000/')?second:f.mainID;order.push(id);active.delete(id);}
   return {ok:true,json:async()=>({ok:true})};
  },helper:async()=>false});
 assert.equal(report.ok,true);assert.deepEqual(order,[f.sideID,second,f.mainID]);assert.equal(f.config.desiredRunning,false);
}));

test('Route-stop failure is reported while remaining verified shutdown still proceeds',()=>fixture(async f=>{
 const active=new Set([f.sideID,f.mainID]),order=[];
 const report=await shutdownProfile({...f,
  observe:async(_file,{gateID})=>active.has(gateID)?{state:'healthy',runtime:{workspaceId:gateID,workspaceRoot:f.records[0].path,instanceID:'a'.repeat(64),port:gateID===f.sideID?1000:2000,adminToken:'fixture'}}:{state:'stopped'},
  inspect:async()=>true,fetcher:async url=>{
   if(url.endsWith('/tunnel/stop'))return {ok:false,status:503};
   const id=url.includes(':1000/')?f.sideID:f.mainID;active.delete(id);order.push(id);return {ok:true,json:async()=>({ok:true})};
  },helper:async()=>false});
 assert.equal(report.ok,false);assert.deepEqual(order,[f.sideID,f.mainID]);assert.equal(report.failures.length,2);
}));
