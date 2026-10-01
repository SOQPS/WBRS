package com.lrs

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

// Idle registration does no disk/Keystore work. Tokens never enter logs or a
// plaintext preference; all storage/crypto runs off the platform UI thread.
class TimewebTokenStore private constructor(private val context: Context) {
    companion object {
        const val CHANNEL = "com.lrs/timeweb_token_store_v1"
        const val PREFERENCES = "timeweb_secure_tokens_v1"
        private const val ALIAS = "clrs.timeweb.tokens.aes.v1"
        private const val SLOT = "ciphertext"
        private const val LIMIT = 32768
        private const val DEADLINE_MS = 5000L
        @Volatile private var instance: TimewebTokenStore? = null
        fun get(context: Context): TimewebTokenStore = instance ?: synchronized(this) {
            instance ?: TimewebTokenStore(context.applicationContext).also { instance = it }
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { action ->
        Thread(action, "clrs-token-store").apply { isDaemon = true }
    }
    private val watchdog = ScheduledThreadPoolExecutor(1) { action ->
        Thread(action, "clrs-token-deadline").apply { isDaemon = true }
    }.apply { removeOnCancelPolicy = true }
    private val busy = AtomicBoolean(false)
    private val poisoned = AtomicBoolean(false)
    @Volatile private var pendingWrite: String? = null
    private val journal: AtomicFile get() = AtomicFile(File(context.noBackupFilesDir, "timeweb_tokens_dirty_v1"))
    private val prefs get() = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    private class Refused(val safeCode: String) : Exception()

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in setOf("read", "write", "confirm", "clear")) { result.notImplemented(); return }
        if (poisoned.get() && call.method != "clear") { result.error("outcome_unknown", "Protected token store needs clearing.", null); return }
        if (!busy.compareAndSet(false, true)) { result.error("store_busy", "Protected token store is busy.", null); return }
        val replied = AtomicBoolean(false)
        val abandoned = AtomicBoolean(false)
        val started = SystemClock.elapsedRealtime()
        fun expire() {
            if (replied.compareAndSet(false, true)) {
                abandoned.set(true); poisoned.set(true)
                main.post { result.error("outcome_unknown", "Protected token operation deadline exceeded.", null) }
            }
        }
        val timer = try { watchdog.schedule({ expire() }, DEADLINE_MS, TimeUnit.MILLISECONDS) }
        catch (_: Exception) {
            busy.set(false); poisoned.set(true)
            result.error("store_unavailable", "Protected token deadline unavailable.", null); return
        }
        fun active() {
            if (SystemClock.elapsedRealtime() - started >= DEADLINE_MS) expire()
            if (abandoned.get()) throw Refused("outcome_unknown")
        }
        try {
            worker.execute {
                var answer: (() -> Unit)? = null
                try {
                    active()
                    val value: Any? = when (call.method) {
                        "read" -> read { active() }
                        "write" -> write(call.arguments, { active() })
                        "confirm" -> confirm(call.arguments, { active() })
                        else -> { clear(); active(); true }
                    }
                    active()
                    if (replied.compareAndSet(false, true)) {
                        timer.cancel(false)
                        answer = { result.success(value) }
                    }
                } catch (error: Exception) {
                    val code = if (error is Refused) error.safeCode else "store_unavailable"
                    if (code != "store_busy" && code != "stale_operation") {
                        poisoned.set(true)
                        try { clear() } catch (_: Exception) { /* journal/poison remain; no plaintext fallback */ }
                    }
                    if (replied.compareAndSet(false, true)) {
                        timer.cancel(false)
                        answer = { result.error(code, "Protected token operation failed.", null) }
                    }
                } finally {
                    // Timeout is not cancellation of a native disk write.
                    // No new operation can run until the old write and cleanup
                    // actually settle. The journal fails closed after restart.
                    if (abandoned.get()) {
                        poisoned.set(true)
                        try { clear() } catch (_: Exception) { /* remain poisoned */ }
                    }
                    busy.set(false)
                    answer?.let { reply -> main.post { reply() } }
                }
            }
        } catch (_: Exception) {
            timer.cancel(false); busy.set(false); poisoned.set(true)
            if (replied.compareAndSet(false, true)) result.error("store_unavailable", "Protected token worker unavailable.", null)
        }
    }

