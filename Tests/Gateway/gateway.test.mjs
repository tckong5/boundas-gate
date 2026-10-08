import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomUUID, randomBytes } from 'node:crypto';
import { spawnSync, execFile } from 'node:child_process';
import http from 'node:http';
import { promisify } from 'node:util';
import { Registry, secureWrite } from '../../Resources/Gateway/registry.mjs';
import { FolderAccess } from '../../Resources/Gateway/access.mjs';
import { proxyPath } from '../../Resources/Tailscale/provider.mjs';
import { loadBackend, startGateway } from '../../Resources/Gateway/server.mjs';

const backendRoot = process.env.BOUNDAS_C2C_ROOT;
if (!backendRoot) throw new Error('Set BOUNDAS_C2C_ROOT to an installed C2C build for gateway integration tests.');
const backend = await loadBackend(backendRoot);
function fixture() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'boundas-gateway-'));
  const allowlistFile = path.join(directory, 'workspaces.json');
  const roots = ['A', 'B', 'C'].map(name => {
    const root = path.join(directory, name); fs.mkdirSync(root); fs.writeFileSync(path.join(root, 'hello.txt'), `${name} read test\n`); fs.writeFileSync(path.join(root, '.env'), 'SECRET=should-never-return');
    const workspace = new backend.Workspace(root);
    return { id: randomUUID().toUpperCase(), name, path: workspace.root, c2cID: workspace.id };
  });
  fs.symlinkSync(roots[1].path, path.join(roots[0].path, 'outside-link'));
  secureWrite(allowlistFile, roots);
  const registry = new Registry({ directory: path.join(directory, 'state'), allowlistFile });
  const select = (...indices) => registry.configure(indices.map(index => roots[index].id.toLowerCase()), backend.Workspace);
  const clean = () => fs.rmSync(directory, { recursive: true, force: true });
  return { directory, roots, registry, allowlistFile, select, clean };
}
function fakeTunnel(registry) {
  let running = false;
  const url = `https://mac.example.ts.net/c2c/${registry.read().id}`;
  return { name: 'test', start: async () => { running = true; return url; }, stop: async () => { running = false; }, status: () => ({ running, url, provider: 'test' }) };
}
async function server(f) {
  const gateway = await startGateway({ backendRoot, registry: f.registry, persistRuntime: false, tunnelProvider: fakeTunnel(f.registry) });
  const reply = await control(gateway, '/control/tunnel/start'); assert.equal(reply.status, 200);
  return gateway;
}
async function control(gateway, route, body) { return fetch(`${gateway.localBase()}${route}`, { method: 'POST', headers: { Authorization: `Bearer ${gateway.adminToken}`, ...(body ? { 'Content-Type': 'application/json' } : {}) }, body: body ? JSON.stringify(body) : undefined }); }
async function pair(gateway) { return (await control(gateway, '/control/pair')).json(); }
async function authorize(gateway, pairing, scope = 'workspace.read workspace.search git.read offline_access') {
  const base = gateway.localBase();
  const registration = await fetch(`${base}/oauth/register`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ client_name: 'Local regression', redirect_uris: ['https://example.test/callback'] }) });
  const client = await registration.json(); assert.equal(registration.status, 201);
  const verifier = 'x'.repeat(64);
  const query = new URLSearchParams({ client_id: client.client_id, redirect_uri: 'https://example.test/callback', response_type: 'code', code_challenge: backend.base64UrlSha256(verifier), code_challenge_method: 'S256', scope });
  const html = await (await fetch(`${base}/oauth/authorize?${query}`)).text();
  const requestID = html.match(/name="request_id" value="([^"]+)"/)[1];
  const approval = await fetch(`${base}/oauth/authorize`, { method: 'POST', redirect: 'manual', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ request_id: requestID, pairing_code: pairing.pairingCode }) });
  assert.equal(approval.status, 302);
  const code = new URL(approval.headers.get('location')).searchParams.get('code');
  const response = await fetch(`${base}/oauth/token`, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ grant_type: 'authorization_code', client_id: client.client_id, code, code_verifier: verifier, redirect_uri: 'https://example.test/callback' }) });
  assert.equal(response.status, 200);
  return { ...await response.json(), client_id: client.client_id };
}
async function rpc(gateway, token, name, args = {}, session) {
  const response = await fetch(`${gateway.localBase()}/mcp`, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args, ...(session === undefined ? {} : { _meta: { 'openai/session': session } }) } }) });
  assert.equal(response.status, 200);
  const body = await response.json(); assert.ok(body.result, JSON.stringify(body));
  return body.result;
}
function data(result) { return result.structuredContent ?? JSON.parse(result.content[0].text); }
async function read(gateway, tokens, id, file = 'hello.txt') { return rpc(gateway, tokens.access_token, 'read_file', { workspace_id: id, path: file }); }

