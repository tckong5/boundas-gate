import { createHash, randomBytes } from 'node:crypto';

const hash = value => createHash('sha256').update(value).digest('hex');
const denied = (message = '請喺 App 產生 Folder 通行碼，再 call unlock_workspace。') =>
  Object.assign(new Error(message), { code: 'FOLDER_LOCKED' });

// Capabilities and codes live only in this daemon. OAuth remains required on every call.
// Conversation metadata is an additional binding, never an access credential by itself.
export class FolderAccess {
  constructor(registry, { now = Date.now } = {}) {
    this.registry = registry; this.now = now;
    this.codes = new Map(); this.keys = new Map(); this.attempts = new Map();
    this.globalAttempts = { start: 0, count: 0 };
  }
  cleanup() {
    const now = this.now();
    for (const [id, value] of this.codes) if (value.expiresAt <= now || !this.current(value)) this.codes.delete(id);
    for (const [id, value] of this.keys) if (value.expiresAt <= now || !this.current(value)) this.keys.delete(id);
    for (const [id, value] of this.attempts) if (value.start + 60000 <= now) this.attempts.delete(id);
  }
  current(value) {
    const root = this.registry.active().find(item => item.id === value.rootID);
    return root?.codeRequired === true && value.gateID === this.registry.read()?.id && root.epoch === value.epoch && root.codeEpoch === value.codeEpoch;
  }
  context(extra) {
    const token = extra.authInfo?.token;
    const session = extra._meta?.['openai/session'];
    if (typeof token !== 'string' || !token || typeof session !== 'string' || !session.length || session.length > 512 || /[\x00-\x1f\x7f]/.test(session)) {
      throw denied('未收到對話識別資料，已拒絕解鎖。請提供此對話專用 session_id 再試。');
    }
    return { principal: hash(token), session };
  }
  issue(id) {
    this.cleanup();
    const root = this.registry.active().find(item => item.id === id);
    if (root?.codeRequired !== true) throw new Error('請先為呢個 Folder 開啟通行碼。');
    this.revoke(id); // Regeneration invalidates previous codes and capabilities for this root.
    const code = `BG-${randomBytes(12).toString('hex').toUpperCase().match(/.{4}/g).join('-')}`;
    const value = { gateID: this.registry.read().id, rootID: id, epoch: root.epoch, codeEpoch: root.codeEpoch, expiresAt: this.now() + 5 * 60000 };
    this.codes.set(hash(code), value);
    return { ok: true, workspaceID: id, name: root.name, code, expiresAt: value.expiresAt };
  }
  revoke(id) {
    for (const [key, value] of this.codes) if (value.rootID === id) this.codes.delete(key);
    for (const [key, value] of this.keys) if (value.rootID === id) this.keys.delete(key);
  }
  revokeAll() { this.codes.clear(); this.keys.clear(); this.attempts.clear(); }
  revokePrincipals(hashes) {
    const principals = new Set(hashes);
    for (const [id, grant] of this.keys) if (principals.has(grant.principal)) this.keys.delete(id);
  }
  unlock(code, scopes, extra) {
    this.cleanup();
    const context = this.context(extra);
    const now = this.now();
    if (this.globalAttempts.start + 60000 <= now) this.globalAttempts = { start: now, count: 0 };
    const attempts = this.attempts.get(context.principal) ?? { start: now, count: 0 };
    if (attempts.count >= 10 || this.globalAttempts.count >= 100 || (!this.attempts.has(context.principal) && this.attempts.size >= 1024)) {
      throw Object.assign(new Error('嘗試次數太多，請一分鐘後再試。'), { code: 'RATE_LIMITED' });
    }
    attempts.count++; this.globalAttempts.count++; this.attempts.set(context.principal, attempts);
    const digest = hash(code.trim().toUpperCase());
    const value = this.codes.get(digest);
    if (!value) throw denied('通行碼無效、已過期或已使用。請喺 App 重新產生。');
    // The code cannot bypass instance authorization or the current shared registry.
    const root = this.registry.authorized(value.rootID, scopes);
    if (!this.current(value)) throw denied();
    if (this.keys.size >= 1024) throw denied('暫時無法新增讀取授權，請稍後再試。');
    this.codes.delete(digest);
    const key = `bg_access_${randomBytes(32).toString('hex')}`;
    const grant = { ...value, ...context, expiresAt: Math.min(now + 30 * 60000, (extra.authInfo.expiresAt ?? 0) * 1000) };
    if (grant.expiresAt <= now) throw denied('OAuth 授權已過期，請重新連線。');
    this.keys.set(hash(key), grant);
    return { workspace_id: root.id, name: root.name, access_key: key, expires_at: grant.expiresAt,
      instruction: 'Include this access_key and the same conversation session_id (when explicit session_id was used) on every tool call for this folder. Do not print, store in files, or share the key. Other folders require their own authorization.' };
  }
  check(root, key, extra) {
    if (root.codeRequired !== true) return;
    this.cleanup();
    const context = this.context(extra);
    const value = typeof key === 'string' ? this.keys.get(hash(key)) : undefined;
    if (!value || value.gateID !== this.registry.read().id || value.rootID !== root.id || value.epoch !== root.epoch || value.codeEpoch !== root.codeEpoch
      || value.principal !== context.principal || value.session !== context.session || value.expiresAt <= this.now()) throw denied();
  }
  status() {
    this.cleanup();
    return this.registry.active().filter(root => root.codeRequired === true).map(root => ({ workspaceID: root.id,
      codeActive: [...this.codes.values()].some(value => value.rootID === root.id),
      unlockedCount: [...this.keys.values()].filter(value => value.rootID === root.id).length }));
  }
}
