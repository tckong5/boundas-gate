#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
source "$project_dir/scripts/release-config.sh"
mkdir -p "$project_dir/.build/apps"
destination="$project_dir/.build/apps/Boundas Gate New User Test.app"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/clang-module-cache"
swift build -c debug --product C2CManager --disable-sandbox --build-system native \
  --cache-path "$project_dir/.build/cache" --config-path "$project_dir/.build/config" --manifest-cache local
GOPATH="$project_dir/.build/go-path" GOCACHE="$project_dir/.build/go-cache" \
  "$project_dir/.build/toolchains/go/bin/go" -C "$project_dir/Native/Tunnel" build -trimpath -ldflags='-s -w' -o "$project_dir/.build/boundas-tunnel" .

# Reuse the verified portable runtime; never copy user settings into the bundle.
version="$RELEASE_VERSION"
previous_test_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$destination/Contents/Info.plist" 2>/dev/null || echo 0)"
[[ "$previous_test_build" == <-> ]] || previous_test_build=0
test_build=$((previous_test_build + 1))
archive="$project_dir/dist/Boundas-Gate-${version}-arm64.zip"
[[ -f "$archive" ]] || { echo 'Build the portable release archive first.' >&2; exit 1; }
staging_dir=$(mktemp -d /private/tmp/boundas-new-user.XXXXXX)
trap 'rm -rf "$staging_dir"' EXIT
ditto -x -k "$archive" "$staging_dir"
app="$staging_dir/Boundas Gate.app"
cp .build/debug/C2CManager "$app/Contents/MacOS/C2CManager"
cp .build/boundas-tunnel "$app/Contents/Resources/Runtime/bin/boundas-tunnel"
cp Resources/Gateway/*.mjs "$app/Contents/Resources/Gateway/"
cp Resources/Gateway/git "$app/Contents/Resources/Gateway/git"
chmod +x "$app/Contents/Resources/Gateway/git"
cp Resources/Tailscale/*.mjs "$app/Contents/Resources/Tailscale/"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Boundas Gate New User Test' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Boundas Gate New User Test' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NEW_USER_TEST_BUNDLE_IDENTIFIER" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :BoundasGateDataProfile string new-user-test' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $test_build" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :BoundasGateBuildDate string $(date -u +%Y-%m-%dT%H:%M:%SZ)" "$app/Contents/Info.plist"
python3 "$project_dir/scripts/configure-updater.py" "$app/Contents/Info.plist" --test
/bin/zsh "$project_dir/scripts/embed-sparkle.sh" "$app"
xattr -cr "$app"
codesign --force --sign - "$app/Contents/Resources/Runtime/bin/boundas-tunnel"
/bin/zsh "$project_dir/scripts/sign-sparkle.sh" "$app" --force --sign -
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
if [[ -d "$destination" ]]; then mv "$destination" "$staging_dir/Previous Test.app"; fi
ditto --norsrc --noextattr "$app" "$destination"
xattr -cr "$destination"
xattr -d com.apple.FinderInfo "$destination" 2>/dev/null || true
echo "$destination"
