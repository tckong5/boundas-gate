# Boundas Gate 1.2.1

For Apple Silicon Macs running macOS 14 or later.

## Installation

1. Open the DMG and drag **Boundas Gate.app** into Applications. For the ZIP, extract it first, then move the app into Applications.
2. Open Boundas Gate and click **Add Folder** to select the folders you want to share.
3. Select **Main Gate** or create a **Side Gate**, then click **Open Gate** to start the local Gate.
4. In **Secure Access**, click **Sign In** or **Set Up**. Current Shared Secure Access uses one Tailscale login; adding Folders or Side Gates does not require another login. Existing legacy fixed-address or external transport stays unchanged until explicitly migrated; endpoints and device identities are never silently replaced.
5. In **Connect an AI App**, choose ChatGPT, Claude, or another MCP-compatible app and follow its connection instructions.
6. **Ready to Use** means that Gate's setup is complete.

ChatGPT setup guides you through:

1. Open Plugins.
2. Click Add +.
3. Choose Create MCP App.

Enter the displayed Name, Description, and Server URL in ChatGPT, then complete authorization. Claude and other MCP apps use independent MCP Connections.

## Main Gate and Side Gates

Main Gate can share zero or more Folders. Each Side Gate has independent Folder membership, Open/Close lifecycle, Secure Access, and MCP authorization. A Folder can appear in both Main Gate and Side Gate. Removing a Side Gate does not delete the Folder or change Main Gate.

## Upgrading an existing installation

Quit the old app, then replace the copy in Applications. Folder records, Gate state, OAuth authorization, Tailscale state, and endpoint metadata remain in:

```text
~/Library/Application Support/Boundas Gate
```

The bundle identifier identifies the macOS app, not the Gate. A bundle-identifier change does not by itself create a new Gate. Production startup safely handles legacy data under the existing migration rules. Debug and New User Test use isolated profiles and do not migrate production state. Existing legacy fixed-address or external transport retains its endpoint and device identity until the user explicitly migrates it.

## Runtime and security

Node.js, the C2C backend, cloudflared, and the Tailscale userspace runtime are bundled. Users do not need to install Homebrew, Node, C2C, or the Tailscale Mac app separately. Third-party runtime components retain their own licenses; the root LICENSE applies only to Boundas Gate's source code.

Folder Passcode Protection adds a Folder-level policy enforced through both Main and Side Gates. The Passcode popover shows temporary access, expiration, and revocation state.

## Signing and Gatekeeper

This GitHub release is **ad-hoc signed and not Apple notarized**. macOS Gatekeeper may require manual approval through **System Settings → Privacy & Security → Open Anyway** after an initial blocked launch. Developer ID signing and notarization are intentionally deferred and are not required for this release.

The optional Developer ID build mode requires `BOUNDAS_CODESIGN_IDENTITY`, `BOUNDAS_NOTARY_PROFILE`, and the corresponding signing/notarization credentials. It fails if credentials are missing instead of silently falling back to ad-hoc signing. See [RELEASE_NOTES.md](RELEASE_NOTES.md) for release status.
