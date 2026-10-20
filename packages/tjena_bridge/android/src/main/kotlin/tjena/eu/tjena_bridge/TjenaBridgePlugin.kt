package tjena.eu.tjena_bridge

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import ffi.Bridge
import ffi.Ffi

/**
 * Flutter plugin wrapping the gomobile-bound Go bridge.
 *
 * Method channel  "tjena.eu/bridge"  handles all Dart→Go calls.
 * Event channel   "tjena.eu/bridge/events"  streams all Go→Dart events (JSON strings).
 *
 * The gomobile AAR exposes Go package "ffi" as Java package "ffi".
 * Factory: ffi.Ffi.new_(dataDir) — "new" is reserved in Java so gomobile appends underscore.
 *
 * THREADING: Flutter delivers method calls on the platform MAIN thread, and every
 * call here crosses into Go and blocks until it returns — a send waits on a
 * network round-trip, a media send on an upload. Running those inline froze the
 * UI thread and Android killed the app with an ANR (a send over a
 * just-dropped Wi-Fi link or a VPN was the reliable way to reproduce it). So no
 * Go call happens on the main thread: each is dispatched to an executor and only
 * the Result callback is posted back, as MethodChannel.Result requires.
 */
class TjenaBridgePlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null

    /**
     * Events that arrived while Dart wasn't listening (stream not subscribed
     * yet, or cancelled and not re-subscribed). Go has already acked those
     * messages to WhatsApp, so dropping them here lost them for good. Only
     * touched on the main thread; flushed in order on the next onListen.
     */
    private val pendingEvents = ArrayDeque<String>()
    private val maxPendingEvents = 5000
    private val mainHandler = Handler(Looper.getMainLooper())

    // The Go Bridge instance — null until start() succeeds.
    // Volatile: created and used from the executor threads below.
    @Volatile
    private var bridge: Bridge? = null

    // Needed to read the system Data Saver setting and watch the network.
    private var appContext: Context? = null

    /**
     * Ordering-sensitive calls (sends, link/account lifecycle) run on one thread
     * so two messages can never swap places on the wire.
     */
    private val serialExec: ExecutorService =
        Executors.newSingleThreadExecutor { r -> Thread(r, "tjena-bridge") }

    /**
     * Reads and long background transfers (backfill, media downloads) run here,
     * so polling the connection state stays responsive while a send is in
     * flight, and a slow upload doesn't hold up the chat list.
     */
    private val ioExec: ExecutorService =
        Executors.newFixedThreadPool(3) { r -> Thread(r, "tjena-bridge-io") }

    /** Methods safe to run concurrently: read-only queries and transfers. */
    private val ioMethods = setOf(
        "getState", "listAccounts", "listChats", "listCachedChats",
        "getLogs", "getSignalLogs", "getSignalStateJSON", "getProxy",
        "countPendingMedia", "getChatAvatarUrl", "getGroupMembers",
        "isDataSaverEnabled", "backfillFromCache", "requestBackfill",
        "requestServerHistory", "downloadPendingForChat", "downloadPendingMedia",
        "fixChat",
    )

    /** Returned by [handle] for an unknown method, so the dispatcher can reply. */
    private object NotImplemented

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "tjena.eu/bridge")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "tjena.eu/bridge/events")
        eventChannel.setStreamHandler(this)
        registerNetworkCallback()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        unregisterNetworkCallback()
        val b = bridge
        bridge = null
        // stop() blocks (closes sockets and the sqlite store) — keep it off main.
        serialExec.execute { b?.stop() }
        serialExec.shutdown()
        ioExec.shutdown()
    }

    // --- Network monitoring ---

    private var netCallback: ConnectivityManager.NetworkCallback? = null

    // Last known "the default network can actually reach the internet" state, so
    // onCapabilitiesChanged only reports a real transition, not every update.
    @Volatile
    private var lastValidated: Boolean? = null

    private val networkChangeRunnable = Runnable {
        ioExec.execute {
            try {
                bridge?.onNetworkChange()
            } catch (t: Throwable) {
                // Older AAR without onNetworkChange — nothing to do but log.
                android.util.Log.w("TjenaBridge", "onNetworkChange unavailable: $t")
            }
        }
    }

    /**
     * A socket bound to the old route survives a network change as a half-open
     * connection: no FIN arrives, so the Go side keeps reporting "connected"
     * while sends disappear. Nothing in whatsmeow notices for three minutes, so
     * tell the bridge as soon as Android tells us.
     */
    private fun onNetworkChanged(reason: String) {
        android.util.Log.i("TjenaBridge", "network changed ($reason) — refreshing bridge socket")
        // A single transition (a VPN coming up) fires several callbacks; coalesce
        // them, and give the new route a moment to settle before reconnecting.
        mainHandler.removeCallbacks(networkChangeRunnable)
        mainHandler.postDelayed(networkChangeRunnable, 1500)
    }

    private fun registerNetworkCallback() {
        val ctx = appContext ?: return
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE)
            as? ConnectivityManager ?: return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                onNetworkChanged("available")
            }

            override fun onLost(network: Network) {
                lastValidated = null
                onNetworkChanged("lost")
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                val validated =
                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                if (lastValidated != validated) {
                    lastValidated = validated
                    if (validated) onNetworkChanged("validated")
                }
            }
        }
        try {
            cm.registerDefaultNetworkCallback(cb)
            netCallback = cb
        } catch (e: Exception) {
            android.util.Log.w("TjenaBridge", "network callback registration failed: $e")
        }
    }

    private fun unregisterNetworkCallback() {
        val ctx = appContext ?: return
        val cb = netCallback ?: return
        netCallback = null
        mainHandler.removeCallbacks(networkChangeRunnable)
        try {
            (ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager)
                ?.unregisterNetworkCallback(cb)
        } catch (e: Exception) {
            // Already unregistered.
        }
    }

    // --- EventChannel.StreamHandler ---

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        eventSink = sink
        if (sink != null) {
            while (pendingEvents.isNotEmpty()) sink.success(pendingEvents.removeFirst())
        }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // --- MethodChannel.MethodCallHandler ---

    // Account id from the call, defaulting to "default" for legacy callers.
    private fun acc(call: MethodCall): String =
        call.argument<String>("accountID") ?: "default"

    /**
     * True when the system's Data Saver is on AND it actually restricts this app
     * right now.
     *
     * getRestrictBackgroundStatus() reports the *effective* status, so it already
     * accounts for the current network being metered and for the user having
     * allowlisted this app (which yields WHITELISTED, not ENABLED). Only ENABLED
     * means "data is being saved for us", so that is the single case we treat as
     * restricted — on unmetered Wi-Fi it reports DISABLED even with Data Saver
     * switched on, which is exactly the behaviour we want.
     */
    private fun isDataSaverRestricted(): Boolean {
        val ctx = appContext ?: return false
        return try {
            val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE)
                as? ConnectivityManager ?: return false
            cm.restrictBackgroundStatus ==
                ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED
        } catch (e: Exception) {
            false
        }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        val exec = if (call.method in ioMethods) ioExec else serialExec
        try {
            exec.execute {
                val reply: Any?
                try {
                    reply = handle(call)
                } catch (t: Throwable) {
                    mainHandler.post {
                        result.error("BRIDGE_ERROR", t.message ?: t.toString(), null)
                    }
                    return@execute
                }
                mainHandler.post {
                    if (reply === NotImplemented) result.notImplemented()
                    else result.success(reply)
                }
            }
        } catch (e: Exception) {
            // Executor rejected the task (engine detaching).
            result.error("BRIDGE_ERROR", "bridge shutting down", null)
        }
    }

    /** Runs the actual Go call. Always off the main thread. */
    private fun handle(call: MethodCall): Any? = when (call.method) {
        "start" -> {
            val dataDir = call.argument<String>("dataDir")!!
            if (bridge == null) {
                val b = Ffi.new_(dataDir)
                b.setListener(buildListener())
                bridge = b
            }
            bridge!!.start()
            null
        }
        "stop" -> {
            bridge?.stop()
            null
        }
        // ---- Account management ----
        "addAccount" -> bridge?.addAccount() ?: ""
        "removeAccount" -> {
            bridge!!.removeAccount(acc(call))
            null
        }
        "listAccounts" -> bridge?.listAccountsJSON() ?: "[]"
        // ---- WhatsApp (per account; accountID defaults to "default") ----
        "getState" -> bridge?.getStateJSON(acc(call)) ?: "{}"
        "requestQRLink" -> {
            bridge!!.requestQRLink(acc(call))
            null
        }
        "requestPhoneLink" -> {
            val phone = call.argument<String>("phone")!!
            bridge!!.requestPhoneLink(acc(call), phone)
            null
        }
        "confirmPhoneLink" -> null
        "sendText" -> {
            val portalID = call.argument<String>("portalID")!!
            val msgID = call.argument<String>("msgID")!!
            val text = call.argument<String>("text")!!
            bridge!!.sendText(acc(call), portalID, msgID, text)
            null
        }
        "sendReaction" -> {
            val portalID = call.argument<String>("portalID")!!
            val targetEventID = call.argument<String>("targetEventID")!!
            val emoji = call.argument<String>("emoji")!!
            bridge!!.sendReaction(acc(call), portalID, targetEventID, emoji)
            null
        }
        "sendRedaction" -> {
            val portalID = call.argument<String>("portalID")!!
            val targetEventID = call.argument<String>("targetEventID")!!
            bridge!!.sendRedaction(acc(call), portalID, targetEventID)
            null
        }
        "markRead" -> {
            val portalID = call.argument<String>("portalID")!!
            val eventID = call.argument<String>("eventID")!!
            bridge!!.markRead(acc(call), portalID, eventID)
            null
        }
        "setTyping" -> {
            val portalID = call.argument<String>("portalID")!!
            val typing = call.argument<Boolean>("typing") ?: false
            bridge!!.setTyping(acc(call), portalID, typing)
            null
        }
        "logout" -> {
            bridge!!.logout(acc(call))
            null
        }
        "forceReset" -> {
            bridge!!.forceReset(acc(call))
            null
        }
        "refreshRoom" -> {
            val jid = call.argument<String>("jid") ?: ""
            bridge?.refreshRoom(acc(call), jid)
            null
        }
        "sendMedia" -> {
            val portalID = call.argument<String>("portalID") ?: ""
            val msgID = call.argument<String>("msgID") ?: ""
            val mimeType = call.argument<String>("mimeType") ?: ""
            val data = call.argument<ByteArray>("data") ?: ByteArray(0)
            val caption = call.argument<String>("caption") ?: ""
            val thumbnail = call.argument<ByteArray>("thumbnail") ?: ByteArray(0)
            val width = (call.argument<Int>("width") ?: 0).toLong()
            val height = (call.argument<Int>("height") ?: 0).toLong()
            bridge!!.sendMedia(
                acc(call), portalID, msgID, mimeType, data, caption, thumbnail, width, height,
            )
            null
        }
        "sendLocation" -> {
            val portalID = call.argument<String>("portalID") ?: ""
            val lat = call.argument<Double>("lat") ?: 0.0
            val lon = call.argument<Double>("lon") ?: 0.0
            bridge!!.sendLocation(acc(call), portalID, lat, lon)
            null
        }
        "requestBackfill" -> {
            val roomID = call.argument<String>("roomID") ?: ""
            val days = call.argument<Int>("days") ?: 7
            val anchorMsgID = call.argument<String>("anchorMsgID") ?: ""
            val anchorFromMe = call.argument<Boolean>("anchorFromMe") ?: false
            val anchorTS = (call.argument<Number>("anchorTS") ?: 0).toLong()
            bridge!!.requestBackfill(
                acc(call), roomID, days.toLong(), anchorMsgID, anchorFromMe, anchorTS,
            )
            null
        }
        "listChats" -> bridge?.listChatsJSON(acc(call)) ?: "[]"
        "listCachedChats" -> bridge?.listCachedChatsJSON(acc(call)) ?: "[]"
        "backfillFromCache" -> {
            val roomID = call.argument<String>("roomID") ?: ""
            val days = call.argument<Int>("days") ?: 30
            bridge!!.backfillFromCache(acc(call), roomID, days.toLong())
        }
        "requestServerHistory" -> {
            val roomID = call.argument<String>("roomID") ?: ""
            val days = call.argument<Int>("days") ?: 30
            bridge!!.requestServerHistory(acc(call), roomID, days.toLong())
            null
        }
        "fixChat" -> {
            val roomID = call.argument<String>("roomID") ?: ""
            val days = call.argument<Int>("days") ?: 7
            bridge?.fixChat(acc(call), roomID, days.toLong()) ?: "{}"
        }
        "rejectCall" -> {
            val callerJID = call.argument<String>("callerJID") ?: ""
            val callID = call.argument<String>("callID") ?: ""
            bridge!!.rejectCall(acc(call), callerJID, callID)
            null
        }
        "clearCache" -> {
            bridge!!.clearCache(acc(call))
            null
        }
        "setDeferMedia" -> {
            val defer = call.argument<Boolean>("defer") ?: false
            bridge?.setDeferMedia(defer)
            null
        }
        "downloadPendingForChat" -> {
            val roomID = call.argument<String>("roomID") ?: ""
            val limit = call.argument<Int>("limit") ?: 0
            bridge?.downloadPendingForChat(acc(call), roomID, limit.toLong())
            null
        }
        "downloadPendingMedia" -> {
            val roomID = call.argument<String>("roomID") ?: ""
            val msgID = call.argument<String>("msgID") ?: ""
            bridge?.downloadPendingMedia(acc(call), roomID, msgID)
            null
        }
        "countPendingMedia" -> {
            val roomID = call.argument<String>("roomID") ?: ""
            (bridge?.countPendingMedia(acc(call), roomID) ?: 0L).toInt()
        }
        "isDataSaverEnabled" -> isDataSaverRestricted()
        "getChatAvatarUrl" -> {
            val roomID = call.argument<String>("roomID") ?: ""
            bridge?.getChatAvatarURL(acc(call), roomID) ?: ""
        }
        "getGroupMembers" -> {
            val roomID = call.argument<String>("roomID") ?: ""
            bridge?.getGroupMembersJSON(acc(call), roomID) ?: "[]"
        }
        "getLogs" -> bridge?.getLogs(acc(call)) ?: "(no bridge)"
        "setProxy" -> {
            val url = call.argument<String>("url") ?: ""
            bridge?.setProxy(acc(call), url)
            null
        }
        "getProxy" -> bridge?.getProxy(acc(call)) ?: ""
        "onForeground" -> {
            bridge?.onForeground()
            null
        }
        "onBackground" -> {
            bridge?.onBackground()
            null
        }
        // ---- stubs: not in current AAR, return safe no-ops ----
        "manualSync" -> null
        "syncRoom" -> null
        "clearPersistedRooms" -> null
        "setBackfillConfig" -> null
        // ---- Signal bridge ----
        "startSignal" -> {
            bridge!!.startSignal()
            null
        }
        "stopSignal" -> {
            bridge?.stopSignal()
            null
        }
        "getSignalStateJSON" ->
            bridge?.getSignalStateJSON()
                ?: "{\"linked\":false,\"connected\":false,\"phone\":\"\"}"
        "requestSignalQR" -> {
            bridge!!.requestSignalQR()
            null
        }
        "signalLogout" -> {
            bridge!!.signalLogout()
            null
        }
        "signalManualSync" -> {
            bridge!!.signalManualSync()
            null
        }
        "signalSyncRoom" -> {
            val chatID = call.argument<String>("chatID")
                ?: call.argument<String>("portalID") ?: ""
            bridge!!.signalSyncRoom(chatID)
            null
        }
        "clearSignalRooms" -> {
            bridge?.clearSignalRooms()
            null
        }
        "getSignalLogs" -> bridge?.getSignalLogs() ?: "(no bridge)"
        else -> NotImplemented
    }

    // Delivers to whichever sink is current *when the event arrives* (not the
    // one captured at creation), buffering while there is none.
    private fun buildListener(): GoEventListener =
        GoEventListener { payload ->
            // gomobile callbacks arrive on a Go goroutine — marshal to main thread.
            mainHandler.post {
                val sink = eventSink
                if (sink != null) {
                    sink.success(payload)
                } else {
                    if (pendingEvents.size >= maxPendingEvents) pendingEvents.removeFirst()
                    pendingEvents.addLast(payload)
                }
            }
        }
}

/** Kotlin implementation of the Go EventListener interface from the gomobile AAR. */
class GoEventListener(private val callback: (String) -> Unit) : ffi.EventListener {
    override fun onEvent(payload: String) = callback(payload)
}
