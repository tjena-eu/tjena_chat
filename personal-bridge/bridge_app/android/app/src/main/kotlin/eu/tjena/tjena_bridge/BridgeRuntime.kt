package eu.tjena.tjena_bridge

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.ServerSocket
import java.net.URL
import java.util.concurrent.TimeUnit

/** Paths, config generation and relay calls shared by the service and the UI channel. */
class BridgeRuntime(val context: Context) {
    val secrets = SecretStore(context)
    val libDir = File(context.applicationInfo.nativeLibraryDir)
    val bridgeBin = File(libDir, "libmautrixwhatsapp.so")
    val relayBin = File(libDir, "librelay.so")
    val dataDir = File(context.filesDir, "bridge").apply { mkdirs() }
    val runDir = File(context.filesDir, "run").apply { mkdirs() }
    val logDir = File(dataDir, "logs").apply { mkdirs() }
    val exampleConfig = File(dataDir, "example-config.yaml")
    val exampleVersion = File(dataDir, "example-config.version")
    val bridgeConfig = File(runDir, "config.yaml")
    val relayConfig = File(runDir, "relay.json")
    val relayStatusFile = File(runDir, "relay-status.json")
    /** Public keys the bridge uploaded, recorded by the relay (security screen). */
    val observedKeysFile = File(dataDir, "observed-keys.json")
    val bridgeDb = File(dataDir, "bridge.db")

    fun bridgeVersion(): String {
        val cache = File(dataDir, "binary.version")
        val stamp = "${bridgeBin.length()}:${bridgeBin.lastModified()}"
        if (cache.exists()) {
            val lines = cache.readLines()
            if (lines.size == 2 && lines[0] == stamp) return lines[1]
        }
        val v = runCapture(listOf(bridgeBin.path, "--version"), 20).trim().lines().firstOrNull() ?: "unknown"
        cache.writeText("$stamp\n$v")
        return v
    }

    fun runCapture(cmd: List<String>, timeoutSec: Long): String {
        val p = ProcessBuilder(cmd).directory(dataDir).redirectErrorStream(true).start()
        val out = p.inputStream.bufferedReader().readText()
        if (!p.waitFor(timeoutSec, TimeUnit.SECONDS)) p.destroyForcibly()
        return out
    }

    /** First-time (or per app update) setup of secrets that never leave the phone. */
    fun ensureLocalSecrets() {
        secrets.update { s ->
            val settings = s.optJSONObject("settings") ?: JSONObject()
            if (!settings.has("prov_secret")) settings.put("prov_secret", SecretStore.randomSecret())
            if (!settings.has("pickle_key")) settings.put("pickle_key", SecretStore.randomSecret())
            if (!settings.has("api_secret")) settings.put("api_secret", SecretStore.randomSecret())
            if (!settings.has("extra_users")) settings.put("extra_users", JSONArray())
            s.put("settings", settings)
            if (!s.has("gateway_url")) s.put("gateway_url", DEFAULT_GATEWAY)
        }
    }

    private fun freePort(): Int = ServerSocket(0).use { it.localPort }

    /**
     * Write bridge config + relay config from the Keystore-encrypted secrets.
     * Returns the relay port. Files are deleted by the service after start.
     */
    fun writeRunConfigs(): Int {
        ensureLocalSecrets()
        val s = secrets.load()
        val bundle = s.getJSONObject("bundle")
        val settings = s.getJSONObject("settings")
        val gateway = s.optString("gateway_url", DEFAULT_GATEWAY)

        // Example config from the bundled bridge version; keeps upstream defaults.
        val version = bridgeVersion()
        if (!exampleConfig.exists() || !exampleVersion.exists() || exampleVersion.readText() != version) {
            exampleConfig.delete()
            runCapture(listOf(bridgeBin.path, "-e", "-c", exampleConfig.path), 30)
            if (!exampleConfig.exists()) throw IllegalStateException("bridge could not generate example config")
            exampleVersion.writeText(version)
        }

        val port = freePort()
        val bundleFile = File(runDir, "bundle.json")
        val settingsFile = File(runDir, "settings.json")
        try {
            bundleFile.writeText(bundle.toString())
            settingsFile.writeText(
                JSONObject()
                    .put("data_dir", dataDir.path)
                    .put("relay_port", port)
                    .put("prov_secret", settings.getString("prov_secret"))
                    .put("pickle_key", settings.getString("pickle_key"))
                    .put("extra_users", settings.optJSONArray("extra_users") ?: JSONArray())
                    .put("log_level", "info")
                    .put("options", settings.optJSONObject("options") ?: JSONObject())
                    .toString()
            )
            val out = runCapture(
                listOf(relayBin.path, "bridge-config", exampleConfig.path, bundleFile.path, settingsFile.path, bridgeConfig.path), 30
            )
            if (!bridgeConfig.exists()) throw IllegalStateException("config generation failed: ${out.take(300)}")
        } finally {
            bundleFile.delete()
            settingsFile.delete()
        }
        relayConfig.writeText(
            JSONObject()
                .put("listen", "127.0.0.1:$port")
                .put("upstream", gateway)
                .put("as_token", bundle.getString("as_token"))
                .put("api_secret", settings.getString("api_secret"))
                .put("prov_secret", settings.getString("prov_secret"))
                .put("owner", bundle.getString("owner"))
                .put("status_file", relayStatusFile.path)
                .put("keys_file", observedKeysFile.path)
                .toString()
        )
        secrets.update { it.getJSONObject("settings").put("relay_port", port) }
        return port
    }

