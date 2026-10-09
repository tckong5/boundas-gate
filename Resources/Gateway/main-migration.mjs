import fs from 'node:fs';
import path from 'node:path';
import { secureWrite } from './registry.mjs';

const phases = ['pending', 'awaiting-login', 'preparing-shared-ingress', 'checking-endpoint', 'committing', 'finalizing'];
export function readMainMigration(registry) {
  let journal;
  try { journal = JSON.parse(fs.readFileSync(path.join(registry.directory, 'endpoint-migration.json'), 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  if (journal.gateID !== registry.read()?.id || !phases.includes(journal.phase) || journal.original?.transport !== 'external') throw new Error('Main migration journal identity is invalid.');
  if (journal.candidateURL && (!/^https:\/\/[a-z0-9-]+(?:\.[a-z0-9-]+)+\.ts\.net\/mcp$/.test(journal.candidateURL) || journal.candidateURL !== `https://${journal.hostname}/mcp`)) throw new Error('Main migration endpoint is invalid.');
  return journal;
}
export function candidateRegistry(registry) {
  return { directory: registry.directory, read: () => ({ ...registry.read(), transport: 'embedded', sharedIngress: true }),
    connection: () => ({ ...registry.connection(), stableMCPURL: null }) };
}
export function verifyMigrationRoute(status, url, runtime) {
  const base = url.replace(/\/mcp$/, '');
  if (status.state !== 'ready' || !status.routes?.some(route => route.gateID === runtime.workspaceId
      && route.instanceID === runtime.instanceID && route.publicUrl === base)) {
    throw new Error('Local shared route readiness/ownership mismatch.');
  }
}
function validationError(step, kind, code, status, exhausted = false) {
  const detail = { step, kind, ...(code ? { code } : {}), ...(status ? { status } : {}) };
  const descriptions = { health: 'public Gate identity', discovery: 'OAuth discovery', resource: 'OAuth resource', mcp: 'MCP authentication boundary' };
  const message = exhausted ? `Public validation ${step} exhausted readiness retry (${code ?? status ?? 'network'}).`
    : `${descriptions[step]} mismatch (${step}; ${code ?? status ?? kind}).`;
  return Object.assign(new Error(message), { validationDetail: detail });
}
export async function validateMainEndpoint(url, runtime, fetcher = fetch, {
  budgetMs = 55000, now = Date.now, sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
} = {}) {
  const base = url.replace(/\/mcp$/, '');
  const deadline = now() + budgetMs;
  const request = async (step, route) => {
    let attempt = 0;
    for (;;) {
      let response, code, status;
      try {
        response = await fetcher(base + route, { redirect: 'error', signal: AbortSignal.timeout(Math.max(1, Math.min(10000, deadline - now()))) });
      } catch (error) {
        const raw = error.cause?.code ?? error.code ?? error.name;
        code = typeof raw === 'string' && /^[A-Za-z0-9_]{1,64}$/.test(raw) ? raw : 'NETWORK_ERROR';
      }
      if (response) {
        status = response.status;
        if (![502, 503, 504].includes(status)) return response;
        await response.body?.cancel();
      }
      const remaining = deadline - now();
      if (remaining <= 0) throw validationError(step, 'transient', code, status, true);
      await sleep(Math.min(remaining, 1000 * 2 ** Math.min(attempt++, 2)));
    }
  };
  const json = async (step, response) => {
    if (!response.ok) throw validationError(step, 'semantic', undefined, response.status);
    try { return await response.json(); }
    catch { throw validationError(step, 'semantic', 'INVALID_JSON', response.status); }
  };
  const health = await request('health', '/health'); const identity = await json('health', health);
  if (identity.service !== 'boundas-gateway' || identity.workspaceId !== runtime.workspaceId || identity.instanceID !== runtime.instanceID) throw validationError('health', 'semantic', undefined, health.status);
  const discovery = await request('discovery', '/.well-known/oauth-authorization-server'); const oauth = await json('discovery', discovery);
  if (oauth.issuer !== base || oauth.authorization_endpoint !== `${base}/oauth/authorize` || oauth.token_endpoint !== `${base}/oauth/token`) throw validationError('discovery', 'semantic', undefined, discovery.status);
  const resource = await request('resource', '/.well-known/oauth-protected-resource/mcp'); const metadata = await json('resource', resource);
  if (metadata.resource !== url || !metadata.authorization_servers?.includes(base)) throw validationError('resource', 'semantic', undefined, resource.status);
  const mcp = await request('mcp', '/mcp');
  if (mcp.status !== 401 || !mcp.headers.get('www-authenticate')?.includes(base)) throw validationError('mcp', 'semantic', undefined, mcp.status);
}
export async function migrateMainToShared({ registry, setup, open, cleanup, finalize, validate = validateMainEndpoint }) {
  const journalFile = path.join(registry.directory, 'endpoint-migration.json');
  let journal = readMainMigration(registry);
  const config = registry.read();
  const finish = async () => {
    journal.phase = 'finalizing'; delete journal.failure; delete journal.failureDetail; secureWrite(journalFile, journal);
    const normal = await finalize(journal);
    if (normal.migrationCandidate !== false) throw new Error('Main runtime has not normalized.');
    try { await validate(journal.candidateURL, normal); }
    catch (error) {
      journal.failure = error.message;
      if (error.validationDetail) journal.failureDetail = error.validationDetail;
      secureWrite(journalFile, journal); throw error;
    }
    fs.rmSync(journalFile);
    return { complete: true };
  };
  if (journal?.candidateURL && config.transport === 'embedded' && config.sharedIngress === true && config.stableMCPURL === journal.candidateURL) {
    return finish();
  }
  if (!journal) {
    if (config.transport !== 'external') throw new Error('Main Gate does not need external migration.');
    const keys = ['transport', 'stableMCPURL', 'configuredMCPURL', 'lastKnownMCPURL', 'desiredRunning', 'reconnectEnabled'];
    journal = { gateID: config.id, original: Object.fromEntries(keys.filter(k => config[k] !== undefined).map(k => [k, config[k]])), phase: 'pending' };
    secureWrite(journalFile, journal);
  }
  const save = phase => { journal.phase = phase; delete journal.failure; delete journal.failureDetail; secureWrite(journalFile, journal); };
  let candidate;
  try {
    save('awaiting-login');
    const account = await setup(candidateRegistry(registry));
    if (account.state !== 'ready') return { complete: false, transportSetup: account };
    journal.hostname = account.hostname; journal.candidateURL = `https://${account.hostname}/mcp`;
    save('preparing-shared-ingress');
    candidate = await open(journal);
    save('checking-endpoint');
    await validate(journal.candidateURL, candidate);
    save('committing');
    const current = registry.read();
    if (current.id !== journal.gateID || current.transport !== journal.original.transport || current.stableMCPURL !== journal.original.stableMCPURL || current.configuredMCPURL !== journal.original.configuredMCPURL) throw new Error('Main configuration changed during migration.');
    secureWrite(path.join(registry.directory, 'config.json'), { ...current, transport: 'embedded', sharedIngress: true,
      stableMCPURL: journal.candidateURL, configuredMCPURL: null,
      lastKnownMCPURL: journal.original.stableMCPURL ?? journal.original.configuredMCPURL ?? journal.original.lastKnownMCPURL,
      previousTransport: journal.original.transport });
    return await finish();
  } catch (error) {
    const committed = registry.read().transport === 'embedded' && registry.read().stableMCPURL === journal.candidateURL;
    if (!committed && candidate) {
      try { await cleanup(candidate); } catch (failure) { journal.cleanupFailure = failure.message; }
    }
    journal.failure = error.message; if (error.validationDetail) journal.failureDetail = error.validationDetail; secureWrite(journalFile, journal);
    throw error;
  }
}
