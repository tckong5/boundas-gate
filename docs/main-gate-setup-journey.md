# Main Gate setup journey

## Secure Access

The main journey uses provider preflight and the existing endpoint diagnostics. `Tailscale · Connected` is shown only when the Tunnel stage is complete, including public endpoint/MCP checks; an authenticated provider alone is not proof of public reachability.

Login, approval and repair actions are inline. Healthy Recheck and Sign Out live in the stage's menu. External logout retains the confirmation that other Gates/services on the same Mac can be affected. Provider/mode, transport details and the existing management sheet are available only through Advanced → Advanced Tunnel Details.

The explicit Set Up / Sign In / Continue Authorization actions record intent in the **existing** Gate `desiredRunning` configuration. Provider preflight remains the source of truth. The existing reconnect coordinator resumes opening once approval succeeds, including after closing/reopening the app. Manual Stop/Sign Out still clears that intent. Auto-reconnect preferences are respected; when disabled, Repair/Open Gate remains the explicit action.

Open Gate now invokes `start-local`, which starts only the existing loopback MCP/OAuth host without starting transport, requesting login or opening a browser. Real local health and unauthenticated MCP checks must pass before Secure Access becomes current. Stage 1 completion alone never means Gate Open.

The persisted `localOnly` intent makes local startup resumable after a crash/restart without escalating into secure access. Explicit Secure Access setup clears that flag and uses the existing desired-running coordinator. Background recovery never requests interactive login or approval. Close Gate stops runtime while preserving Folders, authorizations, settings and account login.

Waiting for a user action uses a grey breathing dot; processing/checking uses blue breathing; complete uses solid green; pending uses a grey hollow dot. Orange remains reserved for genuine attention states. No Folder prerequisite or alternative Tunnel provider was introduced.

## AI setup progress

Main Gate stores one unfinished setup draft in its app data profile:

- Normal profile: `~/Library/Application Support/Boundas Gate/ai-setup.json`
- New-user test profile: `~/Library/Application Support/Boundas Gate New User Test/ai-setup.json`

The file is written atomically with permission `0600`. It contains app choice, stage, Gate identity, attempt identity, non-secret pairing session IDs, associated client ID and timestamps. It contains no pairing code, access/refresh token or client secret. Add Another App creates a fresh attempt after completion/cancellation; an unfinished attempt must first be continued or cancelled.

Closing a section/window/app pauses setup. Reopening shows the app and Continue Setup at the saved configure/authorize stage. A code still available in the running app's memory is shown with its original expiry. Upstream retains only a code hash, so plaintext cannot be recovered after an app restart. The authorization stage remains saved and offers Generate New Code. Code expiry never sends the user back to client creation.

Unused drafts expire after seven days of inactivity only when backend state is readable and there is no correlated client or active pairing session. Authorized clients are never removed by draft expiry.

## Reliable completion and cancellation

Private local status adds `pairingSessionID` and `authorizationSessionID` per client and `setupManagementVersion: 1`. The initial authorization-code exchange correlates completion with the **actually consumed** pairing session, not the client's latest registration or a background token refresh. UI completion requires both the matching session ID and an unexpired authorization. This is authorization evidence, not a claim of live AI app health. Existing tokens and scopes remain unchanged.

Cancel Setup invalidates only this attempt's unused pairing sessions and pending authorization codes. It removes a correlated registration only if it has never been authorized and has no other pending exchange or valid token. Registrations with unknown ownership retain the existing ten-minute abandoned-registration cleanup. A completed authorized attempt is rejected by the cancellation endpoint and uses normal authorization management instead. Cancellation does not stop the Gate/Tunnel, alter Folders/Passcode, or revoke other authorizations. The draft remains if cancellation fails.

Existing running Gate services need one restart to expose the new setup metadata/control route. The UI offers Restart Gate and preserves existing authorizations and addresses; re-pairing existing apps is not required.

## Client instructions

Instructions were checked against official documentation on 2026-10-08:

- ChatGPT: Plugins → + → Add custom MCP server, enter the name/HTTPS MCP URL and select OAuth if asked. [Official OpenAI quickstart](https://developers.openai.com/plugins/build/app-quickstart).
- Claude: Customize → Connectors → + Add → Add custom connector. Team/organization configuration is performed by an owner under Organization settings → Connectors. Use sign-in authentication and automatic client registration for the current Boundas Gate server. Description is optional if Claude does not request it. [Official Claude guide](https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp).
- Other MCP App: generic custom MCP settings, with OAuth when asked.

Name, Description and Server URL have individually aligned Copy actions. Configure and authorization pages use three concise instruction rows; Continue and Back navigate the existing saved setup stages, and Cancel Setup is in the menu. The primary Server URL belongs to Connect an AI App; the Tunnel diagnostics sheet is the only Advanced exception.

## Changed files

UI and setup state:

- `Sources/C2CManager/SharedGatewayView.swift`
- `Sources/C2CManager/AIConnectionSetupView.swift` (new)
- `Sources/C2CManager/AISetupStore.swift` (new)
- `Sources/C2CManager/SecureAccessPresentation.swift` (new)
- `Sources/C2CManager/GateConnectionJourney.swift`
- `Sources/C2CManager/SharedGatewayStore.swift`
- `Sources/C2CManager/TunnelManagementView.swift`

Minimal setup/status plumbing:

- `Resources/Gateway/auth.mjs`
- `Resources/Gateway/connection-status.mjs`
- `Resources/Gateway/launcher.mjs`
- `Resources/Gateway/server.mjs`

Tests and documentation:

- `Tests/C2CManagerTests/AISetupStoreTests.swift` (new)
- `Tests/C2CManagerTests/SecureAccessPresentationTests.swift` (new)
- `Tests/Gateway/gateway.test.mjs`
- `Tests/Gateway/zero-folder-launcher.test.mjs`
- `docs/main-gate-setup-journey.md` (new)

The implementation tests use isolated temporary app data and local transport fixtures; authorization metadata does not claim real ChatGPT/Claude live connectivity. Latest packaged smoke-test coverage and suite results are recorded in [Acceptance — 2026-10-09](acceptance-2026-10-09.md).
