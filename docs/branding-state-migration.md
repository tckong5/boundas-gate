# Boundas Gate branding and state migration

## Identity and profiles

- Production: `~/Library/Application Support/Boundas Gate`.
- Legacy backup: `~/Library/Application Support/C2C Workspace Manager`.
- New User Test: `~/Library/Application Support/Boundas Gate New User Test`.
- The C2C dependency retains its production state in `~/Library/Application Support/codex-with-chatgpt`. Moving this separate backend store would risk existing Side Gate credentials/preferences and other C2C consumers. The test profile uses its own `c2c/` subdirectory.
- Package/target/executable names `C2CWorkspaceManager` and `C2CManager`, and bundled `Runtime/C2C`, are intentionally internal.
- Production bundle identifier remains `local.c2c.WorkspaceManager`; test identifier remains `local.c2c.WorkspaceManager.new-user-test`.

## Safe one-time migration

The app prepares production state before constructing any stores, recovery tasks or child processes.

1. An existing valid new directory wins, even when legacy data also exists. No merge or overwrite occurs.
2. Legacy-only data is copied to a private sibling staging directory. File bytes and permission modes are compared with the source before publication; the source is checked again for changes.
3. An exclusive migration lock coordinates app launches. Atomic exclusive rename publishes the entire directory without replacing a concurrently created profile.
4. Copy/verification/publication failure removes the temporary copy and shows a startup error. No store is created and no fresh Gate identity is generated.
5. Legacy data remains untouched as backup. A live PID in legacy runtime records blocks migration; close the previous Gate before reopening the app. An uncertain runtime is treated conservatively.
6. Fresh installation uses the new location; normal existing store initialization creates its files.
7. Test profile startup never inspects or migrates production data. Inherited production environment paths are overridden for all test children.

The Swift parent and children explicitly share `BOUNDAS_WORKSPACES_FILE`, `BOUNDAS_GATEWAY_DIR`, `BOUNDAS_STATE_DIR` and `C2C_STATE_DIR`. Production overrides remain supported and are resolved by both parent and child; the isolated test profile always overrides them.

Node defaults use the canonical Boundas Gate directory. Direct invocation with legacy-only state fails closed and instructs the user to open the app for migration; it cannot silently generate an independent empty Gate. Module imports alone have no migration side effects.

## Build artifacts

Production `dist/` contains exactly:

```text
Boundas Gate.app
Boundas-Gate-1.2.0-arm64.zip
Boundas-Gate-1.2.0-arm64.dmg
SHA256SUMS.txt
```

`scripts/build-new-user-app.sh` replaces `.build/apps/Boundas Gate New User Test.app`. It retains one current test bundle, does not create numbered copies or BuildNN archives, and reuses the verified portable production runtime. `.build/` and `dist/` remain ignored.

Historical acceptance reports retain their original paths/build numbers as historical evidence.

## Acceptance — 2026-10-09

Production was not launched, stopped or migrated during verification. An isolated copy of the existing production profile was migrated using the actual Swift migration implementation. Only the replica's runtime record was removed to simulate a stopped Gate.

Before/after metadata matched:

- Gate ID (synthetic reporting identity): `012345abc678`.
- Folder count preserved; all Folder IDs matched (synthetic reporting count: 3; actual count omitted).
- Authorized client count preserved (synthetic reporting count: 2; actual count omitted).
- Endpoint identity SHA-256 (synthetic reporting digest): `379e54cb170ba4b66123df76d26da599d15ee5c51b38476be4eec2254a0c7ca9`.
- All persistent file bytes matched, including OAuth, AI setup and Tailscale state; legacy backup also matched.
- The real production profile remained unchanged. Its first app launch will perform migration after the old runtime is closed.

No credentials, pairing codes, access keys or private Tailscale state are included in this report.

Validation: Swift Debug build and 114 Swift tests passed; 101 Gateway/Tailscale tests passed. Release and New User Test (build 53) were packaged with current Gateway/Tailscale resources and all three bundled runtime executables. Bundle names, display names, unchanged identifiers, test-profile marker, signed staged bundles and release checksums were verified. Finder metadata added by File Provider to workspace copies does not change the signed ZIP/DMG contents.

Removed obsolete generated outputs: `C2C Workspace Manager.app`, `Boundas Gate Debug.app`, numbered New User Test copies 2–7, test archives Build41–Build46, and `dist/.DS_Store`. No Application Support directory was deleted.

## Changed files

- `Sources/C2CManager/RuntimePaths.swift`
- `Sources/C2CManager/C2CManagerApp.swift`
- `Resources/Gateway/registry.mjs`
- `Resources/Tailscale/provider.mjs`
- `Resources/Tailscale/profile-paths.mjs`
- `Tests/C2CManagerTests/RuntimePathsTests.swift`
- `Tests/C2CManagerTests/ProductStateMigrationTests.swift`
- `Tests/Tailscale/profile-paths.test.mjs`
- `scripts/build-new-user-app.sh`
- `scripts/package-release.sh`
- `README.md`
- `docs/main-gate-setup-journey.md`
- `docs/gate-contract-v1-implementation.md`
- `docs/branding-state-migration.md`
