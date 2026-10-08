import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { Registry, secureWrite } from '../../Resources/Gateway/registry.mjs';
import { embeddedLocation } from '../../Resources/Tailscale/embedded.mjs';
import { loadBackend } from '../../Resources/Gateway/server.mjs';
import { migrateSideToShared } from '../../Resources/Gateway/side-migration.mjs';
import { SideRegistry } from '../../Resources/Gateway/side-registry.mjs';

const backendRoot = process.env.BOUNDAS_C2C_ROOT;
const backend = await loadBackend(backendRoot);
const execute = promisify(execFile);

test('one account and ingress serve zero-Folder Main + two Side Gates; routed OAuth, revoke, Close and restart stay isolated', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'boundas-shared-'));
  const registry = new Registry({ directory: path.join(directory, 'main'), allowlistFile: path.join(directory, 'folders.json') });
  registry.ensure(); registry.updateConnection({ transport: 'embedded' });
  const records = ['A', 'B'].map(name => {
    const folder = path.join(directory, name); fs.mkdirSync(folder); fs.writeFileSync(path.join(folder, 'read.txt'), name);
    const workspace = new backend.Workspace(folder);
    return { id: randomUUID(), name, path: workspace.root, c2cID: workspace.id, sideGateAdded: true };
  });
  secureWrite(registry.allowlistFile, records);
  const resources = path.join(directory, 'Resources');
  for (const component of ['Gateway', 'Tailscale']) fs.cpSync(path.resolve('Resources', component), path.join(resources, component), { recursive: true });
  const binary = path.join(resources, 'Runtime/bin/boundas-tunnel');
  fs.mkdirSync(path.dirname(binary), { recursive: true }); fs.symlinkSync('/usr/bin/false', binary);
  const env = { ...process.env, BOUNDAS_GATEWAY_DIR: registry.directory, BOUNDAS_WORKSPACES_FILE: registry.allowlistFile,
    C2C_STATE_DIR: path.join(directory, 'c2c'), BOUNDAS_STATE_DIR: path.join(directory, 'routes') };
  const launch = async (gate, action, input) => JSON.parse((await execute(process.execPath,
    gate ? [path.join(resources, 'Gateway/side-lifecycle.mjs'), action, backendRoot, gate.id, ...(input ? [JSON.stringify(input)] : [])]
      : [path.join(resources, 'Gateway/launcher.mjs'), action, backendRoot, ...(input ? [JSON.stringify(input)] : [])], { env, timeout: 45000 })).stdout);
  const routes = new Map(); const accountCalls = [];
  let legacyIPC, legacyLocation;
  let loggedIn = false;
  const hostname = 'shared.example.ts.net';
  const location = embeddedLocation(registry); fs.mkdirSync(location.controlDirectory, { mode: 0o700 });
  // Only account/Funnel are simulated. Gate processes, persistence, OAuth,
  // authorization, tool calls and lifecycle commands are the production code.
  const ipc = http.createServer(async (req, res) => {
    try {
      let body = ''; for await (const chunk of req) body += chunk;
      const input = body ? JSON.parse(body) : {};
      if (req.url === '/login') { accountCalls.push('login'); loggedIn = true; }
      if (req.url === '/logout') { accountCalls.push('logout'); loggedIn = false; routes.clear(); }
      if (req.url === '/routes/start') {
        const health = await (await fetch(`http://127.0.0.1:${input.port}/health`)).json();
        assert.equal(health.workspaceId, input.gateID); assert.equal(health.instanceID, input.instanceID);
        routes.set(input.gateID, { ...input, publicUrl: input.expectedURL });
      }
      if (req.url === '/routes/stop') {
        const route = routes.get(input.gateID);
        assert.ok(!route || route.instanceID === input.instanceID); routes.delete(input.gateID);
      }
      if (req.url === '/stop') routes.delete(registry.read().id);
      res.end(JSON.stringify({ ok: true, service: 'boundas-tsnet', gatewayID: registry.read().id,
        state: loggedIn ? 'ready' : 'login', hostname, message: 'Shared fixture',
        routeManagementVersion: 1, loginManagementVersion: 2, accountManagementVersion: 1,
        routes: [...routes.values()], publicUrl: input.expectedURL ?? routes.get(registry.read().id)?.publicUrl,
        running: routes.has(registry.read().id) }));
    } catch (error) { res.statusCode = 409; res.end(JSON.stringify({ ok: false, message: error.message })); }
  });
  await new Promise(resolve => ipc.listen(location.socket, resolve)); fs.chmodSync(location.socket, 0o600);
  const ingress = http.createServer((req, res) => {
    const incoming = new URL(req.url, 'http://localhost');
    const match = /^\/side\/([a-f0-9]{12})(\/.*)$/.exec(incoming.pathname);
    const id = match?.[1] ?? registry.read().id;
    const local = match?.[2] ?? incoming.pathname;
    const route = routes.get(id);
    if (!route) { res.writeHead(404).end(); return; }
    const headers = { ...req.headers, host: `127.0.0.1:${route.port}`, 'x-forwarded-proto': 'https', 'x-boundas-gate-instance': route.instanceID };
    delete headers['x-forwarded-for'];
    const proxy = http.request({ host: '127.0.0.1', port: route.port, method: req.method, path: local + incoming.search, headers }, response => {
      res.writeHead(response.statusCode, response.headers); response.pipe(res);
    });
    proxy.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end(); }); req.pipe(proxy);
  });
  await new Promise(resolve => ingress.listen(0, '127.0.0.1', resolve));
  const base = gate => `http://127.0.0.1:${ingress.address().port}${gate ? `/side/${gate.c2cID}` : ''}`;
  const canonical = gate => `https://${hostname}${gate ? `/side/${gate.c2cID}` : ''}`;
  const rpc = (gate, token, name = 'list_workspaces', args = {}) => fetch(`${base(gate)}/mcp`, { method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }) });
  const authorize = async gate => {
    const pairing = await launch(gate, 'pair');
    const client = await (await fetch(`${base(gate)}/oauth/register`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ client_name: gate?.name ?? 'Main', redirect_uris: ['https://example.test/callback'] }) })).json();
    const verifier = 'x'.repeat(64);
    const resource = `${canonical(gate)}/mcp`;
    const query = new URLSearchParams({ client_id: client.client_id, redirect_uri: 'https://example.test/callback', response_type: 'code',
      code_challenge: backend.base64UrlSha256(verifier), code_challenge_method: 'S256', scope: 'workspace.read offline_access', resource });
    const html = await (await fetch(`${base(gate)}/oauth/authorize?${query}`)).text();
    const requestID = html.match(/name="request_id" value="([^"]+)"/)[1];
    const approval = await fetch(`${base(gate)}/oauth/authorize`, { method: 'POST', redirect: 'manual', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ request_id: requestID, pairing_code: pairing.pairingCode }) });
    assert.equal(approval.status, 302);
    const code = new URL(approval.headers.get('location')).searchParams.get('code');
    const response = await fetch(`${base(gate)}/oauth/token`, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'authorization_code', client_id: client.client_id, code, code_verifier: verifier,
        redirect_uri: 'https://example.test/callback', resource }) });
    assert.equal(response.status, 200);
    return { ...await response.json(), client_id: client.client_id };
  };
  try {
    await launch(null, 'start-local'); await launch(null, 'login'); await launch(null, 'start');
    assert.deepEqual(registry.active(), []); assert.deepEqual(accountCalls, ['login']);
    for (const gate of records) {
      await launch(gate, 'start-local');
      const before = await launch(gate, 'status'); assert.equal(before.sharedTunnel, true); assert.equal(before.transportSetup.state, 'ready');
      const after = await launch(gate, 'start-tunnel'); assert.equal(after.publicUrl, canonical(gate));
      const metadata = await (await fetch(`${base(gate)}/.well-known/oauth-authorization-server`)).json();
      assert.equal(metadata.issuer, canonical(gate)); assert.equal(metadata.token_endpoint, `${canonical(gate)}/oauth/token`);
    }
    assert.equal(routes.size, 3); assert.deepEqual(accountCalls, ['login']);
    const mainToken = await authorize(null); const tokenA = await authorize(records[0]); const tokenB = await authorize(records[1]);
    assert.equal((await rpc(records[0], mainToken.access_token)).status, 401);
    assert.equal((await rpc(records[1], tokenA.access_token)).status, 401);
    const empty = await (await rpc(null, mainToken.access_token)).json(); assert.deepEqual(empty.result.structuredContent.workspaces, []);
    for (const [gate, token] of [[records[0], tokenA], [records[1], tokenB]]) {
      const read = await (await rpc(gate, token.access_token, 'read_file', { workspace_id: gate.c2cID, path: 'read.txt' })).json();
      assert.equal(read.result.isError, undefined);
    }
    await launch(records[0], 'revoke-client', { clientID: tokenA.client_id });
    assert.equal((await rpc(records[0], tokenA.access_token)).status, 401);
    const refresh = await fetch(`${base(records[0])}/oauth/token`, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'refresh_token', client_id: tokenA.client_id, refresh_token: tokenA.refresh_token }) });
    assert.equal(refresh.status, 400);
    assert.equal((await rpc(records[1], tokenB.access_token)).status, 200);
    await launch(records[0], 'stop'); assert.equal(routes.size, 2); assert.equal((await rpc(null, mainToken.access_token)).status, 200);
    const urlB = (await launch(records[1], 'status')).publicUrl;
    await launch(null, 'stop'); assert.equal(routes.size, 1); assert.equal((await rpc(records[1], tokenB.access_token)).status, 200);
    await launch(records[1], 'stop'); await launch(records[1], 'reconnect');
    assert.equal((await launch(records[1], 'status')).publicUrl, urlB);
    assert.equal((await rpc(records[1], tokenB.access_token)).status, 200); assert.deepEqual(accountCalls, ['login']);
    // Shared ingress restart restores desired routes without a new account action.
    routes.clear(); await launch(records[1], 'reconnect');
    assert.equal((await rpc(records[1], tokenB.access_token)).status, 200);
    await launch(records[0], 'decommission');
    assert.equal(registry.addedFolders().length, 2); assert.equal((await rpc(records[1], tokenB.access_token)).status, 200);
    // A configured legacy Side is not silently moved. Its explicit migration
    // goes through the actual stop/restart commands and preserves its AuthStore.
    const legacy = new SideRegistry(registry, records[0].id, path.join(env.C2C_STATE_DIR, 'side-gates', records[0].c2cID)); legacy.ensure();
    const legacyURL = `https://legacy.example.ts.net/c2c/${records[0].c2cID}/mcp`;
    secureWrite(path.join(legacy.directory, 'config.json'), { ...legacy.read(), roots: undefined,
      transport: 'embedded', stableMCPURL: legacyURL, localOnly: false, desiredRunning: true });
    legacyLocation = embeddedLocation(legacy); fs.mkdirSync(legacyLocation.controlDirectory, { mode: 0o700 });
    let legacyRunning = false, oldStops = 0;
    legacyIPC = http.createServer((req, res) => {
      if (req.url === '/start') legacyRunning = true;
      if (req.url === '/stop') { oldStops++; legacyRunning = false; }
      res.end(JSON.stringify({ ok: true, service: 'boundas-tsnet', gatewayID: records[0].c2cID, state: 'ready',
        hostname: 'legacy.example.ts.net', running: legacyRunning, publicUrl: legacyURL.replace(/\/mcp$/, ''),
        loginManagementVersion: 2, accountManagementVersion: 1 }));
    });
    await new Promise(resolve => legacyIPC.listen(legacyLocation.socket, resolve)); fs.chmodSync(legacyLocation.socket, 0o600);
    const oldAuthFile = path.join(env.C2C_STATE_DIR, 'auth', `${records[0].c2cID}.json`);
    const oldAuth = new backend.AuthStore(records[0].c2cID, { file: oldAuthFile });
    const oldClient = oldAuth.registerClient({ clientName: 'Legacy AI', redirectUris: ['https://example.test/callback'] });
    const oldToken = oldAuth.issueTokens({ clientId: oldClient.clientId, scopes: ['workspace.read', 'offline_access', `bg.instance.${records[0].c2cID}`] });
    await launch(records[0], 'reconnect');
    assert.equal(legacy.read().stableMCPURL, legacyURL);
    const mainBeforeMigration = fs.readFileSync(path.join(registry.directory, 'config.json'), 'utf8');
    const migrated = await launch(records[0], 'migrate-shared');
    assert.equal(migrated.transport, 'shared'); assert.equal(migrated.publicUrl, canonical(records[0])); assert.equal(migrated.configuredMCPURL, null);
    assert.equal(legacyRunning, false); assert.ok(oldStops > 0);
    assert.equal((await rpc(records[0], oldToken.accessToken)).status, 200);
    assert.equal((await rpc(records[1], oldToken.accessToken)).status, 401);
    assert.equal(fs.readFileSync(path.join(registry.directory, 'config.json'), 'utf8'), mainBeforeMigration);
    assert.deepEqual(accountCalls, ['login']);
  } finally {
    for (const gate of [...records, null]) { try { await launch(gate, 'stop'); } catch {} }
    ingress.closeAllConnections(); await new Promise(resolve => ingress.close(resolve));
    ipc.closeAllConnections(); await new Promise(resolve => ipc.close(resolve));
    if (legacyIPC) { legacyIPC.closeAllConnections(); await new Promise(resolve => legacyIPC.close(resolve)); }
    if (legacyLocation) fs.rmSync(legacyLocation.controlDirectory, { recursive: true, force: true });
    fs.rmSync(location.controlDirectory, { recursive: true, force: true }); fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('explicit Side migration preserves Gate identity/auth/Main state and rolls back failure for retry', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'boundas-migrate-'));
  const main = new Registry({ directory: path.join(directory, 'main'), allowlistFile: path.join(directory, 'folders.json') });
  const folder = { id: randomUUID(), c2cID: 'aaaaaa123456', name: 'A', path: directory, sideGateAdded: true,
    configuredMCPURL: 'https://old.example.ts.net/c2c/aaaaaa123456/mcp' };
  secureWrite(main.allowlistFile, [folder]);
  const side = new SideRegistry(main, folder.id, path.join(directory, 'side')); side.ensure();
  side.updateConnection({ desiredRunning: true, localOnly: false });
  const original = fs.readFileSync(path.join(side.directory, 'config.json'), 'utf8');
  const auth = path.join(side.directory, 'auth.json'); secureWrite(auth, { sentinel: 'existing auth' });
  const mainBefore = fs.readFileSync(path.join(main.directory, 'config.json'), 'utf8');
  let stops = 0, opens = 0;
  try {
    await assert.rejects(migrateSideToShared({ registry: side, hostname: 'shared.example.ts.net', stop: async () => { stops++; },
      open: async config => { opens++; if (config.transport === 'shared') throw new Error('route unavailable'); } }), /original endpoint was restored/);
    assert.equal(fs.readFileSync(path.join(side.directory, 'config.json'), 'utf8'), original);
    assert.equal(stops, 2); assert.equal(opens, 2);
    const id = side.read().id, epoch = side.read().epoch;
    await migrateSideToShared({ registry: side, hostname: 'shared.example.ts.net', stop: async () => {}, open: async () => {} });
    assert.equal(side.read().id, id); assert.equal(side.read().epoch, epoch);
    assert.equal(side.read().stableMCPURL, `https://shared.example.ts.net/side/${id}/mcp`);
    assert.equal(side.read().configuredMCPURL, null);
    assert.equal(JSON.parse(fs.readFileSync(auth)).sentinel, 'existing auth');
    assert.equal(fs.readFileSync(path.join(main.directory, 'config.json'), 'utf8'), mainBefore);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
