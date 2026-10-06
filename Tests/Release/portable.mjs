import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
const directory = fs.mkdtempSync('/private/tmp/boundas-portable-');
const app = path.join(directory, 'Boundas Gate.app');
let setup, registry, embeddedLocation, embeddedRequest;
try {
  execFileSync('/usr/bin/ditto', ['--norsrc', '--noextattr', path.resolve('dist/Boundas Gate.app'), app]);
  execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
  const resources = path.join(app, 'Contents/Resources');
  const node = path.join(resources, 'Runtime/bin/node');
  const backend = path.join(resources, 'Runtime/C2C');
  const fixture = path.join(directory, 'Shared'); fs.mkdirSync(fixture); fs.writeFileSync(path.join(fixture, 'proof.txt'), 'Portable runtime test.\n');
  const fakeHome = path.join(directory, 'EmptyHome'); fs.mkdirSync(fakeHome);
  const env = { PATH: '/usr/bin:/bin', HOME: fakeHome, C2C_STATE_DIR: path.join(directory, 'c2c-state'), BOUNDAS_GATEWAY_DIR: path.join(directory, 'gateway'), BOUNDAS_WORKSPACES_FILE: path.join(directory, 'workspaces.json') };
  const invoke = (entry, args) => JSON.parse(execFileSync(node, [entry, ...args], { env, encoding: 'utf8' }));
  const cli = path.join(backend, 'bin/c2c.js');
  const status = invoke(cli, ['status', '--workspace', fixture, '--json']);
  const { loadBackend } = await import(pathToFileURL(path.join(resources, 'Gateway/server.mjs')));
  const { Workspace } = await loadBackend(backend); const workspace = new Workspace(fixture);
  fs.writeFileSync(env.BOUNDAS_WORKSPACES_FILE, JSON.stringify([{ id: 'portable-test', name: 'Shared', path: workspace.root, c2cID: workspace.id }]));
  const launcher = path.join(resources, 'Gateway/launcher.mjs');
  const configured = invoke(launcher, ['configure', backend, JSON.stringify({ selectedIDs: ['portable-test'] })]);
  if (configured.transport !== 'embedded') throw new Error('Fresh install did not select embedded mode');
  const { Registry } = await import(pathToFileURL(path.join(resources, 'Gateway/registry.mjs')));
  ({ embeddedLocation, embeddedRequest } = await import(pathToFileURL(path.join(resources, 'Tailscale/embedded.mjs'))));
  registry = new Registry({ directory: env.BOUNDAS_GATEWAY_DIR, allowlistFile: env.BOUNDAS_WORKSPACES_FILE });
  const login = invoke(launcher, ['login', backend]); setup = await embeddedRequest(registry, '/status');
  if (!setup.userspace) throw new Error('Embedded node uses system networking');
  if (setup.state === 'login' && !setup.loginURL) throw new Error('Interactive login URL was not provided');
  const originalPID = setup.pid;
  invoke(launcher, ['login', backend]);
  const retried = await embeddedRequest(registry, '/status');
  if (retried.pid !== originalPID || retried.gatewayID !== setup.gatewayID) throw new Error('Retry replaced the embedded identity');
  if (retried.state === 'login' && !retried.loginURL) throw new Error('Retry lost the login link');
  console.log(JSON.stringify({ signatureValid: true, noSystemNodeOrC2C: true, isolatedCLIResponded: status.running === false, freshMode: configured.transport, embeddedCoreStarted: setup.service === 'boundas-tsnet', userspace: setup.userspace, loginState: setup.state, loginLinkReady: Boolean(setup.loginURL), retryPreservesIdentity: true, sharedFolders: login.roots.length }));
} finally {
  if (registry) {
    try { const s = await embeddedRequest(registry, '/status'); process.kill(s.pid, 'SIGTERM'); } catch {}
    const control = embeddedLocation(registry).controlDirectory;
    for (let attempt = 0; attempt < 30 && fs.existsSync(path.join(control, 'control.sock')); attempt++) await new Promise(resolve => setTimeout(resolve, 100));
    if (!fs.existsSync(path.join(control, 'control.sock'))) fs.rmSync(control, { recursive: true, force: true });
  }
  fs.rmSync(directory, { recursive: true, force: true });
}
