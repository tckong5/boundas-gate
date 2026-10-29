# Boundas Gate — Security / Robustness Review

Date: 2026-10-08. This historical review used the then-current working tree, preserving earlier uncommitted lifecycle, Tunnel-management, and UI work. It performed no reset, clean, commit, or push, added no ngrok, and did not refactor TunnelProvider.

## Results

| Priority/issue | Fix and verification |
| --- | --- |
| P0 Git option injection | Resolve MCP paths through Workspace; require `--` in C2C Git operations and a fixed read-command/options allowlist in the repository wrapper; test real option-looking filenames end to end |
| P0 Public OAuth abuse | Retain pairing/PKCE; add socket-address and Gate-wide rate limits, a 128-registration cap, abandoned cleanup, 256 pending admissions, and body/type limits |
| P1 Configure lock | Atomic owner metadata with PID/createdAt/random token; no age-based takeover of live owners; recover dead/missing/corrupt owners and clean only with matching ownership |
| P1 Runtime/PID reuse | Match runtime, health, private info, and daemon arguments by nonce; clean only provably stale records, retain uncertain ownership, and never signal a stale PID |
| P2 Passcode policy | Share Folder policy/FolderAccess across Gates; provide Side generate/unlock/revoke routes and the existing popover; scope temporary grants by Gate, credential, Folder, conversation, and expiry |
| P3 Resource lookup | Fail clearly on missing packaged resources; allow source fallback only in unbundled Debug |
| P3 Diagnostics | Preserve sanitized CLI stack/stderr and log exit status/stderr, never stdout, in private files/directories |
| P3 Registry reads | One allowlist snapshot per `active()` operation, reused by launcher status |
| P3 Duplicate/assets | Remove excluded, unused `ConnectionStatusView 2.swift`; retain packaging/design assets and assets with uncertain purpose |

## Git end-to-end trace

1. MCP `git_diff` accepts mode/path/pagination, not arbitrary Git flags. Every handler checks Gate, Folder ACL, and Passcode. `Workspace.resolve(path).rel` enforces boundaries, traversal, symlink, and secret restrictions.
2. Installed/bundled C2C inventory uses `git diff --name-status -z --find-renames=1% [--cached|HEAD] -- .`; patch batches use `git diff --no-color --find-renames=1% [--cached|HEAD] -- :(literal)<path>`.
3. `readGit` points PATH at the repository-owned wrapper, clears inherited `GIT_*`, disables system/global configuration, fsmonitor, and hooks, and fails closed on custom filters.
4. The wrapper allows fixed diff/status/rev-parse read forms. Diff requires `--` and at least one path. Options before it are allowlisted; `--output`, `--config`, `-c`, and `--no-index` are rejected. `--output=...` after the separator is a filename only.
5. Invoke `/usr/bin/git` with `core.fsmonitor=false`, `core.hooksPath=/dev/null`, and diff options `--no-ext-diff --no-textconv`.

Tests created real repositories containing `--output=should-not-exist`, `--config=other`, and `-c` filenames, modified them, and read diffs through MCP. Diffs succeeded without creating output files or changing Git config bytes. Arbitrary options/write commands were rejected.

## OAuth and pairing protection

Retained and tested upstream C2C guarantees:

- Five-minute, one-time pairing codes; a new code replaces the old session.
- Cryptographically random codes, hashed/constant-time verification, five failures per session, and the existing ten attempts per IP per minute.
- Explicit local pairing is required to produce an authorization code; registration alone grants no token/Folder access.
- Five-minute, one-time authorization codes with PKCE S256; wrong verifiers, consumed codes, and replay fail.
- Existing access/refresh TTLs, refresh rotation, scope filtering, revocation, and Gate-bound bearer validation.

Additional protections apply to Main and Side Gates:

