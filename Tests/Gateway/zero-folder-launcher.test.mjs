import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { Registry } from '../../Resources/Gateway/registry.mjs';
import { embeddedLocation } from '../../Resources/Tailscale/embedded.mjs';
import { loadBackend } from '../../Resources/Gateway/server.mjs';

const backendRoot = process.env.BOUNDAS_C2C_ROOT;
const execute = promisify(execFile);
// Exercise the real launcher/daemon/control routes with a local IPC transport fixture.
// Public internet health is covered separately by provider tests, never inferred from this fixture.
test('first-run login, startup, pairing, reconnect and crash recovery need zero Folders', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'boundas-zero-launcher-'));
  const registry = new Registry({ directory: path.join(directory, 'main'), allowlistFile: path.join(directory, 'folders.json') });
  const location = embeddedLocation(registry);
  let publicUrl, running = false, loggedIn = true;
  const accountCalls = [];
  const resources = path.join(directory, 'Resources');
  for (const component of ['Gateway', 'Tailscale']) fs.cpSync(path.resolve('Resources', component), path.join(resources, component), { recursive: true });
  const binary = path.join(resources, 'Runtime/bin/boundas-tunnel');
  fs.mkdirSync(path.dirname(binary), { recursive: true }); fs.symlinkSync('/usr/bin/false', binary);
  fs.mkdirSync(location.controlDirectory, { mode: 0o700 });
  const ipc = http.createServer((req, res) => {
    const hostname = 'fixture.example.ts.net';
    const base = `https://${hostname}/c2c/${registry.read()?.id}`;
    if (req.url === '/start') { running = true; publicUrl = base; }
    if (req.url === '/stop') { running = false; publicUrl = undefined; }
    if (req.url === '/logout') { accountCalls.push('logout'); loggedIn = false; running = false; publicUrl = undefined; }
    if (req.url === '/login') { accountCalls.push('login'); loggedIn = true; }
    res.end(JSON.stringify({ ok: true, service: 'boundas-tsnet', gatewayID: registry.read()?.id,
      state: loggedIn ? 'ready' : 'login', hostname, running, publicUrl, accountManagementVersion: 1 }));
  });
  await new Promise(resolve => ipc.listen(location.socket, resolve)); fs.chmodSync(location.socket, 0o600);
  const env = { ...process.env, BOUNDAS_GATEWAY_DIR: registry.directory, BOUNDAS_WORKSPACES_FILE: registry.allowlistFile,
    C2C_STATE_DIR: path.join(directory, 'c2c'), BOUNDAS_STATE_DIR: path.join(directory, 'routes') };
  const launch = async action => JSON.parse((await execute(process.execPath,
    [path.join(resources, 'Gateway/launcher.mjs'), action, backendRoot], { env, timeout: 30000 })).stdout);
  try {
    const login = await launch('login');
    assert.equal(login.transportSetup.state, 'ready'); assert.deepEqual(login.roots, []);
    const id = registry.read().id;
    for (const action of ['start', 'reconnect']) {
      const value = await launch(action);
      assert.equal(value.running, true); assert.equal(value.tunnel.running, true);
      assert.equal(value.gatewayID, id); assert.deepEqual(value.roots, []);
      assert.equal(value.tokenCount, 0);
    }
    const paired = await launch('pair'); assert.ok(paired.pairingCode); assert.deepEqual(paired.roots, []);
    const runtimeFile = path.join(registry.directory, 'runtime.json');
    const runtime = JSON.parse(fs.readFileSync(runtimeFile));
    process.kill(runtime.pid, 'SIGTERM'); // Our own verified fixture daemon; desired-running survives.
    const deadline = Date.now() + 10000;
    while (fs.existsSync(runtimeFile) && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 100));
    assert.equal(fs.existsSync(runtimeFile), false);
    const recovered = await launch('recover');
    assert.equal(recovered.running, true); assert.equal(recovered.tunnel.running, true);
    assert.equal(recovered.gatewayID, id); assert.deepEqual(recovered.roots, []);
    assert.ok((await launch('pair')).pairingCode);
    assert.equal((await launch('stop')).running, false);
    const restarted = await launch('start');
    assert.equal(restarted.gatewayID, id); assert.equal(restarted.running, true);
    const authFile = path.join(registry.directory, 'auth.json');
    const { AuthStore } = await loadBackend(backendRoot);
    const auth = new AuthStore(id, { file: authFile });
    const client = auth.registerClient({ clientName: 'Test AI', redirectUris: ['https://example.test/callback'] });
    const token = auth.issueTokens({ clientId: client.clientId, scopes: ['workspace.read', 'offline_access', `bg.instance.${id}`] });
    const authBefore = fs.readFileSync(authFile, 'utf8');
    const urlBefore = registry.connection().stableMCPURL;
    const signedOut = await launch('logout');
    assert.equal(signedOut.running, false); assert.equal(signedOut.desiredRunning, false);
    assert.equal(signedOut.transportSetup.state, 'login');
    assert.equal(registry.read().id, id); assert.equal(registry.connection().stableMCPURL, urlBefore);
    assert.equal(fs.readFileSync(authFile, 'utf8'), authBefore);
    await assert.rejects(launch('recover'));
    assert.deepEqual(accountCalls, ['logout']); // Recovery must not silently log the user back in.
    assert.equal((await launch('login')).transportSetup.state, 'ready');
    const reopened = await launch('start');
    assert.equal(reopened.gatewayID, id);
    const access = await fetch(`http://127.0.0.1:${reopened.port}/mcp`, { method: 'POST',
      headers: { Authorization: `Bearer ${token.accessToken}`, 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'list_workspaces', arguments: {} } }) });
    assert.equal(access.status, 200); // The same authorization works after logout/login.
    assert.equal(new AuthStore(id, { file: authFile }).verifyAccessToken(token.accessToken).ok, true);
  } finally {
    try { await launch('stop'); } catch {}
    ipc.closeAllConnections(); await new Promise(resolve => ipc.close(resolve));
    fs.rmSync(location.controlDirectory, { recursive: true, force: true });
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
