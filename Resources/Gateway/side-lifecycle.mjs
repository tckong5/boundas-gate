import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { Registry, secureWrite } from './registry.mjs';
import { TailscaleProvider, retireRoutes, withLock } from '../Tailscale/provider.mjs';
import { SideRegistry } from './side-registry.mjs';
import { startGateway, loadBackend } from './server.mjs';
import { observeRuntime } from './runtime-instance.mjs';
import { diagnosticError } from './diagnostics.mjs';

// Side membership is checked at the process boundary and again on bearer access.
export function sideRecord(registry, sourceID, removing = false) {
  const record = registry.addedFolders().find(item => item.id?.toLowerCase() === sourceID?.toLowerCase());
  if (!record || record.sideGateAdded !== true || (!removing && record.sideGateRemovalState)) throw new Error('Side Gate 未啟用，或者正在移除。');
  if (!/^[a-f0-9]{12}$/.test(record.c2cID) || !path.isAbsolute(record.path)) throw new Error('Side Gate 記錄無效。');
  return record;
}
export function sideAccessAllowed(registry, sourceID) {
  try {
    const record = sideRecord(registry, sourceID);
    return record.sideGateAdded === true; // Passcode is enforced per tool by the shared Gate core.
  } catch { return false; }
}
export async function decommissionSide({ record, runtimeAPI, adminFetch, stateDir, retire = retireRoutes, revoke = true }) {
  const observed = await runtimeAPI.findBridgeObservation(record.c2cID);
  const runtime = observed.runtime;
  if (runtime && (runtime.workspaceId !== record.c2cID || runtime.workspaceRoot !== record.path)) throw new Error('Side Gate 服務身份不符；未有操作其他 Gate。');
  if (observed.state === 'unknown') throw new Error('未能確認 Side Gate 服務，請重新檢查後 Retry。');
  if (observed.state === 'healthy') {
    await adminFetch(runtime, 'POST', '/admin/tunnel/stop', 15000);
    if (revoke) await adminFetch(runtime, 'POST', '/admin/revoke-all', 5000);
    await adminFetch(runtime, 'POST', '/admin/shutdown', 5000);
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      const next = await runtimeAPI.findBridgeObservation(record.c2cID);
      if (next.state === 'stopped') break;
      // A missing runtime is sufficient: the authenticated daemon cleared it only after close.
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    if ((await runtimeAPI.findBridgeObservation(record.c2cID)).state !== 'stopped') throw new Error('Side Gate 尚未停止，可以 Retry。');
  }
  // Recover only journalled routes owned by this Gate, including interrupted shutdowns.
  await retire(record.c2cID);
  if ((await runtimeAPI.findBridgeObservation(record.c2cID)).state !== 'stopped') throw new Error('Side Gate runtime 已改變，未有清除新服務授權；請 Retry。');
  if (revoke) fs.rmSync(path.join(stateDir, 'auth', `${record.c2cID}.json`), { force: true });
  fs.rmSync(path.join(stateDir, 'side-gates', `${record.c2cID}.json`), { force: true });
  if (revoke) fs.rmSync(path.join(stateDir, 'side-gates', record.c2cID, 'config.json'), { force: true });
}