- `/oauth/register`: 20 requests per socket address per minute. Authorize/token/revoke: 60 each, with double-sized Gate-wide budgets.
- Public X-Forwarded-For/CF headers are not trusted as rate-limit identities.
- Rate-limit maps are bounded to 512 keys with expiry cleanup; the pairing IP map also has a 512-entry cap.
- At most 128 registrations per Gate. Unauthorized/abandoned registrations expire after ten minutes; clients with valid access/refresh authorization remain.
- Previously authorized client metadata without valid tokens is retained for at most 30 days; expired authorization codes are removed. Cleanup runs each minute and on OAuth requests.
- At most 256 pending authorization admissions per ten minutes, including concurrent unfinished responses, alongside upstream TTLs. Failed responses release reservations.
- OAuth bodies are limited to 32 KB, redirect URIs to eight of 2,048 characters each, and strings to 4,096 characters; invalid types are rejected.
- Invalid registration/pairing creates no persisted token; registration caps are checked before writing.

Abandoned cleanup does not remove an AI client with a valid refresh token. At capacity, wait for cleanup or remove inactive registrations; valid grants are never evicted automatically.

## Runtime and configure locks

`config.lock/owner.json` is published through a private temporary file/rename and contains PID, createdAt, and a unique token. Owner cleanup requires matching directory inode/device and owner token. Stale reclamation uses an exclusive claim and rechecks ownership to avoid competing cleanup.

- Active PIDs are never reclaimed based on age; permission errors or uncertain liveness do not mean dead.
- Reclaim only a definitely absent PID. Missing/malformed metadata uses a 30-second grace period and mtime.
- Corrupt reclamation metadata remains recoverable instead of permanently locking configuration.

Each new daemon has a 32-random-byte hex nonce and startedAt. Runtime, `/health`, private info, and argv share this identity. Healthy status requires Gate/service/nonce agreement and authenticated private admin identity, including Gate/PID checks.

For unavailable/foreign endpoints, ownership evidence requires the same UID, exact daemon entrypoint, and nonce arguments. Only demonstrably dead/unrelated processes permit stale-record cleanup. Unknown ownership retains the record and reports attention without killing. Cleanup compares PID/admin token/nonce so an old daemon cannot delete a new record. Side decommission rechecks stopped state before cleanup.

Legacy runtimes without a nonce require matching health and authenticated private identity. Main reopen/managed Side status can safely stop the old daemon; reopening loads the new core without revoking valid MCP authorization.

## Folder Passcodes and temporary access

Policy is **Folder-level**. Main sharing and Side membership are independent. A Side-only Folder gets disabled Main registry policy metadata without becoming Main-shared. Missing/mismatched policy fails closed.

Passcode ON no longer permanently disables Side access. Side detail reuses the same popover, and private `code-policy`, `folder-code`, and `lock-folder` routes reuse `FolderAccess`. Public `unlock_workspace` and protected tools use the same mechanism as Main.

| Boundary | Runtime enforcement |
| --- | --- |
| Gate | Independent AuthStores/codes/grants with explicit gateID; reject Main-to-Side and Side-A-to-Side-B tokens |
| Authorization | Bind keys to the OAuth access-credential hash; another credential cannot use them even with the same conversation ID |
| Folder | Validate Folder ID, membership epoch, shared policy epoch, and current ACL |
| Conversation | Prefer `openai/session`; otherwise require explicit `session_id`. This additional binding is not a standalone credential or proof of the AI app's actual chat identity |
| Expiry | Codes last five minutes and are single-use; keys last at most 30 minutes and never exceed OAuth token expiry |
| Revocation | Revoke/Invalidate/Generate New Code clears that Gate's Folder codes/keys; policy toggles change the shared epoch, invalidating old grants across Main/Side |

All Folder operations, including existing Side execution-read tools, revalidate ACL/key before and after work. In-flight revocation prevents output disclosure. Main unlock does not transfer to Side. Disabling Main sharing does not change Side ACL; Side removal does not change Folder policy/Main.

Temporary codes/keys exist only in daemon memory. Restart requires a new Folder code, **not OAuth re-pairing**. Side reuses its existing C2C auth file; valid legacy operation-scope tokens still pass the same Gate-owned AuthStore/bearer checks and never become cross-Gate grants.

