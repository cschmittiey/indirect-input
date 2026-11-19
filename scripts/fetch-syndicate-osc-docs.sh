#!/usr/bin/env bash
# Prints chapter 14 ("OSC control") of Syndicate's online user guide as plain text.
#
# The bridge's routes are written against that chapter, so when Syndicate updates,
# fetch it again and diff against the previous copy to see which addresses changed:
#
#   ./scripts/fetch-syndicate-osc-docs.sh > /tmp/osc-new.txt
#   diff /tmp/osc-old.txt /tmp/osc-new.txt
set -euo pipefail

if [[ $# -ne 0 ]]; then
  printf 'Usage: %s > osc.txt\n' "$0" >&2
  exit 2
fi

url="https://untitledaudiosyndicate.com/user-guide/index.html"

curl -fsSL "$url" | python3 -I -c '
import html, re, sys

page = sys.stdin.read()
start = page.rfind("id=\"c14\"")
if start < 0:
    sys.exit("chapter 14 not found; the guide layout may have changed")
end = page.find("id=\"c15\"", start)
chunk = page[start:end if end > 0 else None]
chunk = re.sub(r"<(script|style)[^>]*>.*?</\1>", "", chunk, flags=re.S)
chunk = re.sub(r"<h[1-6][^>]*>", "\n\n## ", chunk)
chunk = re.sub(r"<tr[^>]*>", "\n", chunk)
chunk = re.sub(r"<t[dh][^>]*>", " | ", chunk)
chunk = re.sub(r"<(p|li|br|div|pre)[^>]*>", "\n", chunk)
text = html.unescape(re.sub(r"<[^>]+>", "", chunk))
text = re.sub(r"[ \t]+", " ", text)
text = re.sub(r"\n\s*\n+", "\n\n", text)
# Drop the leftover attribute fragment the slice starts inside of.
print(text.split("\n", 1)[1].strip() if "\n" in text else text.strip())
'
