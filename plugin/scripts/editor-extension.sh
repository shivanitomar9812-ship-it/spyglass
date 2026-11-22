#!/bin/bash
# Build and install the Spyglass Focus extension into Cursor / VS Code so Spyglass can jump to the exact terminal tab.
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
ext="$root/editor-extension"
home="${SPYGLASS_HOME:-$HOME/.claude/spyglass}"; mkdir -p "$home"
cp "$ext/core.js" "$home/editor-core.js"   # the extension hot-loads this
tmp="$(mktemp -d)"; mkdir -p "$tmp/extension"
cp "$ext/package.json" "$ext/extension.js" "$tmp/extension/"
cp "$ext/extension.vsixmanifest" "$ext/[Content_Types].xml" "$tmp/"
(cd "$tmp" && zip -qr spyglass-focus.vsix '[Content_Types].xml' extension.vsixmanifest extension)
found=0
for cli in \
  "/Applications/Cursor.app/Contents/Resources/app/bin/cursor" \
  "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
  "/Applications/Windsurf.app/Contents/Resources/app/bin/windsurf" \
  "$(command -v cursor 2>/dev/null)" "$(command -v code 2>/dev/null)"; do
  [ -n "$cli" ] && [ -x "$cli" ] || continue
  "$cli" --install-extension "$tmp/spyglass-focus.vsix" >/dev/null 2>&1 && { echo "Installed in: $cli"; found=1; }
  "$cli" --uninstall-extension local.tower-focus >/dev/null 2>&1   # the extension's old name (Tower)
done
rm -rf "$tmp"
[ "$found" = 1 ] || { echo "No Cursor / VS Code / Windsurf found."; exit 1; }
