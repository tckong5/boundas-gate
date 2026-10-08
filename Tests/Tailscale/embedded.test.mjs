import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { Registry, secureWrite } from '../../Resources/Gateway/registry.mjs';
import { transportMode, EmbeddedProvider, embeddedLocation, embeddedRequest, embeddedSetup, tunnelAccount, sharedAgent } from '../../Resources/Tailscale/embedded.mjs';
function fixture() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'boundas-mode-'));
  const registry = new Registry({ directory });
  secureWrite(path.join(directory, 'config.json'), { id: 'abcdef123456', roots: [] });
  return { registry, clean: () => fs.rmSync(directory, { recursive: true, force: true }) };
}
test('shared helper upgrade verifies Main lifetime before sending any admin credential', async () => {
  const f = fixture(); const location = embeddedLocation(f.registry); let ipc, reusedPort;
  const requests = [];
  try {
    f.registry.updateConnection({ transport: 'embedded' });
    reusedPort = http.createServer((req, res) => {
      requests.push({ path: req.url, authorization: req.headers.authorization });
      res.end(JSON.stringify({ service: 'boundas-gateway', workspaceId: 'aaaaaa123456', instanceID: 'a'.repeat(64), status: 'ok' }));
    });
    await new Promise(resolve => reusedPort.listen(0, '127.0.0.1', resolve));
    secureWrite(path.join(f.registry.directory, 'runtime.json'), { workspaceId: f.registry.read().id, instanceID: 'b'.repeat(64),
      adminToken: `bg_admin_${'c'.repeat(64)}`, port: reusedPort.address().port, pid: process.pid });
    fs.mkdirSync(location.controlDirectory, { mode: 0o700 });
    ipc = http.createServer((_req, res) => res.end(JSON.stringify({ ok: true, service: 'boundas-tsnet', gatewayID: f.registry.read().id,
      state: 'ready', running: true, publicUrl: `https://old.example.ts.net/c2c/${f.registry.read().id}` })));
    await new Promise(resolve => ipc.listen(location.socket, resolve)); fs.chmodSync(location.socket, 0o600);
    await assert.rejects(sharedAgent(f.registry, { binary: '/helper' }), /未有傳送管理憑證/);
    assert.deepEqual(requests, [{ path: '/health', authorization: undefined }]);
  } finally {
    for (const server of [ipc, reusedPort]) if (server) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
    fs.rmSync(location.controlDirectory, { recursive: true, force: true }); f.clean();
  }
});
test('external account actions retain the Mac profile and require explicit shared-device logout confirmation', async () => {
  const f = fixture(); const calls = [];
  const url = 'https://old.example.ts.net/c2c/abcdef123456/mcp';
  f.registry.updateConnection({ stableMCPURL: url });
  const run = async (_, args) => { calls.push(args); return JSON.stringify({ ok: true, state: 'login', loginURL: 'https://login.tailscale.com/a/test' }); };
  try {
    await assert.rejects(tunnelAccount(f.registry, 'logout', { binary: '/helper', run }), /先確認/);
    assert.deepEqual(calls, []);
    assert.equal((await tunnelAccount(f.registry, 'login', { binary: '/helper', run })).state, 'login');
    await tunnelAccount(f.registry, 'logout', { binary: '/helper', run, confirmedExternal: true });
    assert.deepEqual(calls, [['--external-auth', 'login'], ['--external-auth', 'logout']]);
    assert.equal(f.registry.connection().stableMCPURL, url);
    assert.equal(transportMode(f.registry, '/helper'), 'external');
  } finally { f.clean(); }
});
test('embedded logout never starts an interactive login and retains the Gate configuration', async () => {
  const f = fixture(); const location = embeddedLocation(f.registry); let server;
  const calls = [];
  try {
    secureWrite(path.join(f.registry.directory, 'config.json'), { ...f.registry.read(), transport: 'embedded' });
    const original = f.registry.read();
    fs.mkdirSync(location.controlDirectory, { mode: 0o700 });
    server = http.createServer((req, res) => {
      calls.push(req.url);
      res.end(JSON.stringify({ ok: true, service: 'boundas-tsnet', gatewayID: original.id, state: 'login', userspace: true, accountManagementVersion: 1 }));
    });
    await new Promise(resolve => server.listen(location.socket, resolve)); fs.chmodSync(location.socket, 0o600);
    await tunnelAccount(f.registry, 'logout', { binary: '/helper' });
    assert.deepEqual(calls, ['/status', '/logout']);
    assert.deepEqual(f.registry.read(), original);
  } finally {
    if (server) await new Promise(resolve => server.close(resolve));
    fs.rmSync(location.controlDirectory, { recursive: true, force: true }); f.clean();
  }
});
test('an old helper without a verifiable process identity cannot be replaced', async () => {
  const f = fixture(); const location = embeddedLocation(f.registry); let server;
  const calls = [];
  try {
    secureWrite(path.join(f.registry.directory, 'config.json'), { ...f.registry.read(), transport: 'embedded' });
    fs.mkdirSync(location.controlDirectory, { mode: 0o700 });
    server = http.createServer((req, res) => {
      calls.push(req.url);
      res.end(JSON.stringify({ ok: true, service: 'boundas-tsnet', gatewayID: f.registry.read().id, state: 'ready' }));
    });
    await new Promise(resolve => server.listen(location.socket, resolve)); fs.chmodSync(location.socket, 0o600);
    await assert.rejects(tunnelAccount(f.registry, 'logout', { binary: '/helper' }), /未能確認舊 Tunnel/);
    assert.deepEqual(calls, ['/status']);
  } finally {
    if (server) await new Promise(resolve => server.close(resolve));
    fs.rmSync(location.controlDirectory, { recursive: true, force: true }); f.clean();
  }
});
test('new packaged installations use embedded mode; existing fixed URLs retain their device identity', () => {
  const f = fixture();
  try {
    assert.equal(transportMode(f.registry, '/bundled/helper'), 'embedded');
    assert.equal(transportMode(f.registry, null), 'external');
    const url = 'https://old.example.ts.net/c2c/abcdef123456/mcp';
    f.registry.updateConnection({ stableMCPURL: url });
    assert.equal(transportMode(f.registry, '/bundled/helper'), 'external');
    assert.equal(f.registry.connection().stableMCPURL, url);
    secureWrite(path.join(f.registry.directory, 'config.json'), { ...f.registry.read(), transport: 'invalid' });
    assert.throws(() => transportMode(f.registry, '/bundled/helper'), /連線模式無效/);
  } finally { f.clean(); }
});
test('interactive login is requested after a delayed startup transition and reused on retry', async () => {
  const f = fixture(); const location = embeddedLocation(f.registry);
  let server, reads = 0, loginRequests = 0;
  try {
    fs.mkdirSync(location.controlDirectory, { mode: 0o700 });
    server = http.createServer((req, res) => {
      if (req.url === '/login') {
        assert.equal(req.method, 'POST'); loginRequests++;
      }
      res.end(JSON.stringify({ ok: true, service: 'boundas-tsnet', gatewayID: f.registry.read().id,
        state: ++reads < 3 ? 'starting' : 'login', userspace: true,
        ...(loginRequests ? { loginURL: 'https://login.tailscale.com/a/test' } : {}) }));
    });
    await new Promise(resolve => server.listen(location.socket, resolve)); fs.chmodSync(location.socket, 0o600);
    const first = await embeddedSetup(f.registry, { start: true, binary: '/bundled/helper' });
    assert.equal(first.loginURL, 'https://login.tailscale.com/a/test');
    const again = await embeddedSetup(f.registry, { start: true, binary: '/bundled/helper' });
    assert.equal(again.loginURL, first.loginURL); assert.equal(loginRequests, 1);
  } finally {
    if (server) await new Promise(resolve => server.close(resolve));
    fs.rmSync(location.controlDirectory, { recursive: true, force: true }); f.clean();
  }
});
test('explicit Sign In requests the login URL again while background checks remain non-interactive', async () => {
  const f = fixture(); const location = embeddedLocation(f.registry); let server;
  let loginRequests = 0;
  try {
    secureWrite(path.join(f.registry.directory, 'config.json'), { ...f.registry.read(), transport: 'embedded' });
    fs.mkdirSync(location.controlDirectory, { mode: 0o700 });
    server = http.createServer((req, res) => {
      if (req.url === '/login') loginRequests++;
      res.end(JSON.stringify({ ok: true, service: 'boundas-tsnet', gatewayID: f.registry.read().id,
        state: 'login', userspace: true, loginManagementVersion: 2,
        loginURL: `https://login.tailscale.com/a/${loginRequests ? 'current' : 'old'}` }));
    });
    await new Promise(resolve => server.listen(location.socket, resolve)); fs.chmodSync(location.socket, 0o600);
    await embeddedSetup(f.registry, { start: true, requestLogin: false, binary: '/helper' });
    assert.equal(loginRequests, 0);
    const first = await tunnelAccount(f.registry, 'login', { binary: '/helper' });
    assert.equal(loginRequests, 1);
    assert.equal(first.loginURL, 'https://login.tailscale.com/a/current');
    await tunnelAccount(f.registry, 'login', { binary: '/helper' });
    assert.equal(loginRequests, 2);
  } finally {
    if (server) await new Promise(resolve => server.close(resolve));
    fs.rmSync(location.controlDirectory, { recursive: true, force: true }); f.clean();
  }
});
test('Sign In reports a missing login URL as a failure instead of silent success', async () => {
  const f = fixture(); const location = embeddedLocation(f.registry); let server;
  try {
    secureWrite(path.join(f.registry.directory, 'config.json'), { ...f.registry.read(), transport: 'embedded' });
    fs.mkdirSync(location.controlDirectory, { mode: 0o700 });
    server = http.createServer((req, res) => {
      res.statusCode = req.url === '/login' ? 409 : 200;
      res.end(JSON.stringify({ ok: req.url !== '/login', service: 'boundas-tsnet', gatewayID: f.registry.read().id,
        state: 'login', userspace: true, loginManagementVersion: 2, message: '未能取得 Tailscale 登入網址。' }));
    });
    await new Promise(resolve => server.listen(location.socket, resolve)); fs.chmodSync(location.socket, 0o600);
    await assert.rejects(tunnelAccount(f.registry, 'login', { binary: '/helper' }), /未能取得 Tailscale 登入網址/);
  } finally {
    if (server) await new Promise(resolve => server.close(resolve));
    fs.rmSync(location.controlDirectory, { recursive: true, force: true }); f.clean();
  }
});
test('embedded start refuses a hostname change before any public route mutation', async () => {
  const f = fixture(); const calls = [];
  const request = async (_, route) => { calls.push(route); return { state: 'ready', hostname: 'new.example.ts.net' }; };
  const provider = new EmbeddedProvider(f.registry, { request, expectedURL: 'https://old.example.ts.net/c2c/abcdef123456' });
  try { await assert.rejects(provider.start(1234), /固定地址/); assert.deepEqual(calls, ['/status']); }
  finally { f.clean(); }
});
test('embedded lifecycle uses only a local port and preserves its URL across restart', async () => {
  const f = fixture(); let running = false;
  const url = 'https://boundas.example.ts.net/c2c/abcdef123456';
  const request = async (_, route, body) => {
    if (route === '/start') { assert.equal(body.port, 1234); assert.equal(body.expectedURL, url); running = true; return { publicUrl: url }; }
    if (route === '/stop') { running = false; return { ok: true }; }
    return { state: 'ready', hostname: 'boundas.example.ts.net', publicUrl: running ? url : undefined, running };
  };
  const provider = new EmbeddedProvider(f.registry, { request });
  try {
    assert.equal(await provider.start(1234), url); await provider.verify(); assert.equal(provider.status().running, true);
    await provider.stop(); assert.equal(provider.status().running, false);
    assert.equal(await provider.start(1234), url);
  } finally { await provider.stop(); f.clean(); }
});
test('private IPC rejects insecure control directories and a different gateway identity', async () => {
  const f = fixture(); const location = embeddedLocation(f.registry); let server;
  try {
    fs.mkdirSync(location.controlDirectory, { mode: 0o700 });
    fs.chmodSync(location.controlDirectory, 0o755);
    await assert.rejects(embeddedRequest(f.registry, '/status'), /控制目錄無效/);
    fs.chmodSync(location.controlDirectory, 0o700);
    server = http.createServer((_, res) => res.end(JSON.stringify({ ok: true, service: 'boundas-tsnet', gatewayID: '000000000000' })));
    await new Promise(resolve => server.listen(location.socket, resolve)); fs.chmodSync(location.socket, 0o600);
    await assert.rejects(embeddedRequest(f.registry, '/status'), /身份唔一致/);
  } finally {
    if (server) await new Promise(resolve => server.close(resolve));
    fs.rmSync(location.controlDirectory, { recursive: true, force: true }); f.clean();
  }
});
