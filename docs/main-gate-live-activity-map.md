# Main Gate Live Activity Map

## Presentation

Main Gate shows the map when Local + Secure Access are usable and its Gate identity has a persisted successful AI onboarding record. First-time, incomplete and cancelled onboarding remains in the existing journey. Closing a Gate, failed Local/Tunnel checks and reconnecting return to the journey. An invalid AI authorization does not close the Gate: its map node is orange and Review Connections opens the existing repair/setup controls.

`AISetupStore` stores Gate IDs in a separate, private `*.completed.json` alongside the existing setup draft. Completion is monotonic and scoped to Gate identity. An observed valid authorization, including an existing authorization on upgrade, records completion once. A previously completed draft can migrate this history. Cancel, draft expiry and revocation do not erase it. A past authorization that was already removed before upgrading cannot be recovered from absent backend evidence.

The summary remains Gate Open with zero authorizations after onboarding. The empty map offers Connect an AI App; zero shared Folders is also a normal state. Side Gate presentation is unchanged.

## Topology source of truth

- Apps: `GatewayStatus.aiConnections`. Authorized nodes require an unexpired authorization; invalid/expired nodes show attention. Revoked, removed and unlinked registrations are excluded. No live session claim is made.
- Folders: effective, enabled `GatewayStatus.roots`, joined to Main Gate `WorkspaceRecord` membership by source ID. Names come from the current record so renames update without a separate map configuration. An unsaved sharing selection is not represented as effective access. Side-only resources are excluded.
- Protection: existing root `codeRequired` policy. Availability: canonical directory checks reported by the local activity feed. Initial availability uses the existing local Folder record.

## Activity and privacy

Main Gate `makeMcpServer` wraps the actual tool callbacks. Each admitted call emits requestStarted and exactly one requestFinished after its actual callback resolves, including denied/error results. Existing scope, passcode and after-read revocation checks remain intact. Identity comes from admitted bearer `authInfo.clientId`, never caller metadata.

`GateActivity` is an ephemeral in-memory journal: up to 512 events, 60 seconds of retention and 256 active requests. It stores request/Gate/client/Folder IDs, category (Read, Search, Git, Info), timestamps, success and duration only. It never accepts file contents, paths/filenames, queries, prompts, tokens, passcodes, access keys, arguments or results. Calls without a Folder ID route only between AI and Gate. Telemetry failures/overflow do not fail the MCP tool.

The Swift client polls `GET /control/activity` at a one-second interval only while the Main map window is visible. It reads the private runtime file without following a final symlink, validates ownership/permissions and Main Gate identity, verifies the live local health nonce, then supplies the existing admin bearer and instance header to 127.0.0.1. Redirects, credential/cookie caches and proxy use are disabled. Existing loopback/admin middleware protects the endpoint. Existing external and shared/native ingress whitelists reject it; there is no new public route or listener.

## Animation and performance

Each requestID owns an independent route. A genuine start launches a short request pulse; long requests retain a subtle Folder highlight. Only a genuine finish starts the response pulse. Fast calls reported together still display each real direction once. Concurrent calls are not serialized. Unknown/unavailable topology never gets fabricated traffic. Failure produces a short orange destination highlight.

Idle topology has no Timeline, recurring animation or per-frame polling. The one-second metadata check remains active while visible; unchanged idle pages do not publish animation state. Minimized/occluded/hidden windows cancel polling and all visual tasks. On resume/restart/journal gaps, a baseline restores only active request highlights and does not replay old traffic. UI routes are bounded at 128; overflow drops visualization events rather than affecting tools.

Reduce Motion removes travelling signal photons and node scale transitions, retaining brief source/destination highlights and readable static topology. Folder materialization uses a brief fade/scale transition. Request and response signals share the same continuous cubic Bézier route; each route displays at most one photon with a bright core, translucent halo and short trail. Arrival briefly brightens/scales the destination node, without a large expanding ring.

## Runtime compatibility

The running Gate daemon must include `activity.mjs` and the updated server. An older daemon still renders topology, with an activity-unavailable tooltip; closing/reopening Main Gate enables telemetry. The UI never automatically restarts a live Gate for this feature.

## Verification

Swift tests cover effective sharing/rename/removal, authorization projection, concurrency, fast/long requests, resume behavior, polling cancellation, Reduce Motion and persistent Gate-scoped onboarding. Node tests cover bounded/redacted journaling, real admitted tools, failures and overlapping requests. Existing native ingress tests explicitly reject activity paths at Main, legacy and Side public URLs.

Packaged acceptance and the connector-origin regression check are recorded in [Acceptance — 2026-10-09](acceptance-2026-10-09.md).
