#!/bin/zsh
set -euo pipefail
app="$1"; shift
framework="$app/Contents/Frameworks/Sparkle.framework"
# Sparkle 2.10's explicit inner-to-outer recipe. Preserve Downloader's original
# entitlements; the caller supplies the enclosing app's identity/options.
version="$framework/Versions/B"
codesign "$@" "$version/XPCServices/Installer.xpc"
codesign "$@" --preserve-metadata=entitlements "$version/XPCServices/Downloader.xpc"
codesign "$@" "$version/Autoupdate"
codesign "$@" "$version/Updater.app"
codesign "$@" "$framework"
