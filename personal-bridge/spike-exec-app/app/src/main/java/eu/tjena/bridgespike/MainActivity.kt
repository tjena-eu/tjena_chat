package eu.tjena.bridgespike

import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.widget.ScrollView
import android.widget.TextView
import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Step 0 spike (items 2 + 3): can an app exec the unmodified mautrix-whatsapp
 * android/arm64 build from nativeLibraryDir, and does it reach SQLite, DNS and TLS?
 *
 * Every line is also logged with tag "BridgeSpike" (adb logcat -s BridgeSpike).
 */
class MainActivity : Activity() {
    private lateinit var out: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        out = TextView(this).apply { setTextIsSelectable(true); textSize = 11f; setPadding(24, 48, 24, 24) }
        setContentView(ScrollView(this).apply { addView(out) })
        thread { runSpike() }
    }

    private fun say(line: String) {
        Log.i("BridgeSpike", line)
        runOnUiThread { out.append(line + "\n") }
    }

    private fun run(bin: File, workDir: File, vararg args: String, timeoutSec: Long = 30): Int {
        say("\n$ ${bin.name} ${args.joinToString(" ")}")
        val p = ProcessBuilder(listOf(bin.absolutePath) + args)
            .directory(workDir).redirectErrorStream(true).start()
        val reader = thread {
            p.inputStream.bufferedReader().forEachLine { say("  " + it.take(400)) }
        }
        if (!p.waitFor(timeoutSec, TimeUnit.SECONDS)) {
            say("  (still running after ${timeoutSec}s -> stopping)")
            p.destroy()
            if (!p.waitFor(5, TimeUnit.SECONDS)) p.destroyForcibly()
        }
        reader.join(2000)
        say("  exit=${p.exitValue()}")
        return p.exitValue()
    }

    private fun runSpike() {
        say("Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}) ${Build.MANUFACTURER} ${Build.MODEL}")
        say("ABIs: ${Build.SUPPORTED_ABIS.joinToString()}")
        val libDir = File(applicationInfo.nativeLibraryDir)
        val bin = File(libDir, "libmautrixwhatsapp.so")
        say("nativeLibraryDir=$libDir")
        say("binary exists=${bin.exists()} size=${bin.length()} canExecute=${bin.canExecute()}")
        if (!bin.exists()) { say("FAIL: binary not extracted"); return }

        val work = File(filesDir, "bridge").apply { mkdirs() }
        val cfg = File(work, "config.yaml")
        val reg = File(work, "registration.yaml")
        cfg.delete(); reg.delete()

        // 1. Can we exec it at all?
        if (run(bin, work, "--version") != 0) { say("FAIL: exec"); return }

        // 2. Generate the example config (exercises the bridge's own config code).
        run(bin, work, "-e", "-c", cfg.absolutePath)
        if (!cfg.exists()) { say("FAIL: no config generated"); return }
        val db = File(work, "bridge.db").absolutePath
        cfg.writeText(
            cfg.readText()
                .replace("type: postgres", "type: sqlite3-fk-wal")
                .replace("uri: postgres://user:password@host/database?sslmode=disable",
                    "uri: file:$db?_txlock=immediate")
                .replace("address: http://example.localhost:8008", "address: https://matrix.tjena.eu")
                .replace("domain: example.com", "domain: tjena.eu")
                .replace("websocket: false", "websocket: true")
                .replace("ping_interval_seconds: 0", "ping_interval_seconds: 30")
                .replace("id: whatsapp\n", "id: wa-spike\n")
                .replace(
                    "        \"*\": relay\n        \"example.com\": user\n        \"@admin:example.com\": admin\n",
                    "        \"@spike-owner:tjena.eu\": admin\n")
        )
        say("config written (${cfg.length()} bytes)")

        // 3. Generate a registration (needs no network).
        run(bin, work, "-g", "-c", cfg.absolutePath, "-r", reg.absolutePath)
        say("registration exists=${reg.exists()}")

        // 4. Start the bridge. Expected: SQLite DB created and migrated, then
        //    an M_UNKNOWN_TOKEN error from matrix.tjena.eu because this
        //    registration isn't loaded in Synapse. Reaching that error proves
        //    exec, cgo SQLite, DNS and TLS all work on this device.
        run(bin, work, "-c", cfg.absolutePath, "-r", reg.absolutePath, "--no-update", timeoutSec = 25)
        say("db exists=${File(db).exists()} size=${File(db).length()}")
        say("\nSPIKE DONE")
    }
}
