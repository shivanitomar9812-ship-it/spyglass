#!/bin/bash
# Build the Spyglass panel. Usage: build.sh [output] [--universal]
# Works around Command Line Tools installs that ship a duplicate swift module.modulemap.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/../bin/Spyglass}"; mkdir -p "$(dirname "$out")"
flags=(-O)
clt=/Library/Developer/CommandLineTools/usr/include/swift
if [ -f "$clt/module.modulemap" ] && [ -f "$clt/bridging.modulemap" ]; then
  tmp="$(mktemp -d)"; : > "$tmp/empty.modulemap"
  cat > "$tmp/vfs.yaml" <<Y
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "directory", "name": "$clt",
  "contents": [ { "type": "file", "name": "module.modulemap", "external-contents": "$tmp/empty.modulemap" } ] } ] }
Y
  flags+=(-vfsoverlay "$tmp/vfs.yaml" -Xcc -ivfsoverlay -Xcc "$tmp/vfs.yaml")
fi
if [ "${2:-}" = "--universal" ]; then
  swiftc "${flags[@]}" -target arm64-apple-macosx13.0 "$here"/*.swift -o "$out.arm64"
  swiftc "${flags[@]}" -target x86_64-apple-macosx13.0 "$here"/*.swift -o "$out.x86_64"
  lipo -create "$out.arm64" "$out.x86_64" -output "$out" && rm -f "$out.arm64" "$out.x86_64"
else
  swiftc "${flags[@]}" -target "$(uname -m)-apple-macosx13.0" "$here"/*.swift -o "$out"
fi
echo "Built $out"
