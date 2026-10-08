# Side Gate setup journey

## Shared presentation

`WorkspaceDetail` presents Folder identity once and uses `GateConnectionContent`, `GateConnectionStepper`, `SecureAccessPresentation` and `AIConnectionSetupView` shared with Main Gate. `GateUIContext` supplies Side-specific labels, MCP app name/description and a profile-local setup file (`side-ai-setup/<Gate ID>.json`). Server URL comes exclusively from the selected Gate's status.

Rename, Recheck, Advanced and confirmed Remove Side Gate live in the header menu. Folder utilities remain below. Legacy ConnectionStatusView, ConnectionRepairGuide and StableConnectionView have no remaining callers and are removed. Advanced Tunnel Details remains available for existing Tailscale modes. Existing Cloudflare providers/bindings stay supported by the lifecycle backend; no automatic endpoint/provider migration is performed.

## Runtime actions and consent

- `start-local` (including legacy/menu/batch `start`): start/verify the owned local Side daemon only. Record `desiredRunning=true, localOnly=true`. Never start the transport, request login, authorize an account or open a browser.
- `prepare-access` / `start-tunnel`: explicit Secure Access intent. Prepare existing transport non-interactively and start this Gate's route only when the provider is ready.
- `login`: explicit account action; the existing shared UI opens the trusted authorization URL. Browser completion is observed through provider preflight and Gate status, with no Done button.
- `reconnect` / `recover`: restore only previously requested Local/transport state, never initiate account login or approval. Automatic recovery obeys desired-running, reconnect settings and existing backoff/DNS protections.
- `stop`: stop owned Local and transport runtime, set desired-running false, retain MCP authorizations, Folder policy, memberships, provider/account identity and saved address. Reopening starts Local only; restoring Secure Access remains explicit.
- `decommission`: existing confirmed removal retires owned runtime/routes and removes Side authorization/config. Membership is cleared only after success; failed removal stays visible for Retry. Only that Gate's AI setup draft/cache is removed.

WorkspaceStore owns one shared observation/reconnect store per Side Gate, so recovery continues while Main Gate is selected. Main-only and removing/failed-removal Folders are excluded. The detail view uses the same store rather than an independent recovery loop.

## Authorization and Passcode

Each Side Gate keeps its own AuthStore file and Gate ID. Shared metadata/control routes support resumable setup and correlated OAuth completion. Existing legacy Side operation-scope credentials are recognized in authorization **display metadata** only when their token belongs to that Side Gate; bearer admission/security rules are unchanged. Authorized is not a live session assertion.

`FolderPasscodeButton` reuses the same Folder-level policy/popover from either Gate. Policy remains shared across Main/Side; passcodes and temporary grants remain restricted by Gate, credential and conversation through the existing core. Close does not disable protection or revoke persistent MCP authorization. Runtime grants are not restored across a stopped daemon.

## Verification

Swift tests cover shared presentation context, per-Gate setup persistence, Local-to-Secure-Access state, healthy compact eligibility, Side membership/removal/cache isolation and explicit setup for an already signed-in provider.

The isolated Side launcher integration test executes actual Local startup, explicit transport preparation/login, OAuth registration/pairing/token exchange, Folder policy/code controls, Close/reopen, crash recovery, decommission and re-add. The transport/account is a private local mock; it proves lifecycle behavior, not real internet reachability. Existing Gateway/Passcode/provider suites verify cross-Gate admission, path boundaries, policy/grant isolation and route ownership.

## Changed files

Presentation: WorkspaceDetail.swift, GateUIContext.swift, SharedGatewayView.swift, GateConnectionJourney.swift, AIConnectionSetupView.swift, FolderPasscodeButton.swift, C2CManagerApp.swift, SecureAccessPresentation.swift.

Lifecycle/status: C2CClient.swift, WorkspaceStore.swift, SharedGatewayStore.swift, side-lifecycle.mjs, side-registry.mjs, connection-status.mjs.

Tests: GateUIContextTests.swift, SideGateLifecycleTests.swift, SecureAccessPresentationTests.swift, side-journey-launcher.test.mjs, side-lifecycle.test.mjs, connection-status.test.mjs, zero-folder-launcher.test.mjs.

Removed: ConnectionStatusView.swift, ConnectionRepairGuide.swift, StableConnectionView.swift. MainGateFolderPasscodeButton.swift is renamed to FolderPasscodeButton.swift.

## Sign-in retry robustness

A reused tsnet account can retain LoggedOut=true/WantRunning=false after an interrupted/sign-out flow. Explicit Sign In now subscribes to initial IPN state, restores WantRunning through the private LocalAPI and then requests interactive login. Login management version 2 upgrades only the verified helper owned by that Gate; a socket reset while the old helper exits is treated as teardown, not an unverified endpoint to kill. Existing Gate identity/MCP authorizations are retained.

Background recovery pauses while a running Local host awaits login/approval. Read-only observation continues; when preflight becomes ready, normal route recovery resumes. This prevents repeated blue reconnecting states during user consent.

Private login failures now distinguish timeout, rejected request, invalid URL and general failure, and record a whitelisted backend state. User copy no longer assumes VPN is the cause. No login URL, tokens or profile secrets are logged.
