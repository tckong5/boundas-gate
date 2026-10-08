import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { boundedAuthStore, boundedPairingManager, oauthSecurity } from '../../Resources/Gateway/oauth-security.mjs';
import { Registry } from '../../Resources/Gateway/registry.mjs';
import { loadBackend, startGateway } from '../../Resources/Gateway/server.mjs';

const backendRoot = process.env.BOUNDAS_C2C_ROOT;
const backend = await loadBackend(backendRoot);
test('registration cap, abandoned cleanup and live authorization retention', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'boundas-registration-'));
  let now = Date.now();
  const Store = boundedAuthStore(backend.AuthStore, { now: () => now, maximum: 2 });
  const file = path.join(directory, 'auth.json'); const store = new Store('abcdef123456', { file });
  try {
    const a = store.registerClient({ clientName: 'A', redirectUris: ['https://example.test/callback'] });
    const tokens = store.issueTokens({ clientId: a.clientId, scopes: ['workspace.read', 'offline_access'] });
    const b = store.registerClient({ clientName: 'Abandoned', redirectUris: ['https://example.test/callback'] });
    const before = fs.readFileSync(file, 'utf8');
    assert.throws(() => store.registerClient({ redirectUris: ['https://example.test'] }), /Too many/);
    assert.equal(fs.readFileSync(file, 'utf8'), before);
    now += 11 * 60000; store.cleanupRegistrations();
    assert.ok(store.getClient(a.clientId)); assert.equal(store.getClient(b.clientId), undefined);
    assert.equal(store.verifyAccessToken(tokens.accessToken).ok, true);
    assert.equal(JSON.parse(fs.readFileSync(file)).clients.length, 1);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
test('existing pairing TTL, one-time consumption, failed-attempt cap and replay guarantees', () => {
  const Pairing = boundedPairingManager(backend.PairingManager); const pairing = new Pairing('abcdef123456');
  const start = Date.now(); let session = pairing.create(); assert.ok(session.expiresAt - start <= 5 * 60000 + 10);
  assert.equal(pairing.verify(session.code, 'a').ok, true);
  assert.equal(pairing.verify(session.code, 'a').ok, false);
  session = pairing.create(); [...pairing.sessions.values()][0].expiresAt = start - 1;
  assert.equal(pairing.verify(session.code, 'b').reason, 'expired');
  pairing.create();
  for (let i = 0; i < 5; i++) assert.equal(pairing.verify('BAD-CODE', 'c').ok, false);
  assert.equal(pairing.hasActiveSession(), false);
  for (let i = 0; i < 600; i++) pairing.verify('BAD-CODE', `spoof-${i}`);
  assert.ok(pairing.ipHits.size <= 512);
});
test('public registration abuse is bounded even with forged proxy IPs; registration grants no access', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'boundas-public-oauth-'));
  const registry = new Registry({ directory, allowlistFile: path.join(directory, 'folders.json') }); registry.ensure();
  const gateway = await startGateway({ backendRoot, registry, persistRuntime: false,
    tunnelProvider: { status: () => ({ running: false }), stop: async () => {} } });
  const register = (body, ip) => fetch(`${gateway.localBase()}/oauth/register`, { method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Forwarded-For': ip }, body: JSON.stringify(body) });
  try {
    for (let i = 0; i < 5; i++) assert.equal((await register({ redirect_uris: [] }, `invalid-${i}`)).status, 400);
    assert.equal(gateway.authStore.clients.size, 0); assert.equal(fs.existsSync(path.join(directory, 'auth.json')), false);
    const valid = await register({ client_name: 'Claude', redirect_uris: ['https://example.test/callback'], grant_types: ['authorization_code'], response_types: ['code'] }, 'valid');
    assert.equal(valid.status, 201); const client = await valid.json();
    assert.equal(gateway.authStore.tokenCount(), 0);
    assert.equal((await fetch(`${gateway.localBase()}/mcp`, { method: 'POST', headers: { Authorization: `Bearer ${client.client_id}` } })).status, 401);
    let denied = 0;
    for (let i = 0; i < 60; i++) {
      const reply = await register({ redirect_uris: ['https://example.test/callback'] }, `spoof-${i}`);
      if (reply.status === 429) denied++;
    }
    assert.ok(denied > 0); assert.ok(gateway.authStore.clients.size <= 15);
    const query = new URLSearchParams({ client_id: client.client_id, redirect_uri: 'https://example.test/callback', response_type: 'code',
      code_challenge: backend.base64UrlSha256('x'.repeat(64)), code_challenge_method: 'S256', scope: 'workspace.read' });
    const html = await (await fetch(`${gateway.localBase()}/oauth/authorize?${query}`)).text();
    const requestID = html.match(/name="request_id" value="([^"]+)"/)[1];
    const session = gateway.pairing.create();
    const approve = code => fetch(`${gateway.localBase()}/oauth/authorize`, { method: 'POST', redirect: 'manual', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ request_id: requestID, pairing_code: code }) });
    assert.equal((await approve('BAD-CODE')).status, 401); assert.equal(gateway.authStore.tokenCount(), 0);
    const approval = await approve(session.code); assert.equal(approval.status, 302);
    const code = new URL(approval.headers.get('location')).searchParams.get('code');
    assert.equal((await approve(session.code)).status, 400);
    assert.equal(gateway.authStore.tokenCount(), 0); // Pairing yields only a PKCE-bound code; no bearer token yet.
    const exchange = (code, verifier) => fetch(`${gateway.localBase()}/oauth/token`, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'authorization_code', client_id: client.client_id, code, code_verifier: verifier, redirect_uri: 'https://example.test/callback' }) });
    assert.equal((await exchange(code, 'wrong'.repeat(16))).status, 400);
    assert.equal((await exchange(code, 'x'.repeat(64))).status, 400); // Wrong verifier consumed the one-time code.
    const newHTML = await (await fetch(`${gateway.localBase()}/oauth/authorize?${query}`)).text();
    const newID = newHTML.match(/name="request_id" value="([^"]+)"/)[1];
    const fresh = gateway.pairing.create();
    const approved = await fetch(`${gateway.localBase()}/oauth/authorize`, { method: 'POST', redirect: 'manual', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ request_id: newID, pairing_code: fresh.code }) });
    assert.equal(approved.status, 302);
    const newCode = new URL(approved.headers.get('location')).searchParams.get('code');
    assert.equal((await exchange(newCode, 'x'.repeat(64))).status, 200);
    assert.equal((await exchange(newCode, 'x'.repeat(64))).status, 400);
    let limited = false;
    for (let i = 0; i < 70; i++) if ((await approve('BAD-CODE')).status === 429) limited = true;
    assert.equal(limited, true);
  } finally { await gateway.close(); fs.rmSync(directory, { recursive: true, force: true }); }
});

test('pending authorization reservations are bounded, including concurrent responses, and expire', () => {
  let now = 1; const middleware = oauthSecurity({ now: () => now, store: { cleanupRegistrations() {} } });
  let admitted = 0;
  const request = () => {
    const req = { path: '/oauth/authorize', method: 'GET', query: {}, socket: { remoteAddress: 'local' } };
    const res = { statusCode: 200, set() { return this; }, status(code) { this.statusCode = code; return this; }, json() {}, once() {} };
    middleware(req, res, () => admitted++); return res.statusCode;
  };
  for (let i = 0; i < 256; i++) { if (i % 50 === 0) now += 60001; assert.equal(request(), 200); }
  assert.equal(request(), 429); assert.equal(admitted, 256);
  now += 10 * 60000 + 1; assert.equal(request(), 200);
});
