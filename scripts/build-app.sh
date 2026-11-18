#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--install" ) ]]; then
  printf 'Usage: %s [--install]\n' "$0" >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/dist/Indirect Input.app"

swift build --package-path "$root" -c release --product IndirectInputApp
bin="$(swift build --package-path "$root" -c release --show-bin-path)"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/IndirectInputApp" "$app/Contents/MacOS/Indirect Input"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
chmod +x "$app/Contents/MacOS/Indirect Input"
codesign --force --deep --sign - "$app" >/dev/null
codesign --verify --deep --strict "$app"

printf 'Built %s\n' "$app"
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  /usr/bin/ditto "$app" "$HOME/Applications/Indirect Input.app"
  codesign --verify --deep --strict "$HOME/Applications/Indirect Input.app"
  printf 'Installed %s\n' "$HOME/Applications/Indirect Input.app"
fi