## Packaging, diagnostics, and assets

Missing bundle resources, Node, or CLI fail clearly with the missing resource identified. Developer `#filePath` fallback is limited to unbundled Debug, never Release.

Gateway/Side stderr retains stacks and underlying stderr after masking Bearer credentials, tokens, secrets, pairing/Folder codes, access keys, passwords, and URL credentials. Swift logs exit status and sanitized stderr in private diagnostics files. Stdout is never logged because it may contain pairing codes or file contents. UI shows a short message rather than raw stacks. Strong redaction may also mask long identifiers.

The New User Test build copies the updated Git wrapper and preserves its executable bit.

Asset audit at the time:

- `Resources/AppIcon.png`: used by README and ICNS packaging; retained.
- `Resources/ChatGPT Image 28 Sept 2026, 18_39_56.png`: packaged menu-bar artwork; retained.
- `Resources/AppIcon-original.png`: possible design source, not proven accidental; retained.
- `ConnectionStatusView 2.swift`: excluded Finder duplicate with no legitimate reference; removed.

## Files changed in this review

Earlier uncommitted work was preserved and is not counted as newly introduced here.

- `Package.swift`
- Gateway `{access,diagnostics,launcher,oauth-security,registry,runtime-instance,server,side-lifecycle,side-registry}.mjs`
- `Resources/Gateway/git`
- Tailscale `{owner-lock,provider}.mjs`
- Swift `{C2CClient,C2CManagerApp,GatewayDiagnosticsLog,MainGateFolderPasscodeButton,RuntimePaths,SharedGatewayStore}.swift`
- Removed `Sources/C2CManager/ConnectionStatusView 2.swift`
- Gateway `{diagnostics,gateway,git-security,oauth-security,passcode-gates,runtime-instance,side-lifecycle}.test.mjs`
- `Tests/Tailscale/owner-lock.test.mjs`
- Swift `{GatewayDiagnosticsLogTests,RuntimePathsTests}.swift`
- `scripts/build-new-user-app.sh`
- Product invariants, the gate-contract implementation report marking the temporary restriction superseded, and this report.

## Tests and build

| Check | Result |
| --- | --- |
| Debug build | PASS |
| Swift resource/diagnostics/lifecycle/UI tests | 58/58 PASS |
| Gateway/Tailscale Node tests, including security regressions | 77/77 PASS |
| Main/Side daemons, legacy auth migration, decommission/re-add | PASS |
| MCP Git special filenames; real reads without writes/config mutation | PASS |
| OAuth abuse, pairing TTL/replay, PKCE, pending cap | PASS |
| Live contention, dead/missing/malformed owners, stale reclaim | PASS |
| Reboot/PID reuse, foreign health, nonce mismatch, owner-only cleanup | PASS |
| Main/Side protected reads, unlock isolation, expiry/revocation/Off ACL | PASS |
| Zero-Folder startup/pair/reconnect/crash recovery | PASS |

Node integration used bundled C2C **0.1.3** and MCP SDK **1.30.0**, including local HTTP MCP, real Git, Side daemon subprocesses, and a legacy C2C daemon. External provider reachability used fixtures without signing users in/out.

## Verification boundary and next steps at the time

The external `/Users/developer/codex-with-chatgpt` source and bundled compiled modules were inspected without modifying that repository. The adapters/wrapper protect App-managed Main/Side Gates; directly running upstream C2C CLI does not automatically acquire the added OAuth limits, nonce, or Folder policy protections.

This review did not verify future backend versions, real public Tailscale/Cloudflare reachability, AI-site live requests, or complete manual UI behavior. Existing provider choices and fixed endpoint identities were retained without provider migration.

Applying the new Debug app to an existing Gate required reopening it once to load the new daemon; existing OAuth pairing survived. Release archives were not published/updated, and real production state/runtime was not changed in this review.
