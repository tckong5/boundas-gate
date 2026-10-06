import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { pathToFileURL } from 'node:url';
import { TailscaleProvider, preflight, proxyPath, assertOwnedConfig, mounts, setupCheck } from '../../Resources/Tailscale/provider.mjs';

const hostname = 'mac.example.ts.net';
const key = `${hostname}:443`;
const idA = 'abcdef123456', idB = '123456abcdef';
function fixture() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'boundas-tailscale-'));
  const config = { TCP: {}, Web: {}, AllowFunnel: {} };
  const calls = [];
  let failAt = null;
  const run = async (_binary, args) => {
    calls.push(args);
    if (args[0] === 'status') return JSON.stringify({ BackendState: 'Running', Self: { DNSName: `${hostname}.` } });
    if (args[1] === 'status') return JSON.stringify(config);
    const mount = args.find(item => item.startsWith('--set-path=')).slice(11);
    config.Web[key] ??= { Handlers: {} };
    if (args.at(-1) === 'off') delete config.Web[key].Handlers[mount];
    else {
      if (mount === failAt) throw new Error('simulated approval failure');
      config.TCP['443'] = { HTTPS: true };
      config.AllowFunnel[key] = true;
      config.Web[key].Handlers[mount] = { Proxy: args.at(-1) };
    }
    return '';
  };
  return { directory, config, calls, run, options: { directory, binary: '/fake/tailscale', run }, failOn: mount => { failAt = mount; }, clean: () => fs.rmSync(directory, { recursive: true, force: true }) };
}
async function listen(server) { await new Promise(resolve => server.listen(0, '127.0.0.1', resolve)); return server.address().port; }
async function close(server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }

