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
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.ParcelUuid
import android.os.SystemClock
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

/** Shared helpers for the near-Mac signals (the Mac side is Near.swift). */
object NearCrypto {
    const val WINDOW_SECONDS = 300L

    fun window() = System.currentTimeMillis() / 1000 / WINDOW_SECONDS

    /** First 6 bytes of HMAC-SHA256(pairingKey, label || window [|| flag]). */
    fun token(key: ByteArray, label: String, window: Long, flag: Byte? = null): ByteArray {
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }
        var msg = label.toByteArray() + ByteBuffer.allocate(8).putLong(window).array()
        if (flag != null) msg += byteArrayOf(flag)
        return mac.doFinal(msg).copyOf(6)
    }
}

/**
 * The phone's Bluetooth signal. It lets the Mac measure distance itself (older Hop versions), and carries the
 * phone's own near/away decision ([NearScanner]) sealed into a token from the pairing key, so nobody else can
 * fake it, recognise the phone or follow it (the token changes every 5 minutes, and Android rotates the
 * Bluetooth address). Non-connectable: nothing can connect to it. About 10 tiny packets a second while paired.
 */
object NearBeacon {
    val SERVICE: ParcelUuid = ParcelUuid.fromString("6B0F1E52-8D3A-4C7B-9E21-5A4F3C2D1B0E")
    private const val COMPANY = 0xFFFF // Bluetooth SIG's id for testing/unassigned use

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var job: Job? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private val callback = object : AdvertiseCallback() {}
    private var key: ByteArray? = null
    private lateinit var app: Context
    /** null: the phone isn't judging distance (no scan permission), 1 near, 2 away. */
    @Volatile private var flag: Byte? = null
    /** Fast while the Mac is around; a slow trickle otherwise, so it costs next to nothing away from the desk. */
    @Volatile private var fast = false

    @Synchronized
    fun setFast(on: Boolean) {
        if (on == fast) return
        fast = on
        if (job?.isActive == true) advertise()
    }

    fun allowed(ctx: Context) =
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED

