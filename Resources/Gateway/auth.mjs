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
      return super.createAuthorizationCode({ ...input,
        scopes: [...input.scopes.filter(scope => !scope.startsWith('bg.')), `bg.instance.${this.workspaceId}`] });
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
