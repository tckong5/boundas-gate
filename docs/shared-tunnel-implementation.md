# Shared Tunnel — Implementation and migration

This records the initial shared-ingress implementation. Subsequent explicit Main Gate migration and production acceptance are recorded in [RELEASE_NOTES.md](../RELEASE_NOTES.md).

## Implemented behavior

- New Main Gate: `https://<instance-hostname>/mcp`.
- New Side Gate: `https://<instance-hostname>/side/<gate-id>/mcp`.
- Side Gates reuse Main's embedded Tailscale identity, login, and Funnel listener, without another tsnet node.
- Side Gates continue using shared transport while Main's local host is closed.
- Gate paths route MCP, OAuth registration/authorization/token/revocation, discovery, and health independently.
- Public ingress accepts fixed localhost targets only, checks Gate ID/runtime instance ID per request, and forwards a lifetime header against port-reuse races.
- Each Gate retains its AuthStore, pairing, Folder ACL, Passcode policy, desired-running intent, and local service.
- Close/Remove retires only that Gate's route; shared Sign Out stops all shared public ingress.
- Removing an MCP Connection removes its access/refresh credentials, unused authorization codes, and temporary Folder access without affecting other Gates/clients.
- File reads recheck the OAuth credential before returning, preventing revoked in-flight requests from disclosing output.
- Gates can start with no Folders/authorizations. Shared transport grants no Folder access.

## Legacy connections and migration

Existing fixed-address Main Gates retain `/c2c/<main-id>/mcp` without requiring AI-app changes. Legacy Side URLs/providers are retained rather than automatically replacing paired endpoints. Embedded Side Gates without an established endpoint adopt the shared identity while preserving Gate ID/epoch.

A paired Side Gate can explicitly migrate through **Secure Access → … → Use Shared Secure Access…**. Main's shared embedded account must already be signed in; migration does not silently open a browser.

Migration:

1. Persist a private migration journal.
2. Stop the Side Gate's old service/route while retaining its AuthStore.
3. Save the new URL and old provider/URL history.
4. Restart that Gate and register its shared route.
5. Remove the journal on success; on failure, attempt to restore the old endpoint and retain Retry if restoration is incomplete.

Update the connected AI app to the new URL. Depending on the client, one-time OAuth authorization may be required. Backend Gate identity and valid tokens are retained; Main tokens never grant Side access. Later Side Gates require no additional Tailscale login.

**Legacy external Tailscale/Cloudflare connections are preserved.** Shared ingress uses the app's embedded runtime. A Main Gate still bound to external Tailscale needs explicit Main transport migration; its identity/domain are not automatically changed.

## Runtime enforcement

Gate routing, runtime nonces, OAuth Gate identity, client revocation, Folder ACLs, and Passcodes are enforced by the backend. `Authorized` describes an authorization relationship, not an AI-side live session. UI `sharedTunnel`/migration fields describe backend mode and do not replace access controls.

## Verification

- Native Tunnel: one listener for Main plus two Side Gates; MCP/OAuth/discovery routing, admin rejection, nonce/port-reuse rejection, isolated Close, and concurrency/race checks.
- Node integration: real launcher, daemon, OAuth PKCE, and MCP reads with only the Tailscale account/Funnel mocked; one login, zero-Folder Main, cross-Gate token rejection, client/refresh revocation, Close/Remove, route restoration, and legacy Side CLI migration/token retention.
- Migration: restore the original URL on failure while preserving Main configuration, Gate ID, epoch, and authorization.
- Swift: shared Side URL parsing, next account action, and existing UI/lifecycle tests.

These tests do not claim to have performed real Tailscale browser authorization or external AI-app migration on the user's behalf.

## Files changed in the original implementation

- Native: `Native/Tunnel/main.go`, `main_test.go`, new `shared.go`/`shared_test.go`.
- Backend: `Resources/Tailscale/embedded.mjs`; Gateway `registry`, `side-registry`, `launcher`, `side-lifecycle`, `server`, `auth`, `access`, and new `side-migration.mjs`.
- UI: `ConnectionDiagnostics.swift`, `SharedGatewayStore.swift`, `SharedGatewayView.swift`, `SecureAccessPresentation.swift`.
- Tests: Gateway `side-lifecycle`, `side-journey-launcher`, `zero-folder-launcher`, new `shared-tunnel.test.mjs`; Swift `ConnectionDiagnosticsTests.swift`/`SecureAccessPresentationTests.swift`.
- Documentation: the shared-tunnel architecture target and this report.
