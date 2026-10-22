package eu.tjena.tjena_bridge

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * All bridge secrets (bridge tokens, provisioning secret, pickle key, relay API
 * secret, the owner's Matrix session) live in one JSON document, encrypted with
 * an AES-GCM key held in the Android Keystore. Nothing secret is stored in plain
 * files; the bridge/relay config files are generated just before start and
 * deleted once both processes have read them.
 *
 * JSON layout:
 *   bundle      provisioner bundle (slot, tokens, bot, owner, ...)
 *   settings    { prov_secret, pickle_key, api_secret, relay_port, extra_users[] }
 *   session     { homeserver, user_id, access_token, device_id }
 *   gateway_url e.g. https://wap.tjena.eu
 */
class SecretStore(private val context: Context) {
    private val file = File(context.filesDir, "secrets.bin")
    private val alias = "tjena_bridge_secrets"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    @Synchronized
    fun load(): JSONObject {
        if (!file.exists()) return JSONObject()
        val data = file.readBytes()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, data, 0, 12))
        return JSONObject(String(cipher.doFinal(data, 12, data.size - 12), Charsets.UTF_8))
    }

    @Synchronized
    fun save(obj: JSONObject) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val ct = cipher.doFinal(obj.toString().toByteArray(Charsets.UTF_8))
        val tmp = File(file.path + ".tmp")
        tmp.writeBytes(cipher.iv + ct)
        tmp.renameTo(file)
    }

    @Synchronized
    fun update(fn: (JSONObject) -> Unit) {
        val obj = load()
        fn(obj)
        save(obj)
    }

    @Synchronized
    fun wipe() {
        file.delete()
        try {
            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(alias)
        } catch (_: Exception) {
        }
    }

    fun isSetUp(): Boolean = try {
        load().has("bundle")
    } catch (_: Exception) {
        false
    }

    companion object {
        private val rng = SecureRandom()
        fun randomSecret(bytes: Int = 32): String {
            val b = ByteArray(bytes)
            rng.nextBytes(b)
            return android.util.Base64.encodeToString(b, android.util.Base64.NO_WRAP or android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING)
        }
    }
}
