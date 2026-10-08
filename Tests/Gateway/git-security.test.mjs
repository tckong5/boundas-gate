import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { Registry, secureWrite } from '../../Resources/Gateway/registry.mjs';
import { spawnSync } from 'node:child_process';
import { loadBackend, startGateway } from '../../Resources/Gateway/server.mjs';

const wrapper = path.resolve('Resources/Gateway/git');
test('Git wrapper refuses option injection, missing separator and write commands', () => {
  for (const args of [['diff', '--output=written', '--', '.'], ['diff', '-c', 'alias.x=x', '--', '.'],
    ['--config=x', 'diff'], ['diff', '--config=x', '--', '.'], ['diff', '--no-index', '/tmp/a', '/tmp/b'],
    ['diff', 'README'], ['status', '--porcelain', '--output=bad'], ['rev-parse', '--git-path', 'config'], ['commit']]) {
    assert.equal(spawnSync(wrapper, args).status, 126, args.join(' '));
  }
});
test('actual option-looking filenames remain literal paths and cannot write files', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'boundas-git-security-'));
  const old = process.env.PATH;
  const git = args => {
    const reply = spawnSync('/usr/bin/git', args, { cwd: directory, encoding: 'utf8' });
    assert.equal(reply.status, 0, reply.stderr); return reply;
  };
  try {
    git(['init', '-q']);
    const names = ['--output=should-not-exist', '--config=other', '-c'];
    for (const name of names) fs.writeFileSync(path.join(directory, name), 'before\n');
    git(['add', '--', ...names]); git(['-c', 'user.name=Test', '-c', 'user.email=test@example.test', 'commit', '-qm', 'fixture']);
    for (const name of names) fs.writeFileSync(path.join(directory, name), 'after\n');
    const before = fs.readFileSync(path.join(directory, '.git/config'), 'utf8');
    process.env.PATH = `${path.dirname(wrapper)}:/usr/bin:/bin`;
    const backend = await loadBackend(process.env.BOUNDAS_C2C_ROOT);
    const workspace = new backend.Workspace(directory);
    for (const name of names) {
      const direct = spawnSync(wrapper, ['diff', '--', name], { cwd: directory, encoding: 'utf8' });
      assert.equal(direct.status, 0); assert.match(direct.stdout, /\+after/);
      const diff = backend.gitDiff(workspace, {}, workspace.resolve(name).rel);
      assert.equal(diff.isRepo, true); assert.match(diff.diff, /\+after/);
    }
    // Traverse the same MCP handler, readGit wrapper and external backend as the App.
    const allowlistFile = path.join(directory, 'folders.json');
    const sourceID = randomUUID();
    secureWrite(allowlistFile, [{ id: sourceID, name: 'Fixture', path: workspace.root, c2cID: workspace.id }]);
    const registry = new Registry({ directory: path.join(directory, 'gate-state'), allowlistFile });
    registry.configure([sourceID], backend.Workspace);
    const gateway = await startGateway({ backendRoot: process.env.BOUNDAS_C2C_ROOT, registry, persistRuntime: false,
      tunnelProvider: { status: () => ({ running: false }), stop: async () => {} } });
    try {
      const client = gateway.authStore.registerClient({ clientName: 'Git fixture', redirectUris: ['https://example.test'] });
      const token = gateway.authStore.issueTokens({ clientId: client.clientId, scopes: ['git.read', `bg.instance.${registry.read().id}`] });
      for (const name of names) {
        const response = await fetch(`${gateway.localBase()}/mcp`, { method: 'POST', headers: {
          Authorization: `Bearer ${token.accessToken}`, 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' },
          body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'git_diff', arguments: { workspace_id: workspace.id, path: name } } }) });
        const reply = await response.json();
        assert.equal(reply.result.isError, undefined, JSON.stringify(reply));
        assert.match(reply.result.structuredContent.diff, /\+after/);
      }
    } finally { await gateway.close(); }
    assert.equal(fs.existsSync(path.join(directory, 'should-not-exist')), false);
    assert.equal(fs.readFileSync(path.join(directory, '.git/config'), 'utf8'), before);
  } finally { process.env.PATH = old; fs.rmSync(directory, { recursive: true, force: true }); }
});