    @Synchronized
    fun start(ctx: Context, key: ByteArray) {
        if (!allowed(ctx)) return
        if (job?.isActive == true && this.key?.contentEquals(key) == true) return
        stop()
        app = ctx.applicationContext
        this.key = key
        job = scope.launch {
            while (isActive) {
                val window = NearCrypto.window()
                advertise()
                // Re-advertise with the next token right after the window turns over
                val next = (window + 1) * NearCrypto.WINDOW_SECONDS * 1000 - System.currentTimeMillis()
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

    /** The phone's own verdict, carried in every packet from now on. */
    @Synchronized
    fun setNear(near: Boolean?) {
        val f: Byte? = near?.let { if (it) 1 else 2 }
        if (f == flag) return
        flag = f
        if (job?.isActive == true) advertise()
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
                // ~10 short packets a second near the Mac (Macs only catch some of them), ~1 a second otherwise
                .setAdvertiseMode(if (fast) AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY else AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                .setConnectable(false)
                .build()
            val data = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                // No fixed service ID: with so few Hop users it would work as a tracking tag. The Mac matches the token.
                .addManufacturerData(COMPANY, NearCrypto.token(key, "hop-near", NearCrypto.window(), flag))
                .build()
            adv.startAdvertising(settings, data, callback)
            advertiser = adv
        }
    }
}

/**
 * The phone decides whether it's near the Mac: the Mac sends its own small signal (service [MAC_SERVICE], with a
 * rotating token from the pairing key as its name), and Android catches nearly every packet, which gives a much
 * steadier distance reading than the Mac can get. The verdict goes to the Mac instantly over the Hop link and,
 * as a backup, in [NearBeacon]'s packets.
 */
object NearScanner {
    val MAC_SERVICE: ParcelUuid = ParcelUuid.fromString("6B0F1E53-8D3A-4C7B-9E21-5A4F3C2D1B0E")
    private const val PREFS = "hop_near"

    private var app: Context? = null
    private var key: ByteArray? = null
    private val samples = ArrayDeque<Pair<Long, Int>>()
    private var lastHeard = 0L
    private var pendingSince = 0L
    @Volatile var near = false
        private set
    /** Strong end of the last 3 seconds of readings, or null when the Mac isn't heard. */
    @Volatile var rssi: Int? = null
        private set
    private var lastReport = 0L

    fun allowed(ctx: Context) =
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED

    /** dBm at or above which the Mac counts as near; set by calibrating from the Mac. */
    fun threshold(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt("nearThreshold", -45) // right beside the Mac reads about -25

    fun calibrate(ctx: Context): Int? {
        val r = rssi ?: return null
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putInt("nearThreshold", r - 3).apply()
        return r
    }

    private val callback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) = heard(result)
        override fun onBatchScanResults(results: MutableList<ScanResult>) = results.forEach(::heard)
    }

    private var fastScan = false
    private var names = emptySet<String>()
    private var namesWindow = -1L

    @Synchronized
    fun start(ctx: Context, key: ByteArray) {
        if (!allowed(ctx)) return
        stop()
        app = ctx.applicationContext
        this.key = key
        scan(fast = false)
    }

    /**
     * Listening is filtered in the Bluetooth chip, so the phone sleeps in between. While the Mac is around it
     * listens all the time for a steady reading; otherwise about a quarter of the time, just to notice it arriving.
     */
    @Suppress("MissingPermission") // checked in allowed()
    private fun scan(fast: Boolean) {
        val ctx = app ?: return
        val scanner = ctx.getSystemService(BluetoothManager::class.java)?.adapter?.bluetoothLeScanner ?: return
        runCatching { scanner.stopScan(callback) }
        fastScan = fast
        val filter = ScanFilter.Builder().setServiceUuid(MAC_SERVICE).build()
        val mode = if (fast) ScanSettings.SCAN_MODE_LOW_LATENCY else ScanSettings.SCAN_MODE_BALANCED
        runCatching { scanner.startScan(listOf(filter), ScanSettings.Builder().setScanMode(mode).build(), callback) }
    }

    @Suppress("MissingPermission")
    @Synchronized
    fun stop() {
        val ctx = app ?: return
        runCatching { ctx.getSystemService(BluetoothManager::class.java)?.adapter?.bluetoothLeScanner?.stopScan(callback) }
        samples.clear()
        rssi = null
    }

    @Synchronized
    private fun heard(r: ScanResult) {
        val key = key ?: return
        val name = r.scanRecord?.deviceName ?: return
        val window = NearCrypto.window()
        // Worked out once per 5-minute window, not for every packet
        if (window != namesWindow) { names = (window - 1..window + 1).map { macName(key, it) }.toSet(); namesWindow = window }
        val ok = name in names
        if (!ok) return
        lastHeard = SystemClock.elapsedRealtime()
        samples.addLast(lastHeard to r.rssi)
        evaluate()
    }

    /** What the Mac calls itself over Bluetooth: "H" plus the start of its token in hex (fits in one packet). */
    fun macName(key: ByteArray, window: Long) =
        "H" + NearCrypto.token(key, "hop-mac", window).joinToString("") { "%02x".format(it) }.take(6)

    /** Also called once a second from [NearService], so "away" is noticed when the Mac goes quiet. */
    @Synchronized
    fun evaluate() {
        val ctx = app ?: return
        val now = SystemClock.elapsedRealtime()
        // Speed up listening while the Mac is around, slow down a minute after it's gone
        val macAround = lastHeard > 0 && now - lastHeard < 60_000
        if (macAround != fastScan) { scan(macAround); NearBeacon.setFast(macAround) }
        while (samples.isNotEmpty() && now - samples.first().first > 2_500) samples.removeFirst()
        rssi = if (samples.isEmpty()) {
            if (now - lastHeard > 10_000) null else rssi
        } else {
            val sorted = samples.map { it.second }.sorted()
            sorted[minOf(sorted.size - 1, (sorted.size * 0.6).toInt())]
        }
        val t = threshold(ctx)
        val r = rssi
        val wants = r != null && r >= t - (if (near) 4 else 0)
        if (wants != near) {
            if (pendingSince == 0L) pendingSince = now
            // Near after 0.8 s, away after 1.5 s: quick, but a passing hand does not flip it
            if (now - pendingSince >= if (wants) 800 else 1_500) {
                near = wants
                pendingSince = 0
                report(force = true)
            }
        } else pendingSince = 0
        if (now - lastReport > 10_000) report(force = false)
    }

    /** Tells a freshly connected Mac where things stand. */
    fun announce() = synchronized(this) { report(force = true) }

    private fun report(force: Boolean) {
        lastReport = SystemClock.elapsedRealtime()
        // Only judge once the Mac's signal has been heard lately; otherwise leave it to the Mac to measure
        val judging = lastHeard > 0 && lastReport - lastHeard < 60_000
        NearBeacon.setNear(if (judging) near else null)
        // The link message is instant; the periodic one also feeds the Mac's live distance readout
        if (force || rssi != null) HopLink.sendNow(org.json.JSONObject().put("t", "near")
            .put("near", if (judging) near else org.json.JSONObject.NULL).put("rssi", rssi ?: 0))
    }
}

/**
 * Keeps the near-Mac signals running, and reports the phone's battery and signal to the Mac. Android puts
 * background apps to sleep (which would silence the signals and drop the Mac connection), so this is a
 * foreground service with a quiet, minimised notification.
 */
class NearService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

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
        PhoneStatus.start(this)
        Ringer.restoreIfInterrupted(this)
        scope.launch {
            while (isActive) { NearScanner.evaluate(); delay(1_000) }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val pairing = Pairing.load(this)
        if (pairing == null || !NearBeacon.allowed(this)) { stopSelf(); return START_NOT_STICKY }
        NearBeacon.start(this, pairing.key)
        NearScanner.start(this, pairing.key)
        if (!NearScanner.allowed(this)) NearBeacon.setNear(null)
        HopLink.poke() // a good moment to (re)connect to the Mac too
        return START_STICKY
    }

    override fun onDestroy() {
        scope.coroutineContext[Job]?.cancel()
        PhoneStatus.stop(this)
        NearScanner.stop()
        NearBeacon.stop()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "near"
        private const val NOTIFICATION_ID = 7

        /** Starts or stops the near-Mac signals to match the pairing and the Nearby devices permission. */
        fun update(ctx: Context) {
            val pairing = Pairing.load(ctx)
            if (pairing == null || !NearBeacon.allowed(ctx)) {
                ctx.stopService(Intent(ctx, NearService::class.java))
                NearBeacon.stop()
                NearScanner.stop()
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
