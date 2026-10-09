import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Registry, secureWrite } from '../../Resources/Gateway/registry.mjs';
import { migrateMainToShared as runMigration, readMainMigration, candidateRegistry, validateMainEndpoint, verifyMigrationRoute } from '../../Resources/Gateway/main-migration.mjs';
import { embeddedLocation } from '../../Resources/Tailscale/embedded.mjs';
import { startGateway } from '../../Resources/Gateway/server.mjs';
const migrateMainToShared = options => runMigration({ finalize: async () => ({ ...runtime, migrationCandidate: false }), ...options });
function fixture(fn) {
 const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'main-migration-'));
 const registry = new Registry({ directory, allowlistFile: path.join(directory, 'workspaces.json') });
 const original = { id: '012345abc678', roots: Array.from({length:3},(_,i)=>({id:i.toString(16).padStart(12,'0'),sourceID:'fixture-'+i,name:'Folder '+i,path:path.join(directory,'folder'+i),enabled:false,epoch:'a'.repeat(32)})), transport: 'external', stableMCPURL: 'https://old.tail.ts.net/c2c/012345abc678/mcp', configuredMCPURL: 'https://old.tail.ts.net/c2c/012345abc678/mcp', desiredRunning: true, reconnectEnabled: false };
 secureWrite(path.join(directory,'config.json'), original); fs.writeFileSync(path.join(directory,'auth.json'),'{}');
 return Promise.resolve().then(() => fn(registry, original)).finally(() => fs.rmSync(directory,{recursive:true,force:true}));
}
const account = { state:'ready', hostname:'new.tail.ts.net' };
const runtime = { workspaceId:'012345abc678', instanceID:'a'.repeat(64) };
test('commit follows validation, preserves identity/roots/auth/preferences and old URL history', () => fixture(async (registry,original) => {
 const file=path.join(registry.directory,'config.json'); const bytes=fs.readFileSync(file); const auth=fs.readFileSync(path.join(registry.directory,'auth.json'));
 await migrateMainToShared({registry,setup:async()=>account,open:async()=>{assert.deepEqual(fs.readFileSync(file),bytes);return runtime;},cleanup:async()=>{},validate:async(_url,state)=>{if(state.migrationCandidate !== false)assert.deepEqual(fs.readFileSync(file),bytes);else assert.equal(registry.read().transport,'embedded');}});
 const next=registry.read(); assert.equal(next.id,original.id);assert.deepEqual(next.roots,original.roots);assert.equal(next.reconnectEnabled,false);assert.equal(next.stableMCPURL,'https://new.tail.ts.net/mcp');assert.equal(next.configuredMCPURL,null);assert.equal(next.lastKnownMCPURL,original.stableMCPURL);assert.equal(next.sharedIngress,true);assert.deepEqual(fs.readFileSync(path.join(registry.directory,'auth.json')),auth);assert.equal(readMainMigration(registry),null);
}));
for (const stage of ['login','approval','Funnel','route','public']) test(`${stage} failure retains config and retries same identity`,()=>fixture(async(registry)=>{
 const file=path.join(registry.directory,'config.json');const bytes=fs.readFileSync(file);const location=embeddedLocation(candidateRegistry(registry));
 await assert.rejects(migrateMainToShared({registry,setup:async()=>{if(['login','approval'].includes(stage))throw Error(stage);return account;},open:async()=>{if(['route','Funnel'].includes(stage))throw Error(stage);return runtime;},validate:async()=>{throw Error('public');},cleanup:async()=>{}}));
 assert.deepEqual(fs.readFileSync(file),bytes);assert.ok(readMainMigration(registry));
 await migrateMainToShared({registry,setup:async view=>{assert.deepEqual(embeddedLocation(view),location);return account;},open:async()=>runtime,validate:async()=>{},cleanup:async()=>{}});
}));
for(const phase of ['pending','awaiting-login','preparing-shared-ingress','checking-endpoint','committing','finalizing']) test(`restart resumes ${phase}`,()=>fixture(async(registry,original)=>{
 secureWrite(path.join(registry.directory,'endpoint-migration.json'),{gateID:original.id,original,phase});
 await migrateMainToShared({registry,setup:async()=>account,open:async()=>runtime,validate:async()=>{},cleanup:async()=>{}});assert.equal(readMainMigration(registry),null);
}));
test('already committed config cleans journal without another login',()=>fixture(async(registry,original)=>{
 const candidateURL='https://new.tail.ts.net/mcp';secureWrite(path.join(registry.directory,'endpoint-migration.json'),{gateID:original.id,original,phase:'committing',hostname:account.hostname,candidateURL});secureWrite(path.join(registry.directory,'config.json'),{...original,transport:'embedded',sharedIngress:true,stableMCPURL:candidateURL});
 await migrateMainToShared({registry,setup:()=>assert.fail('login'),open:()=>assert.fail('open'),validate:async()=>{}});assert.equal(readMainMigration(registry),null);
}));
test('journal rejects another Gate and profiles have separate identity paths',()=>fixture(async(registry,original)=>{
 const trial=new Registry({directory:path.join(registry.directory,'test-profile')});assert.notEqual(embeddedLocation(registry).identity,embeddedLocation(trial).identity);
 secureWrite(path.join(registry.directory,'endpoint-migration.json'),{gateID:'111111111111',original,phase:'pending'});assert.throws(()=>readMainMigration(registry));
}));
test('candidate tunnel start never persists endpoint and discovery passes public validator',()=>fixture(async(registry)=>{
 const bytes=fs.readFileSync(path.join(registry.directory,'config.json'));
 const authBytes=fs.readFileSync(path.join(registry.directory,'auth.json'));
 let base;
 const provider={start:async()=>base,stop:async()=>{},status:()=>({running:true})};
 const gateway=await startGateway({backendRoot:process.env.BOUNDAS_C2C_ROOT,registry,tunnelProvider:provider,migrationCandidateURL:'https://new.tail.ts.net/mcp',instanceID:runtime.instanceID});
 try {
  base='https://new.tail.ts.net';const local=`http://127.0.0.1:${gateway.port}`;
  const state=JSON.parse(fs.readFileSync(path.join(registry.directory,'runtime.json')));
  const reply=await fetch(local+'/control/tunnel/start',{method:'POST',headers:{Authorization:`Bearer ${state.adminToken}`}});assert.equal(reply.status,200);assert.deepEqual(fs.readFileSync(path.join(registry.directory,'config.json')),bytes);
  await validateMainEndpoint(base+'/mcp',runtime,(url,options)=>fetch(local+new URL(url).pathname,options));
  for (const route of ['/oauth/register', '/oauth/token', '/oauth/authorize', '/oauth/revoke']) {
   const response = await fetch(local+route,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({client_name:'Candidate attack',grant_type:'refresh_token',refresh_token:'test'})});
   assert.equal(response.status,503);
  }
  assert.deepEqual(fs.readFileSync(path.join(registry.directory,'auth.json')),authBytes);
 } finally {await gateway.close();}
 assert.deepEqual(fs.readFileSync(path.join(registry.directory,'auth.json')),authBytes);
}));

