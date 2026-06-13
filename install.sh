#!/usr/bin/env bash
# install.sh — mac-wakelock installer
# Requires: macOS 12+ (Monterey or later), bash 3.2+, sudo access.
# No Java, no Homebrew dependency.

set -euo pipefail

DIR="$HOME/.wakelock"
SRC="$(cd "$(dirname "$0")" && pwd)/src"
PLIST_LABEL="com.kuum.wakelock.battery"
SUDOERS_FILE="/etc/sudoers.d/mac-wakelock"

echo ""
echo "╔══════════════════════════════════╗"
echo "║     mac-wakelock  installer      ║"
echo "╚══════════════════════════════════╝"
echo ""

# ── 1. macOS version gate ─────────────────────────────────────────────────────
OS_VER="$(sw_vers -productVersion 2>/dev/null || echo "0.0")"
OS_MAJOR="$(echo "$OS_VER" | cut -d. -f1)"
ARCH="$(uname -m)"

echo "🔍  Detected: macOS $OS_VER on $ARCH"

if [ "$OS_MAJOR" -lt 12 ]; then
    echo "✗  mac-wakelock requires macOS 12 (Monterey) or later."
    echo "   Detected: macOS $OS_VER"
    exit 1
fi

if [ "$OS_MAJOR" -ge 15 ]; then
    echo "⚠️  macOS $OS_VER: Low Power Mode may override pmset disablesleep on battery."
    echo "   If sleep persists, disable Low Power Mode in System Settings → Battery."
fi
echo ""

# ── 2. Install files to ~/.wakelock/ ─────────────────────────────────────────
mkdir -p "$DIR"

install -m 755 "$SRC/wakelock.sh" "$DIR/wakelock"
install -m 755 "$SRC/monitor.sh"  "$DIR/monitor.sh"
echo "✓  Installed wakelock and monitor to $DIR"

# ── 3. Add to PATH ────────────────────────────────────────────────────────────
PROFILE=""
[ -f "$HOME/.zshrc" ]                             && PROFILE="$HOME/.zshrc"
[ -z "$PROFILE" ] && [ -f "$HOME/.bash_profile" ] && PROFILE="$HOME/.bash_profile"
[ -z "$PROFILE" ] && [ -f "$HOME/.bashrc" ]        && PROFILE="$HOME/.bashrc"

if [ -n "$PROFILE" ]; then
    if ! grep -qF 'mac-wakelock' "$PROFILE"; then
        { echo ""; echo "# mac-wakelock"; echo "export PATH=\"\$HOME/.wakelock:\$PATH\""; } >> "$PROFILE"
        echo "✓  PATH updated in $PROFILE"
    else
        echo "✓  PATH already configured in $PROFILE"
    fi
else
    echo "⚠️  Could not detect shell rc file. Add this manually:"
    echo "   export PATH=\"\$HOME/.wakelock:\$PATH\""
fi

# ── 4. Sudoers — passwordless pmset ──────────────────────────────────────────
echo ""
echo "🔐  Configuring sudo access for pmset (enter your password once)…"
USER_NAME="$(whoami)"

# We only grant NOPASSWD for /usr/bin/pmset — nothing else.
LINE="${USER_NAME} ALL=(root) NOPASSWD: /usr/bin/pmset"

ALREADY_CONFIGURED=0
if [ -f "$SUDOERS_FILE" ] && sudo grep -qF "$LINE" "$SUDOERS_FILE" 2>/dev/null; then
    ALREADY_CONFIGURED=1
elif sudo grep -qF "$LINE" /etc/sudoers 2>/dev/null; then
    ALREADY_CONFIGURED=1
fi

if [ "$ALREADY_CONFIGURED" -eq 1 ]; then
    echo "✓  sudoers rule already in place"
else
    TMP_SUDOERS=$(mktemp /tmp/wakelock_sudoers.XXXXXX)
    printf '%s\n' \
        "# mac-wakelock: allow pmset without password" \
        "# Managed by install.sh — remove with: wakelock uninstall" \
        "$LINE" > "$TMP_SUDOERS"
    chmod 0440 "$TMP_SUDOERS"

    if sudo visudo -cf "$TMP_SUDOERS" >/dev/null 2>&1; then
        sudo mkdir -p /etc/sudoers.d
        sudo cp "$TMP_SUDOERS" "$SUDOERS_FILE"
        sudo chmod 0440 "$SUDOERS_FILE"
        echo "✓  sudoers rule written to $SUDOERS_FILE"
    else
        echo "✗  sudoers syntax validation failed — aborting."
        rm -f "$TMP_SUDOERS"
        exit 1
    fi
    rm -f "$TMP_SUDOERS"
fi

# Make wakelock available immediately in this terminal session
export PATH="$DIR:$PATH"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅  mac-wakelock installed successfully!"
echo ""
echo "   Platform : $ARCH / macOS $OS_VER"
echo "   Installed: $DIR/wakelock"
echo ""
echo "   wakelock on         → disable sleep"
echo "   wakelock off        → restore sleep"
echo "   wakelock status     → current state + battery"
echo "   wakelock uninstall  → remove everything"
echo ""
echo "   wakelock is available in this terminal right now."
echo "   In new terminals it will work automatically."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ "$OS_MAJOR" -ge 15 ]; then
    echo "⚠️  Reminder: macOS $OS_VER — disable Low Power Mode if sleep persists on battery."
    echo ""
fi