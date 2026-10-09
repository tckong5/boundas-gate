# Side Gate runtime state ownership

## Ownership

Each existing Side Gate has one cached `SharedGatewayStore`, returned by
`WorkspaceStore.sideGateway(for:)`. Sidebar, detail, batch lifecycle actions,
counts and background observation use that same instance.

| Owner | Responsibility |
| --- | --- |
| `WorkspaceStore` | Folder records, membership, order, selection, rename, collection mutation busy state, Side creation/decommission orchestration, owner cache |
| Side `SharedGatewayStore` | Status, diagnostics, pairing/session/expiry, lifecycle operation state, connection health, reconnect policy |
| Existing Gateway backend | Persistent authorization, Gate/Folder policy, owned runtime/routes and decommission |

`runningCount` and `healthyConnectionCount` read existing cached owners; counting
does not instantiate stores or copy runtime values. Owner change notifications
are forwarded to collection observers, without a second value cache.
`lastObservedMCPURL` remains Folder configuration/history metadata.

## Observation and retirement

The collection's existing eight-second observation loop visits operable Side
Gates even when Main Gate is selected. Each visit uses the cached owner's
`refresh(background: true)` then `recoverIfNeeded()`. The legacy parallel status
and connection-check pass is removed. Concurrent refreshes reuse the owner's
in-flight check; detail Recheck no longer invokes a second legacy refresh.

Removal persists `removing` before backend decommission and retires the owner:
clear runtime/pairing, disable new commands/observations, advance its revision
to reject late status/diagnostic responses. Collection follow-ups also verify
owner identity. Successful decommission discards its subscription, owner cache
and setup draft. Failure retains the visible Retry row and retired owner.
Re-add creates a fresh owner. A stale lookup after removal cannot recreate a
cached active owner. Removal does not interleave with an active lifecycle command
or reconnect.

Open remains `start-local`; Secure Access remains explicit; Close remains
`stop`; Remove retains the existing two-phase decommission contract. Folder,
Main Gate membership/sharing and Passcode policy remain intact.

## Removed legacy collections and methods

Removed from `WorkspaceStore`:

- `statuses`, `diagnostics`, `pairingCodes`, `checkingConnections`, `checkTasks`,
  `checkTokens`, `revisions` and the separate checker.
- `refresh(_:)`, `invalidateConnection`, `checkConnection`, `diagnoseConnection`.
- `setConnectorURL`, `confirmConnectorUpdated`.
- `start`, `stop`, `restart`, `waitForStop`, `reconnectAll`.
- `generatePairingCode`, `copyPairingCode`, `copyURL`, `copySupportReport`,
  `openChatGPT`.
- `refreshSideGateJourneys` is replaced by the single observation path used by
  `refreshAll`.

Caller searches confirmed the removed setup/copy/repair helpers had no remaining
production consumers. Batch Open/Close and counts were the remaining legacy
runtime consumers and now use the cached owner.

Removed unused `C2CClient`/`SideGateClient` wrappers: `status`, `start`,
`reconnect`, `launch`, `stop`, `pair`, `unpair`, `tailscaleSetup`. Removed their
unused response models `StartResult`, `PairingResult`, `PairingCode`,
`TailscaleSetup` and unused collection operation cases.

`ConnectionGuidance`, `ConnectionSetupProgress` and `ConnectionSupportReport`
had no production callers and are removed with their obsolete tests.

## Retained command paths

- `SideGateClient.decommission`, `C2CClient.decommission` and private
  `sideLifecycle`: retain existing backend decommission/error reporting.
- `C2CClient.gateway`: unchanged launcher selection; Main uses `launcher.mjs`,
  Side uses `side-lifecycle.mjs` with its own source ID. `GatewayClient` exposes
  this existing command seam for isolated owner tests.
- `C2CClient.run`/runtime resource helpers: retain bundled runtime/environment,
  output handling and diagnostics behavior.
- `WorkspaceStore.refreshAll`, `startAll`, `stopAll`, `toggleSideGate`: retain
  accepted toolbar/menu/sidebar entry points, routed to the authoritative owner.
- `openFolder`, `openLogs`, `copyText`: retain Folder utilities; no runtime mirror.

No Gateway/Tailscale backend, authorization storage/scopes, Passcode semantics,
shared tunnel architecture, UI design, packaging metadata or production data
migration changed.

## Verification — 2026-10-09

- Debug build and packaged **Boundas Gate New User Test build 54**: PASS.
- Full Swift suite: **113 tests, 0 failures**. Includes 11 existing Side lifecycle
  tests and 8 new owner tests covering shared sidebar/detail owner, cached counts,
  Main-selected observation, concurrent checks, Gate-local pairing/authorization,
  late-result retirement/re-add, failed-removal Retry and in-flight decommission.
- Gateway/Tailscale Node suites: **101 tests, 0 failures**. Existing runtime
  admission and lifecycle integration coverage retained; no backend files changed.
- Packaged test App manual checks: PASS. Main remained Open with its existing
  authorization and 8 shared Folders; disposable Side local Open, Close/reopen,
  sidebar/detail agreement, explicit reuse of shared Secure Access, Claude setup
  and pairing generation, Main/back navigation with the same pairing code,
  Remove/re-add with Closed state/no stale setup or pairing.
- Manual checks did not grant a new external AI authorization. Authorization
  isolation is covered by automated tests; pairing generation/navigation was
  verified in the packaged UI.
- Disposable Side was decommissioned again. Original test Folder records were
  verified unchanged and restored after fixture cleanup. Production data was
  not modified or migrated.
- Working changes remain uncommitted for review; build output is ignored.
