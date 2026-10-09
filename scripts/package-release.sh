#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
source "$project_dir/scripts/release-config.sh"

build_mode="${BOUNDAS_BUILD_MODE:-local}"
if [[ "$build_mode" != local && "$build_mode" != test && "$build_mode" != public ]]; then
  echo "BOUNDAS_BUILD_MODE must be local, test, or public." >&2
  exit 2
fi

app="$project_dir/dist/$PRODUCT_NAME.app"
release_zip="$project_dir/dist/Boundas-Gate-${RELEASE_VERSION}-arm64.zip"
release_dmg="$project_dir/dist/Boundas-Gate-${RELEASE_VERSION}-arm64.dmg"
[[ -d "$app" ]] || { echo 'Build the app before packaging the release.' >&2; exit 1; }
[[ -f "$release_zip" ]] || { echo 'Build the app and signed archive first.' >&2; exit 1; }

typeset -a codesign_args
codesign_args=(--force --sign -)
if [[ "$build_mode" == public ]]; then
  codesign_identity="${BOUNDAS_CODESIGN_IDENTITY:-}"
  [[ -n "$codesign_identity" ]] || { echo 'Public release requires BOUNDAS_CODESIGN_IDENTITY.' >&2; exit 2; }
  [[ -n "${BOUNDAS_NOTARY_PROFILE:-}" ]] || { echo 'Public release requires BOUNDAS_NOTARY_PROFILE.' >&2; exit 2; }
  command -v xcrun >/dev/null || { echo 'Public release requires Xcode command-line tools (xcrun).' >&2; exit 2; }
  xcrun notarytool history --keychain-profile "$BOUNDAS_NOTARY_PROFILE" >/dev/null 2>&1 || {
    echo 'Public release requires a valid notarytool Keychain profile in BOUNDAS_NOTARY_PROFILE.' >&2
    exit 2
  }
  codesign_args=(--force --sign "$codesign_identity" --options runtime --timestamp)
fi

staging_dir=$(mktemp -d /private/tmp/boundas-release.XXXXXX)
trap 'rm -rf "$staging_dir"' EXIT
ditto -x -k "$release_zip" "$staging_dir"
staged_app="$staging_dir/$PRODUCT_NAME.app"
codesign --verify --deep --strict --verbose=2 "$staged_app"

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

staged_bundle_identifier="$(plist_value "$staged_app/Contents/Info.plist" CFBundleIdentifier || true)"
staged_version="$(plist_value "$staged_app/Contents/Info.plist" CFBundleShortVersionString || true)"
staged_build="$(plist_value "$staged_app/Contents/Info.plist" CFBundleVersion || true)"
if [[ "$staged_bundle_identifier" != "$BUNDLE_IDENTIFIER" || "$staged_version" != "$RELEASE_VERSION" || "$staged_build" != "$PRODUCTION_BUILD_NUMBER" ]]; then
  echo "Staged app does not match release-config.sh (bundle=$staged_bundle_identifier version=$staged_version build=$staged_build)." >&2
  exit 2
fi

if [[ "$build_mode" == public ]]; then
  signing_details="$(codesign -dv --verbose=4 "$staged_app" 2>&1 || true)"
  [[ "$signing_details" != *'Signature=adhoc'* ]] || {
    echo 'Public release requires a Developer ID-signed app; staged app is ad hoc signed.' >&2
    exit 2
  }
  [[ "$signing_details" == *"Authority=$codesign_identity"* ]] || {
    echo 'Staged app is not signed with BOUNDAS_CODESIGN_IDENTITY.' >&2
    exit 2
  }
  requested_team=""
  if [[ "$codesign_identity" =~ "\\(([A-Za-z0-9]+)\\)$" ]]; then
    requested_team="$match[1]"
  fi
  [[ -n "$requested_team" && "$signing_details" == *"TeamIdentifier=$requested_team"* ]] || {
    echo 'Staged app TeamIdentifier does not match BOUNDAS_CODESIGN_IDENTITY.' >&2
    exit 2
  }
  xcrun notarytool submit "$release_zip" --keychain-profile "$BOUNDAS_NOTARY_PROFILE" --wait
  xcrun stapler staple "$staged_app"
  xcrun stapler validate "$staged_app"
fi

rm -f "$release_zip"
ditto -c -k --norsrc --noextattr --keepParent "$staged_app" "$release_zip"
rm -rf "$app"
ditto --norsrc --noextattr "$staged_app" "$app"
xattr -cr "$app"
xattr -d com.apple.FinderInfo "$app" 2>/dev/null || true

dmg_staging_dir=$(mktemp -d /private/tmp/boundas-dmg.XXXXXX)
trap 'rm -rf "$staging_dir" "$dmg_staging_dir"' EXIT
ditto --norsrc --noextattr "$app" "$dmg_staging_dir/$PRODUCT_NAME.app"
ln -s /Applications "$dmg_staging_dir/Applications"
cp "$project_dir/INSTALL.md" "$dmg_staging_dir/安裝說明.md"
rm -f "$release_dmg"
hdiutil create -volname "$PRODUCT_NAME" -srcfolder "$dmg_staging_dir" -ov -format UDZO "$release_dmg"

if [[ "$build_mode" == public ]]; then
  codesign "${codesign_args[@]}" "$release_dmg"
  codesign --verify --verbose=2 "$release_dmg"
  xcrun notarytool submit "$release_dmg" --keychain-profile "$BOUNDAS_NOTARY_PROFILE" --wait
  xcrun stapler staple "$release_dmg"
  xcrun stapler validate "$release_dmg"
  spctl --assess --type execute --verbose=2 "$staged_app"
  spctl --assess --type open --verbose=2 "$release_dmg"
else
  codesign --verify --verbose=2 "$release_dmg" 2>/dev/null || true
fi

# Verify the final ZIP copy outside File Provider metadata. The app directory
# in dist may receive FinderInfo again after it is written, while the archive
# remains byte-for-byte clean for distribution.
final_verify_dir=$(mktemp -d /private/tmp/boundas-final-verify.XXXXXX)
trap 'rm -rf "$staging_dir" "$dmg_staging_dir" "$final_verify_dir"' EXIT
ditto -x -k "$release_zip" "$final_verify_dir"
codesign --verify --deep --strict --verbose=2 "$final_verify_dir/$PRODUCT_NAME.app"

(cd "$project_dir/dist" && shasum -a 256 "$(basename "$release_zip")" "$(basename "$release_dmg")") > "$project_dir/dist/SHA256SUMS.txt"
echo "$release_dmg"
