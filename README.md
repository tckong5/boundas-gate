# Boundas Gate

<img src="Resources/AppIcon.png" width="128" alt="Boundas Gate icon">

> Give an AI app access to selected local folders without giving it access to the whole Mac.

Boundas Gate is a native macOS app. Select the **Folders** you want to share, then expose an MCP endpoint through a **Main Gate** or independent **Side Gate**. Gates, Tunnels, MCP Connections, and Folders are managed separately. A Gate can run without any shared Folders or authorized AI apps.

## Getting started

```text
Add Folder
    ↓
Main Gate / Side Gate
    ↓
Open Gate
    ↓
Secure Access
    ↓
Connect an AI App
    ↓
Ready to Use
```

1. Use **Add Folder** in the sidebar. Adding a Folder to Main Gate does not automatically create a Side Gate; Side Gate membership is explicit.
2. Select Main Gate or a Side Gate and click **Open Gate**. This starts the local Gate only.
3. In **Secure Access**, click **Sign In** or **Set Up**. Current Shared Secure Access requires one Tailscale login. Main and Side Gates share a Tailscale identity while retaining separate routes and MCP authorization. Existing legacy fixed-address or external transport stays unchanged until you explicitly migrate it; the app never silently changes an endpoint or device identity.
4. In **Connect an AI App**, choose ChatGPT, Claude, or another MCP-compatible app and follow the setup instructions.
5. After authorization, the Gate shows **Ready to Use**. Once onboarding has completed, removing every MCP Connection leaves a normal empty state instead of restarting first-time setup.

### ChatGPT setup

The current setup instructions guide you through:

1. Open Plugins.
2. Click Add +.
3. Choose Create MCP App.

Complete the connection using the displayed Name, Description, Server URL, and authorization instructions. The primary URL appears in **Connect an AI App**; Secure Access manages whether the Gate is externally reachable.

Claude and other MCP apps use the same Gate model, with independent MCP Connections, tokens, and authorization boundaries.

## Gates, Folders, and authorization

- **Main Gate** can share zero or more Folders.
- A **Side Gate** is managed independently and normally exposes one explicitly added Folder.
- A Folder can belong to both Main Gate and Side Gate. Removing a Side Gate does not delete the Folder or change Main Gate.
- Each MCP Connection belongs to one Gate. Authorized means an authorization exists; it does not imply a live session.
- Gate health covers Local + Secure Access. MCP Connections and Folder sharing are separate information.
- Folder Passcode Protection is a Folder-level policy enforced through both Main and Side Gates.

Detailed contracts and lifecycle documentation:

- [Product model invariants](docs/product-model-architecture-invariants-v1.md)
- [Side Gate runtime owner](docs/side-gate-runtime-owner.md)
- [Secure Access and tunnel journey](docs/tunnel-management.md)
- [Security robustness review](docs/security-robustness-review.md)

## Secure Access

Secure Access provides user-facing Tunnel management. Healthy Shared Secure Access normally shows the provider and readiness, such as `Tailscale · Connected`. Less frequent actions, including Recheck, Sign Out, and technical diagnostics, are available under `…` or Advanced. Main and Side Gates share a Tailscale identity while maintaining independent URL paths, route ownership, and authorization. Existing legacy fixed-address or external transport is preserved until an explicit migration.

The app bundles Node.js, the C2C backend, cloudflared, and a Tailscale userspace runtime. The bundle retains the licenses for Node, C2C, cloudflared, Go, and Tailscale dependencies. The root [LICENSE](LICENSE) applies only to Boundas Gate's own source code.

## Windows, quitting, and updates

Closing the main window closes the UI only; Gates keep running. Use **Show Boundas Gate** in the menu bar to return. **Quit Boundas Gate** stops Side Gates, Main Gate, and verified profile-owned bundled helpers before exiting. It preserves desired-running intent, Folders, OAuth, and Tailscale identity so the next launch can reuse existing state.

Explicit Main Gate external → Shared Secure Access migration, production MCP reads, and identity continuity across restarts have passed acceptance. Migrating an existing external endpoint still requires the user's explicit approval.

v1.2.1 also preserves Folder identity across renames and moves. This was added after v1.2.0 and is not included in the v1.2.0 release assets.

