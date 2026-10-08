import fs from 'node:fs';
import path from 'node:path';
import { secureWrite } from './registry.mjs';

// Explicit endpoint migration. A durable journal permits rollback/retry after
// interruption. Gate identity, auth.json and Folder policy never change.
export async function migrateSideToShared({ registry, hostname, stop, open }) {
  if (!/^[a-z0-9-]+(?:\.[a-z0-9-]+)+\.ts\.net$/.test(hostname ?? '')) throw new Error('Shared Tunnel identity is invalid.');
  const file = path.join(registry.directory, 'config.json');
  const journal = path.join(registry.directory, 'endpoint-migration.json');
  let saved;
  try { saved = JSON.parse(fs.readFileSync(journal, 'utf8')); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  const current = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (saved && (saved.gateID !== current.id || saved.original?.id !== current.id || saved.original?.epoch !== current.epoch)) throw new Error('Migration identity does not match.');
  const original = saved?.original ?? current;
  const endpoint = `https://${hostname}/side/${current.id}/mcp`;
  if (!saved && current.transport === 'shared' && current.stableMCPURL === endpoint) return;
  if (!saved) secureWrite(journal, { gateID: current.id, original, phase: 'preparing' });
  try {
    await stop();
    // The old endpoint remains history only. It is never accepted as a Main
    // token alias or automatically redirected across an OAuth resource boundary.
    const next = { ...original, transport: 'shared', stableMCPURL: endpoint,
      lastKnownMCPURL: original.stableMCPURL ?? original.configuredMCPURL ?? original.lastKnownMCPURL,
      previousTransport: original.transport, configuredMCPURL: null };
    secureWrite(journal, { gateID: current.id, original, phase: 'switching' });
    secureWrite(file, next);
    if (original.desiredRunning !== false) await open(next);
    fs.rmSync(journal);
  } catch (error) {
    try {
      await stop();
      secureWrite(file, original);
      if (original.desiredRunning !== false) await open(original);
      fs.rmSync(journal);
    } catch {
      // Do not hide a failed migration or overwrite the original retry data.
      secureWrite(journal, { gateID: current.id, original, phase: 'rollback-required' });
      throw new Error('Side Gate migration needs Retry. Its original configuration and authorization are preserved.');
    }
    throw new Error(`Side Gate migration failed; the original endpoint was restored. ${error.message}`);
  }
}
