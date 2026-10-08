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
import { SideRegistry } from '../../Resources/Gateway/side-registry.mjs';
import { embeddedLocation } from '../../Resources/Tailscale/embedded.mjs';
import { loadBackend } from '../../Resources/Gateway/server.mjs';

const execute = promisify(execFile);
const backendRoot = process.env.BOUNDAS_C2C_ROOT;
const backend = await loadBackend(backendRoot);

test('Side journey starts Local only; explicit Secure Access, scoped OAuth, Close, resume and removal', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'boundas-side-journey-'));
  const stateDir = path.join(directory, 'c2c');
  const main = new Registry({ directory: path.join(directory, 'main'), allowlistFile: path.join(directory, 'folders.json') });
  const folder = path.join(directory, 'folder'); fs.mkdirSync(folder); fs.writeFileSync(path.join(folder, 'hello.txt'), 'Side test');
  const workspace = new backend.Workspace(folder);
  const record = { id: randomUUID(), name: 'Side Folder', path: workspace.root, c2cID: workspace.id, sideGateAdded: true };
  secureWrite(main.allowlistFile, [record]); main.ensure(); main.ensureFolderPolicy(record);
  const side = new SideRegistry(main, record.id, path.join(stateDir, 'side-gates', record.c2cID)); side.ensure();
  // An isolated provider fixture, not a real account/network or the user's data.
  side.updateConnection({ transport: 'embedded', stableMCPURL: `https://fixture.example.ts.net/c2c/${record.c2cID}/mcp`, localOnly: true });
  const location = embeddedLocation(side);
  fs.mkdirSync(location.controlDirectory, { mode: 0o700 });
  let loggedIn = false, running = false, publicUrl;
  const calls = [];
  const ipc = http.createServer((req, res) => {
    calls.push(req.url);
    const hostname = 'fixture.example.ts.net';
    if (req.url === '/login') loggedIn = true;
    if (req.url === '/start') { running = true; publicUrl = `https://${hostname}/c2c/${record.c2cID}`; }
    if (req.url === '/stop') { running = false; publicUrl = undefined; }
    if (req.url === '/logout') { loggedIn = false; running = false; }
    res.end(JSON.stringify({ ok: true, service: 'boundas-tsnet', gatewayID: record.c2cID,
      state: loggedIn ? 'ready' : 'login', message: loggedIn ? 'ready' : 'Sign in',
      hostname, running, publicUrl, loginManagementVersion: 2, accountManagementVersion: 1 }));
  });
  await new Promise(resolve => ipc.listen(location.socket, resolve)); fs.chmodSync(location.socket, 0o600);
  const resources = path.join(directory, 'Resources');
  for (const component of ['Gateway', 'Tailscale']) fs.cpSync(path.resolve('Resources', component), path.join(resources, component), { recursive: true });
  const binary = path.join(resources, 'Runtime/bin/boundas-tunnel');
  fs.mkdirSync(path.dirname(binary), { recursive: true }); fs.symlinkSync('/usr/bin/false', binary);
  const env = { ...process.env, BOUNDAS_GATEWAY_DIR: main.directory, BOUNDAS_WORKSPACES_FILE: main.allowlistFile,
    C2C_STATE_DIR: stateDir, BOUNDAS_STATE_DIR: path.join(directory, 'routes') };
  const launch = async (action, input) => JSON.parse((await execute(process.execPath,
    [path.join(resources, 'Gateway/side-lifecycle.mjs'), action, backendRoot, record.id, ...(input ? [JSON.stringify(input)] : [])],
    { env, timeout: 30000 })).stdout);
  const authFile = path.join(stateDir, 'auth', `${record.c2cID}.json`);
  const mainSnapshot = fs.readFileSync(path.join(main.directory, 'config.json'), 'utf8');
  const mainConnectionSnapshot = main.connection();
  try {
    let value = await launch('start-local');
    assert.equal(value.running, true); assert.equal(value.localOnly, true); assert.equal(value.tunnel.running, false);
    assert.equal(value.roots.length, 1); assert.equal(value.roots[0].name, record.name);
    assert.deepEqual(value.aiConnections, []);
    assert.equal(calls.includes('/login'), false); assert.equal(calls.includes('/start'), false); assert.equal(calls.includes('/approve'), false);
    assert.equal((await fetch(`http://127.0.0.1:${value.port}/health`)).status, 200);
    assert.equal((await fetch(`http://127.0.0.1:${value.port}/mcp`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: '{"jsonrpc":"2.0","id":1,"method":"ping"}' })).status, 401);
    // Batch/menu legacy Start is also local-only, never silent Secure Access.
    await launch('start'); await launch('recover');
    assert.equal(calls.includes('/start'), false); assert.equal(calls.includes('/login'), false);
    const pending = await launch('prepare-access');
    assert.equal(pending.localOnly, false); assert.equal(pending.transportSetup.state, 'login');
    assert.equal(calls.includes('/login'), false); assert.equal(calls.includes('/start'), false);
    await assert.rejects(launch('recover'));
    value = await launch('login');
    assert.equal(value.transportSetup.state, 'ready'); assert.equal(value.tunnel.running, true);
    assert.ok(calls.includes('/login')); assert.ok(calls.includes('/start'));
    assert.equal(value.publicUrl, `https://fixture.example.ts.net/c2c/${record.c2cID}`);
    const pair = await launch('pair');
    assert.match(pair.sessionID, /^[a-f0-9]{32}$/); assert.equal(pair.roots[0].id, record.c2cID);
    const base = `http://127.0.0.1:${value.port}`;
    const registration = await fetch(`${base}/oauth/register`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ client_name: 'Claude', redirect_uris: ['https://example.test/callback'] }) });
    const client = await registration.json(); assert.equal(registration.status, 201);
    const verifier = 'x'.repeat(64);
    const query = new URLSearchParams({ client_id: client.client_id, redirect_uri: 'https://example.test/callback', response_type: 'code',
      code_challenge: backend.base64UrlSha256(verifier), code_challenge_method: 'S256', scope: 'workspace.read offline_access' });
    const html = await (await fetch(`${base}/oauth/authorize?${query}`)).text();
    const requestID = html.match(/name="request_id" value="([^"]+)"/)[1];
    const approval = await fetch(`${base}/oauth/authorize`, { method: 'POST', redirect: 'manual', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ request_id: requestID, pairing_code: pair.pairingCode }) });
    assert.equal(approval.status, 302);
    const code = new URL(approval.headers.get('location')).searchParams.get('code');
    const tokens = await (await fetch(`${base}/oauth/token`, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'authorization_code', code, client_id: client.client_id, redirect_uri: 'https://example.test/callback', code_verifier: verifier }) })).json();
    assert.ok(tokens.access_token);
    const authorized = await launch('status');
    assert.equal(authorized.aiConnections[0].authorizationState, 'authorized');
    assert.equal(authorized.aiConnections[0].authorizationSessionID, pair.sessionID);
    // Upgrade a legacy running daemon: retain runtime intent and authorization.
    const configFile = path.join(side.directory, 'config.json');
    const oldConfig = JSON.parse(fs.readFileSync(configFile));
    delete oldConfig.desiredRunning; delete oldConfig.localOnly; secureWrite(configFile, oldConfig);
    const markerFile = path.join(stateDir, 'side-gates', `${record.c2cID}.json`);
    secureWrite(markerFile, { ...JSON.parse(fs.readFileSync(markerFile)), protocolVersion: 2 });
    const upgraded = await launch('status');
    assert.equal(upgraded.running, false); assert.equal(upgraded.desiredRunning, true); assert.equal(upgraded.localOnly, false);
    const resumed = await launch('recover');
    assert.equal(resumed.running, true); assert.equal(resumed.tunnel.running, true);
    assert.equal(resumed.aiConnections[0].authorizationState, 'authorized');
    const policy = await launch('code-policy', { workspaceID: record.c2cID, required: true });
    assert.equal(policy.roots[0].codeRequired, true); assert.equal(main.read().roots[0].codeRequired, true);
    const passcode = await launch('folder-code', { workspaceID: record.c2cID }); assert.ok(passcode.code);
    const beforeClose = fs.readFileSync(authFile, 'utf8');
    await launch('stop');
    assert.equal((await launch('status')).running, false);
    assert.equal(fs.readFileSync(authFile, 'utf8'), beforeClose);
    assert.equal(side.active()[0].codeRequired, true); assert.equal(main.addedFolders()[0].sideGateAdded, true);
    assert.equal(calls.includes('/logout'), false);
    await assert.rejects(launch('recover')); // A user Close must not reopen itself.
    calls.length = 0;
    value = await launch('start-local');
    assert.equal(value.tunnel.running, false); assert.equal(value.aiConnections[0].authorizationState, 'authorized');
    assert.equal(calls.includes('/start'), false); assert.equal(calls.includes('/login'), false);
    value = await launch('prepare-access'); // Explicit resume, no account login or re-pairing.
    assert.equal(value.tunnel.running, true); assert.equal(calls.includes('/login'), false);
    // Crash recovery may restore an already requested route, but never an account action.
    process.kill(value.pid, 'SIGKILL'); // PID came from this test's isolated, authenticated Gate.
    await new Promise(resolve => setTimeout(resolve, 150));
    value = await launch('recover');
    assert.equal(value.running, true); assert.equal(value.tunnel.running, true); assert.equal(calls.includes('/login'), false);
    // Main connection/ACL state is unchanged, apart from the intentionally shared Passcode policy.
    const original = JSON.parse(mainSnapshot), current = main.read();
    assert.equal(current.id, original.id); assert.deepEqual(main.connection(), mainConnectionSnapshot);
    assert.equal(current.roots[0].enabled, original.roots[0].enabled);
    secureWrite(main.allowlistFile, [{ ...record, sideGateRemovalState: 'removing' }]);
    await launch('decommission');
    assert.equal(fs.existsSync(authFile), false);
    assert.equal(fs.existsSync(path.join(side.directory, 'config.json')), false);
    assert.equal(main.read().roots[0].codeRequired, true); assert.equal(main.addedFolders().length, 1);
    secureWrite(main.allowlistFile, [record]);
    const fresh = await launch('start-local');
    assert.deepEqual(fresh.aiConnections, []); assert.equal(fresh.roots[0].codeRequired, true);
  } finally {
    secureWrite(main.allowlistFile, [record]);
    await launch('stop').catch(() => {});
    await new Promise(resolve => ipc.close(resolve));
    fs.rmSync(location.controlDirectory, { recursive: true, force: true });
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
