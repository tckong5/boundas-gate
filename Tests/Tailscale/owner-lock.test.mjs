import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { withOwnerLock } from '../../Resources/Tailscale/owner-lock.mjs';

const fixture = () => fs.mkdtempSync(path.join(os.tmpdir(), 'boundas-owner-lock-'));
test('normal contention is serialized and old active owners are not reclaimed by age', async () => {
  const directory = fixture(); let active = 0; let maximum = 0;
  try {
    await Promise.all(Array.from({ length: 6 }, () => withOwnerLock(directory, async () => {
      active++; maximum = Math.max(maximum, active);
      const lock = path.join(directory, 'config.lock'); fs.utimesSync(lock, new Date(0), new Date(0));
      await new Promise(resolve => setTimeout(resolve, 20)); active--;
    }, { delay: 5, attempts: 100, grace: 1 })));
    assert.equal(maximum, 1); assert.equal(fs.existsSync(path.join(directory, 'config.lock')), false);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
test('a dead owner lock is reclaimed after a real process exits', async () => {
  const directory = fixture();
  const script = `import { withOwnerLock } from ${JSON.stringify(pathToFileURL(path.resolve('Resources/Tailscale/owner-lock.mjs')).href)}; await withOwnerLock(${JSON.stringify(directory)}, async () => { process.stdout.write('owned'); setInterval(() => {}, 1000); await new Promise(() => {}); });`;
  const child = spawn(process.execPath, ['--input-type=module', '-e', script], { stdio: ['ignore', 'pipe', 'pipe'] });
  try {
    await new Promise((resolve, reject) => { child.stdout.once('data', resolve); child.once('error', reject); child.once('exit', code => reject(new Error(`child exited ${code}`))); });
    child.kill('SIGKILL'); await new Promise(resolve => child.once('exit', resolve));
    assert.equal(await withOwnerLock(directory, async () => 'recovered', { delay: 1 }), 'recovered');
  } finally { if (child.exitCode === null && child.signalCode === null) child.kill(); fs.rmSync(directory, { recursive: true, force: true }); }
});
for (const kind of ['missing', 'malformed']) test(`${kind} owner metadata observes grace then recovers`, async () => {
  const directory = fixture(); const lock = path.join(directory, 'config.lock'); fs.mkdirSync(lock);
  if (kind === 'malformed') fs.writeFileSync(path.join(lock, 'owner.json'), '{broken');
  try {
    await assert.rejects(withOwnerLock(directory, async () => assert.fail('too soon'), { attempts: 2, delay: 1 }));
    fs.utimesSync(lock, new Date(0), new Date(0));
    assert.equal(await withOwnerLock(directory, async () => true, { delay: 1 }), true);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
test('cleanup refuses a replacement owner token', async () => {
  const directory = fixture();
  try {
    await withOwnerLock(directory, async () => fs.writeFileSync(path.join(directory, 'config.lock/owner.json'), JSON.stringify({ pid: process.pid, createdAt: Date.now(), token: 'different-owner' })));
    assert.equal(fs.existsSync(path.join(directory, 'config.lock')), true);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

test('malformed reclaim metadata cannot leave a permanent stale lock', async () => {
  const directory = fixture(); const lock = path.join(directory, 'config.lock'); fs.mkdirSync(lock);
  fs.writeFileSync(path.join(lock, 'reclaim.json'), JSON.stringify({ token: 'missing-pid' }));
  fs.utimesSync(path.join(lock, 'reclaim.json'), new Date(0), new Date(0)); fs.utimesSync(lock, new Date(0), new Date(0));
  try { assert.equal(await withOwnerLock(directory, async () => true, { delay: 1, grace: 1 }), true); }
  finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