test('preflight handles missing installation, login and MagicDNS', async () => {
  assert.equal((await preflight(null)).state, 'missing');
  assert.equal((await preflight('/fake', async () => '{"BackendState":"NeedsLogin"}')).state, 'login');
  assert.equal((await preflight('/fake', async () => '{"BackendState":"Running","Self":{"DNSName":"bad/path.ts.net"}}')).state, 'blocked');
  assert.equal((await preflight('/fake', async () => JSON.stringify({ BackendState: 'Running', Self: { DNSName: `${hostname}.` } }))).hostname, hostname);
});
test('public proxy routes block admin, path traversal and missing private route secret', () => {
  const secret = 'private';
  for (const raw of ['/mcp', '/private/bridge/admin/info', '/private/bridge/%61dmin/info', '/private/bridge/mcp/../admin/info', '/private/bridge//mcp', '/private/issuer/admin/info']) {
    assert.equal(proxyPath(raw, secret), null);
  }
  assert.equal(proxyPath('/private/bridge/mcp', secret), '/mcp');
  assert.equal(proxyPath('/private/bridge/oauth/authorize?state=value', secret), '/oauth/authorize?state=value');
  assert.equal(proxyPath('/private/issuer/', secret), '/.well-known/oauth-authorization-server');
});
test('unknown Serve routes and foreground listeners are refused', () => {
  assert.throws(() => assertOwnedConfig({ Web: { [key]: { Handlers: { '/': { Proxy: 'http://127.0.0.1:8080' } } } } }, key, {}));
  assert.throws(() => assertOwnedConfig({ Foreground: { x: { TCP: { '443': { HTTPS: true } } } } }, key, {}));
  assert.throws(() => assertOwnedConfig({ TCP: { '443': { TCPForward: '127.0.0.1:8080' } } }, key, {}));
});
test('setup checks refuse existing private Serve routes before disconnecting any bridge', async () => {
  const f = fixture();
  try {
    assert.equal((await setupCheck('/fake', f.run, f.directory)).state, 'ready');
    f.config.Web[key] = { Handlers: { '/private': { Proxy: 'http://127.0.0.1:8080' } } };
    assert.equal((await setupCheck('/fake', f.run, f.directory)).state, 'blocked');
    assert.ok(f.calls.every(args => args[1] === 'status' || args[0] === 'status'));
  } finally { f.clean(); }
});
test('multiple workspaces keep stable distinct URLs; stopping one preserves the other', async () => {
  const f = fixture(); const a = new TailscaleProvider(idA, f.options), b = new TailscaleProvider(idB, f.options);
  try {
    const first = await a.start(12345);
    const other = await b.start(12346);
    assert.notEqual(first, other);
    await a.stop();
    for (const route of mounts(idB)) assert.ok(f.config.Web[key].Handlers[route.path]);
    const second = await a.start(34567);
    assert.equal(first, second);
    await a.stop(); await b.stop();
    assert.deepEqual(f.config.Web[key].Handlers, {});
    assert.ok(f.calls.every(args => !args.includes('reset')));
  } finally { await a.stop(); await b.stop(); f.clean(); }
});
test('a failed start rolls back partial routes and closes the proxy', async () => {
  const f = fixture(); const provider = new TailscaleProvider(idA, f.options);
  f.failOn(mounts(idA)[1].path);
  try {
    await assert.rejects(provider.start(12345), /simulated/);
    assert.equal(provider.proxy, null);
    assert.equal(provider.status().running, false);
    assert.deepEqual(f.config.Web[key].Handlers, {});
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(f.directory, 'routes.json'))), {});
  } finally { await provider.stop(); f.clean(); }
});
test('a hostname change is refused before touching existing Funnel routes', async () => {
  const f = fixture();
  const provider = new TailscaleProvider(idA, { ...f.options, expectedURL: `https://${hostname}/c2c/${idA}` });
  try {
    const url = await provider.start(12345);
    const before = JSON.stringify(f.config);
    const proxy = provider.proxy;
    f.calls.length = 0;
    provider.run = async (binary, args) => args[0] === 'status'
      ? '{"BackendState":"Running","Self":{"DNSName":"other.example.ts.net."}}' : f.run(binary, args);
    await assert.rejects(provider.start(12345), /地址同原有 ChatGPT 設定唔一致/);
    assert.equal(provider.proxy, proxy);
    assert.equal(provider.getPublicUrl(), url);
    assert.equal(JSON.stringify(f.config), before);
    assert.equal(f.calls.length, 0);
  } finally { provider.run = f.run; await provider.stop(); f.clean(); }
});
test('a route changed outside the app is not removed on stop', async () => {
  const f = fixture(); const provider = new TailscaleProvider(idA, f.options);
  try {
    await provider.start(12345);
    const route = mounts(idA)[0].path;
    f.config.Web[key].Handlers[route] = { Proxy: 'http://127.0.0.1:9090' };
    await provider.verify(); assert.equal(provider.status().running, false);
    await provider.stop(); assert.equal(f.config.Web[key].Handlers[route].Proxy, 'http://127.0.0.1:9090');
  } finally { await provider.stop(); f.clean(); }
});
test('disconnected Tailscale is reported as not running despite persistent routes', async () => {
  const f = fixture(); const provider = new TailscaleProvider(idA, f.options);
  try {
    await provider.start(12345);
    provider.run = async (binary, args) => args[0] === 'status' ? '{"BackendState":"Stopped"}' : f.run(binary, args);
    await provider.verify(); assert.equal(provider.status().running, false);
  } finally { await provider.stop(); f.clean(); }
});
test('guard proxy preserves OAuth headers, body and redirect but rejects admin', async () => {
  const f = fixture(); const provider = new TailscaleProvider(idA, f.options);
  const server = http.createServer((request, response) => {
    if (request.url === '/mcp') { response.writeHead(401, { 'WWW-Authenticate': 'Bearer resource_metadata="https://example.test/metadata"' }); response.end(); }
    else if (request.url.startsWith('/oauth/authorize')) { response.writeHead(302, { Location: 'https://example.test/callback?code=test' }); response.end(); }
    else { response.writeHead(200); request.pipe(response); }
  });
  try {
    const port = await listen(server); await provider.start(port);
    const target = f.config.Web[key].Handlers[mounts(idA)[0].path].Proxy;
    const unauthorized = await fetch(`${target}mcp`, { method: 'POST', body: '{}' });
    assert.equal(unauthorized.status, 401); assert.match(unauthorized.headers.get('www-authenticate'), /resource_metadata/);
    const posted = await fetch(`${target}oauth/token`, { method: 'POST', body: 'grant_type=refresh_token' });
    assert.equal(await posted.text(), 'grant_type=refresh_token');
    const redirect = await fetch(`${target}oauth/authorize?state=x`, { redirect: 'manual' });
    assert.equal(redirect.status, 302); assert.match(redirect.headers.get('location'), /callback/);
    assert.equal((await fetch(`${target}admin/info`)).status, 404);
  } finally { await provider.stop(); await close(server); f.clean(); }
});

