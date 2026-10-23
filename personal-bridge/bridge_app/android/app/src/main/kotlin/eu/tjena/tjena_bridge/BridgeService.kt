package eu.tjena.tjena_bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * Foreground service that supervises two processes from nativeLibraryDir:
 *   librelay.so              local relay (127.0.0.1) -> gateway
 *   libmautrixwhatsapp.so    the unmodified bridge, talking only to the relay
 * Restarts them with backoff, holds wake + Wi-Fi locks, START_STICKY.
 */
class BridgeService : Service() {
    private lateinit var rt: BridgeRuntime
    private val running = AtomicBoolean(false)
    private var supervisor: Thread? = null
    @Volatile private var relayProc: Process? = null
    @Volatile private var bridgeProc: Process? = null
    @Volatile private var wacallProc: Process? = null
    private var wacallStartedAt = 0L
    private var wacallBackoffMs = 5_000L
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private val main = android.os.Handler(android.os.Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        rt = BridgeRuntime(this)
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // Stopping waits for the bridge to exit; keep that off the main thread.
            running.set(false)
            thread {
                stopEverything()
                main.post { stopSelf() }
            }
            return START_NOT_STICKY
        }
        val notification = buildNotification("Starting…")
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIF_ID, notification)
        }
        if (intent?.action == ACTION_RESTART) {
            thread { killProcesses() }
        }
        if (running.compareAndSet(false, true)) {
            acquireLocks()
            supervisor = thread(name = "bridge-supervisor") { supervise() }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        running.set(false)
        thread { stopEverything() }
        super.onDestroy()
    }

    private fun stopEverything() {
        running.set(false)
        killProcesses()
        supervisor?.interrupt()
        releaseLocks()
        setState("stopped", null)
    }

    private fun killProcesses() {
        stopWacall()
        bridgeProc?.let { p -> p.destroy(); if (!p.waitFor(8, java.util.concurrent.TimeUnit.SECONDS)) p.destroyForcibly() }
        relayProc?.let { p -> p.destroy(); if (!p.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)) p.destroyForcibly() }
    }

    // ------------------------------------------------------------------ supervisor

    private fun supervise() {
        var backoffMs = 2_000L
        while (running.get()) {
            val started = System.currentTimeMillis()
            var fatal: String? = null
            try {
                if (!rt.secrets.isSetUp()) {
                    setState("not_set_up", "Bridge is not set up")
                    break
                }
                setState("starting", null)
                haltReason = null
                dbFix = null
                rt.writeRunConfigs()
                relayProc = launch(listOf(rt.relayBin.path, "-config", rt.relayConfig.path), "relay")
                Thread.sleep(500)
                bridgeProc = launch(listOf(rt.bridgeBin.path, "-c", rt.bridgeConfig.path, "-n"), "bridge")
                wacallBackoffMs = 5_000L
                startWacall()
                // Both processes read their config at startup; remove the files
                // so secrets aren't left on disk in plaintext.
                thread {
                    Thread.sleep(15_000)
                    rt.deleteRunConfigs()
                }
                setState("running", null)
                updateNotification()
                fatal = waitForExit()
            } catch (_: InterruptedException) {
                break
            } catch (e: Exception) {
                Log.e(TAG, "supervisor error", e)
                setState("error", e.message)
            }
            killProcesses()
            rt.deleteRunConfigs()
            if (!running.get()) break
            if (dpResumeDue) {
                dpResumeDue = false
                try {
                    Log.i(TAG, "fast import done, double puppeting back on: ${rt.doublePuppet("resume")}")
                } catch (e: Exception) {
                    Log.e(TAG, "double puppet resume failed", e)
                }
                backoffMs = 2_000L
                continue
            }
            val fix = dbFix
            if (fix != null) {
                dbFix = null
                if (applyDbFix(fix)) {
                    backoffMs = 2_000L
                    continue
                }
            }
            if (fatal != null) {
                // Don't restart: another phone took over, or the server revoked us.
                setState("halted", fatal)
                updateNotification()
                running.set(false)
                break
            }
            if (System.currentTimeMillis() - started > 10 * 60_000) backoffMs = 2_000L
            setState("restarting", "Restarting in ${backoffMs / 1000}s")
            updateNotification()
            try {
                Thread.sleep(backoffMs)
            } catch (_: InterruptedException) {
                break
            }
            backoffMs = (backoffMs * 2).coerceAtMost(5 * 60_000L)
        }
        releaseLocks()
    }

    private fun launch(cmd: List<String>, name: String): Process {
        val pb = ProcessBuilder(cmd).directory(rt.dataDir).redirectErrorStream(true)
        pb.environment()["TMPDIR"] = cacheDir.path
        pb.environment()["HOME"] = rt.dataDir.path
        val p = pb.start()
        thread(name = "$name-output") {
            try {
                p.inputStream.bufferedReader().forEachLine { line -> onOutput(name, line) }
            } catch (_: Exception) {
            }
        }
        return p
    }

    private fun onOutput(name: String, line: String) {
        val clean = LogRedactor.redact(line)
        synchronized(recentLines) {
            recentLines.addLast("[$name] $clean")
            while (recentLines.size > 300) recentLines.removeFirst()
        }
        if (line.contains("closed by another instance")) {
            haltReason = "Another device is now running this bridge. Use Settings → Make this phone the active bridge to take it back."
        }
        // Fresh database (new phone / reinstall without backup) but the bot
        // already has cross-signing keys on the server: let the bridge create
        // new ones. The opposite case (keys gone from the server) is fixed by
        // forgetting the stale local recovery key.
        if (line.contains("Server already has cross-signing keys, but no key in database")) {
            dbFix = "overwrite"
        } else if (line.contains("No keys on server, but database already has recovery key")) {
            dbFix = "delete"
        }
    }

    @Volatile private var dbFix: String? = null

    /** Applies a recovery_key fix to the bridge's own database (bridge stopped). */
    private fun applyDbFix(fix: String): Boolean = try {
        val db = android.database.sqlite.SQLiteDatabase.openDatabase(
            java.io.File(rt.dataDir, "bridge.db").path, null, android.database.sqlite.SQLiteDatabase.OPEN_READWRITE
        )
        db.use {
            if (fix == "overwrite") {
                it.execSQL(
                    "INSERT INTO kv_store (bridge_id, key, value) VALUES ('', 'recovery_key', 'overwrite') " +
                        "ON CONFLICT (bridge_id, key) DO UPDATE SET value = 'overwrite'"
                )
            } else {
                it.execSQL("DELETE FROM kv_store WHERE bridge_id = '' AND key = 'recovery_key'")
            }
        }
        Log.i(TAG, "applied recovery_key fix: $fix")
        true
    } catch (e: Exception) {
        Log.e(TAG, "recovery_key fix failed", e)
        false
    }

    @Volatile private var haltReason: String? = null
    @Volatile private var dpResumeDue = false
    private var dpCheckedAt = 0L

    /** During a fast history import: true once double puppeting should come back. */
    private fun fastImportDone(): Boolean {
        if (!rt.dpStash.exists()) return false
        val now = System.currentTimeMillis()
        if (now - dpCheckedAt < 60_000) return false
        dpCheckedAt = now
        return try {
            org.json.JSONObject(rt.doublePuppet("status")).optBoolean("import_done", false)
        } catch (e: Exception) {
            Log.w(TAG, "double puppet status: ${e.message}")
            false
        }
    }

    // ------------------------------------------------------------ calls daemon

    /** Starts the calls daemon if calls are on. Its failures never stop the bridge. */
    private fun startWacall() {
        if (!rt.callsEnabled() || !rt.wacallBin.exists()) return
        try {
            val p = launch(listOf(rt.wacallBin.path), "calls")
            p.outputStream.use { it.write(rt.wacallConfig().toByteArray()) }
            wacallProc = p
            wacallStartedAt = System.currentTimeMillis()
        } catch (e: Exception) {
            Log.e(TAG, "calls daemon start failed", e)
        }
    }

    private fun stopWacall() {
        wacallProc?.let { p -> p.destroy(); if (!p.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)) p.destroyForcibly() }
        wacallProc = null
    }

    /** Keeps the calls daemon in line with the setting; restarts it with backoff. */
    private fun superviseWacall() {
        val on = rt.callsEnabled()
        val p = wacallProc
        if (!on) {
            if (p != null) stopWacall()
            return
        }
        if (p != null && p.isAlive) return
        val now = System.currentTimeMillis()
        if (p != null) {
            Log.w(TAG, "calls daemon exited (${p.exitValue()})")
            wacallProc = null
            if (now - wacallStartedAt > 10 * 60_000) wacallBackoffMs = 5_000L
            wacallStartedAt = now // backoff starts now
            return
        }
        if (now - wacallStartedAt < wacallBackoffMs) return
        startWacall()
        wacallBackoffMs = (wacallBackoffMs * 2).coerceAtMost(5 * 60_000L)
    }

    /** Waits until either process exits. Returns a reason if we must not restart. */
    private fun waitForExit(): String? {
        while (running.get()) {
            val relayDead = relayProc?.isAlive == false
            val bridgeDead = bridgeProc?.isAlive == false
            val status = rt.relayStatus()
            if (status.optBoolean("revoked", false)) {
                return "The server no longer accepts this phone: the bridge was removed, or another phone took it over. " +
                    "Use Settings → Make this phone the active bridge, or set it up again from the tjena app."
            }
            if (relayDead || bridgeDead) {
                val which = if (bridgeDead) "bridge exited (${bridgeProc?.exitValue()})" else "relay exited (${relayProc?.exitValue()})"
                Log.w(TAG, which)
                lastExit = "$which at ${java.util.Date()}"
                return haltReason
            }
            superviseWacall()
            if (fastImportDone()) {
                // Restart once with the double-puppet token back in place.
                dpResumeDue = true
                return null
            }
            Thread.sleep(2_000)
            if (System.currentTimeMillis() % 30_000 < 2_000) updateNotification()
        }
        return null
    }

    // ------------------------------------------------------------------ locks

    private fun acquireLocks() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "tjena:bridge").apply {
            setReferenceCounted(false); acquire()
        }
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "tjena:bridge").apply {
            setReferenceCounted(false); acquire()
        }
    }

    private fun releaseLocks() {
        try { wakeLock?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
        try { wifiLock?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
    }

    // ------------------------------------------------------------------ notification

    private fun createChannel() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, "Bridge status", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shows that the WhatsApp bridge is running"
            }
        )
        // Android requires a notification while the service runs. MIN keeps it
        // out of the status bar and folded at the bottom of the shade.
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_MIN, "Bridge status (minimal)", NotificationManager.IMPORTANCE_MIN).apply {
                description = "Required while the bridge runs; shown as small as Android allows"
                setShowBadge(false)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ALERTS, "Bridge problems", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "When the bridge stops or can't reach tjena for a while"
            }
        )
    }

    private val prefs get() = getSharedPreferences(BridgeRuntime.PREFS, Context.MODE_PRIVATE)

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
        )
        val minimal = prefs.getString(PREF_NOTIF_STYLE, "normal") == "minimal"
        return Notification.Builder(this, if (minimal) CHANNEL_MIN else CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("tjena Bridge")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .build()
    }

    private var alertShownFor: String? = null
    private var upstreamDownSince = 0L

    /** One alert per problem: bridge halted, or tjena unreachable for 10 minutes. */
    private fun checkAlerts(st: org.json.JSONObject) {
        if (!prefs.getBoolean(PREF_ALERTS, true)) return
        val now = System.currentTimeMillis()
        val up = st.optBoolean("upstream_connected")
        upstreamDownSince = if (up || state != "running") 0L else if (upstreamDownSince == 0L) now else upstreamDownSince
        val problem = when {
            state == "halted" -> "The bridge stopped: ${stateDetail ?: ""}"
            upstreamDownSince != 0L && now - upstreamDownSince > 10 * 60_000 ->
                "The bridge can't reach tjena for 10 minutes. Check Wi-Fi on this phone."
            else -> null
        }
        val nm = getSystemService(NotificationManager::class.java)
        if (problem == null) {
            if (alertShownFor != null) nm.cancel(ALERT_ID)
            alertShownFor = null
            return
        }
        if (alertShownFor == problem) return
        alertShownFor = problem
        val open = PendingIntent.getActivity(
            this, 1, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
        )
        nm.notify(
            ALERT_ID,
            Notification.Builder(this, CHANNEL_ALERTS)
                .setSmallIcon(android.R.drawable.stat_notify_error)
                .setContentTitle("tjena Bridge needs attention")
                .setContentText(problem)
                .setStyle(Notification.BigTextStyle().bigText(problem))
                .setContentIntent(open)
                .setAutoCancel(true)
                .build()
        )
    }

    private fun updateNotification() {
        val st = rt.relayStatus()
        val text = when (state) {
            "running" -> if (st.optBoolean("upstream_connected")) "Connected to tjena" else "Running, connecting to tjena…"
            "halted" -> "Stopped: ${stateDetail ?: ""}"
            "restarting" -> stateDetail ?: "Restarting…"
            else -> state
        }
        getSystemService(NotificationManager::class.java).notify(NOTIF_ID, buildNotification(text))
        checkAlerts(st)
    }

    private fun setState(s: String, detail: String?) {
        state = s
        stateDetail = detail
        stateSince = System.currentTimeMillis()
    }

    companion object {
        const val TAG = "BridgeService"
        const val CHANNEL = "bridge"
        const val CHANNEL_MIN = "bridge_min"
        const val CHANNEL_ALERTS = "bridge_alerts"
        const val NOTIF_ID = 1
        const val ALERT_ID = 2
        const val PREF_NOTIF_STYLE = "notif_style"
        const val PREF_ALERTS = "notif_alerts"
        const val ACTION_STOP = "eu.tjena.bridge.STOP"
        const val ACTION_RESTART = "eu.tjena.bridge.RESTART"

        @Volatile var state: String = "stopped"
        @Volatile var stateDetail: String? = null
        @Volatile var stateSince: Long = 0
        @Volatile var lastExit: String? = null
        val recentLines = ArrayDeque<String>()

        fun start(ctx: Context) {
            ctx.startForegroundService(Intent(ctx, BridgeService::class.java))
        }

        fun restart(ctx: Context) {
            ctx.startForegroundService(Intent(ctx, BridgeService::class.java).setAction(ACTION_RESTART))
        }

        fun stop(ctx: Context) {
            ctx.startService(Intent(ctx, BridgeService::class.java).setAction(ACTION_STOP))
        }
    }
}

class BootReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val prefs = context.getSharedPreferences(BridgeRuntime.PREFS, Context.MODE_PRIVATE)
        if (prefs.getBoolean("enabled", false) && SecretStore(context).isSetUp()) {
            BridgeService.start(context)
        }
    }
}

/** Removes secrets and personal data from log lines before they are shown or exported. */
object LogRedactor {
    private val patterns = listOf(
        Regex("(?i)(access_token|as_token|hs_token|token|secret|password|pickle_key)([\"'=: ]+)[^\"'&\\s,}]+") to "$1$2[redacted]",
        Regex("Bearer [A-Za-z0-9._~+/=-]+") to "Bearer [redacted]",
        Regex("\\+?\\b\\d{9,15}\\b") to "[number]",
        Regex("\\b\\d{9,15}@(s\\.whatsapp\\.net|lid|g\\.us)") to "[jid]",
        Regex("(?i)\"(body|formatted_body|text|caption)\":\"(\\\\.|[^\"\\\\])*\"") to "\"$1\":\"[content]\"",
    )

    fun redact(line: String): String {
        var out = line.replace(Regex("\u001B\\[[0-9;]*m"), "")
        for ((re, rep) in patterns) out = re.replace(out, rep)
        return out
    }

    fun redactFile(src: File, dst: File) {
        dst.bufferedWriter().use { w ->
            src.bufferedReader().useLines { lines -> lines.forEach { w.write(redact(it)); w.newLine() } }
        }
    }
}
