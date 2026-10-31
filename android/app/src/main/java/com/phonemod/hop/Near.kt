package com.phonemod.hop

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.ParcelUuid
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.nio.ByteBuffer
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * A small Bluetooth signal that lets the paired Mac tell how close the phone is (by signal strength),
 * so the phone can appear on the Mac's screen when it's brought near.
 *
 * About 10 tiny packets a second while paired. The payload is a token derived from the pairing key that
 * changes every 5 minutes, and Android rotates the Bluetooth address too, so nobody else can recognise or
 * follow the phone. Non-connectable: nothing can connect to it.
 */
object NearBeacon {
    /** Shared with the Mac app (Near.swift). */
    val SERVICE: ParcelUuid = ParcelUuid.fromString("6B0F1E52-8D3A-4C7B-9E21-5A4F3C2D1B0E")
    private const val COMPANY = 0xFFFF // Bluetooth SIG's id for testing/unassigned use
    private const val WINDOW_SECONDS = 300L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var job: Job? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private val callback = object : AdvertiseCallback() {}
    private var key: ByteArray? = null
    private lateinit var app: Context

    fun allowed(ctx: Context) =
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED

    /** (Re)starts the signal for this pairing key. */
    @Synchronized
    fun start(ctx: Context, key: ByteArray) {
        if (!allowed(ctx)) return
        if (job?.isActive == true && this.key?.contentEquals(key) == true) return
        stop()
        app = ctx.applicationContext
        this.key = key
        job = scope.launch {
            while (isActive) {
                val window = System.currentTimeMillis() / 1000 / WINDOW_SECONDS
                advertise()
                // Re-advertise with the next token right after the window turns over
                val next = (window + 1) * WINDOW_SECONDS * 1000 - System.currentTimeMillis()
                delay(next.coerceAtLeast(1_000))
            }
        }
    }

    @Synchronized
    fun stop() {
        job?.cancel()
        job = null
        runCatching { advertiser?.stopAdvertising(callback) }
        advertiser = null
    }

    /** First 6 bytes of HMAC-SHA256(pairingKey, "hop-near" || window), the same on the Mac. */
    fun token(key: ByteArray, window: Long): ByteArray {
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }
        return mac.doFinal("hop-near".toByteArray() + ByteBuffer.allocate(8).putLong(window).array()).copyOf(6)
    }

    @Suppress("MissingPermission") // checked in allowed()
    @Synchronized
    private fun advertise() {
        runCatching {
            val key = key ?: return
            val adapter = app.getSystemService(BluetoothManager::class.java)?.adapter ?: return
            if (!adapter.isEnabled || !allowed(app)) return
            val adv = adapter.bluetoothLeAdvertiser ?: return
            runCatching { advertiser?.stopAdvertising(callback) }
            val settings = AdvertiseSettings.Builder()
                // ~10 short packets a second: Macs only catch some of them, and the distance estimate needs a steady stream
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                .setConnectable(false)
                .build()
            val window = System.currentTimeMillis() / 1000 / WINDOW_SECONDS
            val data = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addServiceUuid(SERVICE)
                .addManufacturerData(COMPANY, token(key, window))
                .build()
            adv.startAdvertising(settings, data, callback)
            advertiser = adv
        }
    }
}

/**
 * Keeps the near-Mac signal running. Android puts background apps to sleep (which would silence the signal
 * and drop the Mac connection), so this is a foreground service with a quiet, minimised notification.
 */
class NearService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Near your Mac", NotificationManager.IMPORTANCE_MIN).apply {
            description = "Shown while Hop is ready to appear on your Mac. You can hide it here."
            setShowBadge(false)
        })
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_hop)
            .setContentTitle("Ready near your Mac")
            .setContentText("Bring the phone close to your Mac and it appears on the Mac's screen.")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val pairing = Pairing.load(this)
        if (pairing == null || !NearBeacon.allowed(this)) { stopSelf(); return START_NOT_STICKY }
        NearBeacon.start(this, pairing.key)
        HopLink.poke() // a good moment to (re)connect to the Mac too
        return START_STICKY
    }

    override fun onDestroy() {
        NearBeacon.stop()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "near"
        private const val NOTIFICATION_ID = 7

        /** Starts or stops the near-Mac signal to match the pairing and the Nearby devices permission. */
        fun update(ctx: Context) {
            val pairing = Pairing.load(ctx)
            if (pairing == null || !NearBeacon.allowed(ctx)) {
                ctx.stopService(Intent(ctx, NearService::class.java))
                NearBeacon.stop()
                return
            }
            try {
                ContextCompat.startForegroundService(ctx, Intent(ctx, NearService::class.java))
            } catch (e: Exception) {
                // Android won't start it from the background; keep the signal going without it for now
                NearBeacon.start(ctx, pairing.key)
            }
        }
    }
}
