# Sparkle updates

Sparkle 2.10.0 is pinned in SwiftPM. One standard updater serves the application
menu and menu bar. The bundled public key is configured by
`scripts/configure-updater.py`; the private key stays in Login Keychain.
Do not export it into the repository, build artifacts, environment or logs.

## Production feed (required before distributing updater-enabled builds)

Set `BOUNDAS_UPDATE_FEED_URL` to the final stable HTTPS appcast URL when running
`scripts/build-app.sh`. No URL is inferred from GitHub and no placeholder is
embedded. Without it the menu is disabled and no checks run. The URL is embedded
as `SUFeedURL`; runtime environment cannot override a production app's feed.
`SUPublicEDKey` and `SUVerifyUpdateBeforeExtraction` are always embedded.
Automatic checks are enabled when a feed is configured (Sparkle retains the
user's consent/preferences); automatic installation is not enabled.

The current release is 1.2.1 / build 8. For each future release increment
`PRODUCTION_BUILD_NUMBER` in `scripts/release-config.sh`; update `RELEASE_VERSION`
to the intended public version. Never reuse a published build number.

## Prepare a future update (does not publish)

1. Build with the final `BOUNDAS_UPDATE_FEED_URL`; use existing packaging and
   signing mode. Ad-hoc distribution remains not Apple notarized.
2. Copy the final distribution ZIP into a dedicated update-archive directory
   outside the repo. Keep older archives/appcast there for feed continuity.
3. Run `zsh scripts/generate-update-appcast.sh /absolute/update-directory
   "<final HTTPS GitHub release-download prefix>/"`.
   Official `generate_appcast` signs archives using Login Keychain and emits
   `sparkle:edSignature`. Approve Keychain access if prompted. The script rejects
   empty/unsigned output. Do not modify the signed archive afterwards.
4. Review URLs/version/signatures, then upload archives and publish the appcast
   at the stable feed URL as a separate, explicitly approved release action.

Official single-archive signing command, if needed:
`.build/artifacts/sparkle/Sparkle/bin/sign_update /absolute/update.zip`.
Only the signature/length are output; the private key is not exported.

## Isolated local test

Set `BOUNDAS_TEST_FEED_URL=http://127.0.0.1:8765/appcast.xml` when running
`scripts/build-new-user-app.sh`, then serve a dedicated fixture directory with
`python3 -m http.server 8765 --bind 127.0.0.1 --directory /absolute/fixtures`.
The test bundle clears production `SUFeedURL` and uses `BoundasGateTestFeedURL`.
HTTP is accepted only on loopback in Debug/New User Test; archives still require
the embedded EdDSA key. Never disable verification for fixtures.
Do not install a production archive from a test app: build a matching test bundle
with its test bundle identifier and a higher test build number for install tests.
Unsigned/malformed fixtures must report Sparkle errors, not install. A valid
end-to-end install requires a signed matching test archive and Keychain approval.
Raw executables do not initialize Sparkle because they are not app bundles.

Focused checks: `swift test --filter 'UpdateConfigurationTests|AppQuitCoordinatorTests'`,
`python3 -B Tests/Updater/test_configure_updater.py`, and
`python3 -B scripts/test-updater-smoke.py`. The latter compiles a disposable
standalone host, invokes the standard controller check action, and rejects malformed
feeds / unsigned archives using the real Sparkle framework without installing.

Sparkle restart requests use the existing app termination handler; this
integration does not replace or bypass the accepted Gate shutdown coordinator.