    private fun dirty(): Boolean = journal.baseFile.exists()
        || File(journal.baseFile.path + ".bak").exists()
        || File(journal.baseFile.path + ".new").exists()
    private fun journalId(): String = journal.baseFile.inputStream().use {
        val bytes = ByteArray(36)
        var offset = 0
        while (offset < bytes.size) {
            val count = it.read(bytes, offset, bytes.size - offset)
            if (count < 1) throw Refused("store_corrupted")
            offset += count
        }
        if (it.read() != -1) throw Refused("store_corrupted")
        String(bytes, Charsets.US_ASCII)
    }
    private fun markDirty(id: String) {
        val file = journal.startWrite()
        try {
            file.write(id.toByteArray(Charsets.US_ASCII)); file.fd.sync(); journal.finishWrite(file)
        } catch (error: Exception) { journal.failWrite(file); throw error }
        // AtomicFile may log a failed rename rather than throw. Never persist
        // tokens unless the exact durable intent is present, with no sidecar.
        if (File(journal.baseFile.path + ".new").exists()
            || File(journal.baseFile.path + ".bak").exists()
            || journalId() != id) throw Refused("outcome_unknown")
    }
    private fun cleanJournal() {
        journal.delete()
        if (dirty()) throw Refused("store_unavailable")
    }
    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun key(create: Boolean): SecretKey {
        val store = keyStore()
        val existing = store.getKey(ALIAS, null)
        if (existing != null) return existing as? SecretKey ?: throw Refused("store_corrupted")
        if (!create) throw Refused("store_corrupted")
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true).build())
        return generator.generateKey()
    }
    private fun aad(id: String) = ("CLRS native tokens v1\u0000" + context.packageName + "\u0000" + id).toByteArray(Charsets.UTF_8)
    private fun id(value: String): Boolean = Regex("^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$").matches(value)
    private fun payload(value: String): ByteArray {
        val bytes = value.toByteArray(Charsets.UTF_8)
        if (bytes.size > LIMIT || bytes.isEmpty() || String(bytes, Charsets.UTF_8) != value) throw Refused("invalid_request")
        val json = JSONObject(value)
        val fields = setOf("format", "uid", "emailVerified", "accessToken", "refreshToken", "accessExpiresAt", "refreshExpiresAt")
        if (json.keys().asSequence().toSet() != fields || json.optInt("format", -1) != 1
            || json.get("emailVerified") !is Boolean || json.get("uid") !is String
            || json.get("accessToken") !is String || json.get("refreshToken") !is String
            || json.get("accessExpiresAt") !is Number || json.get("refreshExpiresAt") !is Number) throw Refused("invalid_request")
        return bytes
    }

    private fun write(arguments: Any?, active: () -> Unit): Map<String, String> {
        if (pendingWrite != null) throw Refused("store_busy")
        if (dirty()) throw Refused("store_corrupted")
        val args = arguments as? Map<*, *> ?: throw Refused("invalid_request")
        if (args.keys != setOf("payload")) throw Refused("invalid_request")
        val text = args["payload"] as? String ?: throw Refused("invalid_request")
        val bytes = payload(text)
        val operation = UUID.randomUUID().toString()
        try {
            markDirty(operation); active()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key(true)); cipher.updateAAD(aad(operation)); active()
            val encrypted = cipher.doFinal(bytes); active()
            if (cipher.iv.size != 12) throw Refused("store_unavailable")
            val blob = JSONObject().put("format", 1).put("operationId", operation)
                .put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                .put("ciphertext", Base64.encodeToString(encrypted, Base64.NO_WRAP)).toString()
            if (!prefs.edit().putString(SLOT, blob).commit()) throw Refused("outcome_unknown")
            active()
            if (prefs.getString(SLOT, null) != blob) throw Refused("outcome_unknown")
            pendingWrite = operation // remains unreadable until explicit confirm
            return mapOf("operationId" to operation)
        } finally { bytes.fill(0) }
    }

    private fun confirm(arguments: Any?, active: () -> Unit): Boolean {
        val args = arguments as? Map<*, *> ?: throw Refused("invalid_request")
        val operation = args["operationId"] as? String ?: throw Refused("invalid_request")
        if (args.keys != setOf("operationId") || !id(operation)) throw Refused("invalid_request")
        if (pendingWrite != operation) throw Refused("stale_operation")
        val saved = prefs.getString(SLOT, null) ?: throw Refused("store_corrupted")
        val marker = journalId()
        if (marker != operation || JSONObject(saved).getString("operationId") != operation) throw Refused("store_corrupted")
        active(); cleanJournal(); active()
        pendingWrite = null
        return true
    }

    private fun read(active: () -> Unit): String? {
        if (pendingWrite != null) throw Refused("store_busy")
        if (dirty()) throw Refused("store_corrupted")
        val saved = prefs.getString(SLOT, null) ?: return null
        if (saved.length > LIMIT * 2) throw Refused("store_corrupted")
        val blob = JSONObject(saved)
        if (blob.keys().asSequence().toSet() != setOf("format", "operationId", "iv", "ciphertext")
            || blob.optInt("format", -1) != 1 || !id(blob.getString("operationId"))) throw Refused("store_corrupted")
        val iv = Base64.decode(blob.getString("iv"), Base64.NO_WRAP)
        val encrypted = Base64.decode(blob.getString("ciphertext"), Base64.NO_WRAP)
        if (iv.size != 12 || encrypted.size < 16 || encrypted.size > LIMIT + 16) throw Refused("store_corrupted")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, iv))
        cipher.updateAAD(aad(blob.getString("operationId"))); active()
        val bytes = cipher.doFinal(encrypted)
        try {
            val text = String(bytes, Charsets.UTF_8)
            if (!text.toByteArray(Charsets.UTF_8).contentEquals(bytes)) throw Refused("store_corrupted")
            payload(text).fill(0); active()
            return text
        } finally { bytes.fill(0) }
    }

    private fun clear() {
        markDirty(UUID.randomUUID().toString())
        if (!prefs.edit().remove(SLOT).commit() || prefs.contains(SLOT)) throw Refused("outcome_unknown")
        val store = keyStore()
        if (store.containsAlias(ALIAS)) store.deleteEntry(ALIAS)
        if (store.containsAlias(ALIAS)) throw Refused("outcome_unknown")
        cleanJournal(); pendingWrite = null; poisoned.set(false)
    }
}
