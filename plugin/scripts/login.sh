#!/bin/bash
# Usage: login.sh on|off|status — start the Spyglass panel at login via a LaunchAgent.
home="${SPYGLASS_HOME:-$HOME/.claude/spyglass}"
label="dev.spyglass.panel"
plist="$HOME/Library/LaunchAgents/$label.plist"
dom="gui/$(id -u)"
case "${1:-status}" in
  on)
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$home/Spyglass</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PL
    pkill -f "^$home/Spyglass$" 2>/dev/null; sleep 0.5
    launchctl bootout "$dom/$label" 2>/dev/null
    launchctl bootstrap "$dom" "$plist" && echo "Spyglass will start at login (and is running now)."
    ;;
  off)
    launchctl bootout "$dom/$label" 2>/dev/null
    rm -f "$plist" && echo "Spyglass will no longer start at login."
    ;;
  *)
    if [ -f "$plist" ]; then echo "Start at login: on"; else echo "Start at login: off"; fi
    pgrep -f "^$home/Spyglass$" >/dev/null && echo "Panel: running" || echo "Panel: not running"
    ;;
esac
