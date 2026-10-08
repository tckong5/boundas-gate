// Called only for scopes from the gateway's verified/persisted AuthStore, never
// from client arguments. Legacy bg.<root>.<epoch> grants prove prior pairing
// with this instance; bearerAuth still checks the token's gateway identity.
function connectionScopes(scopes, instanceID) {
  const connection = `bg.instance.${instanceID}`;
  const legacy = /^bg\.[a-f0-9]{12}\.[a-f0-9]{32}$/;
  if (!scopes.includes(connection) && !scopes.some(scope => legacy.test(scope))) return scopes;
  return [...scopes.filter(scope => !scope.startsWith('bg.')), connection];
}

export function instanceAuthStore(BaseAuthStore, registry) {
  return class InstanceAuthStore extends BaseAuthStore {
    consumedSetupSessions = new Map();
    createAuthorizationCode(input) {
      // PairingManager has already verified the one-time local pairing code.
      // Consent connects this client to the instance, not a list of root IDs.
      if (registry.read().id !== this.workspaceId) throw new Error('Boundas Gate instance 已變更，請重新啟動共用連線。');
      if (!this.getClient(input.clientId)) throw new Error('AI 登記已移除，請從 AI app 重新連接。');
      const code = super.createAuthorizationCode({ ...input,
        scopes: [...input.scopes.filter(scope => !scope.startsWith('bg.')), `bg.instance.${this.workspaceId}`] });
      // Non-secret setup correlation; only the verified pairing flow sets it.
      const client = this.getClient(input.clientId);
      const previous = client.pairingSessionID;
      client.pairingSessionID = input.pairingSessionId;
      try { this.save(); }
      catch (error) { client.pairingSessionID = previous; this.authCodes.delete(code); throw error; }
      return code;
    }

    cancelSetup(sessionIDs) {
      if (!Array.isArray(sessionIDs) || sessionIDs.length > 128 || sessionIDs.some(id => typeof id !== 'string' || !/^[a-f0-9]{32}$/.test(id))) throw new Error('Setup identity is invalid.');
      const clients = [...this.clients.values()].filter(client => sessionIDs.includes(client.pairingSessionID)
        || sessionIDs.includes(client.authorizationSessionID));
      if (clients.some(client => sessionIDs.includes(client.authorizationSessionID) && [...this.tokens.values()].some(token => token.clientId === client.clientId
          && !token.revoked && token.expiresAt > Date.now()))) throw new Error('This app is already authorized. Manage its authorization instead.');
      const previous = { clients: new Map(this.clients), authCodes: new Map(this.authCodes) };
      for (const [code, record] of this.authCodes) if (sessionIDs.includes(record.pairingSessionId)) this.authCodes.delete(code);
      // Remove only a pairing-correlated registration that has never been
      // authorized and has no other pending exchange. Uncorrelated registrations
      // retain the existing abandoned-registration TTL rather than guessed ownership.
      let removed = false;
      for (const client of clients) {
        if (!client.authorizedAt && ![...this.tokens.values()].some(token => token.clientId === client.clientId
            && !token.revoked && token.expiresAt > Date.now())
            && ![...this.authCodes.values()].some(code => code.clientId === client.clientId)) {
          this.clients.delete(client.clientId); removed = true;
        }
      }
      try { if (removed) this.save(); }
      catch (error) { Object.assign(this, previous); throw error; }
      for (const [id, session] of this.consumedSetupSessions) if (sessionIDs.includes(session)) this.consumedSetupSessions.delete(id);
    }

    consumeAuthorizationCode(code) {
      const record = super.consumeAuthorizationCode(code);
      if (record) this.consumedSetupSessions.set(record.clientId, record.pairingSessionId);
      return record;
    }

    removeInactiveClient(clientID) {
      if (typeof clientID !== 'string' || !this.getClient(clientID)) throw new Error('搵唔到呢個 AI 登記。');
      if ([...this.tokens.values()].some(token => token.clientId === clientID && !token.revoked && token.expiresAt > Date.now())) {
        throw new Error('呢個 AI 仍有有效授權，未有移除。');
      }
      const previous = { clients: new Map(this.clients), tokens: new Map(this.tokens), authCodes: new Map(this.authCodes) };
      this.clients.delete(clientID);
      for (const [id, token] of this.tokens) if (token.clientId === clientID) this.tokens.delete(id);
      for (const [id, code] of this.authCodes) if (code.clientId === clientID) this.authCodes.delete(id);
      try { this.save(); }
      catch (error) { Object.assign(this, previous); throw error; }
    }

    revokeClient(clientID) {
      if (typeof clientID !== 'string' || !this.getClient(clientID)) throw new Error('搵唔到呢個 MCP Connection。');
      const previous = { clients: new Map(this.clients), tokens: new Map(this.tokens), authCodes: new Map(this.authCodes) };
      const hashes = [...this.tokens.entries()].filter(([, token]) => token.clientId === clientID).map(([hash]) => hash);
      this.clients.delete(clientID);
      for (const hash of hashes) this.tokens.delete(hash); // Includes every access and refresh credential.
      for (const [id, code] of this.authCodes) if (code.clientId === clientID) this.authCodes.delete(id);
      try { this.save(); }
      catch (error) { Object.assign(this, previous); throw error; }
      this.consumedSetupSessions.delete(clientID);
      return hashes;
    }

    verifyAccessToken(token) {
      const verdict = super.verifyAccessToken(token);
      if (!verdict.ok || verdict.record.workspaceId !== this.workspaceId) return verdict;
      return { ...verdict, record: { ...verdict.record,
        scopes: connectionScopes(verdict.record.scopes, this.workspaceId) } };
    }

    issueTokens(input) {
      // Refresh rotation persists the instance scope while preserving the
      // original operation scopes, expiry, client and revocation semantics.
      const sameInstance = input.workspaceId === undefined || input.workspaceId === this.workspaceId;
      // Upstream supplies workspaceId for refresh rotation, but not the initial
      // authorization-code exchange. A background refresh must not finish a new
      // setup merely because the same client already has an older authorization.
      const client = this.getClient(input.clientId);
      if (input.workspaceId === undefined && client) {
        const session = this.consumedSetupSessions.get(input.clientId);
        this.consumedSetupSessions.delete(input.clientId);
        if (session) client.authorizationSessionID = session;
      }
      return super.issueTokens({ ...input, scopes: sameInstance ? connectionScopes(input.scopes, this.workspaceId) : input.scopes });
    }
  };
}
