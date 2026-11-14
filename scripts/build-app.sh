#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/dist/MX2 Syndicate Bridge.app"
rm -rf "$app"

swift build --package-path "$root" -c release --product MX2SyndicateBridge
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/release/MX2SyndicateBridge" "$app/Contents/MacOS/MX2 Syndicate Bridge"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
chmod +x "$app/Contents/MacOS/MX2 Syndicate Bridge"
codesign --force --deep --sign - "$app" >/dev/null

printf 'Built %s\n' "$app"
