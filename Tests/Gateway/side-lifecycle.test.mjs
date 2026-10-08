import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { decommissionSide, sideRecord, sideAccessAllowed } from '../../Resources/Gateway/side-lifecycle.mjs';
import { Registry, secureWrite } from '../../Resources/Gateway/registry.mjs';
import { retireRoutes } from '../../Resources/Tailscale/provider.mjs';

function fixture() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'boundas-side-'));
  const record = { id: 'folder', c2cID: 'abcdef123456', path: directory, sideGateAdded: true };
  const registry = new Registry({ directory: path.join(directory, 'main'), allowlistFile: path.join(directory, 'folders.json') });
  secureWrite(registry.allowlistFile, [record]);
  return { directory, record, registry, clean: () => fs.rmSync(directory, { recursive: true, force: true }) };
}
test('Side lifecycle refuses Main-only, missing, removing and malformed records', () => {
  const f = fixture();
  try {
    assert.equal(sideRecord(f.registry, 'FOLDER').c2cID, f.record.c2cID);
    for (const record of [{ ...f.record, sideGateAdded: false }, { ...f.record, sideGateRemovalState: 'removing' },
      { ...f.record, sideGateRemovalState: 'failed' }, { ...f.record, c2cID: '../main' }]) {
      secureWrite(f.registry.allowlistFile, [record]); assert.throws(() => sideRecord(f.registry, 'folder'));
    }
    assert.throws(() => sideRecord(f.registry, 'other'));
    assert.equal(sideAccessAllowed(f.registry, 'folder'), false);
  } finally { f.clean(); }
});
test('failed route retirement preserves credentials for retry; successful cleanup only clears Side state', async () => {
  const f = fixture();
  try {
    const auth = path.join(f.directory, 'auth', `${f.record.c2cID}.json`);
    const runtime = path.join(f.directory, 'runtime', `${f.record.c2cID}.json`);
    const marker = path.join(f.directory, 'side-gates', `${f.record.c2cID}.json`);
    const main = path.join(f.registry.directory, 'auth.json');
    for (const file of [auth, marker, main]) secureWrite(file, { retained: true });
    const runtimeAPI = { findBridgeObservation: async () => ({ state: 'stopped', runtime: null }), runtimeFile: () => runtime };
    const args = { record: f.record, runtimeAPI, stateDir: f.directory, adminFetch: () => { throw new Error('must not touch dead service'); } };
    await assert.rejects(decommissionSide({ ...args, retire: async () => { throw new Error('route failure'); } }), /route failure/);
    assert.ok(fs.existsSync(auth)); assert.ok(fs.existsSync(marker));
    await decommissionSide({ ...args, retire: async id => assert.equal(id, f.record.c2cID) });
    for (const file of [auth, runtime, marker]) assert.equal(fs.existsSync(file), false);
    assert.deepEqual(JSON.parse(fs.readFileSync(main)), { retained: true });
    await decommissionSide({ ...args, retire: async () => {} }); // Idempotent retry.
  } finally { f.clean(); }
});
test('unknown or mismatched service is never killed or hidden', async () => {
  const f = fixture();
  try {
    for (const observed of [{ state: 'unknown', runtime: null }, { state: 'healthy', runtime: { workspaceId: 'other', workspaceRoot: f.record.path } }]) {
      let touched = false;
      await assert.rejects(decommissionSide({ record: f.record, stateDir: f.directory,
        runtimeAPI: { findBridgeObservation: async () => observed }, adminFetch: async () => { touched = true; }, retire: async () => { touched = true; } }));
      assert.equal(touched, false);
    }
  } finally { f.clean(); }
});
test('route retirement leaves Main and other Side handlers untouched and rejects external edits', async () => {
  const f = fixture();
  try {
    const directory = path.join(f.directory, 'routes');
    const key = 'mac.example.ts.net:443', mount = `/c2c/${f.record.c2cID}/`, other = '/c2c/123456abcdef/';
    const ledger = { [`${key}${mount}`]: { id: f.record.c2cID, target: 'http://127.0.0.1:1234/owned/' },
      [`${key}${other}`]: { id: '123456abcdef', target: 'http://127.0.0.1:4567/main/' } };
    secureWrite(path.join(directory, 'routes.json'), ledger);
    const config = { Web: { [key]: { Handlers: { [mount]: { Proxy: 'http://127.0.0.1:9999/external/' }, [other]: { Proxy: ledger[`${key}${other}`].target } } } } };
    const run = async (_, args) => {
      if (args[1] === 'status') return JSON.stringify(config);
      assert.ok(args.includes(`--set-path=${mount}`)); delete config.Web[key].Handlers[mount]; return '';
    };
    await assert.rejects(retireRoutes(f.record.c2cID, { directory, binary: 'fake', run }), /外部更改/);
    config.Web[key].Handlers[mount].Proxy = ledger[`${key}${mount}`].target;
    await retireRoutes(f.record.c2cID, { directory, binary: 'fake', run });
    assert.ok(config.Web[key].Handlers[other]);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(directory, 'routes.json'))), { [`${key}${other}`]: ledger[`${key}${other}`] });
  } finally { f.clean(); }
});
