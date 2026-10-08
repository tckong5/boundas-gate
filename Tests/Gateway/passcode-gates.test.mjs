import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { Registry, secureWrite } from '../../Resources/Gateway/registry.mjs';
import { SideRegistry } from '../../Resources/Gateway/side-registry.mjs';
import { startGateway, loadBackend } from '../../Resources/Gateway/server.mjs';

const backendRoot = process.env.BOUNDAS_C2C_ROOT;
const backend = await loadBackend(backendRoot);
async function rpc(gate, token, tool, args = {}) {
  const response = await fetch(`${gate.localBase()}/mcp`, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: tool, arguments: args } }) });
  return { status: response.status, body: await response.json() };
}
async function admin(gate, action, id) {
  const response = await fetch(`${gate.localBase()}/control/${action}`, { method: 'POST', headers: { Authorization: `Bearer ${gate.adminToken}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ workspaceID: id }) });
  assert.equal(response.status, 200); return response.json();
}
function token(gate, scopes = ['workspace.read', 'git.read', 'execution.read', 'offline_access', `bg.instance.${gate.id}`]) {
  const client = gate.authStore.registerClient({ clientName: 'Test AI', redirectUris: ['https://example.test/callback'] });
  return gate.authStore.issueTokens({ clientId: client.clientId, scopes }).accessToken;
}
const data = response => response.body.result?.structuredContent;
test('Folder-level policy, per-Gate/client/session grants, expiry, revoke and legacy Side authorization', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'boundas-passcode-gates-'));
  const records = ['A', 'B'].map(name => {
    const folder = path.join(directory, name); fs.mkdirSync(folder); fs.writeFileSync(path.join(folder, 'hello.txt'), name);
    const workspace = new backend.Workspace(folder);
    return { id: randomUUID(), name, path: workspace.root, c2cID: workspace.id, sideGateAdded: true };
  });
  const main = new Registry({ directory: path.join(directory, 'main'), allowlistFile: path.join(directory, 'folders.json') });
  secureWrite(main.allowlistFile, records); main.configure(records.map(root => root.id), backend.Workspace);
  const gates = [];
  const provider = { stop: async () => {}, status: () => ({ running: false }) };
  try {
    const mainGate = await startGateway({ backendRoot, registry: main, persistRuntime: false, tunnelProvider: provider }); gates.push(mainGate);
    const side = new SideRegistry(main, records[0].id, path.join(directory, 'side-a')); side.ensure();
    const authFile = path.join(side.directory, 'auth.json');
    const old = new backend.AuthStore(side.read().id, { file: authFile });
    const oldClient = old.registerClient({ clientName: 'Previously paired AI', redirectUris: ['https://example.test'] });
    const legacyToken = old.issueTokens({ clientId: oldClient.clientId, scopes: ['workspace.read', 'offline_access'] }).accessToken;
    const sideGate = await startGateway({ backendRoot, registry: side, authFile, sideRoot: records[0].path, persistRuntime: false, tunnelProvider: provider }); gates.push(sideGate);
    const sideB = new SideRegistry(main, records[1].id, path.join(directory, 'side-b')); sideB.ensure();
    const sideGateB = await startGateway({ backendRoot, registry: sideB, sideRoot: records[1].path, persistRuntime: false, tunnelProvider: provider }); gates.push(sideGateB);
    const mainToken = token(mainGate), sideToken = token(sideGate), otherSideClient = token(sideGate);
    const id = records[0].c2cID;
    const readArgs = { workspace_id: id, path: 'hello.txt', session_id: 'conversation-a' };
    main.setCodePolicy(id, true);
    for (const [gate, bearer] of [[mainGate, mainToken], [sideGate, sideToken]]) {
      assert.equal((await rpc(gate, bearer, 'read_file', readArgs)).body.result.isError, true);
      assert.deepEqual(data(await rpc(gate, bearer, 'list_workspaces')).workspaces.filter(folder => folder.workspace_id === id), []);
    }
    const mainCode = await admin(mainGate, 'folder-code', id);
    const mainGrant = data(await rpc(mainGate, mainToken, 'unlock_workspace', { code: mainCode.code, session_id: 'conversation-a' }));
    assert.equal(data(await rpc(mainGate, mainToken, 'read_file', { ...readArgs, access_key: mainGrant.access_key })).content, 'A');
    assert.equal((await rpc(sideGate, sideToken, 'read_file', { ...readArgs, access_key: mainGrant.access_key })).body.result.isError, true);
    assert.equal((await rpc(sideGate, sideToken, 'unlock_workspace', { code: mainCode.code, session_id: 'conversation-a' })).body.result.isError, true);
    const sideCode = await admin(sideGate, 'folder-code', id);
    const sideGrant = data(await rpc(sideGate, sideToken, 'unlock_workspace', { code: sideCode.code, session_id: 'conversation-a' }));
    assert.equal(data(await rpc(sideGate, sideToken, 'read_file', { ...readArgs, access_key: sideGrant.access_key })).content, 'A');
    assert.equal((await rpc(sideGate, otherSideClient, 'read_file', { ...readArgs, access_key: sideGrant.access_key })).body.result.isError, true);
    assert.equal((await rpc(sideGate, sideToken, 'read_file', { ...readArgs, session_id: 'other-chat', access_key: sideGrant.access_key })).body.result.isError, true);
    assert.equal((await rpc(sideGate, mainToken, 'read_file', readArgs)).status, 401);
    assert.equal((await rpc(sideGateB, sideToken, 'list_workspaces')).status, 401);
    // Even a accidentally copied grant object carries a different Gate identity.
    for (const [key, value] of mainGate.access.keys) sideGate.access.keys.set(key, value);
    assert.equal((await rpc(sideGate, sideToken, 'read_file', { ...readArgs, access_key: mainGrant.access_key })).body.result.isError, true);
    sideGate.access.now = () => Date.now() + 31 * 60000;
    assert.equal((await rpc(sideGate, sideToken, 'read_file', { ...readArgs, access_key: sideGrant.access_key })).body.result.isError, true);
    sideGate.access.now = Date.now;
    const fresh = await admin(sideGate, 'folder-code', id);
    const renewed = data(await rpc(sideGate, sideToken, 'unlock_workspace', { code: fresh.code, session_id: 'conversation-a' }));
    await admin(sideGate, 'lock-folder', id);
    assert.equal((await rpc(sideGate, sideToken, 'read_file', { ...readArgs, access_key: renewed.access_key })).body.result.isError, true);
    // Side revocation does not revoke the independent Main grant.
    assert.equal(data(await rpc(mainGate, mainToken, 'read_file', { ...readArgs, access_key: mainGrant.access_key })).content, 'A');
    await admin(mainGate, 'lock-folder', id);
    assert.equal((await rpc(mainGate, mainToken, 'read_file', { ...readArgs, access_key: mainGrant.access_key })).body.result.isError, true);
    main.setCodePolicy(id, false);
    assert.equal(data(await rpc(mainGate, mainToken, 'read_file', readArgs)).content, 'A');
    assert.equal(data(await rpc(sideGate, legacyToken, 'read_file', { path: 'hello.txt' })).content, 'A');
    assert.equal((await rpc(sideGate, sideToken, 'test_status')).body.result.isError, undefined);
    const config = main.read(); main.configure([records[1].id], backend.Workspace);
    assert.equal(data(await rpc(sideGate, sideToken, 'read_file', { path: 'hello.txt' })).content, 'A');
    assert.equal(main.read().id, config.id); // Main ACL is independent of Side membership.
  } finally { for (const gate of gates) await gate.close(); fs.rmSync(directory, { recursive: true, force: true }); }
});
