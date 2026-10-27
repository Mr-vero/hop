package com.phonemod.hop

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import java.io.DataInputStream
import java.io.OutputStream

/** Handles what the Mac sends: text lands on the clipboard (links can be opened), files go to Downloads/Hop. */
class Inbox(private val ctx: Context) {
    private var fileUri: Uri? = null
    private var fileOut: OutputStream? = null
    private var fileName = ""
    private var remaining = 0L

    fun run(input: DataInputStream, crypto: SessionCrypto) {
        try {
            while (true) {
                val plain = crypto.open(Frames.read(input))
                if (plain[0].toInt() == 1) { chunk(plain); continue }
                val msg = JSONObject(String(plain, 1, plain.size - 1))
                when (msg.optString("t")) {
                    "text" -> text(msg.optString("text"))
                    "file" -> startFile(msg.optString("name", "file"), msg.optLong("size"))
                }
            }
        } finally {
            // A transfer cut off midway leaves no half-written file behind
            fileOut?.close()
            fileUri?.let { ctx.contentResolver.delete(it, null, null) }
        }
    }

    private fun text(text: String) {
        if (text.isBlank()) return
        ctx.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("From Mac", text))
        val isLink = text.trim().let { (it.startsWith("http://") || it.startsWith("https://")) && ' ' !in it }
        val tap = if (isLink) Intent(Intent.ACTION_VIEW, Uri.parse(text.trim())) else null
        Notify.show(ctx, if (isLink) "Link from Mac" else "Copied from Mac", text.take(200), tap)
    }

    private fun startFile(rawName: String, size: Long) {
        fileName = rawName.substringAfterLast('/')
        remaining = size
        val ext = fileName.substringAfterLast('.', "").lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/Hop")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        fileUri = ctx.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
        fileOut = fileUri?.let { ctx.contentResolver.openOutputStream(it) }
        if (size == 0L) finishFile(mime)
    }

    private fun chunk(plain: ByteArray) {
        val out = fileOut ?: return
        out.write(plain, 1, plain.size - 1)
        remaining -= plain.size - 1
        if (remaining <= 0) finishFile(null)
    }

    private fun finishFile(knownMime: String?) {
        fileOut?.close()
        fileOut = null
        val uri = fileUri ?: return
        fileUri = null
        ctx.contentResolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
        val mime = knownMime ?: ctx.contentResolver.getType(uri) ?: "*/*"
        val open = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        Notify.show(ctx, "Received from Mac", "$fileName · saved in Downloads/Hop", open)
    }
}

object Notify {
    private const val CHANNEL = "hop"

    fun show(ctx: Context, title: String, text: String, tap: Intent? = null) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "From your Mac", NotificationManager.IMPORTANCE_HIGH))
        val pi = tap?.let {
            PendingIntent.getActivity(ctx, text.hashCode(), it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        val n = NotificationCompat.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_hop)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        runCatching { nm.notify(System.currentTimeMillis().toInt(), n) }
    }
}
