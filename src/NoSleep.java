import java.io.*;
import java.nio.file.*;
import java.util.regex.*;

public class NoSleep {

    static final Path DIR   = Path.of(System.getProperty("user.home"), ".wakelock");
    static final Path STATE = DIR.resolve("state");

    public static void main(String[] args) throws Exception {
        switch (args.length > 0 ? args[0] : "help") {
            case "on"     -> on();
            case "off"    -> off();
            case "status" -> status();
            default       -> help();
        }
    }

    // ── ON ───────────────────────────────────────────────────────────────────

    static void on() throws Exception {
        if (Files.exists(STATE)) {
            System.out.println("⚡ Already active.  To stop → wakelock off");
            return;
        }
        if (exec("sudo", "pmset", "-a", "sleep", "0") != 0) {
            System.out.println("✗  No sudo access. Re-run install.sh");
            return;
        }
        exec("sudo", "pmset", "-a", "disablesleep", "1");
        Files.writeString(STATE, "active");

        // Start battery monitor detached from this process
        new ProcessBuilder("nohup", "bash", DIR.resolve("monitor.sh").toString())
                .redirectOutput(DIR.resolve("monitor.log").toFile())
                .redirectErrorStream(true)
                .start();

        System.out.println("✅  Sleep disabled — battery, lid closed, everything");
        System.out.println("🔋  Battery monitor running (alert below 20%)");
    }

    // ── OFF ──────────────────────────────────────────────────────────────────

    static void off() throws Exception {
        if (!Files.exists(STATE)) {
            System.out.println("Not active.");
            return;
        }
        // Stop battery monitor
        try { new ProcessBuilder("pkill", "-f", "wakelock/monitor.sh").start().waitFor(); }
        catch (Exception ignored) {}

        exec("sudo", "pmset", "-a", "disablesleep", "0");
        exec("sudo", "pmset", "-a", "sleep", "1");
        Files.deleteIfExists(STATE);
        System.out.println("✅  Normal sleep behavior restored");
    }

    // ── STATUS ───────────────────────────────────────────────────────────────

    static void status() throws Exception {
        boolean active = Files.exists(STATE);
        int     bat    = battery();

        System.out.println("Status : " + (active ? "✅ active" : "❌ inactive"));
        System.out.println("Battery: " + (bat >= 0 ? bat + "%" : "—"));
        if (active && bat >= 0 && bat < 20)
            System.out.println("⚠️  Low battery! Plug in your charger.");
    }

    // ── HELPERS ──────────────────────────────────────────────────────────────

    static int battery() {
        try {
            Process p = new ProcessBuilder("pmset", "-g", "batt").start();
            String  s = new String(p.getInputStream().readAllBytes());
            Matcher m = Pattern.compile("(\\d+)%").matcher(s);
            return m.find() ? Integer.parseInt(m.group(1)) : -1;
        } catch (Exception e) { return -1; }
    }

    static int exec(String... cmd) throws Exception {
        return new ProcessBuilder(cmd).inheritIO().start().waitFor();
    }

    static void help() {
        System.out.println("""
                mac-wakelock — keeps your MacBook awake with the lid closed

                  wakelock on      disable sleep
                  wakelock off     restore sleep
                  wakelock status  current state + battery level
                """);
    }
}