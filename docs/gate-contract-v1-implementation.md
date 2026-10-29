> Historical implementation report. On 2026-10-08, full Side Gate unlock replaced the temporary fail-closed restriction described here. See [security-robustness-review.md](security-robustness-review.md) for that implementation.

# Gate contract v1 — Implementation and verification

Date: 2026-10-07.

Contract: [Product Model / Architecture Invariants v1](product-model-architecture-invariants-v1.md). Contract semantics remained unchanged.

## Findings and fixes

| Original conflict | Fix |
| --- | --- |
| `sideGateAdded` filtered only the sidebar | Filter all Side lifecycle, batch, refresh, diagnostics, and counts by membership; the Node helper rechecks the persisted registry |
| Remove revoked Main sharing and deleted the Folder | Separate Remove Side Gate from Remove Folder; clear membership only after decommission succeeds |
| Folder count blocked start/pair/reconnect | Initialize Main identity independently; server, launcher, pairing, recovery, and UI accept an empty list |
| Gate Open depended on authorization/Folder count | Runtime `isOpen` depends on Local + Tunnel; `isReady` remains setup-journey state |
| UI mixed Workspace/Repository/AI Connection terminology | Use Folder/Gate/Tunnel/MCP Connection in ordinary UI while retaining internal API names |
| Side could bypass Main Passcode policy | Temporarily reject protected Side access as explicitly approved; full Side unlock was deferred |

## Runtime enforcement

### Side Gate membership

- Main Gate Add Folder defaults to `sideGateAdded = false`.
- Side Add by Path/Add Folder can add existing or new Folders without duplicating records.
- Main-only Folders are excluded from Side start/stop/reconnect/refresh/diagnostics/counts.
- `side-lifecycle.mjs` rereads membership on every operation and rejects Main-only, removing, or failed/pending-retry Gates.
- New Side daemons recheck membership and Passcode policy on bearer requests and stop serving when membership is removed.
- Existing Cloudflare/Tailscale providers are reused; no ngrok or TunnelProvider framework was introduced.

### Remove Side Gate

1. Persist `removing` and retain the row.
2. Verify service identity, Folder path, and local admin credential; never blindly kill an unknown service.
3. Stop the Side-owned Tunnel, revoke Side tokens/pairing, and stop its bridge.
4. Clean that Gate's journaled routes, Side auth file, runtime credential, and daemon marker.
5. Clear active/configured MCP URLs; retain `lastKnownMCPURL` only as history.
6. Persist success before setting `sideGateAdded = false`; retain Folder identity/path/name/provider preference.
7. On failure, retain `failed` and Retry; interrupted removal resumes in a retryable state after app restart.

Side removal does not modify Main configuration, authorization, sharing, or Passcode policy.

Remove Folder deletes only the App record, never the filesystem Folder or Main Gate runtime. A Folder with a Side Gate must first complete Side removal.

### Authorization isolation

- Main has an independent Gate ID/AuthStore and checks current sharing on every file operation.
- Side Gates use their own workspace-bound AuthStores/runtimes; cross-Gate tokens are rejected.
- Removal deletes Side authorization state. Re-adding the same Folder does not reactivate old access/refresh tokens or registrations.
- Authorized means persistent valid authorization, not an active request or live AI session.

### Zero-Folder Main Gate

- Gate identity, local service, Tunnel, pairing, and OAuth can exist before any Folder.
- `list_workspaces → []` is normal.
- Removing the last Folder revokes resource access immediately while Local/Tunnel can remain Open.
- Empty registries support reconnect, crash recovery, and stop/start while retaining Gate identity/OAuth/fixed URL.
- Zero authorizations do not close a running Gate.

### Passcodes at this historical checkpoint

Policy remained in Gateway root metadata, keyed by Folder identity, without a separate policy store. Main unlock/temporary access semantics were unchanged. The Side bearer guard read the same policy, including retained policy for Folders no longer shared through Main.

**Limitation at the time:** protected Side Folders were denied because no Side unlock API existed yet. Main temporary keys did not authorize Side access. This explicitly accepted conservative restriction was not presented as complete cross-Gate unlock support.

## UI/metadata versus runtime

