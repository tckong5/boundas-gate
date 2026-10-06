import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import os from 'node:os';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { setupCheck, TailscaleProvider, withLock } from './provider.mjs';

export function embeddedBinary() {
  const candidate = path.join(path.dirname(fileURLToPath(import.meta.url)), '../Runtime/bin/boundas-tunnel');
  try { fs.accessSync(candidate, fs.constants.X_OK); return candidate; } catch { return null; }
}
export function transportMode(registry, binary = embeddedBinary()) {
  const config = registry.read();
  if (config?.transport !== undefined && !['external', 'embedded'].includes(config.transport)) throw new Error('連線模式無效；未有更改現有連線。');
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
      response.on('data', bytes => { output += bytes; if (output.length > 16384) request.destroy(new Error('內置連線回應無效。')); });
      response.on('end', () => { try {
        const value = JSON.parse(output);
        if (!value.ok || response.statusCode !== 200) throw Object.assign(new Error(value.message ?? '內置連線未能完成操作。'), { approvalURL: value.approvalURL });
        if (route === '/status' && (value.service !== 'boundas-tsnet' || value.gatewayID !== registry.read()?.id)) throw new Error('內置連線身份唔一致。');
        resolve(value);
      } catch (error) { reject(error); } });
    });
    request.setTimeout(timeout, () => request.destroy(new Error('內置連線未有回應。')));
    request.on('error', reject); request.end(body ? JSON.stringify(body) : undefined);
  });
}
export async function embeddedSetup(registry, { start = false, binary = embeddedBinary() } = {}) {
  if (!registry.read()) return { state: 'unconfigured', message: '先揀 Folder 並儲存分享清單。' };
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
  if (!start) return status;
  let requestedLogin = false;
  for (let attempt = 0; attempt < 40 && ['starting', 'login'].includes(status.state) && !status.loginURL && !status.approvalURL; attempt++) {
    // Startup may report "starting" before the node enters NeedsLogin. Request
    // interactive login at that transition, rather than only at the first read.
    if (status.state === 'login' && !requestedLogin) {
      status = await embeddedRequest(registry, '/login', {}, 12000);
      requestedLogin = true;
      if (status.loginURL || status.approvalURL || !['starting', 'login'].includes(status.state)) break;
    }
    await new Promise(resolve => setTimeout(resolve, 300)); status = await embeddedRequest(registry, '/status');
  }
  if (status.state === 'blocked' && !status.approvalURL) status = await embeddedRequest(registry, '/approve', {}, 12000);
  return status;
}
export async function gatewaySetup(registry, options) {
  return transportMode(registry) === 'embedded' ? embeddedSetup(registry, options) : setupCheck();
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
export function gatewayProvider(registry, { expectedURL } = {}) {
  return transportMode(registry) === 'embedded' ? new EmbeddedProvider(registry, { expectedURL }) : new TailscaleProvider(registry.read().id, { expectedURL });
}
