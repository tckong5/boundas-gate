import fs from 'node:fs';
import path from 'node:path';

// Read-only authorization metadata. No credentials or AI-side health probes.
export function summarizeAIConnections(snapshot, instanceID, now = Date.now()) {
  if (!snapshot || !Array.isArray(snapshot.clients) || !Array.isArray(snapshot.tokens)) return null;
  const clients = new Map(snapshot.clients.filter(client => typeof client?.clientId === 'string')
    .map(client => [client.clientId, client]));
  return [...clients.values()].map(client => {
    const records = snapshot.tokens.filter(record => record?.clientId === client.clientId && record.workspaceId === instanceID);
    const valid = records.filter(record => record.revoked === false && Number.isFinite(record.expiresAt)
      && record.expiresAt > now && ['access', 'refresh'].includes(record.kind) && Array.isArray(record.scopes)
      && record.scopes.some(scope => scope === `bg.instance.${instanceID}` || /^bg\.[a-f0-9]{12}\.[a-f0-9]{32}$/.test(scope)));
    let authorizationState = 'unknown';
    let reason = 'No current authorization is recorded.';
    if (valid.length) { authorizationState = 'authorized'; reason = 'A current access or refresh authorization is available.'; }
    else if (records.length && records.every(record => record.revoked === true)) {
      authorizationState = 'revoked'; reason = 'The recorded authorization was revoked.';
    } else if (records.length) { authorizationState = 'invalid'; reason = 'The recorded authorization is expired or invalid.'; }
    // The existing store removes revoked/expired records. Missing records cannot
    // distinguish an unfinished registration from a previously revoked client.
    return { clientID: client.clientId, name: typeof client.clientName === 'string' && client.clientName.trim()
      ? client.clientName.trim().slice(0, 120) : 'AI app', authorizationState,
      authorizationExpiresAt: valid.length ? Math.max(...valid.map(record => record.expiresAt)) : null,
      reason };
  });
}

export function readAIConnections(directory, instanceID) {
  if (!instanceID) return null;
  try { return summarizeAIConnections(JSON.parse(fs.readFileSync(path.join(directory, 'auth.json'), 'utf8')), instanceID); }
  catch (error) { return error.code === 'ENOENT' ? [] : null; }
}
