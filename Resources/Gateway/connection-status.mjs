import fs from 'node:fs';
import path from 'node:path';

// Read-only authorization metadata. No credentials or AI-side health probes.
export function summarizeAIConnections(snapshot, instanceID, now = Date.now(), { legacySide = false } = {}) {
  if (!snapshot || !Array.isArray(snapshot.clients) || !Array.isArray(snapshot.tokens)) return null;
  const clients = new Map(snapshot.clients.filter(client => typeof client?.clientId === 'string')
    .map(client => [client.clientId, client]));
  return [...clients.values()].map(client => {
    const records = snapshot.tokens.filter(record => record?.clientId === client.clientId && record.workspaceId === instanceID);
    const valid = records.filter(record => record.revoked === false && Number.isFinite(record.expiresAt)
      && record.expiresAt > now && ['access', 'refresh'].includes(record.kind) && Array.isArray(record.scopes)
      && (record.scopes.some(scope => scope === `bg.instance.${instanceID}` || /^bg\.[a-f0-9]{12}\.[a-f0-9]{32}$/.test(scope))
        // Historical Side credentials are still checked by their Gate-owned
        // AuthStore. This option changes status reporting only, never admission.
        || legacySide && !record.scopes.some(scope => scope.startsWith("bg."))
          && record.scopes.some(scope => ["workspace.read", "search", "git.read", "execution.read"].includes(scope))));
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
      pairingSessionID: typeof client.pairingSessionID === 'string' ? client.pairingSessionID : null,
      authorizationSessionID: typeof client.authorizationSessionID === 'string' ? client.authorizationSessionID : null,
      reason };
  });
}

export function readAIConnections(directory, instanceID, file = path.join(directory, 'auth.json'), options = {}) {
  if (!instanceID) return null;
  try { return summarizeAIConnections(JSON.parse(fs.readFileSync(file, 'utf8')), instanceID, Date.now(), options); }
  catch (error) { return error.code === 'ENOENT' ? [] : null; }
}
