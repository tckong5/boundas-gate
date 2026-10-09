#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
app="$1"
framework="$project_dir/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$framework" ]] || { echo 'Resolved Sparkle framework missing.' >&2; exit 1; }
mkdir -p "$app/Contents/Frameworks"
ditto --norsrc --noextattr "$framework" "$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/Resources/Runtime/Licenses"
cp "$project_dir/.build/artifacts/sparkle/Sparkle/LICENSE" "$app/Contents/Resources/Runtime/Licenses/Sparkle.txt"
