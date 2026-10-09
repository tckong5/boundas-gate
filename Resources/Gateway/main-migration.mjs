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
export async function validateMainEndpoint(url, runtime, fetcher = fetch) {
  const base = url.replace(/\/mcp$/, '');
  const request = route => fetcher(base + route, { redirect: 'error', signal: AbortSignal.timeout(10000) });
  const health = await request('/health'); const identity = await health.json();
  if (!health.ok || identity.service !== 'boundas-gateway' || identity.workspaceId !== runtime.workspaceId || identity.instanceID !== runtime.instanceID) throw new Error('Candidate public Gate identity mismatch.');
  const discovery = await request('/.well-known/oauth-authorization-server'); const oauth = await discovery.json();
  if (!discovery.ok || oauth.issuer !== base || oauth.authorization_endpoint !== `${base}/oauth/authorize` || oauth.token_endpoint !== `${base}/oauth/token`) throw new Error('Candidate OAuth discovery mismatch.');
  const resource = await request('/.well-known/oauth-protected-resource/mcp'); const metadata = await resource.json();
  if (!resource.ok || metadata.resource !== url || !metadata.authorization_servers?.includes(base)) throw new Error('Candidate OAuth resource mismatch.');
  const mcp = await request('/mcp');
  if (mcp.status !== 401 || !mcp.headers.get('www-authenticate')?.includes(base)) throw new Error('Candidate MCP authentication boundary mismatch.');
}
export async function migrateMainToShared({ registry, setup, open, cleanup, finalize, validate = validateMainEndpoint }) {
  const journalFile = path.join(registry.directory, 'endpoint-migration.json');
  let journal = readMainMigration(registry);
  const config = registry.read();
  const finish = async () => {
    journal.phase = 'finalizing'; secureWrite(journalFile, journal);
    const normal = await finalize(journal);
    if (normal.migrationCandidate !== false) throw new Error('Main runtime has not normalized.');
    await validate(journal.candidateURL, normal);
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
  const save = phase => { journal.phase = phase; delete journal.failure; secureWrite(journalFile, journal); };
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
    journal.failure = error.message; secureWrite(journalFile, journal);
    throw error;
  }
}