test('registry requires explicitly added folders and preserves the gateway ID', () => {
  const f = fixture();
  try {
    assert.throws(() => f.registry.configure(['not-added'], backend.Workspace));
    const first = f.select(0); const second = f.select(0, 1);
    assert.equal(first.id, second.id); assert.equal(first.roots[0].epoch, second.roots[0].epoch);
    f.select(1); f.select(0, 1);
    assert.notEqual(f.registry.read().roots.find(root => root.id === f.roots[0].c2cID).epoch, first.roots[0].epoch);
    assert.equal(fs.statSync(path.join(f.registry.directory, 'config.json')).mode & 0o777, 0o600);
  } finally { f.clean(); }
});
test('one paired OAuth connector reads two roots and no unselected root', async () => {
  const f = fixture(); f.select(0, 1); const gateway = await server(f);
  try {
    const tokens = await authorize(gateway, await pair(gateway));
    const listed = data(await rpc(gateway, tokens.access_token, 'list_workspaces'));
    assert.deepEqual(listed.workspaces.map(root => root.name).sort(), ['A', 'B']);
    assert.ok(!JSON.stringify(listed).includes(f.directory));
    for (let index = 0; index < 2; index++) {
      const result = await read(gateway, tokens, f.roots[index].c2cID);
      assert.equal(result.isError, undefined); assert.match(data(result).content, new RegExp(`${f.roots[index].name} read test`));
    }
    assert.equal((await read(gateway, tokens, f.roots[2].c2cID)).isError, true);
    assert.equal((await read(gateway, tokens, '../../other')).isError, true);
  } finally { await gateway.close(); f.clean(); }
});
test('sharing a root after pairing updates all read tools and refresh without re-pairing', async () => {
  const f = fixture(); f.select(0); const gateway = await server(f);
  try {
    const tokens = await authorize(gateway, await pair(gateway));
    assert.deepEqual(data(await rpc(gateway, tokens.access_token, 'list_workspaces')).workspaces.map(root => root.name), ['A']);
    f.select(0, 1);
    assert.deepEqual(data(await rpc(gateway, tokens.access_token, 'list_workspaces')).workspaces.map(root => root.name), ['A', 'B']);
    for (const [name, args] of [['workspace_info', {}], ['list_directory', {}], ['read_file', { path: 'hello.txt' }], ['search_workspace', { query: 'read test' }], ['git_status', {}], ['git_diff', {}]]) {
      assert.notEqual((await rpc(gateway, tokens.access_token, name, { workspace_id: f.roots[1].c2cID, ...args })).isError, true);
    }
    const verified = gateway.authStore.verifyAccessToken(tokens.access_token);
    assert.ok(verified.record.scopes.includes(f.registry.connectionScope()));
    assert.ok(!verified.record.scopes.some(scope => /^bg\.[a-f0-9]{12}\./.test(scope)));
    const response = await fetch(`${gateway.localBase()}/oauth/token`, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ grant_type: 'refresh_token', client_id: tokens.client_id, refresh_token: tokens.refresh_token }) });
    assert.equal(response.status, 200); const refreshed = await response.json();
    assert.equal((await read(gateway, refreshed, f.roots[1].c2cID)).isError, undefined);
  } finally { await gateway.close(); f.clean(); }
});
test('pairing authorizes the instance and does not snapshot roots before OAuth approval', async () => {
  const f = fixture(); f.select(0); const gateway = await server(f);
  try {
    const pairing = await pair(gateway);
    f.select(0, 1);
    const forgedGrant = `bg.${f.roots[2].c2cID}.${'a'.repeat(32)}`;
    const tokens = await authorize(gateway, pairing, `workspace.read offline_access ${forgedGrant}`);
    assert.equal((await read(gateway, tokens, f.roots[1].c2cID)).isError, undefined);
    assert.equal((await read(gateway, tokens, f.roots[0].c2cID)).isError, undefined);
    assert.equal((await read(gateway, tokens, f.roots[2].c2cID)).isError, true);
    assert.ok(!tokens.scope.includes(forgedGrant));
  } finally { await gateway.close(); f.clean(); }
});
test('disabling revokes every tool and explicit re-sharing works with the same token', async () => {
  const f = fixture(); f.select(0, 1); const gateway = await server(f);
  try {
    const tokens = await authorize(gateway, await pair(gateway));
    f.select(1);
    assert.deepEqual(data(await rpc(gateway, tokens.access_token, 'list_workspaces')).workspaces.map(root => root.name), ['B']);
    for (const [name, args] of [['workspace_info', {}], ['list_directory', {}], ['read_file', { path: 'hello.txt' }], ['search_workspace', { query: 'read test' }], ['git_status', {}], ['git_diff', {}]]) {
      const rejected = await rpc(gateway, tokens.access_token, name, { workspace_id: f.roots[0].c2cID, ...args });
      assert.equal(rejected.isError, true);
      assert.equal(data(rejected).error, 'WORKSPACE_NOT_AUTHORIZED');
    }
    assert.equal((await read(gateway, tokens, f.roots[0].c2cID)).isError, true);
    assert.equal((await read(gateway, tokens, f.roots[1].c2cID)).isError, undefined);
    f.select(0, 1);
    assert.equal((await read(gateway, tokens, f.roots[0].c2cID)).isError, undefined);
  } finally { await gateway.close(); f.clean(); }
});
test('removing and re-adding a folder in the app invalidates the previous source identity', async () => {
  const f = fixture(); f.select(0, 1); const gateway = await server(f);
  try {
    const tokens = await authorize(gateway, await pair(gateway));
    secureWrite(f.allowlistFile, [f.roots[1]]);
    assert.equal((await read(gateway, tokens, f.roots[0].c2cID)).isError, true);
    secureWrite(f.allowlistFile, [{ ...f.roots[0], id: randomUUID() }, f.roots[1]]);
    assert.equal((await read(gateway, tokens, f.roots[0].c2cID)).isError, true);
    fs.writeFileSync(f.allowlistFile, '{broken');
    assert.equal((await read(gateway, tokens, f.roots[1].c2cID)).isError, true);
  } finally { await gateway.close(); f.clean(); }
});
test('file traversal, symlink escape, secrets and unknown write tools are denied', async () => {
  const f = fixture(); f.select(0, 1); const gateway = await server(f);
  try {
    const tokens = await authorize(gateway, await pair(gateway));
    for (const file of ['../B/hello.txt', path.join(f.roots[1].path, 'hello.txt'), 'outside-link/hello.txt', '.env']) {
      const result = await read(gateway, tokens, f.roots[0].c2cID, file); assert.equal(result.isError, true);
      assert.ok(!JSON.stringify(result).includes('should-never-return'));
    }
    const response = await fetch(`${gateway.localBase()}/mcp`, { method: 'POST', headers: { Authorization: `Bearer ${tokens.access_token}`, 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'apply_patch', arguments: { workspace_id: f.roots[0].c2cID } } }) });
    const body = await response.json(); assert.ok(body.error || body.result?.isError);
    assert.equal(fs.readFileSync(path.join(f.roots[0].path, 'hello.txt'), 'utf8'), 'A read test\n');
  } finally { await gateway.close(); f.clean(); }
});
test('root replacement through a symlink is rejected', async () => {
  const f = fixture(); f.select(0); const gateway = await server(f);
  try {
    const tokens = await authorize(gateway, await pair(gateway));
    fs.renameSync(f.roots[0].path, `${f.roots[0].path}-old`); fs.symlinkSync(f.roots[1].path, f.roots[0].path);
    assert.equal((await read(gateway, tokens, f.roots[0].c2cID)).isError, true);
  } finally { await gateway.close(); f.clean(); }
});
test('gateway OAuth and root grants persist across a restart without changing the URL', async () => {
  const f = fixture(); f.select(0, 1); let gateway = await server(f);
  try {
    const tokens = await authorize(gateway, await pair(gateway));
    const id = gateway.id; await gateway.close(); gateway = await server(f);
    assert.equal(gateway.id, id);
    assert.equal((await read(gateway, tokens, f.roots[0].c2cID)).isError, undefined);
    assert.equal((await read(gateway, tokens, f.roots[1].c2cID)).isError, undefined);
    assert.equal(f.registry.connection().stableMCPURL, `${gateway.provider.status().url}/mcp`);
    const refreshed = await fetch(`${gateway.localBase()}/oauth/token`, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ grant_type: 'refresh_token', client_id: tokens.client_id, refresh_token: tokens.refresh_token }) });
    assert.equal(refreshed.status, 200);
    assert.equal((await read(gateway, await refreshed.json(), f.roots[0].c2cID)).isError, undefined);
  } finally { await gateway.close(); f.clean(); }
});
test('legacy access and refresh credentials migrate without changing secrets or operation scopes', async () => {
  const f = fixture(); f.select(0);
  const oldStore = new backend.AuthStore(f.registry.read().id, { file: path.join(f.registry.directory, 'auth.json') });
  const client = oldStore.registerClient({ clientName: 'Existing pre-1.1 connector', redirectUris: ['https://example.test/callback'] });
  const originalRoot = f.registry.active()[0];
  const legacyScope = `bg.${originalRoot.id}.${originalRoot.epoch}`;
  const credentials = oldStore.issueTokens({ clientId: client.clientId, scopes: ['workspace.read', 'offline_access', legacyScope] });
  const revoked = oldStore.issueTokens({ clientId: client.clientId, scopes: ['workspace.read', legacyScope] });
  oldStore.revokeToken(revoked.accessToken);
  const expired = oldStore.issueTokens({ clientId: client.clientId, scopes: ['workspace.read', legacyScope], accessTtlMs: -1 });
  f.select(1); // Migration does not depend on the original root still being shared.
  let gateway = await server(f);
  try {
    const token = { access_token: credentials.accessToken };
    assert.equal((await read(gateway, token, f.roots[1].c2cID)).isError, undefined);
    assert.equal((await read(gateway, token, f.roots[0].c2cID)).isError, true);
    assert.equal((await rpc(gateway, token.access_token, 'search_workspace', { workspace_id: f.roots[1].c2cID, query: 'read test' })).isError, true);
    assert.equal(gateway.authStore.verifyAccessToken(revoked.accessToken).ok, false);
    assert.equal(gateway.authStore.verifyAccessToken(expired.accessToken).ok, false);
    await gateway.close(); gateway = await server(f);
    assert.equal((await read(gateway, token, f.roots[1].c2cID)).isError, undefined);
    const response = await fetch(`${gateway.localBase()}/oauth/token`, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ grant_type: 'refresh_token', client_id: client.clientId, refresh_token: credentials.refreshToken }) });
    assert.equal(response.status, 200); const refreshed = await response.json();
    assert.ok(refreshed.scope.includes(f.registry.connectionScope()));
    assert.ok(!refreshed.scope.includes(legacyScope));
    assert.ok(!refreshed.scope.includes('workspace.search'));
    assert.equal((await read(gateway, refreshed, f.roots[1].c2cID)).isError, undefined);
    await gateway.close(); gateway = await server(f);
    f.select(0, 1, 2);
    assert.equal((await read(gateway, refreshed, f.roots[2].c2cID)).isError, undefined);
    assert.equal((await read(gateway, token, f.roots[2].c2cID)).isError, undefined);
    await control(gateway, '/control/revoke');
    assert.equal(gateway.authStore.verifyAccessToken(token.access_token).ok, false);
    assert.equal(gateway.authStore.verifyAccessToken(refreshed.access_token).ok, false);
  } finally { await gateway.close(); f.clean(); }
});
test('operation scopes alone or a different instance scope cannot authorize the gateway', async () => {
  const f = fixture(); f.select(0); const gateway = await server(f);
  try {
    for (const scopes of [['workspace.read'], ['workspace.read', 'bg.instance.000000000000'], ['workspace.read', 'bg.not-a-pairing']]) {
      const unpaired = gateway.authStore.issueTokens({ clientId: 'unpaired', scopes });
      assert.equal((await rpc(gateway, unpaired.accessToken, 'list_workspaces')).isError, true);
      assert.equal((await read(gateway, { access_token: unpaired.accessToken }, f.roots[0].c2cID)).isError, true);
    }
  } finally { await gateway.close(); f.clean(); }
});
test('reconnecting only the tunnel preserves OAuth, folder grants and an unlocked conversation', async () => {
  const f = fixture(); f.select(0, 1); const gateway = await server(f);
  try {
    const tokens = await authorize(gateway, await pair(gateway));
    const id = f.roots[0].c2cID;
    f.registry.setCodePolicy(id, true);
    const issued = await (await control(gateway, '/control/folder-code', { workspaceID: id })).json();
    const unlocked = data(await rpc(gateway, tokens.access_token, 'unlock_workspace', { code: issued.code }, 'original-chat'));
    const before = f.registry.read();
    await gateway.provider.stop();
    assert.equal((await control(gateway, '/control/tunnel/start')).status, 200);
    assert.deepEqual(f.registry.read().roots, before.roots);
    assert.equal(f.registry.read().stableMCPURL, before.stableMCPURL);
    assert.equal(gateway.authStore.verifyAccessToken(tokens.access_token).ok, true);
    assert.equal((await rpc(gateway, tokens.access_token, 'read_file', { workspace_id: id, path: 'hello.txt', access_key: unlocked.access_key }, 'original-chat')).isError, undefined);
    assert.equal((await read(gateway, tokens, f.roots[1].c2cID)).isError, undefined);
  } finally { await gateway.close(); f.clean(); }
});
test('connection preferences preserve grants and reject replacement addresses', () => {
  const f = fixture(); const initial = f.select(0, 1);
  try {
    const mcpURL = `https://mac.example.ts.net/c2c/${initial.id}/mcp`;
    f.registry.updateConnection({ stableMCPURL: mcpURL, desiredRunning: true });
    f.registry.updateConnection({ desiredRunning: false, reconnectEnabled: false });
    assert.deepEqual(f.registry.read().roots, initial.roots);
    assert.deepEqual(f.registry.connection(), { stableMCPURL: mcpURL, desiredRunning: false, reconnectEnabled: false });
    assert.throws(() => f.registry.updateConnection({ stableMCPURL: `https://other.example.ts.net/c2c/${initial.id}/mcp` }), /固定地址/);
    assert.equal(f.registry.connection().stableMCPURL, mcpURL);
  } finally { f.clean(); }
});
test('Git status/diff work per selected root; ordinary folders remain usable', async () => {
  const f = fixture();
  for (const args of [['init'], ['-c', 'user.email=test@example.test', '-c', 'user.name=Test', 'add', 'hello.txt'], ['-c', 'user.email=test@example.test', '-c', 'user.name=Test', 'commit', '-m', 'initial']]) {
    assert.equal(spawnSync('git', args, { cwd: f.roots[0].path, stdio: 'ignore' }).status, 0);
  }
  fs.appendFileSync(path.join(f.roots[0].path, 'hello.txt'), 'changed\n');
  f.select(0, 1); const gateway = await server(f);
  try {
    const tokens = await authorize(gateway, await pair(gateway));
    const status = data(await rpc(gateway, tokens.access_token, 'git_status', { workspace_id: f.roots[0].c2cID })); assert.equal(status.isRepo, true);
    const diff = data(await rpc(gateway, tokens.access_token, 'git_diff', { workspace_id: f.roots[0].c2cID })); assert.match(diff.diff, /changed/);
    assert.equal(data(await rpc(gateway, tokens.access_token, 'git_status', { workspace_id: f.roots[1].c2cID })).isRepo, false);
    const found = data(await rpc(gateway, tokens.access_token, 'search_workspace', { workspace_id: f.roots[1].c2cID, query: 'read test' })); assert.equal(found.matches[0].path, 'hello.txt');
  } finally { await gateway.close(); f.clean(); }
});
test('MCP requires OAuth, rejects wrong gateway tokens and respects requested scopes', async () => {
  const f = fixture(); f.select(0); const gateway = await server(f);
  try {
    const unauthorized = await fetch(`${gateway.localBase()}/mcp`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' }); assert.equal(unauthorized.status, 401);
    const bad = gateway.authStore.issueTokens({ clientId: 'test', scopes: ['workspace.read'], workspaceId: 'other-gateway' });
    const forbidden = await fetch(`${gateway.localBase()}/mcp`, { method: 'POST', headers: { Authorization: `Bearer ${bad.accessToken}`, 'Content-Type': 'application/json' }, body: '{}' }); assert.equal(forbidden.status, 403);
    const tokens = await authorize(gateway, await pair(gateway), 'workspace.read');
    assert.equal((await rpc(gateway, tokens.access_token, 'search_workspace', { workspace_id: f.roots[0].c2cID, query: 'test' })).isError, true);
    const wrongResource = await fetch(`${gateway.localBase()}/oauth/token`, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ grant_type: 'refresh_token', resource: 'https://other.test/mcp' }) }); assert.equal(wrongResource.status, 400);
    const proxiedAdmin = await fetch(`${gateway.localBase()}/control/info`, { headers: { Authorization: `Bearer ${gateway.adminToken}`, 'X-Forwarded-For': '1.2.3.4' } }); assert.equal(proxiedAdmin.status, 404);
    await control(gateway, '/control/revoke');
    const revoked = await fetch(`${gateway.localBase()}/mcp`, { method: 'POST', headers: { Authorization: `Bearer ${tokens.access_token}`, 'Content-Type': 'application/json' }, body: '{}' }); assert.equal(revoked.status, 401);
  } finally { await gateway.close(); f.clean(); }
});

