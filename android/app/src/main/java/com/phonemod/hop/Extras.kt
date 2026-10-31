package com.phonemod.hop

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.BatteryManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.VibratorManager
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.telecom.TelecomManager
import android.telephony.TelephonyManager
import android.util.Base64
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap

/** The phone's battery and mobile signal, for Hop's menu on the Mac. Sent when connecting and when they change. */
object PhoneStatus {
    private var receiver: BroadcastReceiver? = null
    private var app: Context? = null
    @Volatile private var last = ""

    fun start(ctx: Context) {
        app = ctx.applicationContext
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) = report(false)
        }
        receiver = r
        ctx.registerReceiver(r, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        report(true)
    }

    fun stop(ctx: Context) {
        receiver?.let { runCatching { ctx.unregisterReceiver(it) } }
        receiver = null
    }

    fun report(force: Boolean) {
        val ctx = app ?: return
        val bm = ctx.getSystemService(BatteryManager::class.java)
        val signal = runCatching { ctx.getSystemService(TelephonyManager::class.java)?.signalStrength?.level }.getOrNull() ?: -1
        val j = JSONObject().put("t", "status")
            .put("battery", bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY))
            .put("charging", bm.isCharging)
            .put("signal", signal)
        val s = j.toString()
        if (force || s != last) { last = s; HopLink.sendNow(j) }
    }
}

/** "Find my phone": rings at full alarm volume, even on silent, until stopped or for 30 seconds. */
object Ringer {
    private const val CHANNEL = "ring"
    private const val NOTIFICATION_ID = 9
    private var player: MediaPlayer? = null
    private var oldVolume = -1
    private val handler = Handler(Looper.getMainLooper())

    @Synchronized
    fun ring(ctx: Context) {
        stop(ctx)
        val am = ctx.getSystemService(AudioManager::class.java)
        oldVolume = am.getStreamVolume(AudioManager.STREAM_ALARM)
        // Remembered on disk too, so the volume comes back even if Hop is stopped mid-ring
        ctx.getSharedPreferences("hop_prefs", Context.MODE_PRIVATE).edit().putInt("alarmVolumeBeforeRing", oldVolume).apply()
        runCatching { am.setStreamVolume(AudioManager.STREAM_ALARM, am.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0) }
        val uri = RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        player = runCatching {
            MediaPlayer().apply {
                setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build())
                setDataSource(ctx, uri)
                isLooping = true
                prepare()
                start()
            }
        }.getOrNull()
        ctx.getSystemService(VibratorManager::class.java)?.defaultVibrator
            ?.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 600, 400), 0))
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Find my phone", NotificationManager.IMPORTANCE_HIGH))
        val stop = PendingIntent.getBroadcast(ctx, 0, Intent(ctx, StopRingReceiver::class.java), PendingIntent.FLAG_IMMUTABLE)
        nm.notify(NOTIFICATION_ID, Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_hop)
            .setContentTitle("Your Mac is ringing this phone")
            .setContentText("Tap to stop")
            .setContentIntent(stop)
            .setDeleteIntent(stop)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build())
        handler.postDelayed({ stop(ctx) }, 30_000)
    }

    @Synchronized
    fun stop(ctx: Context) {
        handler.removeCallbacksAndMessages(null)
        player?.let { runCatching { it.stop(); it.release() } }
        player = null
        if (oldVolume >= 0) {
            runCatching { ctx.getSystemService(AudioManager::class.java).setStreamVolume(AudioManager.STREAM_ALARM, oldVolume, 0) }
            oldVolume = -1
        }
        ctx.getSharedPreferences("hop_prefs", Context.MODE_PRIVATE).edit().remove("alarmVolumeBeforeRing").apply()
        ctx.getSystemService(VibratorManager::class.java)?.defaultVibrator?.cancel()
        ctx.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
    }
}

