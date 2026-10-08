#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/clang-module-cache"
swift build -c debug --product C2CManager --disable-sandbox --build-system native \
  --cache-path "$project_dir/.build/cache" --config-path "$project_dir/.build/config" --manifest-cache local
GOPATH="$project_dir/.build/go-path" GOCACHE="$project_dir/.build/go-cache" \
  "$project_dir/.build/toolchains/go/bin/go" -C "$project_dir/Native/Tunnel" build -trimpath -ldflags='-s -w' -o "$project_dir/.build/boundas-tunnel" .

# Reuse the verified portable runtime; never copy user settings into the bundle.
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' 'dist/Boundas Gate.app/Contents/Info.plist')"
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
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.c2c.WorkspaceManager.new-user-test' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :BoundasGateDataProfile string new-user-test' "$app/Contents/Info.plist"
xattr -cr "$app"
codesign --force --sign - "$app/Contents/Resources/Runtime/bin/boundas-tunnel"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
destination="$project_dir/dist/Boundas Gate New User Test.app"
if [[ -d "$destination" ]]; then mv "$destination" "$staging_dir/Previous Test.app"; fi
ditto --norsrc --noextattr "$app" "$destination"
xattr -cr "$destination"
xattr -d com.apple.FinderInfo "$destination" 2>/dev/null || true
echo "$destination"
