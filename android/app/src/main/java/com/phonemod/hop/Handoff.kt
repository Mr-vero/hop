package com.phonemod.hop

import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private sealed interface Phase {
    data class Confirm(val what: String) : Phase
    data class Sending(val what: String) : Phase
    data class Done(val what: String) : Phase
    data class Failed(val why: String) : Phase
}

/** Shared base: a small card at the bottom of the screen while something hops to the Mac. */
abstract class HandoffActivity : ComponentActivity() {
    private var phase by mutableStateOf<Phase>(Phase.Sending(""))
    private var progress by mutableFloatStateOf(0f)
    private var started = false

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        HopLink.init(this)
        setContent { HopTheme { Sheet() } }
    }

    /**
     * Shares ask for a tap first: any app can open the share screen directly, so without this
     * one could push links or files to the Mac without you knowing. Null means send right away.
     */
    protected open fun confirmText(): String? = null

    /** Reading the clipboard is only allowed once the window has focus. */
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || started) return
        started = true
        if (Pairing.load(this) == null) {
            phase = Phase.Failed("Pair Hop with your Mac first.")
            return
        }
        val ask = try { confirmText() } catch (e: Exception) { "1 item" }
        if (ask != null) phase = Phase.Confirm(ask) else send()
    }

    private fun send() {
        phase = Phase.Sending("")
        lifecycleScope.launch {
            // A share can hand over a file we're not allowed to read; say so instead of crashing
            val ok = withContext(Dispatchers.IO) {
                try { deliver() } catch (e: Exception) { fail("Couldn't read that item, so nothing was sent.") }
            }
            if (ok != null) {
                phase = Phase.Done(ok)
                delay(900)
                finish()
            }
        }
    }

    /** Sends the payload and returns a short description, or sets a failure and returns null. */
    protected abstract suspend fun deliver(): String?

    protected fun sending(what: String) { phase = Phase.Sending(what) }
    protected fun progress(p: Float) { progress = p }
    protected fun fail(why: String): String? { phase = Phase.Failed(why); return null }

    protected suspend fun sendText(text: String): String? {
        sending(if (isLink(text)) "link" else "text")
        if (!HopLink.awaitConnected()) return notFound()
        return if (HopLink.sendText(text)) (if (isLink(text)) "Link opened on Mac" else "Copied on your Mac") else notFound()
    }

    /** Only content from other apps: never file:// paths or Hop's own files, which Hop itself could read. */
    protected fun allowed(uri: Uri) = uri.scheme == "content" && uri.authority?.startsWith(packageName) != true

    protected suspend fun sendUris(uris: List<Uri>): String? {
        if (uris.any { !allowed(it) }) return fail("That item can't be shared, so nothing was sent.")
        if (!HopLink.awaitConnected()) return notFound()
        uris.forEachIndexed { i, uri ->
            var name = "file"
            var size = -1L
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    name = c.getString(0) ?: name
                    if (!c.isNull(1)) size = c.getLong(1)
                }
            }
            if (size < 0) size = contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: -1
            if (size < 0) return fail("Couldn't read $name.")
            sending(if (uris.size > 1) "${i + 1} of ${uris.size}: $name" else name)
            val stream = contentResolver.openInputStream(uri) ?: return fail("Couldn't open $name.")
            val mime = contentResolver.getType(uri) ?: "application/octet-stream"
            if (!HopLink.sendFile(name, size, mime, stream) { progress((i + it) / uris.size) }) return notFound()
        }
        return if (uris.size == 1) "Saved to Downloads on your Mac" else "${uris.size} files saved to Downloads on your Mac"
    }

    private fun notFound() = fail("Can't reach your Mac. Make sure Hop is running there and both are on the same Wi-Fi.")

    private fun isLink(t: String) = t.trim().let { (it.startsWith("http://") || it.startsWith("https://")) && ' ' !in it }

    @Composable
    private fun Sheet() {
        val macName = Pairing.load(this)?.macName ?: "your Mac"
        Box(
            Modifier.fillMaxSize().clickable(remember { MutableInteractionSource() }, null) { if (phase !is Phase.Sending) finish() },
            contentAlignment = Alignment.BottomCenter,
        ) {
            Column(
                Modifier.navigationBarsPadding().padding(12.dp).fillMaxWidth()
                    .clip(RoundedCornerShape(28.dp)).background(MaterialTheme.colorScheme.surfaceContainerHigh)
                    .padding(horizontal = 22.dp, vertical = 20.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(40.dp).clip(CircleShape).background(MaterialTheme.colorScheme.primary), contentAlignment = Alignment.Center) {
                        androidx.compose.material3.Icon(painterResource(R.drawable.ic_hop), null, Modifier.size(22.dp), tint = MaterialTheme.colorScheme.onPrimary)
                    }
                    Column(Modifier.padding(start = 14.dp)) {
                        AnimatedContent(phase, label = "phase") { p ->
                            Text(
                                when (p) {
                                    is Phase.Confirm -> "Send to $macName?"
                                    is Phase.Sending -> "Sending to $macName"
                                    is Phase.Done -> p.what
                                    is Phase.Failed -> "Didn't send"
                                },
                                fontSize = 17.sp, fontWeight = FontWeight.SemiBold,
                            )
                        }
                        val sub = when (val p = phase) {
                            is Phase.Confirm -> p.what
                            is Phase.Sending -> p.what
                            is Phase.Done -> "Sent to $macName"
                            is Phase.Failed -> p.why
                        }
                        if (sub.isNotBlank()) Text(sub, fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 3)
                    }
                }
                when (phase) {
                    is Phase.Sending -> LinearProgressIndicator(
                        progress = { progress }, Modifier.fillMaxWidth().clip(CircleShape),
                    )
                    is Phase.Failed -> TextButton(onClick = {
                        startActivity(Intent(this@HandoffActivity, MainActivity::class.java))
                        finish()
                    }) { Text("Open Hop") }
                    is Phase.Confirm -> Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                        TextButton(onClick = { finish() }) { Text("Cancel") }
                        androidx.compose.material3.Button(onClick = { send() }) { Text("Send") }
                    }
                    else -> {}
                }
            }
        }
    }
}

/** Share → "Send to Mac" from any app. */
class ShareActivity : HandoffActivity() {
    @Suppress("DEPRECATION")
    private fun uris(): List<Uri> = when (intent.action) {
        Intent.ACTION_SEND_MULTIPLE -> intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
        else -> listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
    }

    override fun confirmText(): String {
        val uris = uris()
        if (uris.size > 1) return "${uris.size} files"
        if (uris.size == 1) return contentResolver.query(uris[0], arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0) else null } ?: "1 file"
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString().orEmpty().trim()
        return text.take(140) + if (text.length > 140) "…" else ""
    }

    override suspend fun deliver(): String? {
        val i = intent
        val uris = uris()
        if (uris.isNotEmpty()) return sendUris(uris)
        val text = i.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            ?: return fail("There was nothing to send.")
        return sendText(text)
    }
}

/** Opened briefly by the Quick Settings tile, because only a focused app may read the clipboard. */
class ClipboardActivity : HandoffActivity() {
    override suspend fun deliver(): String? {
        val clip = getSystemService(ClipboardManager::class.java).primaryClip
            ?: return fail("Your clipboard is empty.")
        val item = clip.getItemAt(0)
        item.uri?.let { return sendUris(listOf(it)) }
        val text = item.coerceToText(this)?.toString()
        if (text.isNullOrBlank()) return fail("Your clipboard is empty.")
        return sendText(text)
    }
}
