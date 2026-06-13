# mac-wakelock

> Keeps your MacBook **fully awake** — lid closed, on battery or AC power — with two terminal commands.

Built with Java + macOS `pmset`. Includes a battery monitor that alerts you when charge drops below 20%.

---

## Why this exists

`caffeinate -s` only prevents sleep on AC power. Closing the lid on battery still puts the Mac to sleep, suspending all processes. This tool uses `pmset` at the system level to prevent that entirely.

---

## Features

- Prevents sleep with the **lid closed on battery**
- **Battery alert** — sound + macOS notification below 20%
- One-time setup, then just `wakelock on` / `wakelock off`
- No password prompt after install

---

## Requirements

- macOS 12+
- Java 11+
- Admin access (for initial setup only)

---

## Installation

```bash
git clone https://github.com/yourusername/mac-wakelock.git
cd mac-wakelock
chmod +x install.sh && ./install.sh
```

The installer:

1. Checks your Java version
2. Compiles `NoSleep.java` to `~/.wakelock/`
3. Creates the `wakelock` command in your PATH
4. Writes a battery monitor script that runs in the background
5. Configures passwordless `sudo pmset` via `/etc/sudoers`

> You enter your password **once** during setup — never again.

---

## Usage

```bash
wakelock on       # disable sleep (lid closed, battery, everything)
wakelock off      # restore normal sleep behavior
wakelock status   # show current state and battery level
```

### Example session

```
$ wakelock on
✅  Sleep disabled — battery, lid closed, everything
🔋  Battery monitor running (alert below 20%)

$ wakelock status
Status : ✅ active
Battery: 54%

$ wakelock off
✅  Normal sleep behavior restored
```

---

## How it works

```
pmset -a sleep 0          # disable idle sleep timer
pmset -a disablesleep 1   # prevent lid-close sleep (works on battery too)
```

The battery monitor runs as a detached background process (`nohup`). It checks charge every 60 seconds and fires a native macOS notification + Sosumi sound when battery falls below 20%, then resets after charging back above 25%.

---

## Files installed

```
~/.wakelock/
├── NoSleep.class    compiled Java
├── wakelock         shell wrapper → java -cp ~/.wakelock NoSleep "$@"
├── monitor.sh       battery monitor (runs in background while active)
├── monitor.log      monitor output
└── state            exists only while active (used as a lock file)
```

---

## ⚠️ Warning

| Risk | Detail |
|------|--------|
| 🔋 Battery drain | The Mac won't sleep at all — battery drains faster |
| 🌡️ Heat | Don't leave it in a closed bag for extended periods |
| 🔄 Persistence | Active until you run `wakelock off` or reboot |

**Always run `wakelock off` when you no longer need it.**

---

## License

MIT