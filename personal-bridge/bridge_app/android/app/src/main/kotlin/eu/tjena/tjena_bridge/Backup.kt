package eu.tjena.tjena_bridge

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.SecureRandom
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Passphrase-encrypted backup of the bridge database and secrets.
 *
 * Format: "TJBK1" | salt(16) | iv(12) | AES-256-GCM(zip)
 * Key: PBKDF2-HMAC-SHA256, 310 000 iterations.
 * The zip holds bridge.db(+wal/shm) and secrets.json.
 */
object Backup {
    private val MAGIC = "TJBK1".toByteArray()
    private const val ITER = 310_000
    // dp-stash.json: double-puppet token set aside during a fast history import.
    private val DB_FILES = listOf("bridge.db", "bridge.db-wal", "bridge.db-shm", "dp-stash.json")

    private fun deriveKey(pass: String, salt: ByteArray): SecretKeySpec {
        val f = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        val key = f.generateSecret(PBEKeySpec(pass.toCharArray(), salt, ITER, 256)).encoded
        return SecretKeySpec(key, "AES")
    }

    /** Bridge must be stopped so the DB is consistent. */
    fun export(rt: BridgeRuntime, passphrase: String): ByteArray {
        require(passphrase.length >= 8) { "Passphrase must have at least 8 characters" }
        val zipBytes = ByteArrayOutputStream().also { bos ->
            ZipOutputStream(bos).use { zip ->
                for (name in DB_FILES) {
                    val f = File(rt.dataDir, name)
                    if (!f.exists()) continue
                    zip.putNextEntry(ZipEntry(name))
                    f.inputStream().use { it.copyTo(zip) }
                    zip.closeEntry()
                }
                zip.putNextEntry(ZipEntry("secrets.json"))
                zip.write(rt.secrets.load().toString().toByteArray())
                zip.closeEntry()
            }
        }.toByteArray()
        val rng = SecureRandom()
        val salt = ByteArray(16).also { rng.nextBytes(it) }
        val iv = ByteArray(12).also { rng.nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, deriveKey(passphrase, salt), GCMParameterSpec(128, iv))
        cipher.updateAAD(MAGIC)
        return MAGIC + salt + iv + cipher.doFinal(zipBytes)
    }

    /** Bridge must be stopped. Replaces DB and secrets. */
    fun import(rt: BridgeRuntime, data: ByteArray, passphrase: String) {
        require(data.size > MAGIC.size + 28 && data.copyOfRange(0, MAGIC.size).contentEquals(MAGIC)) { "Not a tjena bridge backup" }
        val salt = data.copyOfRange(MAGIC.size, MAGIC.size + 16)
        val iv = data.copyOfRange(MAGIC.size + 16, MAGIC.size + 28)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, deriveKey(passphrase, salt), GCMParameterSpec(128, iv))
        cipher.updateAAD(MAGIC)
        val zipBytes = try {
            cipher.doFinal(data, MAGIC.size + 28, data.size - MAGIC.size - 28)
        } catch (e: Exception) {
            throw IllegalArgumentException("Wrong passphrase or damaged backup")
        }
        val entries = HashMap<String, ByteArray>()
        ZipInputStream(ByteArrayInputStream(zipBytes)).use { zip ->
            while (true) {
                val e = zip.nextEntry ?: break
                if (e.name in DB_FILES || e.name == "secrets.json") entries[e.name] = zip.readBytes()
            }
        }
        val secretsJson = entries["secrets.json"] ?: throw IllegalArgumentException("Backup has no secrets")
        val obj = org.json.JSONObject(String(secretsJson))
        require(obj.has("bundle")) { "Backup has no bridge setup" }
        for (name in DB_FILES) File(rt.dataDir, name).delete()
        for ((name, bytes) in entries) if (name in DB_FILES) File(rt.dataDir, name).writeBytes(bytes)
        rt.secrets.save(obj)
        File(rt.dataDir, "example-config.version").delete()
    }
}