// Optional local integration with the user's installed C2C build. No public Funnel is opened.
const backendRoot = process.env.BOUNDAS_C2C_ROOT;
test('real C2C metadata, paired OAuth and tokens survive a bridge restart with the same URL', { skip: !backendRoot }, async () => {
  const [{ startBridge }, { Workspace }, { base64UrlSha256 }] = await Promise.all([
    import(pathToFileURL(path.join(backendRoot, 'dist/bridge/server.js'))),
    import(pathToFileURL(path.join(backendRoot, 'dist/workspace/manager.js'))),
    import(pathToFileURL(path.join(backendRoot, 'dist/auth/store.js'))),
  ]);
  const f = fixture();
  const root = path.join(f.directory, 'workspace'); fs.mkdirSync(root); fs.writeFileSync(path.join(root, 'hello.txt'), 'test');
  const id = new Workspace(root).id;
  const authStoreFile = path.join(f.directory, 'auth.json');
  let provider = new TailscaleProvider(id, f.options);
  let bridge = await startBridge({ workspaceRoot: root, port: 0, persistRuntime: false, authStoreFile, tunnelProvider: provider });
  const admin = async route => fetch(`${bridge.localBaseUrl()}${route}`, { method: 'POST', headers: { Authorization: `Bearer ${bridge.adminToken}` } });
  try {
    const started = await (await admin('/admin/tunnel/start')).json();
    assert.equal(started.url, `https://${hostname}/c2c/${id}`);
    let target = f.config.Web[key].Handlers[mounts(id)[0].path].Proxy;
    const issuerTarget = f.config.Web[key].Handlers[mounts(id)[1].path].Proxy;
    const issuer = await (await fetch(issuerTarget)).json();
    assert.equal(issuer.issuer, started.url);
    const resource = await (await fetch(`${target}.well-known/oauth-protected-resource/mcp`)).json();
    assert.equal(resource.resource, `${started.url}/mcp`);
    const register = await fetch(`${target}oauth/register`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ redirect_uris: ['https://example.test/callback'], client_name: 'Local regression' }) });
    const client = await register.json(); assert.equal(register.status, 201);
    const verifier = 'v'.repeat(64);
    const query = new URLSearchParams({ client_id: client.client_id, redirect_uri: 'https://example.test/callback', response_type: 'code', code_challenge: base64UrlSha256(verifier), code_challenge_method: 'S256', scope: 'workspace.read offline_access', resource: `${started.url}/mcp` });
    const html = await (await fetch(`${target}oauth/authorize?${query}`)).text();
    const requestID = html.match(/name="request_id" value="([^"]+)"/)[1];
    const pairing = bridge.pairing.create();
    const authorize = await fetch(`${target}oauth/authorize`, { method: 'POST', redirect: 'manual', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ request_id: requestID, pairing_code: pairing.code }) });
    assert.equal(authorize.status, 302);
    const code = new URL(authorize.headers.get('location')).searchParams.get('code');
    const tokenResponse = await fetch(`${target}oauth/token`, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ grant_type: 'authorization_code', client_id: client.client_id, redirect_uri: 'https://example.test/callback', code, code_verifier: verifier, resource: `${started.url}/mcp` }) });
    const tokens = await tokenResponse.json(); assert.equal(tokenResponse.status, 200);
    assert.equal(bridge.authStore.verifyAccessToken(tokens.access_token).ok, true);
    await bridge.close();
    provider = new TailscaleProvider(id, f.options);
    bridge = await startBridge({ workspaceRoot: root, port: 0, persistRuntime: false, authStoreFile, tunnelProvider: provider });
    assert.equal((await (await admin('/admin/tunnel/start')).json()).url, started.url);
    assert.equal(bridge.authStore.verifyAccessToken(tokens.access_token).ok, true);
    target = f.config.Web[key].Handlers[mounts(id)[0].path].Proxy;
    const refresh = await fetch(`${target}oauth/token`, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ grant_type: 'refresh_token', client_id: client.client_id, refresh_token: tokens.refresh_token }) });
    assert.equal(refresh.status, 200);
    assert.equal((await fetch(`${target}admin/info`)).status, 404);
  } finally { await bridge.close(); f.clean(); }
});
