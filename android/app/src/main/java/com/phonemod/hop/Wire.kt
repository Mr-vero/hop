package com.phonemod.hop

import android.content.Context
import android.util.Base64
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** What the phone learned from the Mac's QR code. See ../PROTOCOL.md. */
data class Pairing(val key: ByteArray, val service: String, val host: String, val port: Int, val macName: String) {
    companion object {
        private const val PREFS = "hop_pairing"

        fun parse(qr: String): Pairing? {
            val p = qr.split("|")
            if (p.size < 6 || p[0] != "hop1") return null
            val key = runCatching { Base64.decode(p[1], Base64.DEFAULT) }.getOrNull() ?: return null
            if (key.size != 32) return null
            return Pairing(key, p[2], p[3], p[4].toIntOrNull() ?: 47900, p.drop(5).joinToString("|"))
        }

        fun load(ctx: Context): Pairing? {
            val sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val key = sp.getString("key", null) ?: return null
            return Pairing(
                Base64.decode(key, Base64.DEFAULT), sp.getString("service", "")!!,
                sp.getString("host", "")!!, sp.getInt("port", 47900), sp.getString("mac", "Mac")!!,
            )
        }
    }

    fun save(ctx: Context) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("key", Base64.encodeToString(key, Base64.NO_WRAP))
            .putString("service", service).putString("host", host).putInt("port", port).putString("mac", macName)
            .apply()
    }

    fun withAddress(ctx: Context, newHost: String, newPort: Int): Pairing =
        copy(host = newHost, port = newPort).also { it.save(ctx) }
}

/** AES-256-GCM with a per-connection key and strictly increasing nonces in each direction. */
class SessionCrypto(pairingKey: ByteArray, phoneRandom: ByteArray, macRandom: ByteArray) {
    private val key: SecretKeySpec
    private var sendCounter = 0L
    private var recvCounter = 0L

    init {
        val hmac = Mac.getInstance("HmacSHA256")
        hmac.init(SecretKeySpec(pairingKey, "HmacSHA256"))
        hmac.update("hop-v1".toByteArray())
        hmac.update(phoneRandom)
        hmac.update(macRandom)
        key = SecretKeySpec(hmac.doFinal(), "AES")
    }

    private fun nonce(prefix: Int, counter: Long): ByteArray =
        ByteBuffer.allocate(12).putInt(prefix).putLong(counter).array()

    fun seal(plain: ByteArray): ByteArray {
        val n = nonce(PHONE, sendCounter++)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, n))
        return n + c.doFinal(plain)
    }

    fun open(frame: ByteArray): ByteArray {
        if (frame.size < 28) throw IOException("short frame")
        val n = frame.copyOfRange(0, 12)
        if (!n.contentEquals(nonce(MAC, recvCounter))) throw IOException("unexpected nonce")
        recvCounter++
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, n))
        return c.doFinal(frame, 12, frame.size - 12)
    }

    companion object {
        const val PHONE = 1
        const val MAC = 2
    }
}

object Frames {
    private const val MAX = 1 shl 20

    fun read(input: DataInputStream): ByteArray {
        val len = input.readInt()
        if (len <= 0 || len > MAX) throw IOException("bad frame length $len")
        return ByteArray(len).also { input.readFully(it) }
    }

    fun write(out: DataOutputStream, payload: ByteArray) {
        out.writeInt(payload.size)
        out.write(payload)
        out.flush()
    }
}
