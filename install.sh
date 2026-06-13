#!/usr/bin/env bash
set -euo pipefail

DIR="$HOME/.wakelock"
SRC="$(cd "$(dirname "$0")" && pwd)/src"

echo ""
echo "╔══════════════════════════════════╗"
echo "║     mac-wakelock  installer      ║"
echo "╚══════════════════════════════════╝"
echo ""

# ── 1. Check/Install Java ─────────────────────────────────────────────────────
JAVA_CMD="java"
JAVAC_CMD="javac"
NEEDS_JAVA=0

get_java_version() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        echo "0"
        return
    fi
    # Extracts the major version number safely
    local ver
    ver=$("$cmd" -version 2>&1 | awk -F '"' '/version/{print $2}' | cut -d. -f1)
    if [[ "$ver" =~ ^[0-9]+$ ]]; then
        echo "$ver"
    else
        echo "0"
    fi
}

CURRENT_VER=$(get_java_version "java")
if [ "$CURRENT_VER" -lt 11 ]; then
    echo "⚠️  Java 11+ not found (found: $CURRENT_VER). Trying to install/resolve automatically..."
    NEEDS_JAVA=1
fi

if [ "$NEEDS_JAVA" -eq 1 ]; then
    if command -v brew &>/dev/null; then
        echo "🍺  Homebrew detected. Installing openjdk..."
        brew install openjdk
        
        if [ -x "/opt/homebrew/opt/openjdk/bin/java" ]; then
            JAVA_CMD="/opt/homebrew/opt/openjdk/bin/java"
            JAVAC_CMD="/opt/homebrew/opt/openjdk/bin/javac"
        elif [ -x "/usr/local/opt/openjdk/bin/java" ]; then
            JAVA_CMD="/usr/local/opt/openjdk/bin/java"
            JAVAC_CMD="/usr/local/opt/openjdk/bin/javac"
        fi
        
        JDK_PATH=""
        if [ -d "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk" ]; then
            JDK_PATH="/opt/homebrew/opt/openjdk/libexec/openjdk.jdk"
        elif [ -d "/usr/local/opt/openjdk/libexec/openjdk.jdk" ]; then
            JDK_PATH="/usr/local/opt/openjdk/libexec/openjdk.jdk"
        fi
        if [ -n "$JDK_PATH" ]; then
            echo "🔗  Setting up system symlink for openjdk..."
            sudo ln -sfn "$JDK_PATH" /Library/Java/JavaVirtualMachines/openjdk.jdk || true
        fi
    else
        echo "📦  Homebrew not found. Downloading a portable JDK from Adoptium..."
        UNAME_M=$(uname -m)
        ARCH="x64"
        if [ "$UNAME_M" = "arm64" ] || [ "$UNAME_M" = "aarch64" ]; then
            ARCH="aarch64"
        fi
        
        ADOPTIUM_URL="https://api.adoptium.net/v3/binary/latest/17/ga/mac/${ARCH}/jdk/hotspot/normal/eclipse"
        echo "Downloading JDK from: $ADOPTIUM_URL"
        
        mkdir -p "$DIR"
        if curl -L -f -o "$DIR/jdk.tar.gz" "$ADOPTIUM_URL"; then
            echo "Unpacking JDK..."
            mkdir -p "$DIR/jdk"
            tar -xzf "$DIR/jdk.tar.gz" -C "$DIR/jdk" --strip-components 1
            rm -f "$DIR/jdk.tar.gz"
            
            JAVA_CMD="$DIR/jdk/Contents/Home/bin/java"
            JAVAC_CMD="$DIR/jdk/Contents/Home/bin/javac"
            echo "✓  Portable JDK installed to $DIR/jdk"
        else
            echo "✗  Failed to download JDK. Please install Java 11+ manually: https://adoptium.net"
            exit 1
        fi
    fi
fi

# Verify the resolved java/javac commands
VER=$("$JAVA_CMD" -version 2>&1 | awk -F '"' '/version/{print $2}' | cut -d. -f1)
echo "✓  Using Java $VER ($JAVA_CMD)"

# ── 2. Compile ────────────────────────────────────────────────────────────────
mkdir -p "$DIR"
"$JAVAC_CMD" -d "$DIR" "$SRC/NoSleep.java"
echo "✓  Compiled → $DIR"

# ── 3. Battery monitor script ─────────────────────────────────────────────────
cat > "$DIR/monitor.sh" << 'EOF'
#!/usr/bin/env bash
# Runs in the background while wakelock is active.
# Fires a sound + notification when battery drops below 20%.
THRESHOLD=20
WARNED=0
STATE="$HOME/.wakelock/state"

