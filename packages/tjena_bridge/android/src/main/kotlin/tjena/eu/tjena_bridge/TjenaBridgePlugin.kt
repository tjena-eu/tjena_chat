package tjena.eu.tjena_bridge

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
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
 */
class TjenaBridgePlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // The Go Bridge instance — null until start() succeeds.
    private var bridge: Bridge? = null

    // Needed to read the system Data Saver setting.
    private var appContext: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "tjena.eu/bridge")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "tjena.eu/bridge/events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        bridge?.stop()
        bridge = null
    }

    // --- EventChannel.StreamHandler ---

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        eventSink = sink
        // Wire existing bridge to the new sink (re-attach after hot-restart).
        bridge?.setListener(buildListener(sink))
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
                as? android.net.ConnectivityManager ?: return false
            cm.restrictBackgroundStatus ==
                android.net.ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED
        } catch (e: Exception) {
            false
        }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            when (call.method) {
                "start" -> {
                    val dataDir = call.argument<String>("dataDir")!!
                    if (bridge == null) {
                        val b = Ffi.new_(dataDir)
                        b.setListener(buildListener(eventSink))
                        bridge = b
                    }
                    bridge!!.start()
                    result.success(null)
                }
                "stop" -> {
                    bridge?.stop()
                    result.success(null)
                }
                // ---- Account management ----
                "addAccount" -> result.success(bridge?.addAccount() ?: "")
                "removeAccount" -> {
                    bridge!!.removeAccount(acc(call))
                    result.success(null)
                }
                "listAccounts" -> result.success(bridge?.listAccountsJSON() ?: "[]")
                // ---- WhatsApp (per account; accountID defaults to "default") ----
                "getState" -> result.success(bridge?.getStateJSON(acc(call)) ?: "{}")
                "requestQRLink" -> { bridge!!.requestQRLink(acc(call)); result.success(null) }
                "requestPhoneLink" -> {
                    val phone = call.argument<String>("phone")!!
                    bridge!!.requestPhoneLink(acc(call), phone)
                    result.success(null)
                }
                "confirmPhoneLink" -> result.success(null)
                "sendText" -> {
                    val portalID = call.argument<String>("portalID")!!
                    val msgID = call.argument<String>("msgID")!!
                    val text = call.argument<String>("text")!!
                    bridge!!.sendText(acc(call), portalID, msgID, text)
                    result.success(null)
                }
                "sendReaction" -> {
                    val portalID = call.argument<String>("portalID")!!
                    val targetEventID = call.argument<String>("targetEventID")!!
                    val emoji = call.argument<String>("emoji")!!
                    bridge!!.sendReaction(acc(call), portalID, targetEventID, emoji)
                    result.success(null)
                }
                "sendRedaction" -> {
                    val portalID = call.argument<String>("portalID")!!
                    val targetEventID = call.argument<String>("targetEventID")!!
                    bridge!!.sendRedaction(acc(call), portalID, targetEventID)
                    result.success(null)
                }
                "markRead" -> {
                    val portalID = call.argument<String>("portalID")!!
                    val eventID = call.argument<String>("eventID")!!
                    bridge!!.markRead(acc(call), portalID, eventID)
                    result.success(null)
                }
                "setTyping" -> {
                    val portalID = call.argument<String>("portalID")!!
                    val typing = call.argument<Boolean>("typing") ?: false
                    bridge!!.setTyping(acc(call), portalID, typing)
                    result.success(null)
                }
                "logout" -> { bridge!!.logout(acc(call)); result.success(null) }
                "forceReset" -> { bridge!!.forceReset(acc(call)); result.success(null) }
                "refreshRoom" -> {
                    val jid = call.argument<String>("jid") ?: ""
                    bridge?.refreshRoom(acc(call), jid)
                    result.success(null)
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
                    bridge!!.sendMedia(acc(call), portalID, msgID, mimeType, data, caption, thumbnail, width, height)
                    result.success(null)
                }
                "sendLocation" -> {
                    val portalID = call.argument<String>("portalID") ?: ""
                    val lat = call.argument<Double>("lat") ?: 0.0
                    val lon = call.argument<Double>("lon") ?: 0.0
                    bridge!!.sendLocation(acc(call), portalID, lat, lon)
                    result.success(null)
                }
                "requestBackfill" -> {
                    val roomID = call.argument<String>("roomID") ?: ""
                    val days = call.argument<Int>("days") ?: 7
                    val anchorMsgID = call.argument<String>("anchorMsgID") ?: ""
                    val anchorFromMe = call.argument<Boolean>("anchorFromMe") ?: false
                    val anchorTS = (call.argument<Number>("anchorTS") ?: 0).toLong()
                    bridge!!.requestBackfill(acc(call), roomID, days.toLong(), anchorMsgID, anchorFromMe, anchorTS)
                    result.success(null)
                }
                "listChats" -> result.success(bridge?.listChatsJSON(acc(call)) ?: "[]")
                "listCachedChats" -> result.success(bridge?.listCachedChatsJSON(acc(call)) ?: "[]")
                "backfillFromCache" -> {
                    val roomID = call.argument<String>("roomID") ?: ""
                    val days = call.argument<Int>("days") ?: 30
                    val count = bridge!!.backfillFromCache(acc(call), roomID, days.toLong())
                    result.success(count)
                }
                "requestServerHistory" -> {
                    val roomID = call.argument<String>("roomID") ?: ""
                    val days = call.argument<Int>("days") ?: 30
                    bridge!!.requestServerHistory(acc(call), roomID, days.toLong())
                    result.success(null)
                }
                "rejectCall" -> {
                    val callerJID = call.argument<String>("callerJID") ?: ""
                    val callID = call.argument<String>("callID") ?: ""
                    bridge!!.rejectCall(acc(call), callerJID, callID)
                    result.success(null)
                }
                "clearCache" -> {
                    bridge!!.clearCache(acc(call))
                    result.success(null)
                }
                "setDeferMedia" -> {
                    val defer = call.argument<Boolean>("defer") ?: false
                    bridge?.setDeferMedia(defer)
                    result.success(null)
                }
                "downloadPendingForChat" -> {
                    val roomID = call.argument<String>("roomID") ?: ""
                    val limit = call.argument<Int>("limit") ?: 0
                    bridge?.downloadPendingForChat(acc(call), roomID, limit.toLong())
                    result.success(null)
                }
                "downloadPendingMedia" -> {
                    val roomID = call.argument<String>("roomID") ?: ""
                    val msgID = call.argument<String>("msgID") ?: ""
                    bridge?.downloadPendingMedia(acc(call), roomID, msgID)
                    result.success(null)
                }
                "countPendingMedia" -> {
                    val roomID = call.argument<String>("roomID") ?: ""
                    result.success((bridge?.countPendingMedia(acc(call), roomID) ?: 0L).toInt())
                }
                "isDataSaverEnabled" -> {
                    result.success(isDataSaverRestricted())
                }
                "getChatAvatarUrl" -> {
                    val roomID = call.argument<String>("roomID") ?: ""
                    result.success(bridge?.getChatAvatarURL(acc(call), roomID) ?: "")
                }
                "getGroupMembers" -> {
                    val roomID = call.argument<String>("roomID") ?: ""
                    result.success(bridge?.getGroupMembersJSON(acc(call), roomID) ?: "[]")
                }
                "getLogs" -> result.success(bridge?.getLogs(acc(call)) ?: "(no bridge)")
                "setProxy" -> {
                    val url = call.argument<String>("url") ?: ""
                    bridge?.setProxy(acc(call), url)
                    result.success(null)
                }
                "getProxy" -> result.success(bridge?.getProxy(acc(call)) ?: "")
                "onForeground" -> { bridge?.onForeground(); result.success(null) }
                "onBackground" -> { bridge?.onBackground(); result.success(null) }
                // ---- stubs: not in current AAR, return safe no-ops ----
                "manualSync" -> result.success(null)
                "syncRoom" -> result.success(null)
                "clearPersistedRooms" -> result.success(null)
                "setBackfillConfig" -> result.success(null)
                // ---- Signal bridge ----
                "startSignal" -> { bridge!!.startSignal(); result.success(null) }
                "stopSignal" -> { bridge?.stopSignal(); result.success(null) }
                "getSignalStateJSON" -> result.success(
                    bridge?.getSignalStateJSON()
                        ?: "{\"linked\":false,\"connected\":false,\"phone\":\"\"}"
                )
                "requestSignalQR" -> { bridge!!.requestSignalQR(); result.success(null) }
                "signalLogout" -> { bridge!!.signalLogout(); result.success(null) }
                "signalManualSync" -> { bridge!!.signalManualSync(); result.success(null) }
                "signalSyncRoom" -> {
                    val chatID = call.argument<String>("chatID") ?: call.argument<String>("portalID") ?: ""
                    bridge!!.signalSyncRoom(chatID)
                    result.success(null)
                }
                "clearSignalRooms" -> { bridge?.clearSignalRooms(); result.success(null) }
                "getSignalLogs" -> result.success(bridge?.getSignalLogs() ?: "(no bridge)")
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("BRIDGE_ERROR", e.message, null)
        }
    }

    private fun buildListener(sink: EventChannel.EventSink?): GoEventListener =
        GoEventListener { payload ->
            // gomobile callbacks arrive on a Go goroutine — marshal to main thread.
            mainHandler.post { sink?.success(payload) }
        }
}

/** Kotlin implementation of the Go EventListener interface from the gomobile AAR. */
class GoEventListener(private val callback: (String) -> Unit) : ffi.EventListener {
    override fun onEvent(payload: String) = callback(payload)
}
