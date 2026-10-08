import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import os from 'node:os';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { setupCheck, TailscaleProvider, withLock, command } from './provider.mjs';

export function embeddedBinary() {
  const candidate = path.join(path.dirname(fileURLToPath(import.meta.url)), '../Runtime/bin/boundas-tunnel');
  try { fs.accessSync(candidate, fs.constants.X_OK); return candidate; } catch { return null; }
}
export function transportMode(registry, binary = embeddedBinary()) {
  const config = registry.read();
  if (config?.transport !== undefined && !['external', 'embedded', 'shared'].includes(config.transport)) throw new Error('連線模式無效；未有更改現有連線。');
  if (config?.transport) return config.transport;
  // Preserve the existing device identity and URL. Never silently convert it
  // into a new tsnet node, even if the external Tailscale app is unavailable.
  if (config?.stableMCPURL || config?.configuredMCPURL) return 'external';
  return binary ? 'embedded' : 'external';
}
export function embeddedLocation(registry) {
  const identity = path.join(registry.directory, 'embedded');
  const key = createHash('sha256').update(identity).digest('hex').slice(0, 16);
  return { identity, controlDirectory: `/private/tmp/boundas-tsnet-${os.userInfo().uid}-${key}`, socket: `/private/tmp/boundas-tsnet-${os.userInfo().uid}-${key}/control.sock` };
}
function verifyPrivateControl(directory) {
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== os.userInfo().uid || (stat.mode & 0o777) !== 0o700) throw new Error('內置連線控制目錄無效。');
}
export async function embeddedRequest(registry, route, body, timeout = 6000) {
  const location = embeddedLocation(registry);
  verifyPrivateControl(location.controlDirectory);
  const stat = fs.lstatSync(location.socket);
  if (!stat.isSocket() || stat.uid !== os.userInfo().uid || (stat.mode & 0o777) !== 0o600) throw new Error('內置連線控制端點無效。');
  return new Promise((resolve, reject) => {
    const request = http.request({ socketPath: location.socket, path: route, method: body ? 'POST' : 'GET', headers: body ? { 'Content-Type': 'application/json' } : {} }, response => {
      let output = '';
      response.on('data', bytes => { output += bytes; if (output.length > 131072) request.destroy(new Error('內置連線回應無效。')); });
      response.on('end', () => { try {
        const value = JSON.parse(output);
        if (!value.ok || response.statusCode !== 200) throw Object.assign(new Error(value.message ?? '內置連線未能完成操作。'), { approvalURL: value.approvalURL, errorCode: value.errorCode, backendState: value.backendState });
        if (route === '/status' && (value.service !== 'boundas-tsnet' || value.gatewayID !== registry.read()?.id)) throw new Error('內置連線身份唔一致。');
        resolve(value);
      } catch (error) { reject(error); } });
    });
    request.setTimeout(timeout, () => request.destroy(new Error('內置連線未有回應。')));
    request.on('error', reject); request.end(body ? JSON.stringify(body) : undefined);
  });
}
export async function embeddedSetup(registry, { start = false, requestLogin = true, forceLogin = false, binary = embeddedBinary() } = {}) {
  if (!registry.read()) return { state: 'unconfigured', message: '開啟 Main Gate，開始設定 Tunnel。' };
  if (!binary) return { state: 'missing', message: '安裝包缺少內置連線元件，請重新安裝 Boundas Gate。' };
  let status;
  try { status = await embeddedRequest(registry, '/status'); }
  catch (error) {
    // An unverified endpoint must not be replaced or killed.
    if (!['ENOENT', 'ECONNREFUSED'].includes(error.code)) throw error;
    if (!start) return { state: 'login', message: '按「登入內置連線」完成首次登入。' };
    await withLock(registry.directory, async () => {
      try { await embeddedRequest(registry, '/status'); return; }
      catch (failure) { if (!['ENOENT', 'ECONNREFUSED'].includes(failure.code)) throw failure; }
      const location = embeddedLocation(registry);
      // The helper takes an OS lock, preventing duplicate node identities.
      const child = spawn(binary, ['--state-dir', location.identity, '--gateway-id', registry.read().id], {
        detached: true, stdio: 'ignore', env: { PATH: '/usr/bin:/bin', HOME: os.homedir(), TMPDIR: '/private/tmp', TS_NO_LOGS_NO_SUPPORT: 'true' }
      });
      let launchError; child.once('error', error => { launchError = error; }); child.unref();
      const deadline = Date.now() + 12000;
      while (Date.now() < deadline) {
        if (launchError || child.exitCode !== null) throw new Error('內置連線未能啟動。');
        try { await embeddedRequest(registry, '/status'); return; }
        catch (failure) { if (!['ENOENT', 'ECONNREFUSED'].includes(failure.code)) throw failure; }
        await new Promise(resolve => setTimeout(resolve, 200));
      }
      throw new Error('內置連線未能啟動。');
    });
    status = await embeddedRequest(registry, '/status');
  }
  if (!start || !requestLogin) return status;
  let requestedLogin = false;
  if (forceLogin && status.state === 'login' && !status.approvalURL) {
    status = await embeddedRequest(registry, '/login', {}, 45000);
    requestedLogin = true;
  }
  for (let attempt = 0; attempt < 40 && ['starting', 'login'].includes(status.state) && !status.loginURL && !status.approvalURL; attempt++) {
    // Startup may report "starting" before the node enters NeedsLogin. Request
    // interactive login at that transition, rather than only at the first read.
    if (status.state === 'login' && !requestedLogin) {
      status = await embeddedRequest(registry, '/login', {}, 45000);
      requestedLogin = true;
      if (status.loginURL || status.approvalURL || !['starting', 'login'].includes(status.state)) break;
    }
    await new Promise(resolve => setTimeout(resolve, 300)); status = await embeddedRequest(registry, '/status');
  }
  if (status.state === 'blocked' && !status.approvalURL) status = await embeddedRequest(registry, '/approve', {}, 12000);
  if (['starting', 'login'].includes(status.state) && !status.loginURL && !status.approvalURL) {
    throw Object.assign(new Error('Tailscale 登入回應未完成，請稍後再按 Sign In；原有設定已保留。'), { errorCode: 'login_timeout', backendState: status.backendState });
  }
  return status;
}
export async function gatewaySetup(registry, options) {
  if (transportMode(registry) === 'shared') return gatewaySetup(registry.main, options);
  if (transportMode(registry) !== 'embedded') return setupCheck();
  const status = await embeddedSetup(registry, options);
  return options?.start && registry.read()?.sharedIngress && status.state === 'ready' ? sharedAgent(registry) : status;
}
async function upgradeAccountAgent(registry, status, binary, capability = 'accountManagementVersion', version = 1) {
  // Old helpers remain alive across app updates. Replace only a verified
  // private agent owned by this exact Gate; never kill an unverified PID.
  const pid = status.pid;
  if (!Number.isInteger(pid) || pid < 1) throw new Error('未能確認舊 Tunnel 管理元件，未有操作任何程序。');
  const location = embeddedLocation(registry);
  const [owner, executable, argumentsText] = await Promise.all([
    command('/bin/ps', ['-p', String(pid), '-o', 'uid=']),
    command('/bin/ps', ['-p', String(pid), '-o', 'comm=']),
    command('/bin/ps', ['-p', String(pid), '-o', 'args='])
  ]);
  if (Number(owner.trim()) !== os.userInfo().uid || path.basename(executable.trim()) !== 'boundas-tunnel'
      || !argumentsText.trim().endsWith(`--state-dir ${location.identity} --gateway-id ${registry.read().id}`)) {
    throw new Error('舊 Tunnel 管理元件身份唔一致，未有操作任何程序。');
  }
  // Recheck the private endpoint immediately before signalling that process.
  if ((await embeddedRequest(registry, '/status')).pid !== pid) throw new Error('Tunnel 管理元件已變更，請重新檢查。');
  process.kill(pid, 'SIGTERM');
  const deadline = Date.now() + 12000;
  while (Date.now() < deadline) {
    try { await embeddedRequest(registry, '/status'); }
    catch (error) {
      // This is the verified old agent we just signalled. A request crossing
      // its socket shutdown is expected; wait until the endpoint is absent.
      if (['ECONNRESET', 'EPIPE'].includes(error.code)) {
        await new Promise(resolve => setTimeout(resolve, 200));
        continue;
      }
      if (['ENOENT', 'ECONNREFUSED'].includes(error.code)) {
        const upgraded = await embeddedSetup(registry, { start: true, requestLogin: false, binary });
        if (upgraded[capability] === version) return;
        break;
      }
      throw error;
    }
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  throw new Error('Tunnel 管理元件未完成更新，請稍後重試。');
}
export async function tunnelAccount(registry, action, { binary = embeddedBinary(), run = command, confirmedExternal = false } = {}) {
  if (!['login', 'logout'].includes(action)) throw new Error('Tunnel 操作無效。');
  if (transportMode(registry, binary) === 'shared') return tunnelAccount(registry.main, action, { binary, run, confirmedExternal });
  if (transportMode(registry, binary) === 'external') {
    if (action === 'logout' && !confirmedExternal) throw new Error('外置 Tunnel 登出會影響同一 Mac 裝置嘅其他連線，請先確認。');
    if (!binary) throw new Error('安裝包缺少 Tunnel 管理元件，請更新 Boundas Gate。');
    const result = JSON.parse(await run(binary, ['--external-auth', action], 16000));
    if (!result.ok) throw new Error(result.message ?? 'Tunnel 操作未能完成。');
    return result;
  }
  const setup = await embeddedSetup(registry, { start: true, requestLogin: false, binary });
  if (action === 'login') {
    if (setup.state !== 'ready' && setup.loginManagementVersion !== 2) {
      await upgradeAccountAgent(registry, setup, binary, 'loginManagementVersion', 2);
    }
    return embeddedSetup(registry, { start: true, requestLogin: true, forceLogin: true, binary });
  }
  if (setup.accountManagementVersion !== 1) await upgradeAccountAgent(registry, setup, binary);
  return embeddedRequest(registry, '/logout', {}, 12000);
}
export class EmbeddedProvider {
  name = 'tailscale-embedded';
  constructor(registry, { expectedURL = null, request = embeddedRequest } = {}) {
    this.registry = registry; this.expectedURL = expectedURL; this.request = request; this.running = false; this.url = null;
    this.timer = null;
  }
  async start(port) {
    const setup = await this.request(this.registry, '/status');
    if (setup.state !== 'ready') throw Object.assign(new Error(setup.message), { approvalURL: setup.approvalURL });
    const expected = `https://${setup.hostname}/c2c/${this.registry.read().id}`;
    if (this.expectedURL && this.expectedURL !== expected) throw new Error('固定地址同原有 ChatGPT 設定唔一致；未有更改地址或授權。');
    const reply = await this.request(this.registry, '/start', { port, expectedURL: this.expectedURL ?? expected }, 35000);
    if (reply.publicUrl !== expected) { await this.stop(); throw new Error('內置連線地址無效。'); }
    this.url = reply.publicUrl; this.running = true;
    clearInterval(this.timer); this.timer = setInterval(() => { void this.verify(); }, 10000); this.timer.unref();
    return this.url;
  }
  async verify() {
    try { const status = await this.request(this.registry, '/status'); this.running = status.running === true && status.publicUrl === this.url; } catch { this.running = false; }
  }
  async stop() { clearInterval(this.timer); this.timer = null; this.running = false; this.url = null; await this.request(this.registry, '/stop', {}).catch(error => { if (!['ENOENT', 'ECONNREFUSED'].includes(error.code)) throw error; }); }
  status() { return { running: this.running, url: this.url, provider: this.name }; }
}

export async function sharedAgent(registry, { binary = embeddedBinary() } = {}) {
  const main = registry.main ?? registry;
  if (transportMode(main, binary) !== 'embedded') throw new Error('共用 Secure Access 需要 Main Gate 使用 App 內置 Tailscale；原有地址及授權已保留。');
  // A different lock from embeddedSetup's identity lock avoids nested locking.
  return withLock(path.join(main.directory, 'shared-ingress'), async () => {
    let status = await embeddedSetup(main, { start: false, requestLogin: false, binary });
    if (status.routeManagementVersion === 1) return status;
    let runtime;
    try { runtime = JSON.parse(fs.readFileSync(path.join(main.directory, 'runtime.json'), 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    let restore;
    if (status.running) {
      if (!runtime || runtime.workspaceId !== main.read().id || !/^[a-f0-9]{64}$/.test(runtime.instanceID ?? '')
          || !/^bg_admin_[a-f0-9]{64}$/.test(runtime.adminToken ?? '') || !Number.isInteger(runtime.port) || runtime.port < 1 || runtime.port > 65535) {
        throw new Error('未能確認 Main Gate，未有更新共用 Tunnel。');
      }
      const healthResponse = await fetch(`http://127.0.0.1:${runtime.port}/health`, { redirect: 'error', signal: AbortSignal.timeout(3000) });
      const health = await healthResponse.json();
      if (!healthResponse.ok || health.service !== 'boundas-gateway' || health.workspaceId !== main.read().id || health.instanceID !== runtime.instanceID) {
        throw new Error('Main Gate runtime 已變更，未有傳送管理憑證或更新 Tunnel。');
      }
      const info = await fetch(`http://127.0.0.1:${runtime.port}/control/info`, {
        headers: { Authorization: `Bearer ${runtime.adminToken}` }, redirect: 'error', signal: AbortSignal.timeout(3000)
      });
      const body = await info.json();
      if (!info.ok || body.instanceID !== runtime.instanceID || body.gatewayID !== main.read().id || body.pid !== runtime.pid) throw new Error('Main Gate 身份不符，未有更新共用 Tunnel。');
      restore = { gateID: main.read().id, port: runtime.port, instanceID: runtime.instanceID, expectedURL: status.publicUrl };
    }
    await upgradeAccountAgent(main, status, binary, 'routeManagementVersion', 1);
    status = await embeddedRequest(main, '/status');
    // Replacing the helper does not log in again, but tsnet needs a moment to
    // resume its persisted identity. Do not report a transient startup as a
    // new account setup or leave the already-open Main route un-restored.
    const deadline = Date.now() + 15000;
    while (status.state === 'starting' && Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 300));
      status = await embeddedRequest(main, '/status');
    }
    if (restore && status.state === 'ready' && main.connection().desiredRunning !== false) {
      let current;
      try { current = JSON.parse(fs.readFileSync(path.join(main.directory, 'runtime.json'), 'utf8')); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      if (current?.instanceID === restore.instanceID) await embeddedRequest(main, '/routes/start', restore, 35000);
    }
    return status;
  });
}

export class SharedEmbeddedProvider {
  name = 'tailscale-shared';
  constructor(registry, { expectedURL = null, request = embeddedRequest, prepare = sharedAgent } = {}) {
    this.registry = registry; this.main = registry.main ?? registry; this.gateID = registry.read().id;
    this.expectedURL = expectedURL; this.request = request; this.prepare = prepare;
    this.running = false; this.url = null; this.instanceID = null; this.timer = null;
  }
  async start(port, instanceID) {
    if (!/^[a-f0-9]{64}$/.test(instanceID ?? '')) throw new Error('Gate runtime identity is missing.');
    const setup = await this.prepare(this.registry);
    if (setup.state !== 'ready') throw Object.assign(new Error(setup.message), { approvalURL: setup.approvalURL });
    const gateID = this.registry.read().id;
    const canonical = `https://${setup.hostname}${this.registry.sideMode ? `/side/${gateID}` : ''}`;
    const expected = !this.registry.sideMode && this.expectedURL === `https://${setup.hostname}/c2c/${gateID}` ? this.expectedURL : canonical;
    if (this.expectedURL && this.expectedURL !== expected) throw new Error('Gate 固定地址不符；未有更改 URL 或授權。');
    const reply = await this.request(this.main, '/routes/start', { gateID, instanceID, port, expectedURL: expected }, 35000);
    if (reply.publicUrl !== expected) throw new Error('共用 Tunnel 回傳無效 Gate 地址。');
    this.instanceID = instanceID; this.url = expected; this.running = true;
    clearInterval(this.timer); this.timer = setInterval(() => { void this.verify(); }, 10000); this.timer.unref();
    return expected;
  }
  async verify() {
    try {
      const status = await this.request(this.main, '/status');
      this.running = status.state === 'ready' && status.routes?.some(route => route.gateID === this.registry.read().id
        && route.instanceID === this.instanceID && route.publicUrl === this.url) === true;
    } catch { this.running = false; }
  }
  async stop() {
    clearInterval(this.timer); this.timer = null;
    if (this.instanceID) await this.request(this.main, '/routes/stop', { gateID: this.gateID, instanceID: this.instanceID })
      .catch(error => { if (!['ENOENT', 'ECONNREFUSED'].includes(error.code)) throw error; });
    this.running = false; this.url = null; this.instanceID = null;
  }
  status() { return { running: this.running, url: this.url, provider: this.name }; }
}

// Used for interrupted decommissioning. The private ingress supplies the exact
// route lifetime; this does not touch another Gate or its account identity.
export async function retireSharedRoute(main, gateID) {
  try {
    const status = await embeddedRequest(main, '/status');
    const route = status.routes?.find(item => item.gateID === gateID);
    if (route) {
      if (!route.instanceID && gateID === main.read().id) await embeddedRequest(main, '/stop', {});
      else await embeddedRequest(main, '/routes/stop', { gateID, instanceID: route.instanceID });
    }
  } catch (error) { if (!['ENOENT', 'ECONNREFUSED'].includes(error.code)) throw error; }
}
export function gatewayProvider(registry, { expectedURL } = {}) {
  if (transportMode(registry) === 'shared' || !registry.sideMode && registry.read()?.sharedIngress && transportMode(registry) === 'embedded') return new SharedEmbeddedProvider(registry, { expectedURL });
  return transportMode(registry) === 'embedded' ? new EmbeddedProvider(registry, { expectedURL }) : new TailscaleProvider(registry.read().id, { expectedURL });
}
