#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
# Only regeneration needs librsvg (or Nix); app builds use the checked-in icon.
if command -v rsvg-convert >/dev/null; then
  rsvg-convert -w 1024 -h 1024 -o "$root/AppIcon.png" "$root/AppIcon.svg"
else
  nix shell nixpkgs#librsvg --command rsvg-convert -w 1024 -h 1024 \
    -o "$root/AppIcon.png" "$root/AppIcon.svg"
fi
mkdir -p "$root/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$root/AppIcon.png" \
    --out "$root/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$root/AppIcon.png" \
    --out "$root/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$root/AppIcon.iconset" --output "$root/AppIcon.icns"
printf 'Built %s\n' "$root/AppIcon.icns"