test('revoking an in-flight read discards its output', async () => {
  const f = fixture(); f.select(0); const gateway = await server(f);
  const original = backend.Workspace.prototype.readFile;
  let started, release;
  const begun = new Promise(resolve => { started = resolve; });
  const barrier = new Promise(resolve => { release = resolve; });
  backend.Workspace.prototype.readFile = async function (...args) { started(); await barrier; return original.apply(this, args); };
  try {
    const tokens = await authorize(gateway, await pair(gateway));
    const pending = read(gateway, tokens, f.roots[0].c2cID);
    await begun; f.registry.revokeSource(f.roots[0].id); release();
    const result = await pending; assert.equal(result.isError, true); assert.ok(!JSON.stringify(result).includes('A read test'));
  } finally { release(); backend.Workspace.prototype.readFile = original; await gateway.close(); f.clean(); }
});
test('Git custom diff and fsmonitor programs cannot run during read tools', async () => {
  const f = fixture();
  const marker = path.join(f.directory, 'executed');
  const script = path.join(f.directory, 'unsafe-hook');
  fs.writeFileSync(script, `#!/bin/sh\n/usr/bin/touch '${marker}'\n/bin/cat "$1"\n`, { mode: 0o700 });
  const root = f.roots[0].path;
  for (const args of [['init'], ['add', 'hello.txt'], ['-c', 'user.email=test@example.test', '-c', 'user.name=Test', 'commit', '-m', 'initial'], ['config', 'core.fsmonitor', script], ['config', 'diff.unsafe.textconv', script]]) {
    assert.equal(spawnSync('/usr/bin/git', args, { cwd: root, stdio: 'ignore' }).status, 0);
  }
  fs.writeFileSync(path.join(root, '.gitattributes'), 'hello.txt diff=unsafe\n'); fs.appendFileSync(path.join(root, 'hello.txt'), 'change\n');
  f.select(0); const gateway = await server(f);
  try {
    const tokens = await authorize(gateway, await pair(gateway));
    for (const name of ['workspace_info', 'git_status', 'git_diff']) {
      const result = await rpc(gateway, tokens.access_token, name, { workspace_id: f.roots[0].c2cID }); assert.notEqual(result.isError, true);
    }
    assert.equal(fs.existsSync(marker), false);
  } finally { await gateway.close(); f.clean(); }
});

