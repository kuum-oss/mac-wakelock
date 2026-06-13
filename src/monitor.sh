#!/usr/bin/env bash
# monitor.sh — battery monitor for mac-wakelock.
# Runs as a launchd agent (StartInterval=60). Fires a macOS notification
# + Sosumi sound when battery drops below 20%, resets after charging above 25%.
#
# launchd will only keep this alive while ~/.wakelock/state exists (KeepAlive PathState).
# Do NOT run this manually; it is managed by `wakelock on` / `wakelock off`.

set -euo pipefail

STATE="$HOME/.wakelock/state"
THRESHOLD=20
HYSTERESIS=25
WARNED_FILE="$HOME/.wakelock/.monitor_warned"

# If state file is gone, exit immediately — launchd won't restart us.
[ -f "$STATE" ] || exit 0

# Read battery percentage
BAT=$(pmset -g batt 2>/dev/null | grep -o '[0-9]*%' | tr -d '%' | head -1 || echo "")
[ -n "$BAT" ] || exit 0

# Hysteresis: track warned state via a flag file (launchd restarts us fresh each tick)
WARNED=0
[ -f "$WARNED_FILE" ] && WARNED=1

if [ "$BAT" -lt "$THRESHOLD" ] && [ "$WARNED" -eq 0 ]; then
    # Fire notification + sound
    osascript <<OSASCRIPT
display notification "Battery at ${BAT}% — plug in your charger!" ¬
    with title "mac-wakelock 🔋" ¬
    subtitle "Low Battery Warning" ¬
    sound name "Sosumi"
OSASCRIPT
    touch "$WARNED_FILE"

elif [ "$BAT" -ge "$HYSTERESIS" ] && [ "$WARNED" -eq 1 ]; then
    # Battery recovered — reset warning flag
    rm -f "$WARNED_FILE"
fi

exit 0
