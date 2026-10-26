package tjena.tjenachat

import android.content.Context
import android.net.ConnectivityManager
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

        // System state the app reads (Data Saver for tap-to-load media).
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tjena.chat/system",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isDataSaverRestricted" -> result.success(isDataSaverRestricted())
                else -> result.notImplemented()
            }
        }

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