test('repo clean/process filters are refused before Git status can invoke them', async () => {
  const f = fixture();
  const marker = path.join(f.directory, 'filter-executed');
  const script = path.join(f.directory, 'unsafe-filter');
  fs.writeFileSync(script, `#!/bin/sh\n/usr/bin/touch '${marker}'\n/bin/cat\n`, { mode: 0o700 });
  const root = f.roots[0].path;
  for (const args of [['init'], ['add', 'hello.txt'], ['-c', 'user.email=test@example.test', '-c', 'user.name=Test', 'commit', '-m', 'initial'], ['config', 'filter.unsafe.clean', script]]) {
    assert.equal(spawnSync('/usr/bin/git', args, { cwd: root, stdio: 'ignore' }).status, 0);
  }
  fs.writeFileSync(path.join(root, '.gitattributes'), 'hello.txt filter=unsafe\n');
  f.select(0); const gateway = await server(f);
  try {
    const tokens = await authorize(gateway, await pair(gateway));
    assert.equal((await rpc(gateway, tokens.access_token, 'git_status', { workspace_id: f.roots[0].c2cID })).isError, true);
    assert.equal(fs.existsSync(marker), false);
    assert.equal((await read(gateway, tokens, f.roots[0].c2cID)).isError, undefined);
  } finally { await gateway.close(); f.clean(); }
});

