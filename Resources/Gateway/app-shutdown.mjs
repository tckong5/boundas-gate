import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { Registry } from './registry.mjs';
import { observeRuntime, processOwnership } from './runtime-instance.mjs';
import { embeddedRequest, embeddedLocation, embeddedBinary } from '../Tailscale/embedded.mjs';
import { command } from '../Tailscale/provider.mjs';

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

export async function stopOwnedHelper(registry, { request = embeddedRequest, execute = command,
  binary = embeddedBinary(), signal = (pid, value) => process.kill(pid, value), alive = pid => {
    try { process.kill(pid, 0); return true; } catch (error) { if (error.code === 'ESRCH') return false; throw error; }
  }, now = Date.now, wait = sleep, deadline = Date.now() + 8000 } = {}) {
  if (now() >= deadline) throw new Error('Tunnel helper shutdown deadline exceeded.');
  let status;
  try { status = await request(registry, '/status', undefined, 2000); }
  catch (error) { if (['ENOENT', 'ECONNREFUSED'].includes(error.code)) return false; throw error; }
  const location = embeddedLocation(registry);
  const pid = status.pid;
  if (status.gatewayID !== registry.read().id || !Number.isInteger(pid) || pid < 1 || !binary) throw new Error('Tunnel helper ownership is unverified.');
  const [owner, executable, args] = await Promise.all([
    execute('/bin/ps', ['-p', String(pid), '-o', 'uid='], 2000),
    execute('/bin/ps', ['-p', String(pid), '-o', 'comm='], 2000),
    execute('/bin/ps', ['-p', String(pid), '-o', 'args='], 2000)
  ]);
  if (Number(owner.trim()) !== os.userInfo().uid || fs.realpathSync(executable.trim()) !== fs.realpathSync(binary)
      || !args.trim().endsWith(`--state-dir ${location.identity} --gateway-id ${registry.read().id}`)) throw new Error('Tunnel helper executable/profile ownership mismatch.');
  const current = await request(registry, '/status', undefined, 2000);
  if (current.pid !== pid || current.gatewayID !== status.gatewayID) throw new Error('Tunnel helper changed before shutdown.');
  if (now() >= deadline) throw new Error('Tunnel helper verification exceeded shutdown deadline.');
  signal(pid, 'SIGTERM');
  while (now() < deadline) {
    try {
      const next = await request(registry, '/status', undefined, 1000);
      if (next.pid !== pid) throw new Error('Tunnel helper replaced during shutdown.');
    } catch (error) {
      if (['ENOENT', 'ECONNREFUSED'].includes(error.code) && !alive(pid)) return true;
      if (!['ENOENT', 'ECONNREFUSED', 'ECONNRESET', 'EPIPE'].includes(error.code)) throw error;
    }
    await wait(100);
  }
  throw new Error('Tunnel helper shutdown timed out; no unverified process was killed.');
}

