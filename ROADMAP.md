# Boundas Gate — Roadmap

## Direction: GitHub first, built for everyday use

Project name: **Boundas Gate**. Public repository: [`tckong5/boundas-gate`](https://github.com/tckong5/boundas-gate). The app name and build artifacts use this branding; internal C2C backend names and existing state paths remain compatible.

> Give AI access to your local workspace without giving it access to your whole computer.

Long-term direction: **A permission gateway for AI agents accessing your local machine.**

Start with an open-source tool the developer uses regularly and a small group of friends can evaluate. Consider productization only after the boundary model demonstrates practical value.

The core interaction is choosing a project, permissions, permitted actions, and authorization duration, with the gateway enforcing those boundaries.

Priorities: **Everyday reliability → Verifiable permission boundaries → Clear UI → Tool expansion**.

This is an evolution plan without promised release dates. Unchecked items are not claims about capabilities already available in the app.

### Trial and productization criteria

- [ ] Use the tool in everyday projects and record setup, reconnection, worktree-switching, and pairing issues.
- [ ] Invite a small group of friends to test installation, failures, and common workflows on their own Macs.
- [ ] Verify that users understand the boundary model and can configure and revoke permissions clearly.
- [ ] Compare existing tools on the same tasks to establish the permission model's practical advantage.
- [ ] Record verification of out-of-scope operation rejection, permission expiration, and revocation.

If convenient MCP startup is the main value, maintain an open-source utility. Consider productization when users consistently choose its clear, reliable boundary model and everyday usage supports that direction. Reliability and user feedback guide the current work.

## V1: Multi-Workspace Manager foundation

- [x] Native macOS menu-bar app.
- [x] Boundas Gate display name, app icon with transparent surroundings, and menu-bar artwork using the original corner-frame/infinity motif.
- [x] Add ordinary folders, Git repositories, and Git worktrees.
- [x] Enter or paste absolute paths and `~/` paths.
- [x] Independent bridge and tunnel Start/Restart/Stop per workspace.
- [x] Manage workspace configuration and display status, port, PID, and MCP URL.
- [x] Copy URL, Open Folder, Open Logs, and Open ChatGPT.
- [x] One-time pairing codes, expiration, and code regeneration.
- [x] Expose only explicitly added folders to C2C.

The original C2C-backed V1 used **one ChatGPT connector per workspace**. The current shared Read Only gateway is described under V4 below. The planned Read/Edit/Developer/Custom policy engine is not implemented; available tools and restrictions remain enforced by the existing backend.

### V1.1: Public GitHub distribution

Distribution approach: **Public GitHub repository, GitHub first**.

- [x] Prepare the repository, README, setup guide, architecture documentation, and licensing.
- [x] Bundle the verified C2C 0.1.3 build and its runtime dependencies in 1.2.0, with version/source records and original license notices.
- [x] Bundle Node.js/cloudflared/C2C and provide reinstall guidance when bundle resources are missing.
- [x] Provide a clean installation flow independent of the developer's environment.
- [x] Publish app ZIPs/DMGs, version information, and installation instructions on GitHub Releases.
- [x] Identify Apple Silicon and macOS 14+ support; other architectures are not provided yet.
- [ ] Automate build/release workflows; distribution currently uses the existing manual ad-hoc release path.
- [ ] Verify Add Workspace → Start → Pair → MCP access in a completely new user environment.

Public scope includes app source, documentation, build scripts, and distribution packages. Workspace configuration, OAuth tokens, pairing codes, logs, private projects, and signing credentials remain local.

### 1.2.0 trial package: Bundled runtime and connection core

- [x] Include Node.js, C2C, cloudflared, and original dependency licenses in the app.
- [x] Default new shared setups to tsnet userspace networking, private IPC, and persistent identity, without creating an OS VPN interface.
- [x] Provide embedded account login and HTTPS/Funnel authorization; public ingress accepts only MCP/OAuth/health and rejects admin routes.
- [x] Preserve existing external fixed-address transport, refusing identity/URL substitution while retaining OAuth and dynamic sharing.
- [x] Verify CLI, embedded core, and login links in an empty HOME without system Node/C2C paths.
- [ ] Complete new-account embedded Funnel → ChatGPT pairing → MCP acceptance, testing on another physical Mac and alongside VPNs.
- [x] Provide explicit Main Gate external → Shared Secure Access migration; production migration, MCP reads, and restart identity continuity passed acceptance. Migration is never automatic.
- [x] Produce local DMGs/ZIPs, installation instructions, and SHA256SUMS; verify signatures after extraction to clean staging.
- [x] Verify that the original Plugin can list shared Folders and read files after the 1.2.0 bundled runtime restarts the existing shared Gateway, preserving URL/OAuth.
- [x] Publish DMG/ZIP assets and release notes on GitHub Releases; v1.2.0 is published.
- [ ] Complete first-launch acceptance on a clean Mac; Developer ID signing and notarization are intentionally deferred, not release blockers.
- [x] Integrate Sparkle 2.10, EdDSA verification, native update/About UI, isolated local tests, and appcast-signing tooling.
- [ ] Configure the production GitHub/HTTPS appcast URL and separately approve signed-update publication; builds without a feed keep checks disabled.
- [x] Keep Gates running on window close; explicit menu-bar Quit stops verified runtimes/helpers while preserving desiredRunning, identity, OAuth, and Folder state.
- [x] Preserve Folder UUID, c2cID, Gate, OAuth, and Passcode policy across relocation; production relocation acceptance passed. This was added after v1.2.0.

### Intentionally deferred

- Developer ID signing, Apple notarization, and stapling are intentionally skipped because the project is not enrolled in the Apple Developer Program. Ad-hoc GitHub Releases and Gatekeeper installation guidance remain supported.

### V1.2: Everyday use and connection reliability

- [ ] Complete setup through the UI after one installation, reducing manual cloudflared, MCP, and port handling.
- [x] Add a trial Tailscale Funnel fixed-address option, installation/login checks, and authorization guidance using C2C OAuth with independent workspace endpoints.
- [ ] Verify fixed-address access with real Tailscale accounts and ChatGPT. Independent workspace access has been confirmed; restart and sleep scenarios need continued verification.
- [ ] Verify endpoint stability after Stop/Restart; retain optional Quick Tunnel with clear changing-URL behavior.
- [x] Preserve the shared gateway address across real Stop/Start, with local/public health and OAuth discovery checks; 1.1.0 also passed real post-restart calls through the existing Plugin.
- [x] Persist the shared fixed address, user running intent, and recovery preferences; normal reconnection restores the tunnel while retaining OAuth/root grants.
- [x] Recover an open shared connection during polling and after Mac wake, with backoff; a manually stopped Gate stays stopped.
- [x] Reject automatic replacement of a changed fixed address and identify the existing account/device. Tests cover old access/refresh tokens across gateway restart and Passcode capabilities across tunnel reconnection.
- [ ] Handle sleep, network changes, disconnections, and errors without stale Running/URL displays.
- [ ] Clearly present connector configuration, pairing, and reconnection state.
- [x] Periodically check local/public endpoints, workspace ID, OAuth discovery URLs, and Bridge/Tunnel URL consistency.
- [x] Provide connection checking/recovery UI; a running process alone does not establish public reachability.
- [x] Retain URL history, compare it with the confirmed ChatGPT Server URL, and prompt for updates.
- [x] Provide nontechnical recovery guidance, primary actions, Mac auto-reconnect, ChatGPT field instructions, pairing codes, and read-only tests.
- [x] Hide technical detail by default and provide next steps and copyable support information on failure.
- [ ] Verify these behaviors during everyday use and friend trials before declaring stable-release readiness.

## V2: Workspace permissions and controlled editing

Each workspace will support an independent access profile. New workspaces will default to **Read (Read Only)**.

| Profile | Files | Git | Commands |
| --- | --- | --- | --- |
| Read (Read Only) | list/read/search | status/diff | None |
| Edit (Read & Write) | Read features plus apply patch, create, rename, edit | status/diff | None |
| Developer | Edit features | status/diff; write operations separately authorized | Enabled test/build/lint profiles |
| Custom | Per-tool grants | Per-operation grants | Per-profile grants |

- [ ] Show effective Access, Files, Git, Tests, Build, Shell, Network, and Secrets settings in the UI.
- [ ] Implement a backend policy engine that checks workspace, tool, and operation permissions on every call.
- [ ] Reflect permissions in tool discovery and reject direct calls to disabled tools server-side.
- [ ] Apply permission changes immediately; existing sessions and credentials cannot retain revoked capabilities.
- [ ] Provide file-write previews, atomic updates, and traceable records.
- [ ] Control Git add/commit separately; require distinct permission and confirmation for push, reset, clean, and similar operations.
- [ ] Improve Git-aware editing with patch previews, conflict guidance, change review, and authorized test/build workflows.

### Activity logs, authorization duration, and revocation

- [ ] Show when an AI read, changed, or executed something, including allowed/denied results and the permissions used.
- [ ] Record workspace, client/session, tool, resource, time, and result, with user-controlled sensitive-data handling and retention.
- [ ] Support persistent grants, timed grants, and session-only grants.
- [ ] Allow immediate user revocation; reject new operations, revoke related sessions/credentials, and stop related execution.
- [ ] Enforce expiration in the backend across app restarts, sleep, and clock changes.

Future Custom profile example, **not implemented**:

```yaml
workspace: NetNavi
access: Custom
files: Edit
git: ReadOnly
commands: [pytest]
network: false
secrets: false
grant:
  scope: session
  durationMinutes: 30
```

This proposed profile permits editing one workspace and running its authorized pytest profile for at most 30 minutes in the current session. Command, subprocess, network, and secret restrictions must pass V3 isolation acceptance before being enabled.

### Four backend-enforced boundaries

| Boundary | Requirement |
| --- | --- |
| Workspace | Resolved paths stay within the authorized root; reject traversal, symlink escape, and check/access races |
| Tool | Validate each tool/action against policy without relying on the AI app to remember restrictions |
| Command | Restrict executable, argv, cwd, environment, timeout, and resources; apply the same limits to subprocesses |
| Secret | Block `.env`, credentials, and private keys by default; check file, search, diff, log, and command-output leak paths |

Git worktrees point to metadata outside their root through `.git`. Git tools need a separate controlled interface for necessary metadata access, with explicit limits on shared refs/objects. Ordinary file tools do not gain access to other workspaces as a result.

## V3: Developer commands and execution isolation

**Developer execution requires verifiable isolation.** A cwd, command allowlist, or a UI label saying “workspace only” cannot constrain project scripts and subprocesses.

- [ ] Adopt verified OS/container isolation for filesystem, network, and subprocess access.
- [ ] Disable Developer execution when isolation is unavailable or unverifiable, retaining verified safe tools.
- [ ] Provide test/build/lint profiles with user-reviewed commands.
- [ ] Execute explicit executable + argv; free-form shell and `bash -c` are not default profiles.
- [ ] Treat package scripts, build hooks, and tests as executable code subject to the same isolation.
- [ ] Disable command network access by default, with independently authorized destinations; separate command permissions from gateway/tunnel networking.
- [ ] Deny secret access by default and inject only specifically authorized secrets, never the full login-shell environment.
- [ ] Bound execution time, output size, process count, and cancellation; stop subprocesses together.
- [ ] Show required permissions before execution and retain appropriately redacted records afterward.

Acceptance must cover cross-root reads/writes, symlinks and races, shell escape, subprocesses, Git hooks, networking, secret exposure, and processes left after cancellation.

## V4: Multi-root MCP Gateway

**Read Only is implemented.** Users can select added roots, start a shared Tailscale endpoint, generate pairing codes, and revoke access. One connector exposes seven read-only tools, with an explicit workspace ID on each applicable call. Since 1.1.0, instance OAuth and dynamic sharing allow new shared roots without re-pairing. Edit/Developer profiles, a complete activity log, and execution isolation are not implemented.

One ChatGPT connector can access multiple authorized workspaces:

```text
ChatGPT
   ↓
Boundas Gate
   ├─ Policy engine
   ├─ NetNavi   → Developer
   ├─ HKBench   → Edit
   └─ Live2D    → Read Only
```

The mixed permission profiles above illustrate the future direction.

- [x] Require explicit workspace IDs on tool calls and enforce authorization server-side, except when listing authorized workspaces.
- [x] Bind Read Only connector/OAuth tokens to the gateway instance, preserve operation scopes, and read current sharing state on every call.
- [ ] Provide independent permissions, execution environments, logs, and status per root; separately authorize cross-workspace operations.
- [x] Make newly selected and saved roots available to existing connectors/refresh tokens without re-pairing, including legacy token compatibility.
- [x] Reject access immediately after disabling/removing a Read Only root; recheck before returning asynchronous reads and support global OAuth revocation in the UI.
- [x] Validate root ID, source ID, canonical path, and current sharing. Re-sharing does not revive revoked asynchronous output or old Passcode grants.
- [x] Offer optional Folder Passcodes, off by default: five-minute one-time codes exchange for capabilities lasting at most 30 minutes, checked against Folder, OAuth token, conversation metadata, and current policy; immediate locking is supported.
- [ ] Verify real ChatGPT Passcode unlock, `openai/session` delivery, cross-chat rejection, and re-unlock after OAuth token rotation. Conversation metadata is an additional binding, not an independent identity credential.
- [x] Preserve V1's one-connector-per-workspace workflow.
- [x] In 1.1.0, verify the existing MCP Plugin moving from fewer to more roots, adding/disabling a test root, file reads, boundary rejection, and fixed-address gateway restart without re-OAuth/pairing. Settings used the same App store/shared service; app clicks, Mac reboot, and Passcode metadata were outside that live acceptance scope.

## V5: Additional local tools

After verifying the preceding permissions and isolation:

- [ ] Browser: separately authorized browser sessions, sites, and actions.
- [ ] Excel/documents: explicitly selected documents and read/write capabilities.
- [ ] Codex escalation: explicit tasks, workspaces, actions, and returned results.
- [ ] Other local tools: the same policy, revocation, and logging model.

Define resource scope, permissions, isolation, and acceptance criteria before adding each tool. Tool count is not the main progress measure.

### Boundaries beyond the workspace

| Boundary | Long-term control scope |
| --- | --- |
| Folder | Explicit roots and read/write scope |
| Git repository | Repository/worktree, metadata, and permitted Git operations |
| Command | Authorized executable, argv, execution profile, and resources |
| Network | Allowed destinations, connectivity, and purpose |
| Browser | Session, sites, and actions |
| App/document | Explicit applications, documents, and capabilities |
| Time/session | Expiration, session scope, and immediate revocation |

Workspace is the first resource boundary. Expand only as needed, with backend enforcement and acceptance evidence for every boundary.

## Maturity and future productization criteria

1. Users can clearly see each workspace's scope, access, and runtime state.
2. The server and execution environment enforce permissions independently of model behavior.
3. Files, Git, commands, network, and secrets can be configured and revoked separately.
4. New tools cannot broaden an existing workspace or connector grant.
5. Release documentation promises only implemented and verified security capabilities.
6. Connectivity is reliable, setup is straightforward, activity is traceable, and expiration/revocation are verifiable.
7. The developer and trial users use the tool regularly and can identify the boundary model's practical value over alternatives.
