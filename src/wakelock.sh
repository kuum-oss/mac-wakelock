#!/usr/bin/env bash
# wakelock — keep your MacBook awake with lid closed, on battery or AC.
# Usage: wakelock on | off | status | uninstall | help
#
# Requires: pmset (macOS built-in), osascript (macOS built-in)
# Sudo: needed for pmset -a disablesleep / sleep — cached for session via sudo -v.
#
# POSIX-compatible (bash 3.2+ / zsh). No Java, no Homebrew.

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
DIR="$HOME/.wakelock"
STATE="$DIR/state"
PLIST_LABEL="com.kuum.wakelock.battery"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
SUDOERS_FILE="/etc/sudoers.d/mac-wakelock"
WAKELOCK_BIN="$DIR/wakelock"

# Default sleep value to restore (macOS default is 1 for idle sleep timer)
RESTORE_SLEEP=1

# ── Platform detection ────────────────────────────────────────────────────────
detect_platform() {
    ARCH="$(uname -m)"          # arm64 | x86_64
    OS_VER="$(sw_vers -productVersion 2>/dev/null || echo "0.0")"
    OS_MAJOR="$(echo "$OS_VER" | cut -d. -f1)"
    OS_MINOR="$(echo "$OS_VER" | cut -d. -f2)"
}

warn_macos_version() {
    # macOS 15 (Sequoia) changed how disablesleep interacts with low-power mode
    if [ "$OS_MAJOR" -ge 15 ]; then
        echo "⚠️  macOS $OS_VER detected. On macOS 15+, Low Power Mode may override"
        echo "   pmset disablesleep on battery. If sleep persists, disable Low Power"
        echo "   Mode in System Settings → Battery → Low Power Mode."
    fi
    # macOS 12 minimum (Monterey+)
    if [ "$OS_MAJOR" -lt 12 ]; then
        echo "✗  mac-wakelock requires macOS 12 (Monterey) or later."
        echo "   Detected: macOS $OS_VER"
        exit 1
    fi
}

# ── Sudo helpers ──────────────────────────────────────────────────────────────
# Validate / refresh sudo ticket. Prompts the user once; subsequent pmset
# calls within the same session won't need a password.
sudo_validate() {
    if ! sudo -n true 2>/dev/null; then
        echo "🔐  sudo required for pmset. Enter your password once:"
        sudo -v || { echo "✗  sudo authentication failed."; exit 1; }
    fi
}

# Run pmset with sudo, silently refresh ticket first.
pmset_sudo() {
    sudo -n pmset "$@"
}

# ── ON ────────────────────────────────────────────────────────────────────────
cmd_on() {
    if [ -f "$STATE" ]; then
        echo "⚡  Already active.  To stop → wakelock off"
        return 0
    fi

    detect_platform
    warn_macos_version
    sudo_validate

    echo "🔧  Disabling sleep…"

    # Disable idle sleep timer (all power sources)
    pmset_sudo -a sleep 0

    # Prevent lid-close sleep — works on battery too
    pmset_sudo -a disablesleep 1

    # Apple Silicon fallback: also zero out hibernation delay
    if [ "$ARCH" = "arm64" ]; then
        pmset_sudo -a hibernatemode 0 2>/dev/null || true
        pmset_sudo -a standby 0       2>/dev/null || true
        pmset_sudo -a autopoweroff 0  2>/dev/null || true
    fi

    # Record state (include arch + OS for reference)
    mkdir -p "$DIR"
    printf '%s\n' "active" "arch=$ARCH" "macos=$OS_VER" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE"

    # Start launchd battery monitor
    _launchd_load

    echo "✅  Sleep disabled — battery, lid closed, everything"
    echo "🔋  Battery monitor running (alert below 20%)"
    if [ "$ARCH" = "arm64" ]; then
        echo "🍎  Apple Silicon: hibernation + standby also disabled"
    fi
}

# ── OFF ───────────────────────────────────────────────────────────────────────
cmd_off() {
    if [ ! -f "$STATE" ]; then
        echo "ℹ️   Not active."
        return 0
    fi

    detect_platform
    sudo_validate

    # Stop launchd battery monitor
    _launchd_unload

    echo "🔧  Restoring sleep settings…"

    pmset_sudo -a disablesleep 0
    pmset_sudo -a sleep "$RESTORE_SLEEP"

    # Restore Apple Silicon defaults
    if [ "$ARCH" = "arm64" ]; then
        pmset_sudo -a hibernatemode 3 2>/dev/null || true
        pmset_sudo -a standby 1       2>/dev/null || true
        pmset_sudo -a autopoweroff 1  2>/dev/null || true
    fi

    rm -f "$STATE"
    echo "✅  Normal sleep behavior restored"
}

