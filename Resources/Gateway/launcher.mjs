import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { migrateMainToShared, readMainMigration, candidateRegistry, verifyMigrationRoute } from './main-migration.mjs';
import { Registry, secureWrite } from './registry.mjs';
import { loadBackend, startGateway } from './server.mjs';
import { withLock } from '../Tailscale/provider.mjs';
import { gatewaySetup, transportMode, tunnelAccount, retireSharedRoute, embeddedSetup, embeddedRequest, SharedEmbeddedProvider } from '../Tailscale/embedded.mjs';
import { readAIConnections } from './connection-status.mjs';
import { readRuntime, observeRuntime } from './runtime-instance.mjs';
import { diagnosticError } from './diagnostics.mjs';

const [action, backendRoot, input] = process.argv.slice(2);
const registry = new Registry();
const runtimeFile = path.join(registry.directory, 'runtime.json');
const output = value => process.stdout.write(`${JSON.stringify(value)}\n`);
function runtime() {
  return readRuntime(runtimeFile);
}
async function control(state, route, method = 'POST', timeout = 120000, body) {
  const response = await fetch(`http://127.0.0.1:${state.port}${route}`, { method, headers: { Authorization: `Bearer ${state.adminToken}`, ...(body ? { 'Content-Type': 'application/json' } : {}) }, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(timeout) });
  const data = await response.json();
  if (!response.ok) throw new Error(data.message ?? '共用連線未能完成操作。');
  return data;
}
async function observation() {
  return observeRuntime(runtimeFile, { gateID: registry.read()?.id, service: 'boundas-gateway',
    entrypoint: fileURLToPath(import.meta.url), getInfo: state => control(state, '/control/info', 'GET', 3000) });
}
async function stopGate() {
  await withLock(registry.directory, async () => {
    const current = await observation();
    if (registry.read()) registry.updateConnection({ desiredRunning: false });
    if (current.state === 'unknown') throw new Error(current.reason);
    if (current.state === 'healthy') {
      await control(current.runtime, '/control/shutdown');
      const deadline = Date.now() + 20000;
      while (runtime() && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 250));
      if (runtime()) throw new Error('Gate 仍在停止中，請稍後再檢查。');
    }
    if (registry.read()?.transport === 'embedded') await retireSharedRoute(registry, registry.read().id);
  });
}
// Start only the loopback MCP/OAuth host. No provider preflight or account action.
// Called under the existing Gate lock by both local and full startup paths.
async function ensureLocalHost(candidate = false) {
  let current = await observation();
  if (current.state === 'unknown') throw new Error(current.reason);
  if (current.state === 'healthy' && current.legacy) {
    await control(current.runtime, '/control/shutdown');
    const deadline = Date.now() + 20000;
    while (runtime() && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 250));
    current = await observation();
    if (current.state !== 'stopped') throw new Error('舊 Gate 未完成停止，請稍後再試。');
  }
  if (current.state === 'stopped') {
    fs.mkdirSync(registry.directory, { recursive: true, mode: 0o700 });
    const logFile = path.join(registry.directory, 'gateway.log');
    const descriptor = fs.openSync(logFile, 'a', 0o600); fs.chmodSync(logFile, 0o600);
    const child = spawn(process.execPath, [fileURLToPath(import.meta.url), 'daemon', backendRoot, `--instance-id=${randomBytes(32).toString('hex')}`, ...(candidate ? ['--migration-candidate'] : [])], { detached: true, stdio: ['ignore', descriptor, descriptor], env: process.env });
    child.unref(); fs.closeSync(descriptor);
    const deadline = Date.now() + 20000;
    do {
      await new Promise(resolve => setTimeout(resolve, 250));
      current = await observation();
    } while (current.state !== 'healthy' && Date.now() < deadline && child.exitCode === null);
    if (current.state !== 'healthy') throw new Error('共用連線未能啟動。');
  }
  return current;
}
async function status() {
  const config = registry.read();
  const observed = await observation();
  const connection = registry.connection();
  const transport = transportMode(registry);
  const migration = readMainMigration(registry);
  const transportSetup = config ? migration ? await embeddedSetup(candidateRegistry(registry), { start: false, requestLogin: false }) : await gatewaySetup(registry) : undefined;
  return { ok: true, running: observed.state === 'unknown' ? null : observed.state === 'healthy', state: observed.state, reason: observed.reason,
    publicUrl: connection.stableMCPURL?.replace(/\/mcp$/, ''), ...observed.info, ...connection,
    desiredRunning: connection.desiredRunning ?? observed.state === 'healthy',
    connectionRemembered: connection.desiredRunning !== null,
    gatewayID: config?.id, roots: registry.active(), configuredMCPURL: config?.configuredMCPURL,
    sharedMigrationAvailable: transport === 'external', endpointMigrationPending: !!migration,
    transport, sharedTunnel: transport === 'embedded', transportSetup, aiConnections: readAIConnections(registry.directory, config?.id) };
}
try {
  if (readMainMigration(registry) && !['daemon', 'status', 'migrate-shared', 'connection-check'].includes(action)) throw new Error('Main endpoint migration needs Retry before lifecycle operations.');
  if (action === 'daemon') {
    const instanceID = input?.replace(/^--instance-id=/, '');
    if (!/^[a-f0-9]{64}$/.test(instanceID ?? '')) throw new Error('Gate instance ID 無效。');
    const candidate = process.argv.includes('--migration-candidate') ? readMainMigration(registry) : null;
    if (process.argv.includes('--migration-candidate') && !candidate?.candidateURL) throw new Error('Candidate migration journal missing.');
    const gateway = await startGateway({ backendRoot, registry, instanceID, ...(candidate ? { migrationCandidateURL: candidate.candidateURL, tunnelProvider: new SharedEmbeddedProvider(candidateRegistry(registry), { expectedURL: candidate.candidateURL.replace(/\/mcp$/, '') }) } : {}) });
    let closing = false;
    const close = () => { if (!closing) { closing = true; void gateway.close().finally(() => process.exit(0)); } };
    process.on('SIGTERM', close); process.on('SIGINT', close);
  } else if (action === 'configure') {
    const { Workspace } = await loadBackend(backendRoot);
    await withLock(registry.directory, async () => registry.configure(JSON.parse(input).selectedIDs, Workspace));
    output(await status());
  } else if (action === 'remove-root') {
    await withLock(registry.directory, async () => registry.revokeSource(JSON.parse(input).sourceID));
    output(await status());
  } else if (['code-policy', 'folder-code', 'lock-folder'].includes(action)) {
    await withLock(registry.directory, async () => {
      const current = await observation();
      if (current.state === 'unknown') throw new Error(current.reason);
      const body = JSON.parse(input);
      if (current.state === 'healthy') {
        if (current.info.accessCodeVersion !== 1) throw new Error('請先停止並重新開啟共用連線，以套用新版通行碼功能。');
        const reply = await control(current.runtime, `/control/${action}`, 'POST', 12000, body);
        output(action === 'folder-code' ? reply : await status());
      } else if (action === 'code-policy') {
        registry.setCodePolicy(body.workspaceID, body.required); output(await status());
      } else throw new Error('請先開啟共用連線。');
    });
  } else if (['remove-client', 'revoke-client'].includes(action)) {
    await withLock(registry.directory, async () => {
      const current = await observation();
      if (current.state !== 'healthy' || current.info.clientManagementVersion !== 1) throw new Error('請先重新開啟共用連線，以套用 AI 登記管理功能。');
      await control(current.runtime, `/control/${action}`, 'POST', 12000, JSON.parse(input));
      output(await status());
    });
  } else if (action === 'migrate-shared') {
    const result = await withLock(path.join(registry.directory, 'main-migration-lock'), () => migrateMainToShared({ registry,
      setup: view => embeddedSetup(view, { start: true, requestLogin: true }),
      open: async journal => {
        const previous = await observation();
        if (previous.state === 'unknown') throw new Error(previous.reason);
        if (previous.state === 'healthy') {
          await control(previous.runtime, '/control/shutdown');
          const deadline = Date.now() + 20000;
          while (runtime() && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 200));
          if (runtime()) throw new Error('Previous Main runtime did not stop.');
        }
        const current = await ensureLocalHost(true);
        try {
          await control(current.runtime, '/control/tunnel/start');
          verifyMigrationRoute(await embeddedRequest(candidateRegistry(registry), '/status'), journal.candidateURL, current.runtime);
        }
        catch (error) { await control(current.runtime, '/control/shutdown'); throw error; }
        return current.runtime;
      },
      finalize: async journal => {
        let current = await observation();
        if (current.state === 'unknown') throw new Error(current.reason);
        if (current.state === 'healthy' && current.info.migrationCandidate !== false) {
          await control(current.runtime, '/control/shutdown');
          const deadline = Date.now() + 20000;
          while (runtime() && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 200));
          if (runtime()) throw new Error('Candidate Main runtime did not stop.');
        }
        current = await ensureLocalHost();
        await control(current.runtime, '/control/tunnel/start');
        verifyMigrationRoute(await embeddedRequest(registry, '/status'), journal.candidateURL, current.runtime);
        const info = await control(current.runtime, '/control/info', 'GET', 3000);
        if (info.migrationCandidate !== false || `${info.publicUrl}/mcp` !== journal.candidateURL) throw new Error('Committed Main runtime endpoint mismatch.');
        return { ...current.runtime, migrationCandidate: info.migrationCandidate };
      },
      cleanup: candidate => control(candidate, '/control/shutdown') }));
    output({ ...await status(), ...result });
  } else if (action === 'status') { output(await status()); }
  else if (action === 'start-local') {
    await withLock(registry.directory, async () => {
      registry.ensure();
      await ensureLocalHost();
      registry.updateConnection({ desiredRunning: true, localOnly: true });
    });
    output(await status());
  }
  else if (action === 'prepare-access') {
    // Explicit setup intent uses the existing reconnect policy. Closing the UI
    // during browser approval does not lose the user's request to open the Gate.
    await withLock(registry.directory, async () => { registry.ensure(); registry.updateConnection({ desiredRunning: true, localOnly: false }); });
    const setup = await gatewaySetup(registry, { start: true, requestLogin: false });
    output({ ...await status(), transportSetup: setup });
  }
  else if (action === 'cancel-setup') {
    const current = await observation();
    if (current.state === 'unknown') throw new Error(current.reason);
    if (current.state === 'healthy') {
      if (current.info.setupManagementVersion !== 1) throw new Error('Restart Gate to update setup support.');
      await control(current.runtime, '/control/cancel-setup', 'POST', 12000, JSON.parse(input));
    }
    // A stopped process has no pairing session or pending authorization codes.
    output(await status());
  }
  else if (action === 'login') {
    await withLock(registry.directory, async () => registry.ensure());
    const setup = await tunnelAccount(registry, 'login');
    output({ ...await status(), transportSetup: setup });
  }
  else if (action === 'logout') {
    const confirmedExternal = input ? JSON.parse(input).confirmedExternal === true : false;
    if (transportMode(registry) === 'external' && !confirmedExternal) throw new Error('外置 Tunnel 登出會影響同一 Mac 裝置嘅其他連線，請先確認。');
    await stopGate();
    await tunnelAccount(registry, 'logout', { confirmedExternal });
    output(await status());
  }
  else if (action === 'connection-settings') {
    const body = JSON.parse(input);
    if (typeof body.enabled !== 'boolean') throw new Error('自動重連設定無效。');
    await withLock(registry.directory, async () => { registry.ensure(); registry.updateConnection({ reconnectEnabled: body.enabled }); });
    output(await status());
  }
  else if (action === 'remember-running') {
    await withLock(registry.directory, async () => {
      const current = await observation();
      if (current.state === 'healthy' && registry.connection().desiredRunning === null) registry.updateConnection({ desiredRunning: true });
    });
    output(await status());
  }
  else if (['start', 'reconnect', 'recover'].includes(action)) {
    await withLock(registry.directory, async () => registry.ensure());
    if (action === 'recover') {
      const connection = registry.connection();
      const current = await observation();
      if (!connection.reconnectEnabled || connection.desiredRunning === false
          || (connection.desiredRunning === null && current.state !== 'healthy')) throw new Error('Gate 已由用戶停止，未有自動開啟。');
    }
    if (action === 'recover' && registry.connection().localOnly) {
      await withLock(registry.directory, async () => {
        const connection = registry.connection();
        if (!connection.reconnectEnabled || connection.desiredRunning !== true) throw new Error('Gate 已由用戶停止。');
        await ensureLocalHost();
      });
      output(await status());
      process.exit(0);
    }
    // Reconnect must never initiate interactive login or approval.
    const setup = await gatewaySetup(registry, { start: true, requestLogin: false });
    if (setup.state !== 'ready') throw new Error(setup.message);
    await withLock(registry.directory, async () => {
      let current = await observation();
      if (current.state === 'unknown') throw new Error(current.reason);
      const connection = registry.connection();
      if (action === 'recover' && (!connection.reconnectEnabled || connection.desiredRunning === false
          || (connection.desiredRunning === null && current.state !== 'healthy'))) throw new Error('共用連線已由用戶停止，未有自動開啟。');
      const expected = connection.stableMCPURL ?? (registry.read().sharedIngress && transportMode(registry) === 'embedded' ? `https://${setup.hostname}/mcp` : `https://${setup.hostname}/c2c/${registry.read().id}/mcp`);
      if (new URL(expected).hostname !== setup.hostname) throw new Error('Tunnel identity changed; the saved URL is preserved.');
      if (connection.stableMCPURL && connection.stableMCPURL !== expected) throw new Error('Tailscale 地址同原有 ChatGPT 設定唔一致。請連返原有帳戶／裝置；未有更改地址或授權。');
      secureWrite(path.join(registry.directory, 'config.json'), { ...registry.read(), transport: transportMode(registry) });
      registry.updateConnection({ stableMCPURL: expected, desiredRunning: true, localOnly: false });
      current = await ensureLocalHost();
      if (current.info?.tunnel?.running !== true || action !== 'start') await control(current.runtime, '/control/tunnel/start');
    });
    output(await status());
  } else if (action === 'stop') {
    await stopGate();
    output(await status());
  } else if (['pair', 'revoke'].includes(action)) {
    const current = await observation();
    if (current.state === 'unknown') throw new Error(current.reason);
      if (current.state !== 'healthy') throw new Error('請先啟動共用連線。');
      if (action === 'pair') output(await control(current.runtime, '/control/pair'));
      if (action === 'revoke') { await control(current.runtime, '/control/revoke'); output(await status()); }
  } else if (action === 'confirm') {
    const current = await observation();
    const value = JSON.parse(input).url;
    if (current.state !== 'healthy' || current.info.tunnel.running !== true || value !== `${current.info.publicUrl}/mcp`) throw new Error('連線地址已變更，請重新檢查。');
    await withLock(registry.directory, async () => secureWrite(path.join(registry.directory, 'config.json'), { ...registry.read(), configuredMCPURL: value }));
    output(await status());
  } else throw new Error('Unknown action');
} catch (error) {
  console.error(diagnosticError(error));
  output({ ok: false, message: error.message ?? '共用連線未能完成操作。' }); process.exitCode = 1;
}
