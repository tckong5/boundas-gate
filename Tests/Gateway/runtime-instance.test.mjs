import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { observeRuntime, clearOwnedRuntime } from '../../Resources/Gateway/runtime-instance.mjs';
import { secureWrite } from '../../Resources/Gateway/registry.mjs';

const record = { service: 'boundas-gateway', workspaceId: 'abcdef123456', pid: process.pid, port: 1234,
  instanceID: 'a'.repeat(64), startedAt: new Date().toISOString(), adminToken: `bg_admin_${'b'.repeat(64)}` };
for (const kind of ['reboot-stale', 'PID-reused', 'foreign-health', 'owned-unavailable', 'matched', 'nonce-mismatch']) test(`runtime observation: ${kind}`, async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'boundas-instance-')); const file = path.join(directory, 'runtime.json'); secureWrite(file, record);
  let adminCalls = 0;
  const owned = ['owned-unavailable', 'matched', 'nonce-mismatch'].includes(kind);
  const probe = async () => kind === 'matched' ? record : kind === 'nonce-mismatch' ? { ...record, instanceID: 'c'.repeat(64) }
    : kind === 'foreign-health' ? { ...record, workspaceId: 'other' } : null;
  try {
    const result = await observeRuntime(file, { gateID: record.workspaceId, service: record.service, probe, inspect: async () => owned,
      getInfo: async () => { adminCalls++; return record; } });
    assert.equal(result.state, kind === 'matched' ? 'healthy' : owned ? 'unknown' : 'stopped');
    assert.equal(adminCalls, kind === 'matched' ? 1 : 0);
    assert.equal(fs.existsSync(file), owned);
    if (!owned) {
      secureWrite(file, { ...record, instanceID: 'd'.repeat(64) });
      clearOwnedRuntime(file, record); assert.equal(fs.existsSync(file), true);
    }
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