test('code protection is opt-in, preserves legacy config and survives membership saves', () => {
  const f = fixture(); f.select(0, 1);
  try {
    assert.ok(f.registry.active().every(root => root.codeRequired === false));
    const legacy = f.registry.read();
    for (const root of legacy.roots) { delete root.codeRequired; delete root.codeEpoch; }
    secureWrite(path.join(f.registry.directory, 'config.json'), legacy);
    assert.equal(f.registry.active()[0].codeRequired, undefined);
    const id = f.roots[0].c2cID;
    f.registry.setCodePolicy(id, true); f.select(0, 1);
    assert.equal(f.registry.active().find(root => root.id === id).codeRequired, true);
    f.select(1); f.select(0, 1);
    assert.equal(f.registry.active().find(root => root.id === id).codeRequired, true);
    const invalid = f.registry.read(); invalid.roots[0].codeRequired = 'yes';
    secureWrite(path.join(f.registry.directory, 'config.json'), invalid);
    assert.throws(() => f.registry.read());
  } finally { f.clean(); }
});

test('locked roots are hidden and all file and Git tools require a folder capability', async () => {
  const f = fixture(); f.select(0, 1); const gateway = await server(f);
  try {
    const tokens = await authorize(gateway, await pair(gateway));
    const id = f.roots[0].c2cID;
    const policy = await control(gateway, '/control/code-policy', { workspaceID: id, required: true });
    assert.equal(policy.status, 200);
    assert.deepEqual(data(await rpc(gateway, tokens.access_token, 'list_workspaces')).workspaces.map(root => root.name), ['B']);
    for (const [name, args] of [['workspace_info', {}], ['list_directory', {}], ['read_file', { path: 'hello.txt' }], ['search_workspace', { query: 'test' }], ['git_status', {}], ['git_diff', {}]]) {
      const reply = await rpc(gateway, tokens.access_token, name, { workspace_id: id, ...args }, 'chat-A');
      assert.equal(reply.isError, true); assert.equal(data(reply).error, 'FOLDER_LOCKED');
      assert.ok(!JSON.stringify(reply).includes('A read test'));
    }
    assert.equal((await read(gateway, tokens, f.roots[1].c2cID)).isError, undefined);
  } finally { await gateway.close(); f.clean(); }
});

