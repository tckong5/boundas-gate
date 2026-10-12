import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { Registry, secureWrite, fileIdentity } from './registry.mjs';
import { retireRoutes, withLock } from '../Tailscale/provider.mjs';
import { SideRegistry } from './side-registry.mjs';
import { startGateway, loadBackend } from './server.mjs';
import { observeRuntime } from './runtime-instance.mjs';
import { diagnosticError } from './diagnostics.mjs';
import { gatewaySetup, gatewayProvider, transportMode, tunnelAccount, embeddedRequest, retireSharedRoute, sharedAgent } from '../Tailscale/embedded.mjs';
import { readAIConnections } from './connection-status.mjs';
import { migrateSideToShared } from './side-migration.mjs';

// Side membership is checked at the process boundary and again on bearer access.
export function sideRecord(registry, sourceID, removing = false) {
  const record = registry.addedFolders().find(item => item.id?.toLowerCase() === sourceID?.toLowerCase());
  if (!record || record.sideGateAdded !== true || (!removing && record.sideGateRemovalState)) throw new Error('Side Gate 未啟用，或者正在移除。');
  if (!/^[a-f0-9]{12}$/.test(record.c2cID) || !path.isAbsolute(record.path)
      || record.folderFileIdentity && fileIdentity(record.path) !== record.folderFileIdentity) throw new Error('Side Gate 記錄無效。');
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
  if (revoke) {
    fs.rmSync(path.join(stateDir, 'side-gates', record.c2cID, 'config.json'), { force: true });
    fs.rmSync(path.join(stateDir, 'side-gates', record.c2cID, 'endpoint-migration.json'), { force: true });
  }
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
    const directory = path.join(stateDir, 'side-gates', record.c2cID);
    await withLock(directory, async () => {
      const file = path.join(directory, 'config.json');
      let config; try { config = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (error) { if (error.code !== 'ENOENT') throw error; }
      if (config && (config.id !== record.c2cID || !/^[a-f0-9]{32}$/.test(config.epoch))) throw new Error('Side Gate 設定身份不符；未有操作其他 Gate。');
      if (config) secureWrite(file, { ...config, desiredRunning: false });
      if (config?.transport === 'embedded') {
        // Account identity is retained; retire only this Gate's verified private route.
        const identity = { directory, read: () => config };
        try { await embeddedRequest(identity, '/status'); await embeddedRequest(identity, '/stop', {}); }
        catch (error) { if (!['ENOENT', 'ECONNREFUSED'].includes(error.code)) throw error; }
      }
      await decommissionSide({ record, runtimeAPI, adminFetch, stateDir, revoke: action === 'decommission',
        retire: async id => { if (config?.transport === 'shared') await retireSharedRoute(registry, id); else await retireRoutes(id); } });
    });
    output({ ok: true }); return;
  }
  const workspace = new Workspace(record.path);
  if (workspace.root !== record.path || record.folderFileIdentity && fileIdentity(workspace.root) !== record.folderFileIdentity) throw new Error('Folder 位置已改變，請喺 App 重新定位。');
  const sideRegistry = new SideRegistry(registry, sourceID, path.join(stateDir, 'side-gates', record.c2cID));
  await withLock(registry.directory, () => sideRegistry.ensure());
  if (fs.existsSync(path.join(sideRegistry.directory, 'endpoint-migration.json')) && !['status', 'tunnel-status', 'migrate-shared', 'daemon'].includes(action)) throw new Error('Side Gate endpoint migration needs Retry before reconnecting.');
  if (action === 'daemon') {
    const instanceID = input?.replace(/^--instance-id=/, '');
    if (!/^[a-f0-9]{64}$/.test(instanceID ?? '')) throw new Error('Side Gate instance ID 無效。');
    const backend = await loadBackend(backendRoot);
    let tunnelProvider;
    if (sideRegistry.read().transport !== 'cloudflare') tunnelProvider = gatewayProvider(sideRegistry, { expectedURL: sideRegistry.connection().stableMCPURL?.replace(/\/mcp$/, '') });
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
    secureWrite(markerFile, { workspaceId: record.c2cID, adminToken: bridge.adminToken, instanceID, protocolVersion: 4 });
    let closing = false;
    const close = () => { if (!closing) { closing = true; void bridge.close().finally(() => process.exit(0)); } };
    process.on('SIGTERM', close); process.on('SIGINT', close);
    setInterval(() => {
      if (!registry.addedFolders().some(item => item.id?.toLowerCase() === sourceID.toLowerCase() && item.sideGateAdded === true)) close();
    }, 2000).unref();
    return;
  }
  const control = async (runtime, route, body, method = 'POST', timeout = 12000) => {
    const response = await fetch(`http://127.0.0.1:${runtime.port}/control/${route}`, {
      method, headers: { Authorization: `Bearer ${runtime.adminToken}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(timeout) });
    const reply = await response.json(); if (!response.ok) throw new Error(reply.message ?? 'Side Gate operation failed.');
    return reply;
  };
  const mode = () => sideRegistry.read().transport === 'cloudflare' ? 'cloudflare' : transportMode(sideRegistry);
  const setup = options => mode() === 'cloudflare' ? { state: 'ready', message: 'External access is available.' } : gatewaySetup(sideRegistry, options);
  const readStatus = async (known, transportSetup) => {
    const observed = known ?? await runtimeAPI.findBridgeObservation(record.c2cID);
    const info = observed.state === 'healthy' ? await adminFetch(observed.runtime, 'GET', '/admin/info', 5000) : {};
    const connection = sideRegistry.connection();
    return { ok: true, ...info, running: observed.state === 'unknown' ? null : observed.state === 'healthy',
      state: observed.state, reason: observed.reason, port: observed.runtime?.port, pid: observed.runtime?.pid,
      gatewayID: record.c2cID, roots: sideRegistry.active(), ...connection,
      desiredRunning: connection.desiredRunning ?? observed.state === 'healthy', connectionRemembered: connection.desiredRunning !== null,
      configuredMCPURL: sideRegistry.read().transport === 'shared' ? sideRegistry.read().configuredMCPURL : sideRegistry.read().configuredMCPURL ?? record.configuredMCPURL,
      transport: mode(), sharedTunnel: mode() === 'shared',
      sharedMigrationAvailable: mode() !== 'shared' && transportMode(registry) === 'embedded',
      endpointMigrationPending: fs.existsSync(path.join(sideRegistry.directory, 'endpoint-migration.json')),
      transportSetup: transportSetup ?? await setup(),
      aiConnections: readAIConnections(sideRegistry.directory, record.c2cID, path.join(stateDir, 'auth', `${record.c2cID}.json`), { legacySide: true }) };
  };
  // Provider setup takes its own lock. Never nest it inside the same Gate lock.
  if (['prepare-access', 'start-tunnel', 'login', 'logout'].includes(action)) {
    const observed = await runtimeAPI.findBridgeObservation(record.c2cID);
    if (observed.state !== 'healthy' && action !== 'logout') throw new Error('Open this Side Gate before setting up Secure Access.');
    if (observed.runtime && (observed.runtime.workspaceId !== record.c2cID || observed.runtime.workspaceRoot !== record.path)) throw new Error('Side Gate service identity does not match.');
    if (['login', 'logout'].includes(action) && mode() === 'cloudflare') throw new Error('此 Gate 並非使用 Tailscale。');
    const confirmedExternal = input ? JSON.parse(input).confirmedExternal === true : false;
    if (action === 'logout' && mode() === 'external' && !confirmedExternal) throw new Error('External Tailscale sign-out requires confirmation.');
    await withLock(sideRegistry.directory, () => sideRegistry.updateConnection({ desiredRunning: action !== 'logout', localOnly: false,
      transport: mode() }));
    if (action === 'logout') {
      // Stop runtime without revoking MCP authorization or Folder policy.
      await withLock(sideRegistry.directory, () => decommissionSide({ record, runtimeAPI, adminFetch, stateDir, revoke: false }));
      const account = await tunnelAccount(sideRegistry, 'logout', { confirmedExternal });
      output(await readStatus(undefined, account)); return;
    }
    const account = action === 'login' ? await tunnelAccount(sideRegistry, 'login') : await setup({ start: true, requestLogin: false });
    if (account.state === 'ready') {
      await withLock(sideRegistry.directory, async () => {
        sideRecord(registry, sourceID);
        const current = await runtimeAPI.findBridgeObservation(record.c2cID);
        if (current.state !== 'healthy') throw new Error('Side Gate stopped during Secure Access setup.');
        if (!current.info?.tunnel?.running) await control(current.runtime, 'tunnel/start', undefined, 'POST', 120000);
      });
    }
    output(await readStatus(undefined, account)); return;
  }
  let recoverySetup;
  if (action === 'migrate-shared') {
    recoverySetup = await gatewaySetup(registry, { start: true, requestLogin: false });
    if (recoverySetup.state !== 'ready') throw new Error('Sign in to shared Secure Access from Main Gate before migrating this Side Gate.');
    recoverySetup = await sharedAgent(sideRegistry);
  }
  if (['reconnect', 'recover'].includes(action) && !sideRegistry.connection().localOnly) {
    const connection = sideRegistry.connection();
    if (action === 'recover' && (!connection.reconnectEnabled || connection.desiredRunning !== true)) throw new Error('Side Gate was closed by the user.');
    recoverySetup = await setup({ start: true, requestLogin: false });
  }
  await withLock(sideRegistry.directory, async () => {
    let observed = await runtimeAPI.findBridgeObservation(record.c2cID);
    if (observed.runtime && (observed.runtime.workspaceRoot !== record.path || observed.runtime.workspaceId !== record.c2cID)) throw new Error('Side Gate 服務身份不符。');
    if (observed.state === 'unknown') throw new Error('Side Gate 狀態未能確認。');
    const ensureLocal = async () => {
      let marker; try { marker = JSON.parse(fs.readFileSync(markerFile, 'utf8')); } catch {}
      if (observed.state === 'healthy' && (marker?.adminToken !== observed.runtime.adminToken || marker?.protocolVersion !== 4)) {
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
    };
    if (action === 'migrate-shared') {
      await migrateSideToShared({ registry: sideRegistry, hostname: recoverySetup.hostname,
        stop: async () => {
          const transport = sideRegistry.read().transport;
          if (transport === 'embedded') {
            try { await embeddedRequest(sideRegistry, '/status'); await embeddedRequest(sideRegistry, '/stop', {}); }
            catch (error) { if (!['ENOENT', 'ECONNREFUSED'].includes(error.code)) throw error; }
          }
          await decommissionSide({ record, runtimeAPI, adminFetch, stateDir, revoke: false,
            retire: id => transport === 'shared' ? retireSharedRoute(registry, id) : retireRoutes(id) });
          observed = await runtimeAPI.findBridgeObservation(record.c2cID);
        },
        open: async config => {
          await ensureLocal();
          if (!config.localOnly) await control(observed.runtime, 'tunnel/start', undefined, 'POST', 120000);
        } });
      output(await readStatus());
    } else if (['start', 'start-local', 'reconnect', 'recover'].includes(action)) {
      const connection = sideRegistry.connection();
      if (action === 'recover' && (!connection.reconnectEnabled || connection.desiredRunning !== true)) throw new Error('Side Gate was closed by the user.');
      const localOnly = ['start', 'start-local'].includes(action) || connection.localOnly;
      // Startup never performs account setup. Reconnect can only restore prior explicit intent.
      sideRegistry.updateConnection({ desiredRunning: true, localOnly, transport: mode() });
      await ensureLocal();
      if (!localOnly && (action !== 'recover' || !observed.info?.tunnel?.running)) {
        const account = recoverySetup ?? await setup(); // Recovery never initiates login or approval.
        if (account.state !== 'ready') throw new Error(account.message);
        await control(observed.runtime, 'tunnel/start', undefined, 'POST', 120000);
      }
      const value = await readStatus(observed);
      output({ ...value, mcpUrl: value.tunnel?.running ? `${value.publicUrl}/mcp` : null });
    } else if (action === 'status' || action === 'tunnel-status') {
      let marker; try { marker = JSON.parse(fs.readFileSync(markerFile, 'utf8')); } catch {}
      if (observed.state === 'healthy' && (marker?.adminToken !== observed.runtime.adminToken || marker?.protocolVersion !== 4)) {
        // A pre-journey running Gate has no desired-running field yet.
        // Remember its actual runtime before replacing the old daemon, so the
        // normal coordinator can resume it without re-pairing/account actions.
        if (sideRegistry.connection().desiredRunning === null) {
          sideRegistry.updateConnection({ desiredRunning: true, localOnly: !observed.info?.tunnel?.running });
        }
        await decommissionSide({ record, runtimeAPI, adminFetch, stateDir, revoke: false });
        observed = await runtimeAPI.findBridgeObservation(record.c2cID);
      }
      output(await readStatus(observed));
    } else if (action === 'connection-settings' || action === 'remember-running') {
      if (action === 'connection-settings') {
        const body = JSON.parse(input); if (typeof body.enabled !== 'boolean') throw new Error('Invalid reconnect setting.');
        sideRegistry.updateConnection({ reconnectEnabled: body.enabled });
      } else if (observed.state === 'healthy' && sideRegistry.connection().desiredRunning === null) sideRegistry.updateConnection({ desiredRunning: true });
      output(await readStatus(observed));
    } else if (['code-policy', 'folder-code', 'lock-folder'].includes(action)) {
      const body = JSON.parse(input);
      if (body.workspaceID !== record.c2cID) throw new Error('Folder 身份不符。');
      if (observed.state !== 'healthy' && action === 'code-policy') {
        await withLock(registry.directory, () => sideRegistry.setCodePolicy(body.workspaceID, body.required));
        output(await readStatus(observed)); return;
      }
      if (observed.state !== 'healthy' || observed.info.accessCodeVersion !== 1) throw new Error('請先重新開啟 Side Gate。');
      const reply = await control(observed.runtime, action, body);
      output(action === 'folder-code' ? reply : await readStatus(observed));
    } else if (['pair', 'remove-client', 'revoke-client', 'cancel-setup', 'revoke', 'unpair', 'confirm'].includes(action)) {
      if (observed.state !== 'healthy') throw new Error('請先開啟 Side Gate。');
      if (action === 'confirm') {
        const value = JSON.parse(input).url;
        if (!observed.info?.tunnel?.running || value !== `${observed.info.publicUrl}/mcp`) throw new Error('Side Gate URL changed.');
        sideRegistry.updateConnection({ configuredMCPURL: value });
      } else {
        const route = action === 'unpair' ? 'revoke' : action;
        const reply = await control(observed.runtime, route, ['remove-client', 'revoke-client', 'cancel-setup'].includes(action) ? JSON.parse(input) : undefined);
        if (action === 'pair') { output(reply); return; }
      }
      output(await readStatus(observed));
    } else throw new Error('Unknown Side Gate action');
  });
}
if (process.argv[1] && pathToFileURL(fs.realpathSync(process.argv[1])).href === import.meta.url) {
  main().catch(error => {
    console.error(diagnosticError(error));
    process.stdout.write(`${JSON.stringify({ ok: false, message: error.message })}\n`); process.exitCode = 1;
  });
}
