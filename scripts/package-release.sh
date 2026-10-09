#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/dist/Boundas Gate.app/Contents/Info.plist")"
release_zip="$project_dir/dist/Boundas-Gate-${version}-arm64.zip"
[[ -f "$release_zip" ]] || { echo 'Build the app and signed archive first.' >&2; exit 1; }
staging_dir=$(mktemp -d /private/tmp/boundas-release.XXXXXX)
trap 'rm -rf "$staging_dir"' EXIT
ditto -x -k "$release_zip" "$staging_dir"
codesign --verify --deep --strict "$staging_dir/Boundas Gate.app"
ln -s /Applications "$staging_dir/Applications"
cp "$project_dir/INSTALL.md" "$staging_dir/安裝說明.md"
hdiutil create -volname 'Boundas Gate' -srcfolder "$staging_dir" -ov -format UDZO "$project_dir/dist/Boundas-Gate-${version}-arm64.dmg"
(cd "$project_dir/dist" && shasum -a 256 "Boundas-Gate-${version}-arm64.zip" "Boundas-Gate-${version}-arm64.dmg") > "$project_dir/dist/SHA256SUMS.txt"
echo "$project_dir/dist/Boundas-Gate-${version}-arm64.dmg"