async function main() {
  const [action, backendRoot, sourceID, input] = process.argv.slice(2);
  const registry = new Registry();
  const record = sideRecord(registry, sourceID, ['stop', 'decommission'].includes(action));
  const stateDir = process.env.C2C_STATE_DIR ?? path.join(os.homedir(), 'Library/Application Support/codex-with-chatgpt');
  const load = file => import(pathToFileURL(path.join(backendRoot, 'dist', file)).href);
  const [legacyRuntime, { adminFetch }, { Workspace }] = await Promise.all([load('bridge/runtime.js'), load('process/daemon.js'), load('workspace/manager.js')]);
  const runtimeAPI = { ...legacyRuntime, findBridgeObservation: id => observeRuntime(legacyRuntime.runtimeFile(id), {
    gateID: id, service: legacyRuntime.SERVICE_NAME, entrypoint: fileURLToPath(import.meta.url),
    getInfo: state => adminFetch(state, 'GET', '/admin/info', 3000) }) };
  const markerFile = path.join(stateDir, 'side-gates', `${record.c2cID}.json`);
  const output = value => process.stdout.write(`${JSON.stringify(value)}\n`);
  if (['stop', 'decommission'].includes(action)) {
    await withLock(path.join(stateDir, 'side-gates', record.c2cID), () => decommissionSide({ record, runtimeAPI, adminFetch, stateDir, revoke: action === 'decommission' }));
    output({ ok: true }); return;
  }
  const workspace = new Workspace(record.path);
  if (workspace.id !== record.c2cID || workspace.root !== record.path) throw new Error('Folder 位置已改變，請重新加入。');
  const sideRegistry = new SideRegistry(registry, sourceID, path.join(stateDir, 'side-gates', record.c2cID));
  await withLock(registry.directory, () => sideRegistry.ensure());
  if (action === 'daemon') {
    const instanceID = input?.replace(/^--instance-id=/, '');
    if (!/^[a-f0-9]{64}$/.test(instanceID ?? '')) throw new Error('Side Gate instance ID 無效。');
    const backend = await loadBackend(backendRoot);
    let tunnelProvider;
    if (record.connectionProvider === 'tailscale') tunnelProvider = new TailscaleProvider(record.c2cID);
    else {
      // Preserve the existing C2C named binding; security changes never migrate
      // a configured endpoint to a temporary Quick Tunnel.
      const [{ namedTunnelBinding, readTunnelState }, { CloudflaredNamedTunnel }] = await Promise.all([
        load('tunnel/state.js'), load('tunnel/cloudflared-named.js')]);
      const binding = namedTunnelBinding(readTunnelState(record.c2cID));
      tunnelProvider = binding ? new CloudflaredNamedTunnel({ ...binding, logger: backend.logger })
        : new backend.CloudflaredQuickTunnel(backend.logger);
    }
    const bridge = await startGateway({ backendRoot, registry: sideRegistry, sideRoot: record.path, port: 0,
      tunnelProvider, service: legacyRuntime.SERVICE_NAME, instanceID,
      runtimePath: runtimeAPI.runtimeFile(record.c2cID), authFile: path.join(stateDir, 'auth', `${record.c2cID}.json`) });
    secureWrite(markerFile, { workspaceId: record.c2cID, adminToken: bridge.adminToken, instanceID, protocolVersion: 2 });
    let closing = false;
    const close = () => { if (!closing) { closing = true; void bridge.close().finally(() => process.exit(0)); } };
    process.on('SIGTERM', close); process.on('SIGINT', close);
    setInterval(() => {
      if (!registry.addedFolders().some(item => item.id?.toLowerCase() === sourceID.toLowerCase() && item.sideGateAdded === true)) close();
    }, 2000).unref();
    return;
  }
  await withLock(path.join(stateDir, 'side-gates', record.c2cID), async () => {
    let observed = await runtimeAPI.findBridgeObservation(record.c2cID);
    if (observed.runtime && (observed.runtime.workspaceRoot !== record.path || observed.runtime.workspaceId !== record.c2cID)) throw new Error('Side Gate 服務身份不符。');
    if (observed.state === 'unknown') throw new Error('Side Gate 狀態未能確認。');
    if (action === 'start') {
      // Existing legacy daemons need one controlled restart to install dynamic membership/policy checks.
      let marker; try { marker = JSON.parse(fs.readFileSync(markerFile, 'utf8')); } catch {}
      if (observed.state === 'healthy' && (marker?.adminToken !== observed.runtime.adminToken || marker?.protocolVersion !== 2)) {
        await decommissionSide({ record, runtimeAPI, adminFetch, stateDir, revoke: false });
        observed = await runtimeAPI.findBridgeObservation(record.c2cID);
      }
      if (observed.state === 'stopped') {
        const log = path.join(stateDir, 'logs', `bridge-${record.c2cID}.out.log`);
        fs.mkdirSync(path.dirname(log), { recursive: true, mode: 0o700 });
        const fd = fs.openSync(log, 'a', 0o600); fs.chmodSync(log, 0o600);
        const child = spawn(process.execPath, [fileURLToPath(import.meta.url), 'daemon', backendRoot, sourceID, `--instance-id=${randomBytes(32).toString('hex')}`], { detached: true, stdio: ['ignore', fd, fd], env: process.env });
        child.unref(); fs.closeSync(fd);
        const deadline = Date.now() + 20000;
        do { await new Promise(resolve => setTimeout(resolve, 200)); observed = await runtimeAPI.findBridgeObservation(record.c2cID); }
        while (observed.state !== 'healthy' && Date.now() < deadline && child.exitCode === null);
        if (observed.state !== 'healthy') throw new Error('Side Gate 未能啟動。');
      }
      sideRecord(registry, sourceID);
      const { url } = await adminFetch(observed.runtime, 'POST', '/admin/tunnel/start', 120000);
      output({ ok: true, mcpUrl: `${url}/mcp` });
    } else if (action === 'status') {
      let marker; try { marker = JSON.parse(fs.readFileSync(markerFile, 'utf8')); } catch {}
      if (observed.state === 'healthy' && (marker?.adminToken !== observed.runtime.adminToken || marker?.protocolVersion !== 2)) {
        // A pre-upgrade daemon has no live membership/policy guard. Retire its route
        // before reporting it as managed; reopening installs the guard, retaining OAuth.
        await decommissionSide({ record, runtimeAPI, adminFetch, stateDir, revoke: false });
        output({ ok: true, running: false, state: 'stopped', roots: sideRegistry.active(), gatewayID: record.c2cID,
          reason: '請重新開啟 Side Gate，以套用 Folder 授權保護。' });
        return;
      }
      const info = observed.state === 'healthy' ? await adminFetch(observed.runtime, 'GET', '/admin/info', 5000) : {};
      output({ ok: true, ...info, running: observed.state === 'healthy', state: observed.state, port: observed.runtime?.port, pid: observed.runtime?.pid,
        gatewayID: record.c2cID, roots: sideRegistry.active(), transport: 'external' });
    } else if (['code-policy', 'folder-code', 'lock-folder'].includes(action)) {
      const body = JSON.parse(input);
      if (body.workspaceID !== record.c2cID) throw new Error('Folder 身份不符。');
      if (action === 'code-policy') {
        await withLock(registry.directory, () => sideRegistry.setCodePolicy(body.workspaceID, body.required));
        output({ ok: true }); return;
      }
      if (observed.state !== 'healthy' || observed.info.accessCodeVersion !== 1) throw new Error('請先重新開啟 Side Gate。');
      const response = await fetch(`http://127.0.0.1:${observed.runtime.port}/control/${action}`, {
        method: 'POST', headers: { Authorization: `Bearer ${observed.runtime.adminToken}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(body), signal: AbortSignal.timeout(12000) });
      const reply = await response.json(); if (!response.ok) throw new Error(reply.message);
      output(reply);
    } else if (action === 'pair') {
      if (observed.state !== 'healthy') throw new Error('請先開啟 Side Gate。');
      const pairing = await adminFetch(observed.runtime, 'POST', '/admin/pairing', 5000);
      output({ ok: true, pairingCode: pairing.code, expiresAt: pairing.expiresAt });
    } else if (action === 'unpair') {
      if (observed.state === 'healthy') await adminFetch(observed.runtime, 'POST', '/admin/revoke-all', 5000);
      else fs.rmSync(path.join(stateDir, 'auth', `${record.c2cID}.json`), { force: true });
      output({ ok: true });
    } else throw new Error('Unknown Side Gate action');
  });
}
if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  main().catch(error => {
    console.error(diagnosticError(error));
    process.stdout.write(`${JSON.stringify({ ok: false, message: error.message })}\n`); process.exitCode = 1;
  });
}
