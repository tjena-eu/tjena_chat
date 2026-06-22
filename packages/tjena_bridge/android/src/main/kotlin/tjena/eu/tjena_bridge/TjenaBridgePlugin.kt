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

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
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
                "getState" -> result.success(bridge?.getStateJSON() ?: "{}")
                "requestQRLink" -> { bridge!!.requestQRLink(); result.success(null) }
                "requestPhoneLink" -> {
                    val phone = call.argument<String>("phone")!!
                    bridge!!.requestPhoneLink(phone)
                    result.success(null)
                }
                "confirmPhoneLink" -> {
                    val code = call.argument<String>("code")!!
                    bridge!!.confirmPhoneLink(code)
                    result.success(null)
                }
                "sendText" -> {
                    val portalID = call.argument<String>("portalID")!!
                    val msgID = call.argument<String>("msgID")!!
                    val text = call.argument<String>("text")!!
                    bridge!!.sendText(portalID, msgID, text)
                    result.success(null)
                }
                "sendReaction" -> {
                    val portalID = call.argument<String>("portalID")!!
                    val targetEventID = call.argument<String>("targetEventID")!!
                    val emoji = call.argument<String>("emoji")!!
                    bridge!!.sendReaction(portalID, targetEventID, emoji)
                    result.success(null)
                }
                "sendRedaction" -> {
                    val portalID = call.argument<String>("portalID")!!
                    val targetEventID = call.argument<String>("targetEventID")!!
                    bridge!!.sendRedaction(portalID, targetEventID)
                    result.success(null)
                }
                "markRead" -> {
                    val portalID = call.argument<String>("portalID")!!
                    val eventID = call.argument<String>("eventID")!!
                    bridge!!.markRead(portalID, eventID)
                    result.success(null)
                }
                "setTyping" -> {
                    val portalID = call.argument<String>("portalID")!!
                    val typing = call.argument<Boolean>("typing") ?: false
                    bridge!!.setTyping(portalID, typing)
                    result.success(null)
                }
                "logout" -> { bridge!!.logout(); result.success(null) }
                "forceReset" -> { bridge!!.forceReset(); result.success(null) }
                "refreshRoom" -> {
                    val jid = call.argument<String>("jid") ?: ""
                    bridge?.refreshRoom(jid)
                    result.success(null)
                }
                "sendMedia" -> {
                    val portalID = call.argument<String>("portalID") ?: ""
                    val msgID = call.argument<String>("msgID") ?: ""
                    val mimeType = call.argument<String>("mimeType") ?: ""
                    val data = call.argument<ByteArray>("data") ?: ByteArray(0)
                    bridge!!.sendMedia(portalID, msgID, mimeType, data)
                    result.success(null)
                }
                "sendLocation" -> {
                    val portalID = call.argument<String>("portalID") ?: ""
                    val lat = call.argument<Double>("lat") ?: 0.0
                    val lon = call.argument<Double>("lon") ?: 0.0
                    bridge!!.sendLocation(portalID, lat, lon)
                    result.success(null)
                }
                "requestBackfill" -> {
                    val roomID = call.argument<String>("roomID") ?: ""
                    val days = call.argument<Int>("days") ?: 7
                    val anchorMsgID = call.argument<String>("anchorMsgID") ?: ""
                    val anchorFromMe = call.argument<Boolean>("anchorFromMe") ?: false
                    val anchorTS = (call.argument<Number>("anchorTS") ?: 0).toLong()
                    bridge!!.requestBackfill(roomID, days.toLong(), anchorMsgID, anchorFromMe, anchorTS)
                    result.success(null)
                }
                "listChats" -> result.success(bridge?.listChatsJSON() ?: "[]")
                "listCachedChats" -> result.success(bridge?.listCachedChatsJSON() ?: "[]")
                "backfillFromCache" -> {
                    val roomID = call.argument<String>("roomID") ?: ""
                    val days = call.argument<Int>("days") ?: 30
                    bridge!!.backfillFromCache(roomID, days.toLong())
                    result.success(null)
                }
                "getChatAvatarUrl" -> {
                    val roomID = call.argument<String>("roomID") ?: ""
                    result.success(bridge?.getChatAvatarURL(roomID) ?: "")
                }
                "getLogs" -> result.success(bridge?.getLogs() ?: "(no bridge)")
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