| Item | Enforcement layer |
| --- | --- |
| Side membership, decommission, cross-Gate rejection | Store/Node/MCP runtime |
| Dynamic ACL, path/symlink/read-only restrictions | Existing server checks and integration tests |
| Zero-Folder Main startup/pair/recovery | Launcher, daemon, OAuth runtime |
| Gate Open versus setup Ready | UI mapping from Local/Tunnel diagnostics, without a new network state machine |
| Authorized/Invalid/Not authorized clients | Persistent authorization evidence, not live client health |
| `lastKnownMCPURL`, provider/domain reservation | Historical/configuration metadata, not an active endpoint |
| Side Passcode support at this checkpoint | Real fail-closed restriction; full temporary unlock not yet implemented |

## Migration

- Adding a Folder or normally restarting Main requires no new Plugin registration/OAuth.
- Legacy records missing membership use previously recorded Side endpoint evidence for one-time migration; provider preference alone does not create a Side Gate.
- Legacy Side daemons without membership/policy guards are safely stopped on first refresh. Reopening installs the new guard while retaining OAuth.
- Unverifiable runtime identity/route ownership fails with Retry/diagnostics, without hiding rows or touching other Gates.
- Re-adding after Remove Side Gate is a new authorization flow and requires pairing, consistent with decommission semantics.

## Verification

Debug build passed. Swift: 55 tests passed; Gateway/Tunnel Node: 52 tests passed. Relevant tests were rerun after the final Side lifecycle fix.

| Acceptance | Result | Coverage |
| --- | --- | --- |
| Main Add Folder does not create Side membership | PASS | Swift Store and Node checks |
| Side batch actions exclude Main-only Folders | PASS | Swift lifecycle tests |
| Add existing/new Folder to Side | PASS | Swift lifecycle tests |
| Folder survives Side removal | PASS | Store persistence and real Side daemon |
| Main sharing/authorization stays unchanged | PASS | Real OAuth/file reads and config/auth byte comparison |
| Failed removal retains row and Retry | PASS | Store failure/restart/retry and route cleanup failure |
| Re-add does not revive old authorization | PASS | Real old Side token rejection and successful new pairing |
| Main/Side coexist for one Folder | PASS | Real MCP reads; Main remains accessible after Side removal |
| Main token → Side / Side A token → Side B | PASS | Real HTTP/MCP 401; reverse direction also rejected |
| Zero-Folder startup/pair/reconnect/recovery | PASS | Real launcher/daemon/control and local transport IPC fixture |
| Last Folder removal keeps Gate Open | PASS | Main service/Tunnel fixture; empty list and denied old root |
| Protected Side Folder cannot bypass policy | PASS | Real bearer guard, including disabled Main sharing |
| Legacy Side migration retains OAuth | PASS | Legacy daemon safely replaced; new daemon accepts original token |

Tests used real local MCP/OAuth/daemons and isolated transport fixtures. Fixtures were not claimed as public-network health. Complete manual UX and real external installation acceptance were outside this round.

## Files changed in the original implementation

### App

- `Sources/C2CManager/WorkspaceRecord.swift`
- `Sources/C2CManager/WorkspaceStore.swift`
- `Sources/C2CManager/C2CClient.swift`
- `Sources/C2CManager/SharedGatewayStore.swift`
- `Sources/C2CManager/GatewayReconnectPolicy.swift`
- `Sources/C2CManager/GateConnectionJourney.swift`
- `Sources/C2CManager/SharedGatewayView.swift`
- `Sources/C2CManager/C2CManagerApp.swift`
- `Sources/C2CManager/ConnectionGuidance.swift` (later removed as unused in the [runtime ownership cleanup](side-gate-runtime-owner.md))

### Runtime

- Gateway `registry.mjs`, `launcher.mjs`, `server.mjs`, new `side-lifecycle.mjs`, and `oauth-presentation.mjs`.
- Tailscale `provider.mjs` and `embedded.mjs`.

### Tests and documentation

- New `Tests/C2CManagerTests/SideGateLifecycleTests.swift`.
- Swift `GateConnectionJourneyTests.swift`, `GatewayReconnectPolicyTests.swift`, and `SharedGatewayConnectionTests.swift`.
- Gateway `gateway.test.mjs`, new `side-lifecycle.test.mjs`, and new `zero-folder-launcher.test.mjs`.
- This report.

## Builds available at the time

- `dist/Boundas Gate Debug.app`
- `.build/apps/Boundas Gate New User Test.app`

The existing Debug/isolated test bundles were updated without resetting Folders/OAuth. The normal release bundle remained unchanged. This round made no commit and added no ngrok support.
