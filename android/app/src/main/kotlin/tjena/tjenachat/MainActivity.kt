package tjena.tjenachat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor.DartEntrypoint
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

    private var proximityWakeLock: PowerManager.WakeLock? = null

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return provideEngine(getApplicationContext())
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Plugins are registered in provideEngine. Only tjena's own channels
        // are set up here (again on every attach; the handlers are replaced).

        // System state the app reads (network type + Data Saver for media
        // auto-download). Changes are pushed as "networkChanged".
        val system = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tjena.chat/system",
        )
        system.setMethodCallHandler { call, result ->
            when (call.method) {
                "isDataSaverRestricted" -> result.success(isDataSaverRestricted())
                "networkState" -> result.success(networkState())
                else -> result.notImplemented()
            }
        }
        systemChannel = system
        registerNetworkCallback()

        // Proximity screen-off for audio calls
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tjena.chat/call_manager",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireProximityWakeLock" -> {
                    try {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        proximityWakeLock?.release()
                        @Suppress("DEPRECATION")
                        proximityWakeLock = pm.newWakeLock(
                            PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                            "tjenachat:proximity",
                        )
                        proximityWakeLock?.acquire()
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("WAKELOCK_ERROR", e.message, null)
                    }
                }
                "releaseProximityWakeLock" -> {
                    try {
                        proximityWakeLock?.let { if (it.isHeld) it.release() }
                        proximityWakeLock = null
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("WAKELOCK_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private var systemChannel: MethodChannel? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    /**
     * "mobile" for a metered network (cellular, metered hotspot), "wifi" for an
     * unmetered one, "none" when offline. dataSaver: Data Saver restricts us now.
     */
    private fun networkState(): Map<String, Any> {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        val caps = cm?.getNetworkCapabilities(cm.activeNetwork)
        val type = when {
            caps == null -> "none"
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) -> "wifi"
            else -> "mobile"
        }
        // Data Saver only limits metered networks; on Wi-Fi it doesn't apply.
        // Android also reports "restricted" when Background data is off for
        // this app, which has the same effect on mobile data.
        return mapOf(
            "type" to type,
            "dataSaver" to (type == "mobile" && isDataSaverRestricted()),
        )
    }

    private fun registerNetworkCallback() {
        if (networkCallback != null) return
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        val main = Handler(Looper.getMainLooper())
        val notify = { main.post { systemChannel?.invokeMethod("networkChanged", networkState()) } }
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { notify() }
            override fun onLost(network: Network) { notify() }
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) { notify() }
            override fun onBlockedStatusChanged(network: Network, blocked: Boolean) { notify() }
        }
        try {
            cm.registerDefaultNetworkCallback(cb)
            networkCallback = cb
        } catch (e: Exception) {
            // Too many callbacks or no permission: the app still re-reads on resume.
        }
        // Data Saver switched on/off (e.g. from quick settings) doesn't change
        // the network, so the callback above doesn't see it.
        if (dataSaverReceiver == null) {
            val r = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) { notify() }
            }
            try {
                registerReceiver(r, IntentFilter(ConnectivityManager.ACTION_RESTRICT_BACKGROUND_CHANGED))
                dataSaverReceiver = r
            } catch (_: Exception) {}
        }
    }

    private var dataSaverReceiver: BroadcastReceiver? = null

    override fun onDestroy() {
        networkCallback?.let {
            try {
                (getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager)?.unregisterNetworkCallback(it)
            } catch (_: Exception) {}
        }
        networkCallback = null
        dataSaverReceiver?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
        dataSaverReceiver = null
        systemChannel = null
        super.onDestroy()
    }

    // Prevent Flutter engine gets destroyed on back button close.
    override fun createFlutterFragment(): FlutterFragment =
        super.createFlutterFragment().apply {
            arguments?.putBoolean("destroy_engine_with_fragment", false)
        }

    /**
     * True when Data Saver is on AND restricts this app right now.
     * restrictBackgroundStatus is the effective status (metered network,
     * allowlisted app), so only ENABLED means restricted.
     */
    private fun isDataSaverRestricted(): Boolean = try {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        cm?.restrictBackgroundStatus == ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED
    } catch (e: Exception) {
        false
    }

    companion object {
        var engine: FlutterEngine? = null
        fun provideEngine(context: Context): FlutterEngine {
            val eng = engine ?: FlutterEngine(context, emptyArray(), true, false)
            engine = eng
            return eng
        }

        // Make push services run in the same engine.
        // https://codeberg.org/UnifiedPush/flutter-connector/src/branch/main/unifiedpush_android/android/src/main/kotlin/org/unifiedpush/flutter/connector/UnifiedPushService.kt#L17-L32
        fun provideRunningEngine(context: Context): FlutterEngine {
            var eng = engine
            if (eng == null) {
                eng = provideEngine(context)
                eng.getLocalizationPlugin().sendLocalesToFlutter(
                    context.getResources().getConfiguration())
                eng.getDartExecutor().executeDartEntrypoint(
                    DartEntrypoint.createDefault())
            }
            return eng
        }
    }
}