test('a one-time code unlocks only its folder, OAuth credential and conversation', async () => {
  const f = fixture(); f.select(0, 1); const gateway = await server(f);
  try {
    const tokens = await authorize(gateway, await pair(gateway));
    const other = await authorize(gateway, await pair(gateway));
    for (const root of f.roots.slice(0, 2)) f.registry.setCodePolicy(root.c2cID, true);
    const issued = await (await control(gateway, '/control/folder-code', { workspaceID: f.roots[0].c2cID })).json();
    assert.match(issued.code, /^BG-(?:[A-F0-9]{4}-){5}[A-F0-9]{4}$/);
    assert.equal((await rpc(gateway, tokens.access_token, 'unlock_workspace', { code: issued.code })).isError, true);
    const unlocked = data(await rpc(gateway, tokens.access_token, 'unlock_workspace', { code: issued.code }, 'chat-A'));
    assert.equal(unlocked.workspace_id, f.roots[0].c2cID); assert.ok(unlocked.access_key);
    const args = { workspace_id: unlocked.workspace_id, path: 'hello.txt', access_key: unlocked.access_key };
    assert.equal((await rpc(gateway, tokens.access_token, 'read_file', args, 'chat-A')).isError, undefined);
    for (const session of ['chat-B', undefined]) assert.equal((await rpc(gateway, tokens.access_token, 'read_file', args, session)).isError, true);
    assert.equal((await rpc(gateway, other.access_token, 'read_file', args, 'chat-A')).isError, true);
    assert.equal((await rpc(gateway, tokens.access_token, 'read_file', { ...args, workspace_id: f.roots[1].c2cID }, 'chat-A')).isError, true);
    assert.equal((await rpc(gateway, tokens.access_token, 'read_file', { ...args, access_key: undefined }, 'chat-A')).isError, true);
    assert.equal((await rpc(gateway, tokens.access_token, 'unlock_workspace', { code: issued.code }, 'chat-A')).isError, true);
    const listed = data(await rpc(gateway, tokens.access_token, 'list_workspaces', { access_key: unlocked.access_key }, 'chat-A'));
    assert.deepEqual(listed.workspaces.map(root => root.name), ['A']);
    assert.ok(!JSON.stringify(listed).includes(unlocked.access_key));
    const publicAdmin = await fetch(`${gateway.localBase()}/control/folder-code`, { method: 'POST', headers: { Authorization: `Bearer ${gateway.adminToken}`, 'X-Forwarded-For': '1.2.3.4', 'Content-Type': 'application/json' }, body: JSON.stringify({ workspaceID: f.roots[0].c2cID }) });
    assert.equal(publicAdmin.status, 404);
    for (const route of ['code-policy', 'folder-code', 'lock-folder']) {
      assert.equal(proxyPath(`/private-secret/bridge/control/${route}`, 'private-secret'), null);
    }
    // Newly shared protected roots remain hidden until their own code unlocks them.
    f.select(0, 1, 2); f.registry.setCodePolicy(f.roots[2].c2cID, true);
    const newCode = await (await control(gateway, '/control/folder-code', { workspaceID: f.roots[2].c2cID })).json();
    assert.equal((await read(gateway, tokens, f.roots[2].c2cID)).isError, true);
    const newKey = data(await rpc(gateway, tokens.access_token, 'unlock_workspace', { code: newCode.code }, 'chat-A'));
    assert.equal((await rpc(gateway, tokens.access_token, 'read_file', { workspace_id: f.roots[2].c2cID, path: 'hello.txt', access_key: newKey.access_key }, 'chat-A')).isError, undefined);
  } finally { await gateway.close(); f.clean(); }
});

test('temporary codes and keys expire, rate limit guesses and cannot revive after policy changes', () => {
  const f = fixture(); f.select(0); const id = f.roots[0].c2cID; f.registry.setCodePolicy(id, true);
  let now = Date.now(); const access = new FolderAccess(f.registry, { now: () => now });
  const extra = { authInfo: { token: 'valid-oauth', expiresAt: Math.floor(now / 1000) + 7200 }, _meta: { 'openai/session': 'chat-A' } };
  const scopes = ['workspace.read', f.registry.connectionScope()];
  try {
    const expired = access.issue(id); now += 5 * 60000;
    assert.throws(() => access.unlock(expired.code, scopes, extra));
    for (let i = 0; i < 9; i++) assert.throws(() => access.unlock('wrong', scopes, extra));
    const limited = access.issue(id);
    assert.throws(() => access.unlock(limited.code, scopes, extra), error => error.code === 'RATE_LIMITED');
    now += 60000;
    const unlocked = access.unlock(limited.code, scopes, extra);
    access.check(f.registry.active()[0], unlocked.access_key, extra);
    now += 30 * 60000;
    assert.throws(() => access.check(f.registry.active()[0], unlocked.access_key, extra));
    const next = access.unlock(access.issue(id).code, scopes, extra);
    const replacement = access.issue(id); assert.throws(() => access.check(f.registry.active()[0], next.access_key, extra));
    const key = access.unlock(replacement.code, scopes, extra).access_key;
    f.registry.setCodePolicy(id, false); access.check(f.registry.active()[0], undefined, {});
    f.registry.setCodePolicy(id, true); assert.throws(() => access.check(f.registry.active()[0], key, extra));
    const removed = access.issue(id); f.select(); f.select(0);
    assert.throws(() => access.unlock(removed.code, scopes, extra));
  } finally { f.clean(); }
});

test('locking a folder discards reads in flight and restarting keeps it locked', async () => {
  const f = fixture(); f.select(0); const id = f.roots[0].c2cID; f.registry.setCodePolicy(id, true);
  let gateway = await server(f);
  const original = backend.Workspace.prototype.readFile;
  let started, release;
  const begun = new Promise(resolve => { started = resolve; });
  const barrier = new Promise(resolve => { release = resolve; });
  try {
    const tokens = await authorize(gateway, await pair(gateway));
    const code = await (await control(gateway, '/control/folder-code', { workspaceID: id })).json();
    const unlocked = data(await rpc(gateway, tokens.access_token, 'unlock_workspace', { code: code.code }, 'chat-A'));
    backend.Workspace.prototype.readFile = async function (...args) { started(); await barrier; return original.apply(this, args); };
    const args = { workspace_id: id, path: 'hello.txt', access_key: unlocked.access_key };
    const pending = rpc(gateway, tokens.access_token, 'read_file', args, 'chat-A');
    await begun; assert.equal((await control(gateway, '/control/lock-folder', { workspaceID: id })).status, 200); release();
    const result = await pending; assert.equal(result.isError, true); assert.ok(!JSON.stringify(result).includes('A read test'));
    backend.Workspace.prototype.readFile = original;
    const freshCode = await (await control(gateway, '/control/folder-code', { workspaceID: id })).json();
    const fresh = data(await rpc(gateway, tokens.access_token, 'unlock_workspace', { code: freshCode.code }, 'chat-A'));
    const unused = await (await control(gateway, '/control/folder-code', { workspaceID: id })).json();
    await gateway.close(); gateway = await server(f);
    assert.equal((await rpc(gateway, tokens.access_token, 'read_file', { ...args, access_key: fresh.access_key }, 'chat-A')).isError, true);
    assert.equal((await rpc(gateway, tokens.access_token, 'unlock_workspace', { code: unused.code }, 'chat-A')).isError, true);
    assert.equal((await read(gateway, tokens, id)).isError, true);
    await control(gateway, '/control/code-policy', { workspaceID: id, required: false });
    assert.equal((await read(gateway, tokens, id)).isError, undefined);
  } finally { release(); backend.Workspace.prototype.readFile = original; await gateway.close(); f.clean(); }
});

