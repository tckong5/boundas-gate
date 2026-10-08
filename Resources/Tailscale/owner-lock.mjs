import fs from 'node:fs';
import path from 'node:path';
import { randomBytes } from 'node:crypto';

const alive = pid => {
  if (!Number.isInteger(pid) || pid < 1) return null;
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'ESRCH' ? false : null; }
};
const read = file => { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; } };
const same = (a, b) => a?.ino === b?.ino && a?.dev === b?.dev;
const stat = file => { try { return fs.lstatSync(file); } catch (error) { if (error.code === 'ENOENT') return null; throw error; } };
function stale(lock, now, grace, info = stat(lock)) {
  if (!info?.isDirectory() || info.isSymbolicLink()) return false;
  const owner = read(path.join(lock, 'owner.json'));
  if (owner && typeof owner.token === 'string' && Number.isFinite(owner.createdAt)) {
    const state = alive(owner.pid);
    if (Number.isInteger(owner.pid) && owner.pid > 0) return state === false;
  }
  // Support pre-upgrade PID files; an active PID is never reclaimed by age.
  try {
    const pid = Number(fs.readFileSync(path.join(lock, 'pid'), 'utf8'));
    const state = alive(pid); if (Number.isInteger(pid) && pid > 0) return state === false;
  } catch {}
  return now - info.mtimeMs > grace;
}
function reclaim(lock, now, grace) {
  const original = stat(lock);
  if (!stale(lock, now, grace)) return false;
  const claimFile = path.join(lock, 'reclaim.json');
  const token = randomBytes(16).toString('hex');
  let descriptor;
  try { descriptor = fs.openSync(claimFile, 'wx', 0o600); }
  catch (error) {
    if (error.code === 'ENOENT') return false;
    if (error.code !== 'EEXIST') throw error;
    const claim = read(claimFile), info = stat(claimFile);
    const state = alive(claim?.pid);
    const malformed = !Number.isInteger(claim?.pid) || claim.pid < 1;
    if (state === false || (malformed && info && now - info.mtimeMs > grace)) {
      // Only a stale lock has this path; never touch a new replacement directory.
      if (same(original, stat(lock))) fs.rmSync(claimFile, { force: true });
    }
    return false;
  }
  try {
    fs.writeFileSync(descriptor, JSON.stringify({ pid: process.pid, token, createdAt: now }));
    if (!same(original, stat(lock)) || !stale(lock, now, grace, original)) return false;
    // The exclusive reclaim claim serializes stale-lock recovery. Active owners
    // cannot enter this branch, and other reclaimers cannot remove this claim.
    const retired = `${lock}.stale.${token}`;
    fs.renameSync(lock, retired);
    fs.rmSync(retired, { recursive: true, force: true });
    return true;
  } finally {
    fs.closeSync(descriptor);
    if (same(original, stat(lock)) && read(claimFile)?.token === token) fs.rmSync(claimFile, { force: true });
  }
}

export async function withOwnerLock(directory, action, { grace = 30000, attempts = 80, delay = 250, now = Date.now } = {}) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const lock = path.join(directory, 'config.lock');
  const owner = { pid: process.pid, createdAt: now(), token: randomBytes(16).toString('hex') };
  for (let attempt = 0; attempt < attempts; attempt++) {
    try { fs.mkdirSync(lock, { mode: 0o700 }); }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      if (reclaim(lock, now(), grace)) continue;
      await new Promise(resolve => setTimeout(resolve, delay)); continue;
    }
    const identity = stat(lock);
    const temporary = path.join(lock, `owner.${owner.token}.tmp`);
    let published = false;
    try {
      fs.writeFileSync(temporary, JSON.stringify(owner), { mode: 0o600, flag: 'wx' });
      fs.renameSync(temporary, path.join(lock, 'owner.json'));
      published = true;
      return await action();
    } finally {
      const current = read(path.join(lock, 'owner.json'));
      if (same(identity, stat(lock)) && (current?.token === owner.token || (!published && !current))) fs.rmSync(lock, { recursive: true, force: true });
    }
  }
  throw new Error('另一個 Folder 正在設定，請稍後再試。');
}
