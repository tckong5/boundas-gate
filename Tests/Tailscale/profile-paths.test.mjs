import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const root = path.resolve('Resources');
function isolated(home, script, overrides = {}) {
  const env = { ...process.env, HOME: home };
  for (const key of ['BOUNDAS_GATEWAY_DIR', 'BOUNDAS_WORKSPACES_FILE', 'BOUNDAS_STATE_DIR', 'C2C_STATE_DIR']) delete env[key];
  return execFileSync(process.execPath, ['--input-type=module', '-e', script], { env: { ...env, ...overrides }, encoding: 'utf8' });
}
function fixture(action) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'boundas-profile-'));
  try { action(home, path.join(home, 'Library/Application Support')); }
  finally { fs.rmSync(home, { recursive: true, force: true }); }
}
const registry = `const {Registry}=await import(${JSON.stringify(`file://${root}/Gateway/registry.mjs`)});`;
const provider = `const {TailscaleProvider}=await import(${JSON.stringify(`file://${root}/Tailscale/provider.mjs`)});`;
test('fresh Node and Tunnel defaults share the Boundas Gate profile', () => fixture((home, support) => {
  const result = JSON.parse(isolated(home, `${registry}${provider}const r=new Registry();const p=new TailscaleProvider('123456789abc');console.log(JSON.stringify([r.directory,r.allowlistFile,p.directory]));`));
  assert.deepEqual(result, ['gateway', 'workspaces.json', 'tailscale'].map(name => path.join(support, 'Boundas Gate', name)));
  assert.equal(fs.existsSync(path.join(support, 'Boundas Gate')), false);
}));
test('legacy-only default runtime refuses to invent a new identity before app migration', () => fixture((home, support) => {
  const legacy = path.join(support, 'C2C Workspace Manager'); fs.mkdirSync(legacy, { recursive: true });
  fs.writeFileSync(path.join(legacy, 'workspaces.json'), 'original');
  isolated(home, `${registry}${provider}for(const create of [()=>new Registry().ensure(),()=>new TailscaleProvider('123456789abc')]){try{create();process.exit(9)}catch(e){if(!e.message.includes('migrate existing data'))process.exit(10)}}`);
  assert.equal(fs.existsSync(path.join(support, 'Boundas Gate')), false);
  assert.equal(fs.readFileSync(path.join(legacy, 'workspaces.json'), 'utf8'), 'original');
}));
test('new profile wins without merging legacy', () => fixture((home, support) => {
  for (const name of ['Boundas Gate', 'C2C Workspace Manager']) fs.mkdirSync(path.join(support, name, 'gateway'), { recursive: true });
  const config = { id: '123456789abc', roots: [] };
  fs.writeFileSync(path.join(support, 'Boundas Gate/gateway/config.json'), JSON.stringify(config));
  assert.equal(isolated(home, `${registry}console.log(new Registry().ensure().id);`).trim(), config.id);
  assert.equal(fs.existsSync(path.join(support, 'Boundas Gate/workspaces.json')), false);
}));
test('explicit test-profile environment never reads production or legacy', () => fixture((home, support) => {
  fs.mkdirSync(path.join(support, 'C2C Workspace Manager'), { recursive: true });
  const trial = path.join(support, 'Boundas Gate New User Test');
  const overrides = { BOUNDAS_GATEWAY_DIR: path.join(trial, 'gateway'), BOUNDAS_WORKSPACES_FILE: path.join(trial, 'workspaces.json'), BOUNDAS_STATE_DIR: path.join(trial, 'tailscale') };
  const values = JSON.parse(isolated(home, `${registry}${provider}const r=new Registry();const p=new TailscaleProvider('123456789abc');console.log(JSON.stringify([r.directory,r.allowlistFile,p.directory]));`, overrides));
  assert.deepEqual(values, Object.values(overrides));
  assert.equal(fs.existsSync(path.join(support, 'Boundas Gate')), false);
}));