    fun deleteRunConfigs() {
        bridgeConfig.delete()
        relayConfig.delete()
    }

    fun relayStatus(): JSONObject = try {
        JSONObject(relayStatusFile.readText())
    } catch (_: Exception) {
        JSONObject()
    }

    /** HTTP call to the local relay API. Returns {status, body}. */
    fun relayCall(method: String, path: String, body: String?, timeoutMs: Int = 15_000): JSONObject {
        val s = secrets.load()
        val settings = s.getJSONObject("settings")
        val port = settings.optInt("relay_port", 0)
        if (port == 0) return JSONObject().put("status", 0).put("body", "{\"error\":\"bridge not running\"}")
        val conn = URL("http://127.0.0.1:$port$path").openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.connectTimeout = 3000
        conn.readTimeout = timeoutMs
        conn.setRequestProperty("Authorization", "Bearer " + settings.getString("api_secret"))
        if (body != null) {
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.outputStream.use { it.write(body.toByteArray()) }
        }
        return try {
            val code = conn.responseCode
            val stream = if (code >= 400) conn.errorStream else conn.inputStream
            JSONObject().put("status", code).put("body", stream?.bufferedReader()?.readText() ?: "")
        } catch (e: Exception) {
            JSONObject().put("status", 0).put("body", JSONObject().put("error", e.message ?: "error").toString())
        } finally {
            conn.disconnect()
        }
    }

    /** Bridge options (backfill, status updates); see relay Options. */
    fun options(): JSONObject =
        secrets.load().optJSONObject("settings")?.optJSONObject("options") ?: JSONObject()

    fun setOptions(o: JSONObject) {
        secrets.update { it.getJSONObject("settings").put("options", o) }
    }

    /**
     * Read-only key and trust summary from the bridge's own database (relay
     * subcommand). Public keys only; the pickle key stays in this process.
     */
    fun securityInfo(): String {
        val s = secrets.load()
        val bundle = s.getJSONObject("bundle")
        val pickleKey = s.getJSONObject("settings").getString("pickle_key")
        val p = ProcessBuilder(
            listOf(
                relayBin.path, "security-info", bridgeDb.path, pickleKey,
                bundle.getString("owner"), bundle.getString("bot_mxid"), observedKeysFile.path,
            )
        ).directory(dataDir).start()
        val out = p.inputStream.bufferedReader().readText()
        val err = p.errorStream.bufferedReader().readText()
        if (!p.waitFor(30, TimeUnit.SECONDS)) p.destroyForcibly()
        if (p.exitValue() != 0) throw IllegalStateException(err.trim().ifEmpty { "security-info failed" })
        return out
    }

    /** History import summary: bridge DB + JSON log, read-only (relay history-info). */
    fun historyInfo(): String {
        val p = ProcessBuilder(listOf(relayBin.path, "history-info", bridgeDb.path, logDir.path))
            .directory(dataDir).redirectErrorStream(false).start()
        val out = p.inputStream.bufferedReader().readText()
        val err = p.errorStream.bufferedReader().readText()
        if (!p.waitFor(60, TimeUnit.SECONDS)) p.destroyForcibly()
        if (p.exitValue() != 0) throw IllegalStateException(err.trim().ifEmpty { "history-info failed" })
        return out
    }

    /** Lets the bridge finish history imports that stopped early. Bridge must be stopped. */
    fun historyCatchup(): String {
        val p = ProcessBuilder(listOf(relayBin.path, "history-catchup", bridgeDb.path))
            .directory(dataDir).redirectErrorStream(false).start()
        val out = p.inputStream.bufferedReader().readText()
        val err = p.errorStream.bufferedReader().readText()
        if (!p.waitFor(60, TimeUnit.SECONDS)) p.destroyForcibly()
        if (p.exitValue() != 0) throw IllegalStateException(err.trim().ifEmpty { "history-catchup failed" })
        return out
    }

    /** Double-puppet token set aside during a fast history import (relay double-puppet). */
    val dpStash = File(dataDir, "dp-stash.json")

    /** pause / resume (bridge stopped) or status of the fast history import. Returns JSON. */
    fun doublePuppet(action: String): String {
        val p = ProcessBuilder(listOf(relayBin.path, "double-puppet", bridgeDb.path, dpStash.path, action))
            .directory(dataDir).redirectErrorStream(false).start()
        val out = p.inputStream.bufferedReader().readText()
        val err = p.errorStream.bufferedReader().readText()
        if (!p.waitFor(60, TimeUnit.SECONDS)) p.destroyForcibly()
        if (p.exitValue() != 0) throw IllegalStateException(err.trim().ifEmpty { "double-puppet $action failed" })
        return out
    }

    /** Remove everything: secrets, bridge DB, logs. */
    fun wipeAll() {
        secrets.wipe()
        dataDir.deleteRecursively()
        runDir.deleteRecursively()
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
    }

    companion object {
        const val DEFAULT_GATEWAY = "https://wap.tjena.eu"
        const val PREFS = "bridge_prefs"
    }
}