/** Puts the alarm volume back if a ring was cut off (Hop stopped before it could). */
fun Ringer.restoreIfInterrupted(ctx: Context) {
    val prefs = ctx.getSharedPreferences("hop_prefs", Context.MODE_PRIVATE)
    val v = prefs.getInt("alarmVolumeBeforeRing", -1)
    if (v >= 0) {
        runCatching { ctx.getSystemService(AudioManager::class.java).setStreamVolume(AudioManager.STREAM_ALARM, v, 0) }
        prefs.edit().remove("alarmVolumeBeforeRing").apply()
    }
}

class StopRingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = Ringer.stop(context)
}

/**
 * Phone notifications and incoming calls, shown in the island on the Mac. Replies, dismissals and
 * answer/decline come back from the Mac and are carried out here.
 */
object NotifBridge {
    private const val PREFS = "hop_prefs"
    private val active = ConcurrentHashMap<String, StatusBarNotification>()
    private val icons = ConcurrentHashMap<String, String>()
    var listener: NotificationListenerService? = null
    private var callKey: String? = null

    fun enabled(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("notifyMac", true)
    fun setEnabled(ctx: Context, on: Boolean) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("notifyMac", on).apply()

    fun callsAllowed(ctx: Context) =
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED

    private val skipCategories = setOf(
        Notification.CATEGORY_SERVICE, Notification.CATEGORY_PROGRESS, Notification.CATEGORY_TRANSPORT,
        Notification.CATEGORY_SYSTEM, Notification.CATEGORY_NAVIGATION, Notification.CATEGORY_STATUS,
    )

    fun posted(svc: NotificationListenerService, sbn: StatusBarNotification) {
        if (sbn.packageName == svc.packageName) return
        if (!enabled(svc)) return
        val n = sbn.notification
        if (n.category == Notification.CATEGORY_CALL) {
            // Only the phone's real dialer: any app can label a notification as a call
            val dialer = runCatching { svc.getSystemService(TelecomManager::class.java).defaultDialerPackage }.getOrNull()
            if (sbn.packageName == dialer) call(svc, sbn)
            return
        }
        // Notifications marked secret never leave the phone
        if (n.visibility == Notification.VISIBILITY_SECRET) return
        if (n.flags and (Notification.FLAG_ONGOING_EVENT or Notification.FLAG_FOREGROUND_SERVICE or Notification.FLAG_GROUP_SUMMARY) != 0) return
        if (n.category in skipCategories) return
        // Quiet notifications stay quiet
        val ranking = NotificationListenerService.Ranking()
        if (svc.currentRanking?.getRanking(sbn.key, ranking) == true && ranking.importance < NotificationManager.IMPORTANCE_DEFAULT) return
        // Private ones (the default) follow the phone's own lock-screen choice: if it hides sensitive content
        // there, the Mac gets only the public version too
        val hideSensitive = runCatching {
            android.provider.Settings.Secure.getInt(svc.contentResolver, "lock_screen_allow_private_notifications", 1) == 0
        }.getOrDefault(false)
        val redact = hideSensitive && n.visibility == Notification.VISIBILITY_PRIVATE
        val shown = if (redact) n.publicVersion else n
        var title = shown?.extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        var text = (shown?.extras?.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: shown?.extras?.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
        if (redact && shown == null) { title = ""; text = "Contents hidden" }
        if (title.isBlank() && text.isBlank()) return
        active[sbn.key] = sbn
        HopLink.sendNow(JSONObject().put("t", "notif").put("id", sbn.key)
            .put("app", label(svc, sbn.packageName)).put("pkg", sbn.packageName).put("title", title.take(120)).put("text", text.take(400))
            .put("reply", replyAction(n) != null).put("icon", icon(svc, sbn.packageName)))
    }

    fun removed(svc: Context, sbn: StatusBarNotification) {
        if (sbn.key == callKey) {
            callKey = null
            HopLink.sendNow(JSONObject().put("t", "call").put("state", "ended").put("id", sbn.key))
        }
        if (active.remove(sbn.key) != null) HopLink.sendNow(JSONObject().put("t", "notif-gone").put("id", sbn.key))
    }

    fun reply(ctx: Context, id: String, text: String) {
        val sbn = active[id] ?: return
        val action = replyAction(sbn.notification) ?: return
        val inputs = action.remoteInputs ?: return
        val intent = Intent()
        val results = Bundle().apply { inputs.forEach { putCharSequence(it.resultKey, text) } }
        RemoteInput.addResultsToIntent(inputs, intent, results)
        runCatching { action.actionIntent.send(ctx, 0, intent) }
    }

    /** Opens what the notification points to (the chat, the email…), as tapping it on the phone would. */
    fun open(ctx: Context, id: String) {
        val sbn = active[id] ?: return
        val n = sbn.notification
        val options = android.app.ActivityOptions.makeBasic()
            .setPendingIntentBackgroundActivityStartMode(android.app.ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED)
        runCatching { n.contentIntent?.send(ctx, 0, null, null, null, null, options.toBundle()) }
        if (n.flags and Notification.FLAG_AUTO_CANCEL != 0) dismiss(id)
    }

    fun dismiss(id: String) {
        runCatching { listener?.cancelNotification(id) }
    }

    private fun replyAction(n: Notification) = n.actions?.firstOrNull { a -> a.remoteInputs?.any { it.allowFreeFormInput } == true }

    // MARK: calls

    private fun call(svc: Context, sbn: StatusBarNotification) {
        val n = sbn.notification
        val type = n.extras.getInt(Notification.EXTRA_CALL_TYPE, 0) // 1 incoming, 2 ongoing, 3 screening
        val ringing = type == 1 || (type == 0 && n.fullScreenIntent != null)
        val person = n.extras.getParcelable(Notification.EXTRA_CALL_PERSON, android.app.Person::class.java)
        val name = person?.name?.toString() ?: n.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val detail = n.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
        active[sbn.key] = sbn
        callKey = sbn.key
        HopLink.sendNow(JSONObject().put("t", "call").put("state", if (ringing) "ringing" else "active")
            .put("id", sbn.key).put("name", name.take(80)).put("detail", detail.take(80)))
    }

    @Suppress("MissingPermission", "DEPRECATION")
    fun answer(ctx: Context) {
        if (callsAllowed(ctx)) {
            runCatching { ctx.getSystemService(TelecomManager::class.java).acceptRingingCall() }.onSuccess { return }
        }
        callAction(listOf("answer", "accept"))?.let { runCatching { it.actionIntent.send() } }
    }

    @Suppress("MissingPermission", "DEPRECATION")
    fun decline(ctx: Context) {
        if (callsAllowed(ctx)) {
            runCatching { ctx.getSystemService(TelecomManager::class.java).endCall() }.onSuccess { if (it) return }
        }
        callAction(listOf("decline", "reject", "hang up", "end"))?.let { runCatching { it.actionIntent.send() } }
    }

    private fun callAction(words: List<String>): Notification.Action? {
        val n = callKey?.let { active[it] }?.notification ?: return null
        return n.actions?.firstOrNull { a -> words.any { a.title?.toString()?.lowercase()?.contains(it) == true } }
    }

    // MARK: helpers

    private fun label(ctx: Context, pkg: String) = runCatching {
        ctx.packageManager.getApplicationLabel(ctx.packageManager.getApplicationInfo(pkg, 0)).toString()
    }.getOrDefault(pkg)

    /** The app's icon as a small PNG, cached per app. */
    private fun icon(ctx: Context, pkg: String): String = icons.getOrPut(pkg) {
        runCatching {
            val d = ctx.packageManager.getApplicationIcon(pkg)
            val bmp = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888)
            d.setBounds(0, 0, 64, 64)
            d.draw(Canvas(bmp))
            val out = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
            Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
        }.getOrDefault("")
    }
}