# ── STATUS ────────────────────────────────────────────────────────────────────
cmd_status() {
    detect_platform

    local active="❌ inactive"
    local arch_info="$ARCH"
    local macos_info="macOS $OS_VER"

    if [ -f "$STATE" ]; then
        active="✅ active"
    fi

    # Battery level
    local bat
    bat=$(pmset -g batt 2>/dev/null | grep -o '[0-9]*%' | tr -d '%' | head -1 || echo "")

    # Charging state
    local charging=""
    if pmset -g batt 2>/dev/null | grep -q "AC Power"; then
        charging=" (AC power)"
    elif pmset -g batt 2>/dev/null | grep -q "discharging"; then
        charging=" (discharging)"
    fi

    # pmset current values
    local ds
    ds=$(pmset -g | awk '/disablesleep/{print $2}' || echo "?")
    local sl
    sl=$(pmset -g | awk '/^ *sleep /{print $2}' || echo "?")

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  mac-wakelock status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-14s %s\n" "State:"    "$active"
    printf "  %-14s %s\n" "Platform:" "$arch_info / $macos_info"
    if [ -n "$bat" ]; then
        printf "  %-14s %s\n" "Battery:"  "${bat}%${charging}"
    else
        printf "  %-14s %s\n" "Battery:"  "— (not detected)"
    fi
    printf "  %-14s %s\n" "disablesleep:" "${ds}"
    printf "  %-14s %s\n" "sleep timer:"  "${sl} min"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ -f "$STATE" ] && [ -n "$bat" ] && [ "$bat" -lt 20 ]; then
        echo "⚠️   Low battery! Plug in your charger."
    fi
}

# ── UNINSTALL ─────────────────────────────────────────────────────────────────
cmd_uninstall() {
    echo ""
    echo "╔══════════════════════════════════╗"
    echo "║    mac-wakelock  uninstaller     ║"
    echo "╚══════════════════════════════════╝"
    echo ""
    echo "This will:"
    echo "  • Restore default macOS sleep settings"
    echo "  • Remove the launchd battery monitor"
    echo "  • Delete ~/.wakelock/"
    echo "  • Remove the sudoers rule"
    echo "  • Remove PATH entry from your shell rc files"
    echo ""
    printf "Continue? [y/N] "
    read -r CONFIRM
    case "$CONFIRM" in
        [Yy]|[Yy][Ee][Ss]) ;;
        *) echo "Aborted."; return 0 ;;
    esac

    detect_platform
    sudo_validate

    # 1. Re-enable normal sleep
    echo "🔧  Restoring pmset defaults…"
    pmset_sudo -a disablesleep 0  2>/dev/null || true
    pmset_sudo -a sleep 1         2>/dev/null || true
    if [ "$ARCH" = "arm64" ]; then
        pmset_sudo -a hibernatemode 3 2>/dev/null || true
        pmset_sudo -a standby 1       2>/dev/null || true
        pmset_sudo -a autopoweroff 1  2>/dev/null || true
    fi
    echo "  ✓ pmset defaults restored"

    # 2. Remove launchd agent
    _launchd_unload 2>/dev/null || true
    if [ -f "$PLIST_PATH" ]; then
        rm -f "$PLIST_PATH"
        echo "  ✓ LaunchAgent plist removed"
    fi

    # 3. Remove sudoers rule
    if [ -f "$SUDOERS_FILE" ]; then
        sudo rm -f "$SUDOERS_FILE"
        echo "  ✓ Sudoers rule removed"
    fi

    # 4. Remove PATH entries from shell rc files
    for RC in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.profile"; do
        if [ -f "$RC" ] && grep -q 'mac-wakelock' "$RC"; then
            # Remove the 3-line block added by installer
            sed -i.bak '/# mac-wakelock/,+1d' "$RC" && rm -f "${RC}.bak"
            echo "  ✓ PATH entry removed from $RC"
        fi
    done

    # 5. Remove ~/.wakelock/
    if [ -d "$DIR" ]; then
        rm -rf "$DIR"
        echo "  ✓ ~/.wakelock/ removed"
    fi

    echo ""
    echo "✅  mac-wakelock fully uninstalled."
    echo ""
}

# ── HELP ──────────────────────────────────────────────────────────────────────
cmd_help() {
    cat <<'EOF'
mac-wakelock — keeps your MacBook awake with the lid closed

  wakelock on         disable sleep (lid closed, battery, everything)
  wakelock off        restore normal sleep behavior
  wakelock status     show current state, battery level, pmset values
  wakelock uninstall  remove mac-wakelock completely
  wakelock help       show this message

Requires sudo for pmset (password prompted once per session).
For details: https://github.com/kuum-oss/mac-wakelock
EOF
}

# ── LaunchAgent helpers ───────────────────────────────────────────────────────
_launchd_load() {
    # Write/refresh the plist (monitor.sh path baked in)
    _write_plist
    # Load (or reload if already loaded)
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load   "$PLIST_PATH"
}

_launchd_unload() {
    if [ -f "$PLIST_PATH" ]; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
    fi
}

_write_plist() {
    mkdir -p "$(dirname "$PLIST_PATH")"
    cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${DIR}/monitor.sh</string>
    </array>

    <!-- Run every 60 seconds -->
    <key>StartInterval</key>
    <integer>60</integer>

    <!-- Auto-start on login while wakelock is active -->
    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <!-- Only keep alive while state file exists -->
        <key>PathState</key>
        <dict>
            <key>${STATE}</key>
            <true/>
        </dict>
    </dict>

    <key>StandardOutPath</key>
    <string>${DIR}/monitor.log</string>
    <key>StandardErrorPath</key>
    <string>${DIR}/monitor.log</string>

    <key>ProcessType</key>
    <string>Background</string>

    <key>ThrottleInterval</key>
    <integer>55</integer>
</dict>
</plist>
PLIST
}

# ── Entry point ───────────────────────────────────────────────────────────────
CMD="${1:-help}"
case "$CMD" in
    on)        cmd_on        ;;
    off)       cmd_off       ;;
    status)    cmd_status    ;;
    uninstall) cmd_uninstall ;;
    help|--help|-h) cmd_help ;;
    *)
        echo "✗  Unknown command: $CMD"
        echo ""
        cmd_help
        exit 1
        ;;
esac