Sparkle 2.10 integration is implemented, with **Check for Updates…** and the native **About Boundas Gate…** panel. Update archives require EdDSA verification; the private key stays in Login Keychain. The production appcast URL is not configured yet, and builds without a feed do not check for updates. See [UPDATES.md](docs/UPDATES.md) for release configuration and isolated testing.

## Passcode Protection

Folder rows always display the same password-lock icon. It represents the protection policy, not temporary unlock state. The popover separately shows:

- Protection policy: Passcode Protection On or Off.
- Temporary access: Protected or Temporarily Unlocked, expiration, and revocation.

Passcodes add Folder-level protection. Turning the policy off does not remove Gate authorization. See the [product model](docs/product-model-architecture-invariants-v1.md) for capability, expiration, and revocation rules.

## Data and profiles

The production app uses:

```text
~/Library/Application Support/Boundas Gate
```

New User Test uses the isolated `Boundas Gate New User Test` profile. Raw Debug executables default to `Boundas Gate Debug` and do not read or migrate production state. A DEBUG build can explicitly opt into production with `BOUNDAS_DATA_PROFILE=production`; New User Test ignores this override.

Existing Gate identity, OAuth, Tailscale state, and Folder records are retained. The bundle identifier is not the Gate identity. Initial installation or upgrade migration runs only for the production profile; Debug and test profiles do not migrate real user data.

## Build and release

Local and test builds use ad-hoc signing:

```sh
./scripts/build-app.sh
./scripts/package-release.sh
./scripts/build-new-user-app.sh
```

[`scripts/release-config.sh`](scripts/release-config.sh) is the single source of truth for the product name, bundle identifiers, version, and production build number. The current public release is **1.2.1, build 8**, available on [GitHub Releases](https://github.com/tckong5/boundas-gate/releases/tag/v1.2.1). It is **ad-hoc signed and not Apple notarized**. macOS Gatekeeper may require manual approval with **Open Anyway**. Developer ID signing and notarization are optional future release paths, not installation requirements for this release.

**1.2.1 (build 8)** fixes macOS filesystem identity recovery and Gateway/WorkspaceStore identity synchronization while preserving existing Gate, OAuth, and Passcode settings.

The optional Developer ID mode requires explicit signing and notarization credentials and never silently falls back to ad-hoc signing:

```sh
BOUNDAS_BUILD_MODE=public \
BOUNDAS_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
BOUNDAS_NOTARY_PROFILE="boundas-release" \
./scripts/build-app.sh

BOUNDAS_BUILD_MODE=public \
BOUNDAS_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
BOUNDAS_NOTARY_PROFILE="boundas-release" \
./scripts/package-release.sh
```

`BOUNDAS_NOTARY_PROFILE` names an `xcrun notarytool` Keychain profile. Never put private keys, Apple ID passwords, or app-specific passwords in the repository. Public mode uses hardened runtime, timestamps, nested Mach-O signing, notarization, stapling, and `codesign`/`spctl` verification; missing credentials stop the build. Bundled Node/V8 uses only `com.apple.security.cs.allow-jit`, which is required for its CodeRange initialization under hardened runtime. Other runtime executables receive no additional entitlement.

Release output in `dist/` contains:

```text
Boundas Gate.app
Boundas-Gate-1.2.1-arm64.zip
Boundas-Gate-1.2.1-arm64.dmg
SHA256SUMS.txt
```

New User Test is written only to `.build/apps/Boundas Gate New User Test.app`, not `dist/`.

## Tests

```sh
swift test
node --test Tests/Gateway/*.test.mjs Tests/Tailscale/*.test.mjs
(cd Native/Tunnel && go test ./...)
```

Gateway integration tests require a verified `BOUNDAS_C2C_ROOT`. Portable release smoke tests use an isolated HOME and temporary state, without modifying the real production profile.

## License

Boundas Gate's own source code is MIT licensed. Node, C2C, cloudflared, Go, Tailscale, and Sparkle retain their upstream licenses; see the packaged Runtime license files. See [artwork provenance](docs/artwork-provenance.md) for artwork redistribution authorization. The source-code MIT License does not establish rights to third-party assets.

## Historical documentation

`docs/` retains acceptance reports, migration records, security reviews, and architecture contracts. Historical reports describe their recorded versions and acceptance scope, rather than the current UI workflow. See [RELEASE_NOTES.md](RELEASE_NOTES.md) for current release status.