test('new launcher refuses to enable code protection on an older running daemon', async () => {
  const f = fixture(); f.select(0);
  const fake = http.createServer((req, res) => {
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify(req.url === '/health' ? { service: 'boundas-gateway', workspaceId: f.registry.read().id } : { running: true, state: 'running' }));
  });
  await new Promise(resolve => fake.listen(0, '127.0.0.1', resolve));
  try {
    secureWrite(path.join(f.registry.directory, 'runtime.json'), { service: 'boundas-gateway', workspaceId: f.registry.read().id, pid: process.pid, port: fake.address().port, adminToken: `bg_admin_${'a'.repeat(64)}` });
    const input = JSON.stringify({ workspaceID: f.roots[0].c2cID, required: true });
    const execute = promisify(execFile);
    await assert.rejects(execute(process.execPath, ['Resources/Gateway/launcher.mjs', 'code-policy', backendRoot, input], { env: { ...process.env, BOUNDAS_GATEWAY_DIR: f.registry.directory, BOUNDAS_WORKSPACES_FILE: f.allowlistFile } }), error => {
      assert.equal(JSON.parse(error.stdout).ok, false); return true;
    });
    assert.equal(f.registry.active()[0].codeRequired, false);
  } finally { fake.closeAllConnections(); await new Promise(resolve => fake.close(resolve)); f.clean(); }
});

test('zero Folder Main Gate starts, pairs, reconnects and keeps authorization after last Folder removal', async () => {
  const f = fixture(); f.registry.ensure(); let gateway = await server(f);
  try {
    const originalID = f.registry.read().id;
    const tokens = await authorize(gateway, await pair(gateway));
    assert.deepEqual(data(await rpc(gateway, tokens.access_token, 'list_workspaces')).workspaces, []);
    f.select(0);
    assert.equal(data(await read(gateway, tokens, f.roots[0].c2cID)).content, 'A read test');
    secureWrite(f.allowlistFile, []); // Removing the last added Folder revokes access, never the Gate.
    assert.deepEqual(data(await rpc(gateway, tokens.access_token, 'list_workspaces')).workspaces, []);
    assert.equal((await read(gateway, tokens, f.roots[0].c2cID)).isError, true);
    assert.equal((await fetch(`${gateway.localBase()}/health`)).status, 200);
    assert.equal(gateway.provider.status().running, true);
    f.registry.configure([], backend.Workspace);
    await gateway.close(); gateway = await server(f);
    assert.equal(f.registry.read().id, originalID);
    assert.deepEqual(data(await rpc(gateway, tokens.access_token, 'list_workspaces')).workspaces, []);
    assert.equal(gateway.authStore.refresh(tokens.refresh_token, tokens.client_id).ok, true);
    assert.equal((await control(gateway, '/control/tunnel/start')).status, 200);
    const newTokens = await authorize(gateway, await pair(gateway));
    assert.deepEqual(data(await rpc(gateway, newTokens.access_token, 'list_workspaces')).workspaces, []);
  } finally { await gateway.close(); f.clean(); }
});