export async function shutdownProfile({ registry, stateDir, budgetMs = 30000, now = Date.now, wait = sleep,
  observe = observeRuntime, inspect = processOwnership, helper = stopOwnedHelper, fetcher = fetch, progress = () => {} } = {}) {
  if (!registry || !stateDir) throw new Error('Explicit profile paths are required for app shutdown.');
  const deadline = now() + budgetMs;
  const failures = [], stopped = [];
  const remaining = () => {
    const value = deadline - now();
    if (value <= 0) throw new Error('App shutdown deadline exceeded.');
    return Math.max(1, Math.min(2500, value));
  };
  const control = async (runtime, route, method = 'POST') => {
    const response = await fetcher(`http://127.0.0.1:${runtime.port}/control/${route}`, {
      method, headers: { Authorization: `Bearer ${runtime.adminToken}` }, signal: AbortSignal.timeout(remaining()) });
    if (!response.ok) throw new Error(`Runtime ${route} failed (HTTP ${response.status}).`);
    return response.json();
  };
  const main = registry.read();
  if (!main) return { ok: true, stopped, failures };
  const records = registry.addedFolders();
  const known = new Set(records.map(record => record.c2cID));
  try {
    for (const file of fs.readdirSync(path.join(stateDir, 'runtime'))) {
      if (/^[a-f0-9]{12}\.json$/.test(file) && !known.has(file.slice(0, 12))) {
        failures.push({ component: `Side ${file.slice(0, 12)}`, message: 'No matching Folder ownership record; runtime was left untouched.' });
      }
    }
  } catch (error) { if (error.code !== 'ENOENT') failures.push({ component: 'Side runtime inventory', message: error.message }); }
  const helpers = [];
  for (const record of records) {
    if (!/^[a-f0-9]{12}$/.test(record.c2cID)) throw new Error('Invalid Folder identity during shutdown.');
    const directory = path.join(stateDir, 'side-gates', record.c2cID);
    const file = path.join(directory, 'config.json');
    try {
      const config = JSON.parse(fs.readFileSync(file));
      if (config.id !== record.c2cID) throw new Error('Side helper Gate identity mismatch.');
      helpers.push({ directory, read: () => config });
    } catch (error) { if (error.code !== 'ENOENT') failures.push({ component: `Side ${record.c2cID}`, message: error.message }); }
  }
  const stopRuntime = async (gateID, file, service, entrypoint, root) => {
    const component = `${service} ${gateID}`;
    progress(component);
    try {
      remaining();
      const observed = await observe(file, { gateID, service, entrypoint, getInfo: runtime => control(runtime, 'info', 'GET') });
      if (observed.state === 'stopped') return;
      if (observed.state !== 'healthy') throw new Error(observed.reason ?? 'Runtime ownership is unverified.');
      const runtime = observed.runtime;
      if (root && runtime.workspaceRoot !== root) throw new Error('Side Folder ownership mismatch.');
      // Authenticate first, then require the process/nonce to match this exact
      // bundled daemon entrypoint. Never signal a bare PID or process name.
      if (!runtime.instanceID || await inspect(runtime, entrypoint) !== true) throw new Error('Daemon process ownership is unverified.');
      try { await control(runtime, 'tunnel/stop'); }
      catch (error) { failures.push({ component: component + ' route', message: error.message }); }
      await control(runtime, 'shutdown');
      while (now() < deadline) {
        const next = await observe(file, { gateID, service, entrypoint, getInfo: value => control(value, 'info', 'GET') });
        if (next.state === 'stopped') { stopped.push(component); return; }
        if (next.runtime?.instanceID !== runtime.instanceID) throw new Error('Runtime replaced during shutdown.');
        await wait(100);
      }
      throw new Error('Runtime shutdown acknowledgement timed out.');
    } catch (error) { failures.push({ component, message: error.message }); }
  };
  // Read existing records/config only: stop never decommissions or writes intent.
  for (const record of records) {
    await stopRuntime(record.c2cID, path.join(stateDir, 'runtime', `${record.c2cID}.json`), 'c2c-bridge',
      fileURLToPath(new URL('./side-lifecycle.mjs', import.meta.url)), record.path);
  }
  await stopRuntime(main.id, path.join(registry.directory, 'runtime.json'), 'boundas-gateway',
    fileURLToPath(new URL('./launcher.mjs', import.meta.url)));
  // Independent legacy Side agents, then the one shared Main agent. External
  // system Tailscale/VPN services are never queried, stopped or signed out.
  for (const identity of [...helpers, registry]) {
    const component = `Tunnel helper ${identity.read().id}`;
    progress(component);
    try { remaining(); if (await helper(identity, { deadline, now, wait })) stopped.push(component); }
    catch (error) { failures.push({ component, message: error.message }); }
  }
  return { ok: failures.length === 0, stopped, failures };
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  try {
    if (!process.env.BOUNDAS_GATEWAY_DIR || !process.env.BOUNDAS_WORKSPACES_FILE || !process.env.C2C_STATE_DIR) throw new Error('Explicit app profile environment is required.');
    const result = await shutdownProfile({ registry: new Registry(), stateDir: process.env.C2C_STATE_DIR, progress: component => console.error(`Quit: ${component}`) });
    console.log(JSON.stringify(result));
    if (!result.ok) process.exitCode = 1;
  } catch (error) { console.log(JSON.stringify({ ok: false, failures: [{ component: 'App shutdown', message: error.message }] })); process.exitCode = 1; }
}
