import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Registry, secureWrite, fileIdentity } from '../../Resources/Gateway/registry.mjs';
import { SideRegistry } from '../../Resources/Gateway/side-registry.mjs';

function fixture() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'boundas-identity-recovery-'));
  const folder = path.join(directory, 'Folder'); fs.mkdirSync(folder);
  const current = fileIdentity(folder), previous = `999999:${current.split(':')[1]}`;
  const record = { id: '11111111-1111-4111-8111-111111111111', c2cID: 'abcdef123456',
    path: folder, name: 'Fixture', sideGateAdded: true, folderFileIdentity: current,
    folderBookmark: Buffer.from('trusted local bookmark fixture').toString('base64'),
    folderIdentityRecovery: { previous, current, path: folder } };
  const root = { id: record.c2cID, sourceID: record.id, name: record.name, path: folder,
    fileIdentity: previous, enabled: true, epoch: 'a'.repeat(32), codeRequired: true, codeEpoch: 'b'.repeat(32) };
  const registry = new Registry({ directory: path.join(directory, 'gateway'), allowlistFile: path.join(directory, 'workspaces.json') });
  const config = { id: '123456abcdef', roots: [root], transport: 'embedded', sharedIngress: true,
    desiredRunning: true, stableMCPURL: 'https://fixture.example.ts.net/mcp' };
  secureWrite(registry.allowlistFile, [record]); secureWrite(path.join(registry.directory, 'config.json'), config);
  const auth = path.join(registry.directory, 'auth.json'); secureWrite(auth, { fixture: 'untouched' });
  class Workspace { constructor(value) { this.root = value; this.id = record.c2cID; } }
  return { directory, registry, record, root, config, current, previous, auth, Workspace,
    clean: () => fs.rmSync(directory, { recursive: true, force: true }) };
}

test('verified remount handoff fixes the failing configure fixture and preserves policy', () => {
  const f = fixture();
  try {
    const auth = fs.readFileSync(f.auth);
    assert.equal(f.registry.active().length, 0);
    const config = f.registry.configure([f.record.id], f.Workspace);
    assert.deepEqual(config, { ...f.config, roots: [{ ...f.root, fileIdentity: f.current }] });
    assert.equal(f.registry.active().length, 1);
    assert.deepEqual(fs.readFileSync(f.auth), auth);
  } finally { f.clean(); }
});

test('identity-only synchronization preserves disabled membership, epochs and Side policy', () => {
  const f = fixture();
  try {
    const config = { ...f.config, roots: [{ ...f.root, enabled: false }] };
    secureWrite(path.join(f.registry.directory, 'config.json'), config);
    f.registry.synchronizeFolderIdentities();
    assert.deepEqual(f.registry.read(), { ...config, roots: [{ ...config.roots[0], fileIdentity: f.current }] });
    assert.equal(f.registry.active().length, 0);
    const side = new SideRegistry(f.registry, f.record.id, path.join(f.directory, 'side'));
    const existing = { id: f.record.c2cID, epoch: 'c'.repeat(32), transport: 'shared', desiredRunning: false };
    secureWrite(path.join(side.directory, 'config.json'), existing);
    const recovered = side.ensure();
    assert.equal(recovered.epoch, existing.epoch);
    assert.equal(recovered.roots[0].codeEpoch, f.root.codeEpoch);
    assert.equal(recovered.roots[0].codeRequired, true);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(side.directory, 'config.json'))), existing);
  } finally { f.clean(); }
});

test('device/inode resemblance without verified recovery never opens a Folder', () => {
  const f = fixture();
  try {
    const original = fs.readFileSync(path.join(f.registry.directory, 'config.json'));
    for (const change of [
      { folderIdentityRecovery: undefined },
      { folderBookmark: undefined },
      { folderIdentityRecovery: { ...f.record.folderIdentityRecovery, previous: '1:2' } },
      { folderIdentityRecovery: { ...f.record.folderIdentityRecovery, path: '/different' } },
    ]) {
      secureWrite(f.registry.allowlistFile, [{ ...f.record, ...change }]);
      assert.throws(() => f.registry.configure([f.record.id], f.Workspace), /身份已改變/);
      assert.throws(() => f.registry.ensureFolderPolicy({ ...f.record, ...change }), /身份已改變/);
      f.registry.synchronizeFolderIdentities();
      assert.deepEqual(fs.readFileSync(path.join(f.registry.directory, 'config.json')), original);
      assert.equal(f.registry.active().length, 0);
    }
  } finally { f.clean(); }
});

test('replacement Folder rejects stale proof and cannot inherit Passcode or epoch', () => {
  const f = fixture();
  try {
    const original = fs.readFileSync(path.join(f.registry.directory, 'config.json'));
    fs.renameSync(f.record.path, path.join(f.directory, 'Original'));
    fs.mkdirSync(f.record.path);
    assert.notEqual(fileIdentity(f.record.path), f.current);
    assert.throws(() => f.registry.configure([f.record.id], f.Workspace), /身份未能確認/);
    assert.throws(() => f.registry.ensureFolderPolicy(f.record), /身份已改變/);
    f.registry.synchronizeFolderIdentities();
    assert.equal(f.registry.active().length, 0);
    assert.deepEqual(fs.readFileSync(path.join(f.registry.directory, 'config.json')), original);
  } finally { f.clean(); }
});
