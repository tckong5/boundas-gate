# Tunnel management

## Normal flow

Secure Access shows the actual next action inline: Set Up, Sign In, Continue Authorization, or Repair. Healthy state shows `Tailscale · Connected`, with Recheck/Sign Out under the stage's `…` menu. The primary Server URL belongs to Connect an AI App. Technical detail and the existing management sheet are available under Advanced → Advanced Tunnel Details.

Open Gate starts only the local MCP/OAuth host. Secure Access requires an explicit action; background refresh/reconnect never requests interactive login. Provider preflight and endpoint checks are the source of truth, without a separate Done confirmation.

## Shared embedded Tunnel

New Main/Side Gates share one private Tailscale agent/account. Each Side Gate has an independent URL path, route nonce, and MCP authorization. Adding a Side Gate requires no repeat login; when already signed in, Set Up enables only that Gate's route. Existing independent Side endpoints require explicit migration and are never silently replaced.

Shared Sign Out requires confirmation that it affects Gates using that Tunnel. Normal sign-out does not revoke MCP authorizations, Folder membership, or Passcode policy. Stopping/removing one Gate affects only its runtime/route and does not sign out other Gates.

External mode uses the Mac LocalAPI and retains logout confirmation because other services on the device may be affected. Embedded mode needs no separate Tailscale installation. Signing into a different account with a mismatched hostname is rejected by the existing URL guard rather than silently changing the Server URL.

## DNS and repair

A local DNS failure is not treated as a login failure and does not repeatedly restart a healthy route. Repair network cache requires explicit confirmation. See [Secure Access DNS troubleshooting](secure-access-dns-troubleshooting.md).

Implementation, isolated/migration tests, and acceptance evidence:

- [Shared Tunnel implementation](shared-tunnel-implementation.md)
- [Main Gate setup journey](main-gate-setup-journey.md)
- [Side Gate setup journey](side-gate-setup-journey.md)
- [Acceptance — 2026-10-09](acceptance-2026-10-09.md)
