package com.phonemod.hop

import android.app.Application
import android.app.Notification
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Telephony
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.service.quicksettings.TileService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class HopApp : Application() {
    override fun onCreate() {
        super.onCreate()
        HopLink.init(this)
    }
}

/**
 * Android keeps a notification listener bound for as long as access is granted, which also keeps
 * the Mac connection available for incoming files. Only one-time codes are ever forwarded.
 */
/** Both the SMS receiver and the notification listener report codes here, so each code is sent once. */
object OtpForwarder {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var lastCode = ""
    private var lastAt = 0L

    @Synchronized
    fun forward(code: String, from: String, done: () -> Unit = {}) {
        val now = System.currentTimeMillis()
        if (code == lastCode && now - lastAt < 120_000) { done(); return }
        lastCode = code
        lastAt = now
        scope.launch {
            try { HopLink.sendOtp(code, from) } finally { done() }
        }
    }
}

/**
 * Codes from SMS. Android 15+ hides one-time codes inside notifications from apps like Hop,
 * but an incoming text message with RECEIVE_SMS permission still arrives in full.
 */
class SmsCodeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val parts = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        val body = parts.joinToString("") { it.messageBody.orEmpty() }
        val code = Otp.find(body) ?: return
        val sender = parts.firstOrNull()?.displayOriginatingAddress ?: "SMS"
        HopLink.init(context)
        val pending = goAsync()
        OtpForwarder.forward(code, "SMS from $sender") { pending.finish() }
    }
}

class OtpListener : NotificationListenerService() {

    override fun onListenerConnected() {
        HopLink.init(this)
        HopLink.poke()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName == packageName) return
        val n = sbn.notification
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val title = n.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val body = (n.extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: n.extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
        val code = Otp.find("$title\n$body") ?: return
        val from = runCatching { packageManager.getApplicationLabel(packageManager.getApplicationInfo(sbn.packageName, 0)).toString() }
            .getOrDefault(title)
        OtpForwarder.forward(code, if (title.isNotBlank() && title != from) "$title ($from)" else from)
    }
}

/** Quick Settings tile: sends whatever is on the clipboard to the Mac. */
class ClipTile : TileService() {
    override fun onClick() {
        val intent = Intent(this, ClipboardActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(intent)
        }
    }
}
