import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { Registry, secureWrite } from '../../Resources/Gateway/registry.mjs';
import { transportMode, EmbeddedProvider, embeddedLocation, embeddedRequest, embeddedSetup } from '../../Resources/Tailscale/embedded.mjs';
function fixture() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'boundas-mode-'));
  const registry = new Registry({ directory });
  secureWrite(path.join(directory, 'config.json'), { id: 'abcdef123456', roots: [] });
  return { registry, clean: () => fs.rmSync(directory, { recursive: true, force: true }) };
}
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
