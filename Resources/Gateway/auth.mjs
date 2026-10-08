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
    createAuthorizationCode(input) {
      // PairingManager has already verified the one-time local pairing code.
      // Consent connects this client to the instance, not a list of root IDs.
      if (registry.read().id !== this.workspaceId) throw new Error('Boundas Gate instance 已變更，請重新啟動共用連線。');
      if (!this.getClient(input.clientId)) throw new Error('AI 登記已移除，請從 AI app 重新連接。');
      return super.createAuthorizationCode({ ...input,
        scopes: [...input.scopes.filter(scope => !scope.startsWith('bg.')), `bg.instance.${this.workspaceId}`] });
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
      return super.issueTokens({ ...input, scopes: sameInstance ? connectionScopes(input.scopes, this.workspaceId) : input.scopes });
    }
  };
}
