# Boundas Gate acceptance — 2026-10-09

## Acceptance and behavior freeze

The behavior recorded in this report was accepted and frozen. This round organized repository history; Activity Map curvature, breathing, AI icons, and other visual polish were deferred to a later iteration.

The latest source was built with `scripts/build-new-user-app.sh`. Acceptance used:

`dist/Boundas Gate New User Test.app` (build 45, isolated new-user-test data profile).

Only that packaged app was launched; the raw `.build/debug/C2CManager` executable was not used for smoke testing. `Runtime/bin/boundas-tunnel`, `node`, and `cloudflared` were present and executable. Gateway and Tailscale resources matched the source file by file.

## Packaged smoke test

| Check | Result and evidence |
| --- | --- |
| Main Gate local Open/Close | PASS; Close retained Folders/MCP authorization, and Open started only the local host without requesting Tailscale login |
| Secure Access | PASS; explicit Set Up enabled the shared embedded route and opened the Gate |
| Existing MCP authorization | PASS; existing ChatGPT authorization survived Close/Open and quit/reopen |
| New MCP authorization | PASS; a disposable MCP client completed real registration, pairing, OAuth PKCE, and token exchange through the packaged service |
| Add Folder/Main sharing | PASS; an isolated Folder was added by path and shared; Main/Side membership operated independently |
| Live Map topology | PASS; effective AI/Folder nodes and Gate-to-Folder connectors were correct |
| Real MCP traffic | PASS; six real read_file/search_workspace calls, including a public HTTPS read, produced six successful requestStarted/requestFinished pairs; request photons, active Folders, responses, and AI arrival indicators were visually checked |
| Zero MCP Connections after onboarding | PASS; revoking the disposable client kept Gate Open and displayed an empty map with Connect an AI App, without restarting first-run setup |
| Side Gate Open/Close | PASS; a new Side Gate reused the signed-in shared account without another login; closing it left Main and other Side Gates running |
| Folder Passcode policy | PASS; protected fixture reads without an access key were denied; the same read succeeded after invalidation/turning protection off; the policy was restored to Off afterward |
| Quit/reopen | PASS; the packaged app recovered Gate Open, the existing ChatGPT authorization, and the two original Main Folders |
| Fixture cleanup | PASS; decommissioning the test Side Gate retained its Folder; the test Folder was then removed, original authorization bytes and client identities were restored/verified, and temporary credentials/Folders were cleaned up |

The new authorization used a real OAuth/MCP test client, not simulated UI state. This does not claim complete manual onboarding or live-session health testing of third-party ChatGPT/Claude apps.

## Acceptance blockers and limited fixes

1. **Missing map connector path origin:** move an empty static Path to the Gate before adding its existing cubic Bézier. Added a geometry regression test without changing curvature/topology.
2. **Missing fast-request arrival feedback:** cover the response phase with Folder arrival feedback and deduplicate by requestID, so fast requests do not skip arrival pulses. Telemetry and concurrency semantics stayed unchanged.
3. **Folder path alias differed from server canonical path:** use filesystem realpath for new record paths/IDs, avoiding `/tmp` versus `/private/tmp` sharing failures. Added symlink canonicalization/deduplication tests.
4. Made the packaging script executable while retaining bundle profiles/resources; build number and date identify the new package.

## Tests and build

- Swift: 103 tests, zero failures.
- Gateway/Tailscale Node: 97 tests, zero failures.
- Go Tunnel: all passed.
- Debug build: passed.
- Portable runtime smoke passed using a clean isolated copy of the same New User Test bundle: valid signatures, no system Node/C2C dependency, and persistent identity across fresh embedded startup/login retry.
- Each coherent staged commit was exported to an isolated snapshot and verified with a Debug build; Native/Gateway snapshots also ran their relevant suites.
- The full suites and Debug build were rerun after cleanup; the delivery report records the final results.

Coverage included zero-Folder startup/pair/reconnect, Side membership/decommission/retry, Gate authorization isolation, Passcodes, MCP revocation, shared route nonces/port reuse, DNS reconnect guards, setup persistence, and activity privacy/concurrency/Reduce Motion.

## Obsolete source

These views had been replaced by the shared journey and had no remaining callers:

- `Sources/C2CManager/ConnectionRepairGuide.swift`
- `Sources/C2CManager/ConnectionStatusView.swift`
- `Sources/C2CManager/StableConnectionView.swift`

`MainGateFolderPasscodeButton.swift` was renamed to `FolderPasscodeButton.swift`, retaining its implementation for reuse by Main and Side Gates.

Other modified/untracked source, tests, and documentation belonged to completed work. Build output, local credentials, temporary scripts/logs, and screenshot captures were not added to Git.

## Delivery limitations at the time

The repository was on a macOS Documents File Provider volume. FinderInfo/File Provider extended attributes could reappear on the final app copy and cause strict codesign resource-fork failures at that location. Script staging verification passed; the specified dist app launched, and resource bytes were checked. This was a local filesystem-metadata limitation rather than incomplete MCP/Tunnel functionality. System settings were not changed.

No functional blocker remained. This round added no provider framework/ngrok, performed no push, and created no branch.
