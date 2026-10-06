#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"
mkdir -p "$project_dir/.build/cache" "$project_dir/.build/config" "$project_dir/.build/clang-module-cache"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/clang-module-cache"
swift build -c release --product C2CManager \
  --disable-sandbox \
  --build-system native \
  -debug-info-format none \
  --cache-path "$project_dir/.build/cache" \
  --config-path "$project_dir/.build/config" \
  --manifest-cache local

staging_dir=$(mktemp -d /private/tmp/boundas-build.XXXXXX)
trap 'rm -rf "$staging_dir"' EXIT
iconset_dir="$staging_dir/BoundasGate.iconset"
mkdir -p "$iconset_dir"
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" "$project_dir/Resources/AppIcon.png" \
    --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -s format png -z "$retina_size" "$retina_size" "$project_dir/Resources/AppIcon.png" \
    --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_dir" -o "$staging_dir/AppIcon.icns"
app_dir="$staging_dir/Boundas Gate.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/.build/release/C2CManager" "$app_dir/Contents/MacOS/C2CManager"
cp "$staging_dir/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
node_binary="${BOUNDAS_NODE:-$(command -v node)}"
backend_root="${BOUNDAS_C2C_ROOT:-$HOME/codex-with-chatgpt}"
go_binary="${BOUNDAS_GO:-$project_dir/.build/toolchains/go/bin/go}"
if [[ ! -x "$go_binary" ]]; then go_binary="$(command -v go)"; fi
export GOPATH="$project_dir/.build/go-path"
export GOCACHE="$project_dir/.build/go-cache"
(
  cd "$project_dir/Native/Tunnel"
  "$go_binary" build -trimpath -ldflags='-s -w' -o "$project_dir/.build/boundas-tunnel" .
  "$go_binary" list -m -json all > "$project_dir/.build/go-modules.stream.json"
)
python3 - "$project_dir/.build/go-modules.stream.json" "$project_dir/.build/go-modules.json" <<'PYMODULES'
import json, sys
text = open(sys.argv[1]).read(); decoder = json.JSONDecoder(); modules = []
while text.strip():
    item, length = decoder.raw_decode(text.lstrip()); modules.append(item); text = text.lstrip()[length:]
json.dump(modules, open(sys.argv[2], 'w'))
PYMODULES
"$node_binary" "$project_dir/scripts/bundle-runtime.mjs" "$backend_root" "$app_dir/Contents/Resources/Runtime" "$node_binary"
cp "$project_dir/.build/boundas-tunnel" "$app_dir/Contents/Resources/Runtime/bin/boundas-tunnel"
mkdir -p "$app_dir/Contents/Resources/Runtime/Licenses/Go"
"$node_binary" "$project_dir/scripts/collect-go-licenses.mjs" "$project_dir/.build/go-modules.json" "$app_dir/Contents/Resources/Runtime/Licenses/Go"
cp "$(dirname "$(dirname "$go_binary")")/LICENSE" "$app_dir/Contents/Resources/Runtime/Licenses/Go-toolchain.txt"
cp "$project_dir/Resources/ChatGPT Image 28 Sept 2026, 18_39_56.png" "$app_dir/Contents/Resources/MenuBarArtwork.png"
mkdir -p "$app_dir/Contents/Resources/Tailscale"
cp "$project_dir/Resources/Tailscale/"*.mjs "$app_dir/Contents/Resources/Tailscale/"
mkdir -p "$app_dir/Contents/Resources/Gateway"
cp "$project_dir/Resources/Gateway/"*.mjs "$app_dir/Contents/Resources/Gateway/"
cp "$project_dir/Resources/Gateway/git" "$app_dir/Contents/Resources/Gateway/git"
chmod u+x "$app_dir/Contents/Resources/Gateway/git"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>C2CManager</string>
  <key>CFBundleIdentifier</key><string>local.c2c.WorkspaceManager</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Boundas Gate</string>
  <key>CFBundleDisplayName</key><string>Boundas Gate</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2.0</string>
  <key>CFBundleVersion</key><string>6</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
chmod -R u+w "$app_dir"
xattr -cr "$app_dir"
for executable in node cloudflared boundas-tunnel; do
  codesign --force --sign - "$app_dir/Contents/Resources/Runtime/bin/$executable"
done
codesign --force --sign - "$app_dir"
xattr -cr "$app_dir"
codesign --verify --deep --strict "$app_dir"
final_app_dir="$project_dir/dist/Boundas Gate.app"
mkdir -p "$project_dir/dist"
release_zip="$project_dir/dist/Boundas-Gate-1.2.0-arm64.zip"
ditto -c -k --norsrc --noextattr --keepParent "$app_dir" "$release_zip"
rm -rf "$final_app_dir"
ditto --norsrc --noextattr "$app_dir" "$final_app_dir"
touch "$final_app_dir"
xattr -cr "$final_app_dir"
# File Provider can retain FinderInfo on the bundle itself after recursive clearing.
xattr -d com.apple.FinderInfo "$final_app_dir" 2>/dev/null || true
# The signed archive is generated and verified outside File Provider storage.
# Its extracted bundle has identical signed resources, without Finder metadata.
echo "$final_app_dir"
echo "$release_zip"
