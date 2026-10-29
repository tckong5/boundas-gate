# Boundas Gate — Shared Tunnel architecture target

Status: the app's shared embedded Tailscale ingress is implemented. See the [implementation and migration report](shared-tunnel-implementation.md).

This supplements [Product Model / Architecture Invariants v1](product-model-architecture-invariants-v1.md) with Tunnel ownership requirements. Gate lifecycle, Folder membership, Passcode policy, and independent MCP authorization retain the original contract.

## 1. Product goals

- One Boundas Gate instance shares one Tailscale account/device identity, initial authorization, and active Tunnel. Adding a Side Gate must not create another Tailscale device or require another login.
- Main and Side Gates use one HTTPS origin with stable, independent URL paths.
- Every Gate remains an independent MCP endpoint, authorization boundary, and lifecycle.
- Tailscale authorization and MCP authorization are separate; sharing transport grants no AI access to any Gate.
- Unauthorized Side Gate access is denied by default. Sharing a Folder, opening a local host, or enabling a route does not grant MCP access.

## 2. URLs and routing

Conceptual paths:

```text
https://<instance-hostname>/mcp
https://<instance-hostname>/side/<gate-id>/mcp
```

These examples do not imply that an arbitrary `boundas-gate.ts.net` name is available. The origin comes from the existing Tailscale account/device domain. Gate IDs remain stable and independent of Folder display names; renaming does not change the URL.

Shared ingress must use a server-owned route registry to send fixed Gate paths to verified, Gate-owned loopback services. Clients cannot supply arbitrary localhost ports, absolute Folder paths, or target URLs.

Routing must cover each Gate's MCP, OAuth discovery/registration/authorization/token/callback, and health paths, not just `/mcp`. Issuer, resource metadata, scopes/audience, and authorization storage must remain consistent. Verify discovery paths against the implementation and relevant standards rather than assuming all clients behave identically.

## 3. Ownership and lifecycle

```text
Boundas Gate instance
├── Shared Tailscale identity / Tunnel runtime
└── Gate route registry
    ├── Main Gate → owned Local service → independent AuthStore / Folder access
    ├── Side Gate A → owned Local service → independent AuthStore / Folder access
    └── Side Gate B → owned Local service → independent AuthStore / Folder access
```

- The shared transport coordinator owns the account, runtime, retry/backoff, and ingress. Each Gate coordinator owns its local service, route, and desired-running intent.
- Open Gate starts only the local layer. Initial Secure Access authorization remains an explicit user action.
- Once shared transport is authorized, a new Gate creates its route without another login.
- Closing Main or Side Gate stops only that Gate's service/route, without signing out, stopping other Gates, or revoking persistent MCP authorization.
- Remove Side Gate must finish decommission, revocation, and route retirement before hiding membership. Failures remain retryable; Folder and Main Gate state survive.
- Shared Sign Out is instance-wide and requires explicit confirmation of its effect on all shared Gates.
- A healthy Tunnel does not mean every Gate is Open. Each Gate needs its own healthy local service and active route. Zero MCP Connections/Folders do not prevent opening.
- After the last route closes, an unused listener may stop while retaining transport identity/login state; reopening must not require another login for that reason.

## 4. Runtime authorization and revocation

```text
Main Gate authorization ≠ Side Gate A authorization ≠ Side Gate B authorization
```

- After ingress selects a Gate, every request validates that Gate's authorization, identity, scopes/audience, current Folder ACL, and Passcode policy.
- Main tokens cannot access Side Gates; Side A tokens cannot access Side B.
- Matching client display names do not imply the same authorization and must not drive cross-Gate revocation.
- Disabling/removing an MCP Connection must revoke its access/refresh credentials, pending exchanges, and temporary grants in that Gate's backend. Subsequent requests and refreshes must fail; hiding a row is insufficient. Other authorizations stay valid.
- Authorized describes authorization state, not a live AI session.
- Shared transport must not weaken traversal, symlink, read-only, or Passcode restrictions.

## 5. Existing clients and migration

- Inspect existing identities, origins, URL bindings, AuthStores, OAuth metadata, and helpers before deciding compatibility.
- Prefer retaining the Main origin and each Gate's identity/authorization. Sharing transport does not justify clearing authorization, recreating Gates, or changing Folder policy.
- Old Side hostnames do not automatically become aliases. Preserving an old URL requires its existing ingress or provider-supported mapping to the same Gate. HTTP redirects are not assumed sufficient for every MCP/OAuth client.
- If a new URL requires authorization, explain the one-time endpoint migration. Never silently map an old Side URL to Main Gate or treat cross-Gate tokens as compatible.
- Retire an old route/helper only after its Gate migrates successfully. Failures stay retryable without prematurely deleting a working ingress. Later additions must not require another Tailscale login.

## 6. Implementation order and acceptance

1. Review the tree and identify differences in per-Gate transport ownership.
2. Implement a minimal shared coordinator/fixed route registry using the existing Tailscale provider, without adding ngrok or a generic provider framework.
3. Test cross-Gate routing, OAuth discovery, and token isolation in isolated fixtures.
4. Integrate Main/Side lifecycle and verify targeted Close/Remove/reconnect behavior.
5. Implement backend connection revocation and verify access, refresh, and temporary-grant invalidation.
6. Implement migration, then connect Secure Access UI/shared status to the new source of truth.
7. Build Debug, run relevant tests, then verify at least two Gates under one authorization, restart, Side Gate addition, and individual AI-connection revocation on a real machine.

Required cases: one initial login; no additional login for Side Gates; zero-Folder Main Gate; mutual Main/Side A/Side B token rejection; immediate read/refresh rejection after revocation; isolated Close/Remove; identity/authorization/route retention across restart; and no orphan or silent cross-Gate mapping after migration failure.