test('login approval pause preserves config and durable Retry',()=>fixture(async(registry)=>{
 const bytes=fs.readFileSync(path.join(registry.directory,'config.json'));
 const result=await migrateMainToShared({registry,setup:async()=>({state:'login',loginURL:'https://login.tailscale.com/example'}),open:()=>assert.fail('open')});
 assert.equal(result.complete,false);assert.equal(readMainMigration(registry).phase,'awaiting-login');assert.deepEqual(fs.readFileSync(path.join(registry.directory,'config.json')),bytes);
}));
test('public validation rejects wrong runtime and wrong OAuth resource',async()=>{
 await assert.rejects(validateMainEndpoint('https://new.tail.ts.net/mcp',runtime,async()=>new Response(JSON.stringify({service:'boundas-gateway',workspaceId:runtime.workspaceId,instanceID:'b'.repeat(64)}))),/identity mismatch/);
});

for (const broken of ['discovery', 'resource']) test(`public validation rejects wrong OAuth ${broken}`, async()=>{
 const base='https://new.tail.ts.net';
 const fetcher=async url=>{
  const route=new URL(url).pathname;
  if(route==='/health')return Response.json({service:'boundas-gateway',workspaceId:runtime.workspaceId,instanceID:runtime.instanceID});
  if(route==='/.well-known/oauth-authorization-server')return Response.json({issuer:broken==='discovery'?'https://old.tail.ts.net':base,authorization_endpoint:base+'/oauth/authorize',token_endpoint:base+'/oauth/token'});
  return Response.json({resource:'https://old.tail.ts.net/mcp',authorization_servers:[base]});
 };
 await assert.rejects(validateMainEndpoint(base+'/mcp',runtime,fetcher),new RegExp(`OAuth ${broken} mismatch`));
});
test('commit interruption keeps candidate pending until Retry normalizes without another login',()=>fixture(async(registry)=>{
 let candidateAlive=false;let normalAlive=false;
 await assert.rejects(migrateMainToShared({registry,setup:async()=>account,open:async()=>{candidateAlive=true;return runtime;},validate:async()=>{},cleanup:()=>assert.fail('no rollback after commit'),finalize:async()=>{throw Error('interrupted after commit');}}),/interrupted/);
 assert.equal(registry.read().transport,'embedded');assert.equal(candidateAlive,true);assert.equal(readMainMigration(registry).phase,'finalizing');
 await migrateMainToShared({registry,setup:()=>assert.fail('must reuse identity'),open:()=>assert.fail('no second candidate'),validate:async()=>{assert.equal(candidateAlive,false);assert.equal(normalAlive,true);},finalize:async()=>{candidateAlive=false;normalAlive=true;return {...runtime,migrationCandidate:false};}});
 assert.equal(readMainMigration(registry),null);
}));
test('candidate flag cannot be reported as complete',()=>fixture(async(registry)=>{
 await assert.rejects(migrateMainToShared({registry,setup:async()=>account,open:async()=>runtime,validate:async()=>{},finalize:async()=>({...runtime,migrationCandidate:true})}),/not normalized/);
 assert.ok(readMainMigration(registry));
}));
test('successful commit replaces actual candidate server with normal OAuth runtime',()=>fixture(async(registry)=>{
 let gateway;let local;let candidatePort;
 const base='https://new.tail.ts.net';
 const provider=()=>({start:async()=>base,stop:async()=>{},status:()=>({running:true})});
 const launch=async candidate=>{
  gateway=await startGateway({backendRoot:process.env.BOUNDAS_C2C_ROOT,registry,tunnelProvider:provider(),...(candidate?{migrationCandidateURL:base+'/mcp'}:{})});
  local=`http://127.0.0.1:${gateway.port}`;
  const state=JSON.parse(fs.readFileSync(path.join(registry.directory,'runtime.json')));
  await fetch(local+'/control/tunnel/start',{method:'POST',headers:{Authorization:`Bearer ${state.adminToken}`}});
  const info=await(await fetch(local+'/control/info',{headers:{Authorization:`Bearer ${state.adminToken}`}})).json();
  return {...state,migrationCandidate:info.migrationCandidate};
 };
 try {
  const result=await migrateMainToShared({registry,setup:async()=>account,open:async()=>{const state=await launch(true);candidatePort=gateway.port;return state;},cleanup:async()=>gateway.close(),
   validate:(url,state)=>validateMainEndpoint(url,state,(url,options)=>fetch(local+new URL(url).pathname,options)),
   finalize:async()=>{await gateway.close();return launch(false);}});
  assert.equal(result.complete,true);
  await assert.rejects(fetch(`http://127.0.0.1:${candidatePort}/health`));
  const registration=await fetch(local+'/oauth/register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({client_name:'Normal client',redirect_uris:['https://chatgpt.com/connector/oauth/test']})});
  assert.equal(registration.status,201);
  assert.equal(JSON.parse(fs.readFileSync(path.join(registry.directory,'auth.json'))).clients.length,1);
 } finally {if(gateway)await gateway.close();}
}));

function fastTiming(budgetMs = 20) {
 let time = 0;
 return { budgetMs, now: () => time, sleep: async ms => { time += ms; } };
}
function readyResponse(url) {
 const base = 'https://new.tail.ts.net';
 switch (new URL(url).pathname) {
 case '/health': return Response.json({service:'boundas-gateway',workspaceId:runtime.workspaceId,instanceID:runtime.instanceID});
 case '/.well-known/oauth-authorization-server': return Response.json({issuer:base,authorization_endpoint:base+'/oauth/authorize',token_endpoint:base+'/oauth/token'});
 case '/.well-known/oauth-protected-resource/mcp': return Response.json({resource:base+'/mcp',authorization_servers:[base]});
 default: return new Response('{}',{status:401,headers:{'www-authenticate':`Bearer resource_metadata="${base}/.well-known/oauth-protected-resource/mcp"`}});
 }
}
test('local route readiness requires ready state and exact Gate/instance/URL',()=>{
 const route={gateID:runtime.workspaceId,instanceID:runtime.instanceID,publicUrl:'https://new.tail.ts.net'};
 verifyMigrationRoute({state:'ready',routes:[route]},route.publicUrl+'/mcp',runtime);
 for(const changed of [{state:'login',routes:[route]}, {state:'ready',routes:[{...route,gateID:'000000000000'}]}, {state:'ready',routes:[{...route,instanceID:'b'.repeat(64)}]}, {state:'ready',routes:[{...route,publicUrl:'https://old.tail.ts.net'}]}]) assert.throws(()=>verifyMigrationRoute(changed,route.publicUrl+'/mcp',runtime),/ownership mismatch/);
});
test('transport readiness failures then success reuse same validator/runtime',async()=>{
 let attempts=0;const fetcher=async url=>{if(++attempts<=3)throw Object.assign(new TypeError('fetch failed'),{cause:{code:'ENOTFOUND'}});return readyResponse(url);};
 await validateMainEndpoint('https://new.tail.ts.net/mcp',runtime,fetcher,fastTiming(10000));assert.equal(attempts,7);
});
test('transient 502/503/504 then success',async()=>{
 let attempts=0;const codes=[502,503,504];
 await validateMainEndpoint('https://new.tail.ts.net/mcp',runtime,async url=>++attempts<=3?new Response('',{status:codes[attempts-1]}):readyResponse(url),fastTiming(10000));assert.equal(attempts,7);
});
for(const step of ['health','discovery','resource','mcp']) test(`${step} semantic error fails without retry`,async()=>{
 let attempts=0;let sleeps=0;
 const paths={health:'/health',discovery:'/.well-known/oauth-authorization-server',resource:'/.well-known/oauth-protected-resource/mcp',mcp:'/mcp'};
 await assert.rejects(validateMainEndpoint('https://new.tail.ts.net/mcp',runtime,async url=>{
  attempts++;return new URL(url).pathname===paths[step]?Response.json({wrong:true}):readyResponse(url);
 },{...fastTiming(),sleep:async()=>{sleeps++;}}),error=>error.validationDetail.step===step && error.validationDetail.kind==='semantic');
 assert.equal(sleeps,0);assert.equal(attempts,['health','discovery','resource','mcp'].indexOf(step)+1);
});
test('readiness exhaustion preserves precommit bytes and useful journal diagnostics',()=>fixture(async registry=>{
 const before=fs.readFileSync(path.join(registry.directory,'config.json'));let setups=0;let opens=0;
 const validate=(url,state)=>validateMainEndpoint(url,state,async()=>{throw Object.assign(Error('fetch failed'),{cause:{code:'ECONNREFUSED'}});},fastTiming());
 await assert.rejects(migrateMainToShared({registry,setup:async()=>{setups++;return account;},open:async()=>{opens++;return runtime;},cleanup:async()=>{},validate}),/health exhausted readiness retry/);
 assert.deepEqual(fs.readFileSync(path.join(registry.directory,'config.json')),before);
 assert.deepEqual(readMainMigration(registry).failureDetail,{step:'health',kind:'transient',code:'ECONNREFUSED'});assert.equal(setups,1);assert.equal(opens,1);
}));
test('normal runtime validation tolerates readiness delay without identity/login recreation',()=>fixture(async registry=>{
 let setups=0;let opens=0;let finalizes=0;let normalAttempts=0;
 await migrateMainToShared({registry,setup:async()=>{setups++;return account;},open:async()=>{opens++;return runtime;},cleanup:async()=>{},finalize:async()=>{finalizes++;return {...runtime,migrationCandidate:false};},
 validate:(url,state)=>validateMainEndpoint(url,state,async url=>{
  if(state.migrationCandidate===false && ++normalAttempts<=2)throw Object.assign(Error('fetch failed'),{cause:{code:'ECONNRESET'}});
  return readyResponse(url);
 },fastTiming(10000))});
 assert.equal(setups,1);assert.equal(opens,1);assert.equal(finalizes,1);assert.equal(normalAttempts,6);assert.equal(readMainMigration(registry),null);
}));