test('real Main and Side Gates enforce separate OAuth, decommission, re-add and Folder passcode policy', async () => {
  const f = fixture(); f.select(0, 1);
  f.roots[0].sideGateAdded = true; f.roots[1].sideGateAdded = true;
  secureWrite(f.allowlistFile, f.roots);
  const gateway = await server(f);
  const sideEnv = { ...process.env, BOUNDAS_WORKSPACES_FILE: f.allowlistFile, BOUNDAS_GATEWAY_DIR: f.registry.directory,
    C2C_STATE_DIR: path.join(f.directory, 'side-state'), BOUNDAS_STATE_DIR: path.join(f.directory, 'routes') };
  const helper = path.resolve('Resources/Gateway/side-lifecycle.mjs');
  const children = [];
  const execute = promisify(execFile);
  async function side(index, legacy = false) {
    const { spawn } = await import('node:child_process');
    const child = spawn(process.execPath, legacy
      ? [path.join(backendRoot, 'bin/c2c.js'), 'serve', '--workspace', f.roots[index].path, '--port', '0']
      : [helper, 'daemon', backendRoot, f.roots[index].id.toLowerCase(), `--instance-id=${randomBytes(32).toString('hex')}`],
      { env: sideEnv, stdio: ['ignore', 'ignore', 'ignore'] });
    children.push(child);
    const runtimeFile = path.join(sideEnv.C2C_STATE_DIR, 'runtime', `${f.roots[index].c2cID}.json`);
    const marker = path.join(sideEnv.C2C_STATE_DIR, 'side-gates', `${f.roots[index].c2cID}.json`);
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      if (fs.existsSync(runtimeFile) && (legacy || fs.existsSync(marker))) {
        const runtime = JSON.parse(fs.readFileSync(runtimeFile));
        const endpoint = { adminToken: runtime.adminToken, localBase: () => `http://127.0.0.1:${runtime.port}` };
        if ((await fetch(`${endpoint.localBase()}/health`)).ok) return endpoint;
      }
      if (child.exitCode !== null) throw new Error(`Side Gate daemon exited (${child.exitCode})`);
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    throw new Error('Side Gate test daemon not ready');
  }
  async function sidePair(endpoint) {
    const reply = await control(endpoint, '/admin/pairing');
    const value = await reply.json(); assert.equal(reply.status, 200);
    return { pairingCode: value.code, expiresAt: value.expiresAt };
  }
  async function statusCode(endpoint, token) {
    return (await fetch(`${endpoint.localBase()}/mcp`, { method: 'POST', headers: {
      Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }) })).status;
  }
  try {
    const mainTokens = await authorize(gateway, await pair(gateway));
    let a = await side(0); let b = await side(1, true);
    const aStatus = JSON.parse((await execute(process.execPath, [helper, 'status', backendRoot, f.roots[0].id.toLowerCase()], { env: sideEnv })).stdout);
    assert.equal(aStatus.ok, true); assert.equal(aStatus.roots[0].id, f.roots[0].c2cID);
    const aTokens = await authorize(a, await sidePair(a)); const bTokens = await authorize(b, await sidePair(b));
    const oldSideAuth = fs.readFileSync(path.join(sideEnv.C2C_STATE_DIR, 'auth', `${f.roots[1].c2cID}.json`));
    const migration = await execute(process.execPath, [helper, 'status', backendRoot, f.roots[1].id.toLowerCase()], { env: sideEnv, timeout: 30000 });
    assert.equal(JSON.parse(migration.stdout).running, false);
    assert.deepEqual(fs.readFileSync(path.join(sideEnv.C2C_STATE_DIR, 'auth', `${f.roots[1].c2cID}.json`)), oldSideAuth);
    b = await side(1);
    assert.equal(await statusCode(a, aTokens.access_token), 200);
    assert.equal(await statusCode(b, bTokens.access_token), 200);
    assert.equal(await statusCode(a, mainTokens.access_token), 401);
    assert.equal(await statusCode(b, aTokens.access_token), 401);
    assert.equal(await statusCode(a, bTokens.access_token), 401);
    assert.equal(await statusCode(gateway, aTokens.access_token), 401);
    assert.equal(data(await read(gateway, mainTokens, f.roots[0].c2cID)).content, 'A read test');
    const configBefore = fs.readFileSync(path.join(f.registry.directory, 'config.json'));
    const authBefore = fs.readFileSync(path.join(f.registry.directory, 'auth.json'));
    f.roots[0].sideGateRemovalState = 'removing'; secureWrite(f.allowlistFile, f.roots);
    assert.equal(await statusCode(a, aTokens.access_token), 401);
    const removal = await execute(process.execPath, [helper, 'decommission', backendRoot, f.roots[0].id.toLowerCase()], { env: sideEnv, timeout: 30000 });
    assert.equal(JSON.parse(removal.stdout).ok, true);
    assert.equal(fs.existsSync(path.join(sideEnv.C2C_STATE_DIR, 'auth', `${f.roots[0].c2cID}.json`)), false);
    f.roots[0].sideGateAdded = false; delete f.roots[0].sideGateRemovalState; secureWrite(f.allowlistFile, f.roots);
    assert.deepEqual(fs.readFileSync(path.join(f.registry.directory, 'config.json')), configBefore);
    assert.deepEqual(fs.readFileSync(path.join(f.registry.directory, 'auth.json')), authBefore);
    assert.equal(data(await read(gateway, mainTokens, f.roots[0].c2cID)).content, 'A read test');
    assert.equal(await statusCode(b, bTokens.access_token), 200);
    assert.equal(f.registry.active().length, 2);
    f.roots[0].sideGateAdded = true; secureWrite(f.allowlistFile, f.roots);
    a = await side(0);
    assert.equal(await statusCode(a, aTokens.access_token), 401);
    const fresh = await authorize(a, await sidePair(a));
    assert.equal(await statusCode(a, fresh.access_token), 200);
    f.registry.setCodePolicy(f.roots[0].c2cID, true);
    assert.equal(await statusCode(a, fresh.access_token), 200); // Policy guards operations, not OAuth transport.
    assert.equal((await read(a, fresh, f.roots[0].c2cID)).isError, true);
    const generated = JSON.parse((await execute(process.execPath, [helper, 'folder-code', backendRoot, f.roots[0].id.toLowerCase(), JSON.stringify({ workspaceID: f.roots[0].c2cID })], { env: sideEnv })).stdout);
    const unlocked = data(await rpc(a, fresh.access_token, 'unlock_workspace', { code: generated.code, session_id: 'side-review' }));
    assert.equal((await rpc(a, fresh.access_token, 'read_file', { path: 'hello.txt', access_key: unlocked.access_key, session_id: 'side-review' })).isError, undefined);
    await execute(process.execPath, [helper, 'lock-folder', backendRoot, f.roots[0].id.toLowerCase(), JSON.stringify({ workspaceID: f.roots[0].c2cID })], { env: sideEnv });
    assert.equal((await rpc(a, fresh.access_token, 'read_file', { path: 'hello.txt', access_key: unlocked.access_key, session_id: 'side-review' })).isError, true);
    assert.equal((await read(gateway, mainTokens, f.roots[0].c2cID)).isError, true);
    assert.equal(await statusCode(b, bTokens.access_token), 200);
    f.registry.revokeSource(f.roots[0].id);
    assert.equal((await read(a, fresh, f.roots[0].c2cID)).isError, true); // Turning Main sharing off cannot bypass Folder policy.
    f.registry.configure([f.roots[0].id, f.roots[1].id], backend.Workspace);
    f.registry.setCodePolicy(f.roots[0].c2cID, false);
    assert.equal(await statusCode(a, fresh.access_token), 200);
  } finally {
    for (const child of children) if (child.exitCode === null) child.kill('SIGTERM');
    await Promise.all(children.map(child => child.exitCode !== null ? Promise.resolve() : new Promise(resolve => child.once('exit', resolve))));
    await gateway.close(); f.clean();
  }
});
