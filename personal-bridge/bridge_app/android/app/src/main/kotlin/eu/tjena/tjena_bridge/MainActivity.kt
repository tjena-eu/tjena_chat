package eu.tjena.tjena_bridge

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private lateinit var rt: BridgeRuntime
    private val main = Handler(Looper.getMainLooper())
    private var pendingBackup: Pair<ByteArray, MethodChannel.Result>? = null
    private var pendingImport: Pair<String, MethodChannel.Result>? = null

    private val mxidRe = Regex("^@[a-z0-9._=/+-]+:[a-zA-Z0-9.-]+(:\\d+)?$")

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 13+: the bridge's status notification needs this permission.
        if (android.os.Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 4100)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        rt = BridgeRuntime(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "eu.tjena.bridge/native")
            .setMethodCallHandler { call, result -> handle(call, result) }
    }

    private fun bg(result: MethodChannel.Result, fn: () -> Any?) {
        thread {
            try {
                val v = fn()
                main.post { result.success(v) }
            } catch (e: Exception) {
                main.post { result.error("ERR", e.message ?: e.toString(), null) }
            }
        }
    }

    private val prefs get() = getSharedPreferences(BridgeRuntime.PREFS, Context.MODE_PRIVATE)

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getState" -> bg(result) { state().toString() }
            "getSession" -> bg(result) { rt.secrets.load().optJSONObject("session")?.toString() }
            "saveSetup" -> bg(result) {
                val bundle = JSONObject(call.argument<String>("bundle")!!)
                val session = JSONObject(call.argument<String>("session")!!)
                val gateway = call.argument<String>("gateway") ?: BridgeRuntime.DEFAULT_GATEWAY
                val owner = bundle.getString("owner")
                require(mxidRe.matches(owner)) { "invalid owner" }
                require(session.optString("user_id") == owner) { "session user and bridge owner differ" }
                rt.secrets.update {
                    it.put("bundle", bundle)
                    it.put("session", session)
                    it.put("gateway_url", gateway.trimEnd('/'))
                }
                rt.ensureLocalSecrets()
                true
            }
            "updateBundle" -> bg(result) {
                val bundle = JSONObject(call.argument<String>("bundle")!!)
                rt.secrets.update {
                    val old = it.getJSONObject("bundle")
                    require(old.getString("owner") == bundle.getString("owner")) { "owner changed" }
                    it.put("bundle", bundle)
                }
                true
            }
            "start" -> {
                prefs.edit().putBoolean("enabled", true).apply()
                BridgeService.start(this); result.success(true)
            }
            "stop" -> {
                prefs.edit().putBoolean("enabled", false).apply()
                BridgeService.stop(this); result.success(true)
            }
            "restart" -> {
                prefs.edit().putBoolean("enabled", true).apply()
                BridgeService.restart(this); result.success(true)
            }
            "relay" -> bg(result) {
                rt.relayCall(
                    call.argument<String>("method")!!,
                    call.argument<String>("path")!!,
                    call.argument<String>("body"),
                    call.argument<Int>("timeoutMs") ?: 15_000,
                ).toString()
            }
            "setExtraUsers" -> bg(result) {
                val users = call.argument<List<String>>("users") ?: emptyList()
                val owner = rt.secrets.load().getJSONObject("bundle").getString("owner")
                for (u in users) {
                    require(mxidRe.matches(u)) { "\"$u\" is not a full Matrix ID. Wildcards and whole domains are not allowed." }
                    require(u != owner) { "The owner is always admin" }
                }
                rt.secrets.update { it.getJSONObject("settings").put("extra_users", JSONArray(users.distinct())) }
                if (prefs.getBoolean("enabled", false)) BridgeService.restart(this)
                true
            }
            "setGatewayUrl" -> bg(result) {
                val url = call.argument<String>("url")!!.trim().trimEnd('/')
                require(url.startsWith("https://") || url.startsWith("http://")) { "URL must start with https://" }
                rt.secrets.update { it.put("gateway_url", url) }
                if (prefs.getBoolean("enabled", false)) BridgeService.restart(this)
                true
            }
            "wacall" -> bg(result) {
                rt.wacallCall(
                    call.argument<String>("method")!!,
                    call.argument<String>("path")!!,
                    call.argument<String>("body"),
                    call.argument<Int>("timeoutMs") ?: 15_000,
                ).toString()
            }
            "setCallsEnabled" -> bg(result) {
                // The service starts or stops the calls daemon within a few seconds.
                rt.setCallsEnabled(call.argument<Boolean>("on") == true)
                true
            }
            "getOptions" -> bg(result) { rt.options().toString() }
            "setOptions" -> bg(result) {
                val o = JSONObject(call.argument<String>("options")!!)
                val status = o.optString("status_broadcast", "off")
                require(status in setOf("off", "muted", "on")) { "invalid status_broadcast" }
                rt.setOptions(o)
                if (prefs.getBoolean("enabled", false)) BridgeService.restart(this)
                true
            }
            "securityInfo" -> bg(result) { rt.securityInfo() }
            "historyInfo" -> bg(result) { rt.historyInfo() }
            // Fast history import: set double puppeting aside / put it back.
            "doublePuppet" -> bg(result) {
                val action = call.argument<String>("action")!!
                if (action == "status") {
                    rt.doublePuppet("status")
                } else {
                    require(action == "pause" || action == "resume")
                    val wasOn = prefs.getBoolean("enabled", false)
                    stopAndWait()
                    try {
                        rt.doublePuppet(action)
                    } finally {
                        if (wasOn) BridgeService.start(this)
                    }
                }
            }
            "historyCatchup" -> bg(result) {
                val wasOn = prefs.getBoolean("enabled", false)
                stopAndWait()
                try {
                    rt.historyCatchup()
                } finally {
                    if (wasOn) BridgeService.start(this)
                }
            }
            "setNotificationPrefs" -> bg(result) {
                val style = call.argument<String>("style") ?: "normal"
                require(style == "normal" || style == "minimal") { "invalid style" }
                prefs.edit()
                    .putString(BridgeService.PREF_NOTIF_STYLE, style)
                    .putBoolean(BridgeService.PREF_ALERTS, call.argument<Boolean>("alerts") ?: true)
                    .apply()
                // The status notification switches channel on the next start.
                if (prefs.getBoolean("enabled", false)) BridgeService.restart(this)
                true
            }
            "openNotificationSettings" -> {
                val channel = call.argument<String>("channel")
                val i = if (channel != null) {
                    Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                        .putExtra(Settings.EXTRA_CHANNEL_ID, channel)
                } else {
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                }
                startActivity(i)
                result.success(true)
            }
            "requestBatteryExemption" -> {
                try {
                    startActivity(
                        Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                            .setData(Uri.parse("package:$packageName"))
                    )
                    result.success(true)
                } catch (e: Exception) {
                    startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                    result.success(false)
                }
            }
            "recentLog" -> result.success(synchronized(BridgeService.recentLines) { BridgeService.recentLines.joinToString("\n") })
            "exportLogs" -> bg(result) {
                val out = File(cacheDir, "tjena-bridge-log.txt")
                out.bufferedWriter().use { w ->
                    w.write("tjena Bridge log export (secrets, numbers and message text removed)\n")
                    w.write("bridge: ${rt.bridgeVersion()}\nstate: ${BridgeService.state} ${BridgeService.stateDetail ?: ""}\n\n")
                    rt.logDir.listFiles()?.sortedBy { it.name }?.forEach { f ->
                        w.write("==== ${f.name}\n")
                        f.bufferedReader().useLines { ls -> ls.forEach { w.write(LogRedactor.redact(it)); w.newLine() } }
                    }
                    w.write("==== recent process output\n")
                    synchronized(BridgeService.recentLines) { BridgeService.recentLines.forEach { w.write(it); w.newLine() } }
                }
                out.path
            }
            "exportBackup" -> thread {
                // The result is delivered from onActivityResult once the user picked a file.
                try {
                    val pass = call.argument<String>("passphrase")!!
                    val wasEnabled = prefs.getBoolean("enabled", false)
                    stopAndWait()
                    val bytes = try { Backup.export(rt, pass) } finally { if (wasEnabled) BridgeService.start(this) }
                    main.post {
                        pendingBackup = bytes to result
                        startActivityForResult(
                            Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                                .setType("application/octet-stream")
                                .putExtra(Intent.EXTRA_TITLE, "tjena-bridge-backup.tjbk"),
                            REQ_EXPORT
                        )
                    }
                } catch (e: Exception) {
                    main.post { result.error("ERR", e.message ?: e.toString(), null) }
                }
            }
            "importBackup" -> {
                pendingImport = call.argument<String>("passphrase")!! to result
                startActivityForResult(
                    Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*"),
                    REQ_IMPORT
                )
            }
            "wipe" -> bg(result) {
                prefs.edit().putBoolean("enabled", false).apply()
                stopAndWait()
                rt.wipeAll()
                true
            }
            else -> result.notImplemented()
        }
    }

    private fun stopAndWait() {
        BridgeService.stop(this)
        val deadline = System.currentTimeMillis() + 15_000
        while (BridgeService.state != "stopped" && System.currentTimeMillis() < deadline) Thread.sleep(250)
        Thread.sleep(500)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        val uri = data?.data
        when (requestCode) {
            REQ_EXPORT -> {
                val (bytes, res) = pendingBackup ?: return
                pendingBackup = null
                if (uri == null) { res.success(false); return }
                bg(res) { contentResolver.openOutputStream(uri)!!.use { it.write(bytes) }; true }
            }
            REQ_IMPORT -> {
                val (pass, res) = pendingImport ?: return
                pendingImport = null
                if (uri == null) { res.success(false); return }
                bg(res) {
                    val bytes = contentResolver.openInputStream(uri)!!.use { it.readBytes() }
                    stopAndWait()
                    Backup.import(rt, bytes, pass)
                    prefs.edit().putBoolean("enabled", true).apply()
                    BridgeService.start(this)
                    true
                }
            }
        }
    }

    private fun state(): JSONObject {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        val o = JSONObject()
            .put("set_up", rt.secrets.isSetUp())
            .put("enabled", prefs.getBoolean("enabled", false))
            .put("calls_enabled", try { rt.callsEnabled() } catch (_: Exception) { false })
            .put("service_state", BridgeService.state)
            .put("service_detail", BridgeService.stateDetail ?: JSONObject.NULL)
            .put("service_since", BridgeService.stateSince)
            .put("last_exit", BridgeService.lastExit ?: JSONObject.NULL)
            .put("relay", rt.relayStatus())
            .put("app_version", try {
                val pi = packageManager.getPackageInfo(packageName, 0)
                "${pi.versionName} (${androidx.core.content.pm.PackageInfoCompat.getLongVersionCode(pi)})"
            } catch (_: Exception) { "?" })
            .put("battery_unrestricted", pm.isIgnoringBatteryOptimizations(packageName))
            .put("binaries_present", rt.bridgeBin.exists() && rt.relayBin.exists())
            .put("notif_style", prefs.getString(BridgeService.PREF_NOTIF_STYLE, "normal"))
            .put("notif_alerts", prefs.getBoolean(BridgeService.PREF_ALERTS, true))
        if (rt.bridgeBin.exists()) o.put("bridge_version", try { rt.bridgeVersion() } catch (e: Exception) { "?" })
        try {
            val s = rt.secrets.load()
            s.optJSONObject("bundle")?.let { b ->
                o.put("owner", b.optString("owner"))
                    .put("slot", b.optString("slot"))
                    .put("bot_mxid", b.optString("bot_mxid"))
                    .put("server_name", b.optString("server_name"))
            }
            o.put("gateway_url", s.optString("gateway_url", BridgeRuntime.DEFAULT_GATEWAY))
            o.put("homeserver", s.optJSONObject("session")?.optString("homeserver") ?: JSONObject.NULL)
            o.put("extra_users", s.optJSONObject("settings")?.optJSONArray("extra_users") ?: JSONArray())
        } catch (e: Exception) {
            o.put("secrets_error", e.message)
        }
        return o
    }

    companion object {
        private const val REQ_EXPORT = 4101
        private const val REQ_IMPORT = 4102
    }
}