while [ -f "$STATE" ]; do
    BAT=$(pmset -g batt | grep -o '[0-9]*%' | tr -d '%' | head -1)

    if [ -n "$BAT" ] && [ "$BAT" -lt "$THRESHOLD" ] && [ "$WARNED" -eq 0 ]; then
        osascript -e "display notification \"Battery: ${BAT}%. Plug in your charger!\" \
            with title \"mac-wakelock 🔋\" sound name \"Sosumi\""
        osascript -e "beep 3"
        WARNED=1
    elif [ -n "$BAT" ] && [ "$BAT" -ge $(( THRESHOLD + 5 )) ]; then
        WARNED=0   # reset after charging back up
    fi

    sleep 60
done
EOF
chmod +x "$DIR/monitor.sh"
echo "✓  Battery monitor ready"

# ── 4. wakelock command ───────────────────────────────────────────────────────
cat > "$DIR/wakelock" << EOF
#!/usr/bin/env bash
exec "$JAVA_CMD" -cp "$DIR" NoSleep "\$@"
EOF
chmod +x "$DIR/wakelock"
echo "✓  wakelock command created"

# ── 5. Add to PATH ────────────────────────────────────────────────────────────
PROFILE=""
[ -f "$HOME/.zshrc" ]                             && PROFILE="$HOME/.zshrc"
[ -z "$PROFILE" ] && [ -f "$HOME/.bash_profile" ] && PROFILE="$HOME/.bash_profile"
[ -z "$PROFILE" ] && [ -f "$HOME/.bashrc" ]        && PROFILE="$HOME/.bashrc"

if [ -n "$PROFILE" ] && ! grep -qF 'mac-wakelock' "$PROFILE"; then
    { echo ""; echo "# mac-wakelock"; echo "export PATH=\"\$HOME/.wakelock:\$PATH\""; } >> "$PROFILE"
    echo "✓  PATH updated in $PROFILE"
else
    echo "✓  PATH already configured"
fi

# ── 6. Sudoers — password-free pmset ─────────────────────────────────────────
echo ""
echo "🔐  Configuring sudo (you'll enter your password once, never again)..."
USER_NAME="$(whoami)"
LINE="${USER_NAME} ALL=(ALL) NOPASSWD: /usr/bin/pmset"

# Check if sudoers is already configured via /etc/sudoers or files in /etc/sudoers.d
ALREADY_CONFIGURED=0
if sudo grep -qF "$LINE" /etc/sudoers 2>/dev/null; then
    ALREADY_CONFIGURED=1
elif [ -d "/etc/sudoers.d" ] && sudo grep -rqF "$LINE" /etc/sudoers.d 2>/dev/null; then
    ALREADY_CONFIGURED=1
fi

if [ "$ALREADY_CONFIGURED" -eq 1 ]; then
    echo "✓  sudoers already configured"
else
    TMP_SUDOERS=$(mktemp /tmp/wakelock_sudoers.XXXXXX)
    echo "$LINE" > "$TMP_SUDOERS"
    chmod 0440 "$TMP_SUDOERS"

    # Validate syntax with visudo
    if sudo visudo -cf "$TMP_SUDOERS" >/dev/null 2>&1; then
        # If /etc/sudoers.d exists and is included, use it
        if [ -d "/etc/sudoers.d" ] && sudo grep -q "^#includedir /etc/sudoers.d" /etc/sudoers 2>/dev/null; then
            sudo mkdir -p /etc/sudoers.d
            sudo cp "$TMP_SUDOERS" /etc/sudoers.d/mac-wakelock
            sudo chmod 0440 /etc/sudoers.d/mac-wakelock
            echo "✓  sudoers configured safely via /etc/sudoers.d/mac-wakelock"
        else
            # Fallback: safely append to /etc/sudoers with validation
            TMP_FULL=$(mktemp /tmp/sudoers.XXXXXX)
            sudo cp /etc/sudoers "$TMP_FULL"
            sudo chmod 0640 "$TMP_FULL"
            sudo sh -c "echo '$LINE' >> '$TMP_FULL'"
            sudo chmod 0440 "$TMP_FULL"
            if sudo visudo -cf "$TMP_FULL" >/dev/null 2>&1; then
                sudo cp "$TMP_FULL" /etc/sudoers
                sudo chmod 0440 /etc/sudoers
                echo "✓  sudoers configured safely via /etc/sudoers"
            else
                echo "✗  Failed to validate modified /etc/sudoers. Changes aborted."
                rm -f "$TMP_FULL" "$TMP_SUDOERS"
                exit 1
            fi
            rm -f "$TMP_FULL"
        fi
    else
        echo "✗  Generated sudoers rule failed syntax validation. Aborting."
        rm -f "$TMP_SUDOERS"
        exit 1
    fi
    rm -f "$TMP_SUDOERS"
fi

# Make wakelock available in the current terminal session too
export PATH="$DIR:$PATH"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅  Installation complete!"
echo ""
echo "   wakelock on      disable sleep"
echo "   wakelock off     restore sleep"
echo "   wakelock status  current state + battery"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "wakelock is available in this terminal right now."
echo "In new terminals it will work automatically."
echo ""