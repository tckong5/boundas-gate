#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
archives="${1:?Pass a directory containing final signed update archives}"
download_prefix="${2:?Pass the final HTTPS release-download URL prefix}"
[[ "$download_prefix" == https://* ]] || { echo 'Release downloads require HTTPS.' >&2; exit 2; }
tools="$project_dir/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$tools/generate_appcast" ]] || { echo 'Resolve the Sparkle SwiftPM dependency first.' >&2; exit 2; }
# Official tools access Login Keychain directly. No private-key export or arguments.
"$tools/generate_appcast" --download-url-prefix "$download_prefix" "$archives"
python3 - "$archives" <<'PY'
import pathlib, sys, xml.etree.ElementTree as ET
feeds = list(pathlib.Path(sys.argv[1]).glob('*.xml'))
if not feeds:
    raise SystemExit('No appcast generated')
for feed in feeds:
    items = ET.parse(feed).findall('./channel/item')
    if not items:
        raise SystemExit('Empty appcast: no update archives found')
    for item in items:
        enclosure = item.find('enclosure')
        if enclosure is None or not enclosure.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'):
            raise SystemExit('Unsigned update enclosure rejected')
PY
