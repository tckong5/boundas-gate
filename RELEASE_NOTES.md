# Boundas Gate 1.2.1 (production build 8) — Released

This bug-fix release has passed production acceptance:
[Boundas Gate v1.2.1](https://github.com/tckong5/boundas-gate/releases/tag/v1.2.1).

## Fixes

- Fix Folder access being incorrectly rejected after a macOS restart or filesystem remount changes the device ID. Recovery requires successful verification through the original bookmark, with matching path and inode safety checks.
- Synchronize verified identity recovery from WorkspaceStore to the Gateway registry while preserving Folder UUIDs, c2cIDs, Gate settings, MCP URLs, OAuth credentials, Passcode policies, and authorization epochs. Synchronization never automatically re-enables a disabled Folder.
- Preserve fail-closed security: replacement Folders, unverifiable identities, and missing recovery evidence remain rejected. A matching inode alone is never sufficient.
- Show an explicit error when Main Gate cannot save sharing changes, and identify Folders that need relocation instead of showing only a brief loading state.
- Include the Folder relocation support completed after v1.2.0, retaining existing identities and authorization across renames and moves.

## Release identity and verification

- Version: `1.2.1`; production build: `8`; bundle identifier: `com.boundasgate.app`.
- **Ad-hoc signed and not Apple notarized.** macOS Gatekeeper may require manual approval with **Open Anyway**. Developer ID signing and notarization are intentionally deferred and are not release blockers.
- Sparkle integration is retained; the production appcast/update feed is not enabled yet.
- Focused identity checks passed: original-Folder remount recovery, replacement rejection, Gateway/WorkspaceStore synchronization, and existing-policy preservation. Production v1.2.1 passed Gateway, existing Folder, authenticated MCP read, and Main Gate save acceptance.
- Built from the verified isolated source snapshot containing the completed identity hotfix and necessary version/documentation changes.

## Release artifacts

```text
Boundas-Gate-1.2.1-arm64.zip
Boundas-Gate-1.2.1-arm64.dmg
SHA256SUMS.txt
```

---

# Boundas Gate 1.2.0 (production build 7) — Released

v1.2.0 is the published open-source public beta:
[Boundas Gate v1.2.0](https://github.com/tckong5/boundas-gate/releases/tag/v1.2.0).
It is **ad-hoc signed and not Apple notarized**. macOS Gatekeeper may require manual approval with **Open Anyway**.
The product version is 1.2.0 and the production build number is 7.

## Completed work

- Consistent Gate, Folder, Tunnel, and MCP Connection models across Main and Side Gates.
- Current Shared Secure Access shares a Tailscale identity while keeping routes, lifecycles, and authorization boundaries independent. Existing legacy fixed-address/external transport is retained until explicitly migrated.
- A consistent Secure Access → Connect an AI App → Ready to Use setup journey.
- Live Gate Activity Map showing Gate, AI app, Folder topology, and request activity.
- One owner for Side Gate runtime state, avoiding duplicate start, refresh, reconnect, and stale state.
- Boundas Gate branding and the `com.boundasgate.app` bundle identifier. Production data migration and Main Gate external → Shared Secure Access migration passed acceptance, retaining Gate identity, Folder settings, OAuth, and embedded identity continuity.
- Production MCP reads and clean quit/reopen acceptance completed.
- Closing the window leaves Gates running. Menu-bar Quit stops Side Gates, Main Gate, and verified helpers while retaining desiredRunning and persistent identities/authorization.
- Sparkle 2.10, Check for Updates, and the native About panel are implemented, with EdDSA verification for update archives. The production appcast URL is not configured/published; builds without a feed do not check for updates.
- Workspace state fails closed on corrupt configuration, invalid or duplicate Folder identities, duplicate canonical paths, and c2cID collisions, rather than treating them as an empty Folder list.
- Raw Debug defaults to the isolated `Boundas Gate Debug` profile. New User Test uses a separate profile and does not read production state.
- MIT License for Boundas Gate's own source; third-party Runtime licenses remain separate.
- Separate local/test ad-hoc and optional Developer ID/notarization build modes. Public mode fails on missing credentials instead of falling back to ad-hoc signing.
- Node/V8 hardened-runtime entitlements narrowed through testing to `com.apple.security.cs.allow-jit`, without broad executable-memory or other additional entitlements.

## Developments after v1.2.0

- Folder relocation was added in commit `8bc7f59` and is included in v1.2.1. Renames and moves preserve UUID, c2cID, Gate, OAuth, and Passcode policy. It is not part of the v1.2.0 release assets.
- The Local Network permission investigation currently requires no Boundas code change. The legacy Tailscale Network Extension is the leading suspected cause, but reboot acceptance after disabling it is pending; the root cause is not conclusively verified.

## Release identity

| Item | Value |
| --- | --- |
| Product | Boundas Gate |
| Bundle identifier | `com.boundasgate.app` |
| New User Test bundle identifier | `com.boundasgate.app.new-user-test` |
| Version | `1.2.0` |
| Production build | `7` |
| License | MIT, for Boundas Gate's own source only |

## Acceptance status

The full-suite counts below are historical release-preparation baselines, not a claim that every later commit reran all suites. Subsequent migration, Quit, and Sparkle changes used relevant focused tests and packaged checks.

| Check | Result |
| --- | --- |
| Swift suite | PASS, 128 tests |
| Gateway/Tailscale Node suite | PASS, 101 tests |
| Go tunnel tests | PASS, `go test -race ./...` |
| Local/test ad-hoc signing | PASS; bundle and extracted ZIP app pass `codesign --verify --deep --strict` |
| Developer ID signing | Implemented but intentionally deferred; requires `BOUNDAS_CODESIGN_IDENTITY` |
| Notarization/stapling/Gatekeeper | Not performed; requires `BOUNDAS_NOTARY_PROFILE` and Developer ID credentials |
| Portable release smoke | PASS; isolated bundle, userspace core, login URL, and retry identity |

Production migration, MCP reads, and quit/reopen identity continuity passed acceptance. The pre-public repository cleanup did not touch production data or runtime.

## Release commands

Local ad-hoc builds:

```sh
./scripts/build-app.sh
./scripts/package-release.sh
```

The optional Developer ID/notarization mode requires the following configuration. The published ad-hoc public beta does not use this mode:

```sh
BOUNDAS_BUILD_MODE=public
BOUNDAS_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
BOUNDAS_NOTARY_PROFILE="boundas-release"
```

`BOUNDAS_NOTARY_PROFILE` names an `xcrun notarytool` Keychain profile. Public mode signs nested Mach-O components, enables hardened runtime and timestamps, submits and waits for notarization, staples tickets, and runs `codesign`/`spctl` verification. Missing credentials stop this mode rather than reporting success.

## Historical v1.2.0 distribution layout

```text
Boundas Gate.app
Boundas-Gate-1.2.0-arm64.zip
Boundas-Gate-1.2.0-arm64.dmg
SHA256SUMS.txt
```

New User Test remains at:

```text
.build/apps/Boundas Gate New User Test.app
```

## Next steps

Configuring the production appcast URL and publishing signed Sparkle updates remain optional future work; the feed is disabled. Production migration, MCP reads, Quit/reopen, and Folder relocation acceptance are complete. Developer ID signing and notarization are intentionally deferred without Apple Developer Program enrollment. The v1.2.1 release is documented at the top of this file.
