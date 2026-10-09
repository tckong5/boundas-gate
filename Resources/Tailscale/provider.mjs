import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import { randomBytes } from 'node:crypto';
import { execFile } from 'node:child_process';
import { withOwnerLock as withLock } from './owner-lock.mjs';
import { productDirectory, defaultProductPath } from './profile-paths.mjs';

export const stateDirectory = process.env.BOUNDAS_STATE_DIR ?? path.join(productDirectory, 'tailscale');
export function findBinary() {
  return [path.join(os.homedir(), 'Applications/Tailscale.app/Contents/MacOS/Tailscale'), '/Applications/Tailscale.app/Contents/MacOS/Tailscale', '/Applications/Tailscale.app/Contents/MacOS/tailscale', '/opt/homebrew/bin/tailscale', '/usr/local/bin/tailscale'].find(file => {
    try { fs.accessSync(file, fs.constants.X_OK); return true; } catch { return false; }
  });
}
export function command(binary, args, timeout = 12000) {
  return new Promise((resolve, reject) => {
    execFile(binary, args, { timeout, maxBuffer: 1024 * 1024, env: process.env }, (error, stdout, stderr) => {
      if (!error) return resolve(stdout);
      const output = `${stdout}\n${stderr}`;
      const approvalURL = output.match(/https:\/\/login\.tailscale\.com\/[^\s<>"']+/)?.[0];
      const failure = new Error(approvalURL
        ? `請先喺 Tailscale 頁面允許 HTTPS／Funnel，再返嚟重試。 ${approvalURL}`
        : 'Tailscale 未能完成設定。請確認已登入、已連線，同埋帳戶允許 Funnel。');
      failure.approvalURL = approvalURL;
      reject(failure);
    });
  });
}
export async function preflight(binary = findBinary(), run = command) {
  if (!binary) return { state: 'missing', message: '先安裝 Tailscale，再開啟並登入。' };
  try {
    const status = JSON.parse(await run(binary, ['status', '--json']));
    if (status.BackendState !== 'Running') {
      const setup = { state: 'login', message: '請登入／連線 Tunnel，再重新檢查。' };
      try {
        const url = new URL(status.AuthURL);
        if (url.protocol === 'https:' && url.hostname === 'login.tailscale.com' && !url.username && !url.password) setup.loginURL = url.href;
      } catch {}
      if (status.BackendState === 'NeedsMachineAuth') setup.approvalURL = 'https://login.tailscale.com/admin/machines';
      return setup;
    }
    const hostname = status.Self?.DNSName?.replace(/\.$/, '').toLowerCase();
    if (!hostname || !/^[a-z0-9-]+(?:\.[a-z0-9-]+)+\.ts\.net$/.test(hostname)) {
      return { state: 'blocked', message: 'Tailscale 未提供 HTTPS 主機名稱。請先啟用 MagicDNS。' };
    }
    return { state: 'ready', hostname, message: 'Tailscale 已連線，可以設定固定地址。' };
  } catch { return { state: 'login', message: '未能連接 Tailscale。請先開啟 App 並登入。' }; }
}
export function mounts(id) {
  if (!/^[a-f0-9]{12}$/.test(id)) throw new Error('Workspace ID 無效。');
  return [
    { path: `/c2c/${id}/`, mode: 'bridge' },
    { path: `/.well-known/oauth-authorization-server/c2c/${id}`, mode: 'issuer' },
    { path: `/.well-known/oauth-protected-resource/c2c/${id}/mcp`, mode: 'resource' },
    { path: `/.well-known/openid-configuration/c2c/${id}`, mode: 'issuer' },
  ];
}
function readLedger(directory) {
  try { return JSON.parse(fs.readFileSync(path.join(directory, 'routes.json'), 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return {}; throw new Error('固定地址設定記錄無效；未有更改 Tailscale。'); }
}
function writeLedger(directory, ledger) {
  const file = path.join(directory, 'routes.json');
  const temporary = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(ledger), { mode: 0o600 });
  fs.renameSync(temporary, file);
}
export async function retireRoutes(id, { directory = process.env.BOUNDAS_STATE_DIR ?? defaultProductPath('tailscale'), binary = findBinary(), run = command } = {}) {
  mounts(id); // Validate the Gate identity before inspecting its routes.
  await withLock(directory, async () => {
    const ledger = readLedger(directory);
    const entries = Object.entries(ledger).filter(([, entry]) => entry.id === id);
    if (!entries.length) return;
    if (!binary) throw new Error('未能清理 Side Gate Tunnel，請連接 Tailscale 後 Retry。');
    for (const [entryKey, entry] of entries) {
      const suffix = mounts(id).find(mount => entryKey.endsWith(mount.path))?.path;
      if (!suffix) throw new Error('Side Gate route 記錄無效，請重新檢查。');
      const key = entryKey.slice(0, -suffix.length);
      const config = JSON.parse(await run(binary, ['funnel', 'status', '--json']));
      const handler = config.Web?.[key]?.Handlers?.[suffix];
      if (handler && (![entry.target, entry.previousTarget].includes(handler.Proxy) || handler.Path || handler.Text || handler.Redirect)) {
        throw new Error('Side Gate route 已被外部更改；未有移除其他服務。');
      }
      if (handler) await run(binary, ['funnel', '--bg', '--yes', '--https=443', `--set-path=${suffix}`, 'off']);
      const after = JSON.parse(await run(binary, ['funnel', 'status', '--json']));
      if (after.Web?.[key]?.Handlers?.[suffix]) throw new Error('Side Gate route 尚未移除，可以 Retry。');
      delete ledger[entryKey]; writeLedger(directory, ledger);
    }
  });
}
export { withOwnerLock as withLock } from './owner-lock.mjs';
function handlerEntries(config, key) { return Object.entries(config?.Web?.[key]?.Handlers ?? {}); }
export function assertOwnedConfig(config, key, ledger) {
  if (config?.TCP?.['443'] && config.TCP['443'].HTTPS !== true) throw new Error('Tailscale 443 已經用於其他服務；未有更改。');
  if (Object.values(config?.Foreground ?? {}).some(item => item?.TCP?.['443'] || item?.Web?.[key])) {
    throw new Error('Tailscale 443 已經有其他前景服務；未有更改。');
  }
  for (const hostname of Object.keys(config?.Web ?? {}).filter(name => name.endsWith(':443'))) {
    for (const [mount, handler] of handlerEntries(config, hostname)) {
      const entry = ledger[`${hostname}${mount}`];
      if (!entry || ![entry.target, entry.previousTarget].includes(handler.Proxy) || handler.Path || handler.Text || handler.Redirect) {
        throw new Error('Tailscale 443 已經有其他服務。為免一併公開，App 未有更改設定。');
      }
    }
  }
}
export async function setupCheck(binary = findBinary(), run = command, directory = process.env.BOUNDAS_STATE_DIR ?? defaultProductPath('tailscale')) {
  const setup = await preflight(binary, run);
  if (setup.state !== 'ready') return setup;
  try {
    const config = JSON.parse(await run(binary, ['funnel', 'status', '--json']));
    assertOwnedConfig(config, `${setup.hostname}:443`, readLedger(directory));
    return setup;
  } catch (error) { return { state: 'blocked', hostname: setup.hostname, message: error.message }; }
}
const publicRoutes = new Set(['/health', '/mcp', '/oauth/register', '/oauth/authorize', '/oauth/token', '/oauth/revoke', '/.well-known/oauth-authorization-server', '/.well-known/oauth-authorization-server/mcp', '/.well-known/openid-configuration', '/.well-known/oauth-protected-resource', '/.well-known/oauth-protected-resource/mcp']);
export function proxyPath(raw, secret) {
  if (!raw?.startsWith(`/${secret}/`)) return null;
  const remainder = raw.slice(secret.length + 1);
  const match = /^\/(bridge|issuer|resource)(\/[^?]*)?(\?.*)?$/.exec(remainder);
  if (!match) return null;
  let route = match[2] || '/';
  if (match[1] !== 'bridge') {
    if (route !== '/') return null;
    route = match[1] === 'issuer' ? '/.well-known/oauth-authorization-server' : '/.well-known/oauth-protected-resource/mcp';
  }
  return publicRoutes.has(route) ? route + (match[3] ?? '') : null;
}
export function createGuardProxy(port, secret) {
  return http.createServer((request, response) => {
    const route = proxyPath(request.url, secret);
    if (!route) { response.writeHead(404); response.end(); return; }
    const headers = { ...request.headers, host: `127.0.0.1:${port}`, 'x-forwarded-for': '127.0.0.1', 'x-forwarded-proto': 'https' };
    // Never forward proxy configuration or connection-specific headers.
    for (const header of ['connection', 'proxy-authorization', 'proxy-connection', 'upgrade']) delete headers[header];
    const upstream = http.request({ hostname: '127.0.0.1', port, path: route, method: request.method, headers }, result => {
      response.writeHead(result.statusCode ?? 502, result.headers);
      result.pipe(response);
    });
    upstream.on('error', () => { if (!response.headersSent) response.writeHead(502); response.end(); });
    response.on('close', () => upstream.destroy());
    request.on('aborted', () => upstream.destroy());
    request.pipe(upstream);
  });
}

export class TailscaleProvider {
  name = 'tailscale-funnel';
  constructor(id, { binary = findBinary(), run = command, directory = process.env.BOUNDAS_STATE_DIR ?? defaultProductPath('tailscale'), expectedURL = null } = {}) {
    this.id = id; this.binary = binary; this.run = run; this.directory = directory;
    this.expectedURL = expectedURL;
    this.url = null; this.running = false; this.proxy = null; this.routes = []; this.timer = null; this.pending = Promise.resolve();
  }
  async config() { return JSON.parse(await this.run(this.binary, ['funnel', 'status', '--json'])); }
  enqueue(action) {
    const task = this.pending.then(action); this.pending = task.catch(() => {}); return task;
  }
  start(port) { return this.enqueue(() => this.startInternal(port)); }
  stop() { return this.enqueue(() => this.stopInternal()); }
  async startInternal(port) {
    const setup = await preflight(this.binary, this.run);
    if (setup.state !== 'ready') throw new Error(setup.message);
    const url = `https://${setup.hostname}/c2c/${this.id}`;
    if (this.expectedURL && url !== this.expectedURL) throw new Error('Tailscale 地址同原有 ChatGPT 設定唔一致。請連返原有 Tailscale 帳戶／裝置；App 未有更改地址或授權。');
    const key = `${setup.hostname}:443`;
    // Check ownership before opening a proxy or changing any network setting.
    await withLock(this.directory, async () => assertOwnedConfig(await this.config(), key, readLedger(this.directory)));
    if (this.proxy) await this.stopInternal();
    const secret = randomBytes(32).toString('hex');
    this.proxy = createGuardProxy(port, secret);
    try {
      await new Promise((resolve, reject) => { this.proxy.once('error', reject); this.proxy.listen(0, '127.0.0.1', resolve); });
    } catch (error) { this.proxy = null; throw error; }
    this.key = key;
    this.routes = mounts(this.id).map(mount => ({ ...mount, target: `http://127.0.0.1:${this.proxy.address().port}/${secret}/${mount.mode}/` }));
    try {
      await withLock(this.directory, async () => {
        const ledger = readLedger(this.directory);
        assertOwnedConfig(await this.config(), key, ledger);
        for (const route of this.routes) {
          const entryKey = `${key}${route.path}`;
          if (ledger[entryKey] && ledger[entryKey].id !== this.id) throw new Error('固定地址路徑已被其他服務使用。');
          // Journal before mutation so an interrupted start can be recovered.
          ledger[entryKey] = { id: this.id, target: route.target, previousTarget: ledger[entryKey]?.target };
          writeLedger(this.directory, ledger);
          await this.run(this.binary, ['funnel', '--bg', '--yes', '--https=443', `--set-path=${route.path}`, route.target], 25000);
          delete ledger[entryKey].previousTarget; writeLedger(this.directory, ledger);
        }
        const config = await this.config();
        if (!config.AllowFunnel?.[key] || !this.routes.every(route => config.Web?.[key]?.Handlers?.[route.path]?.Proxy === route.target)) {
          throw new Error('Tailscale 未確認公開連線；請重新檢查。');
        }
      });
      this.url = url;
      this.running = true;
      this.timer = setInterval(() => { void this.verify(); }, 10000);
      this.timer.unref();
      return this.url;
    } catch (error) { await this.stopInternal().catch(() => {}); throw error; }
  }
  async verify() {
    const proxy = this.proxy;
    try {
      const setup = await preflight(this.binary, this.run);
      const config = await this.config();
      if (this.proxy !== proxy) return;
      this.running = Boolean(proxy) && setup.state === 'ready' && `${setup.hostname}:443` === this.key && config.AllowFunnel?.[this.key] === true
        && this.routes.every(route => config.Web?.[this.key]?.Handlers?.[route.path]?.Proxy === route.target);
    } catch { if (this.proxy === proxy) this.running = false; }
  }
  async stopInternal() {
    clearInterval(this.timer); this.timer = null; this.running = false; this.url = null;
    // Close the private proxy first. Leftover routes cannot reach this bridge.
    const proxy = this.proxy; this.proxy = null;
    if (proxy) { proxy.closeAllConnections(); await new Promise(resolve => proxy.close(resolve)); }
    if (!this.key || !this.binary) return;
    await withLock(this.directory, async () => {
      const ledger = readLedger(this.directory);
      for (const route of this.routes) {
        const entryKey = `${this.key}${route.path}`;
        if (ledger[entryKey]?.target !== route.target) continue;
        const config = await this.config();
        const current = config.Web?.[this.key]?.Handlers?.[route.path];
        if (current && [route.target, ledger[entryKey]?.previousTarget].includes(current.Proxy)) {
          await this.run(this.binary, ['funnel', '--bg', '--yes', '--https=443', `--set-path=${route.path}`, 'off']);
        } else if (current) { continue; } // An external edit must be left untouched.
        delete ledger[entryKey]; writeLedger(this.directory, ledger);
      }
    });
  }
  async restart(port) { await this.stop(); return this.start(port); }
  status() { return { running: this.running, url: this.url, provider: this.name }; }
  getPublicUrl() { return this.url; }
  async doctor() { await this.verify(); return { provider: this.name, binaryFound: Boolean(this.binary), binaryPath: this.binary, running: this.running, url: this.url, problems: this.running ? [] : ['固定地址未能連線'] }; }
}
