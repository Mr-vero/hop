package com.phonemod.hop

import android.Manifest
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.content.pm.PackageManager
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
 * for sharing the Mac's keyboard and showing the phone when it's placed next to the Mac.
 *
 * Only runs while connected to the Mac. The payload is a token derived from the pairing key that changes
 * every 5 minutes, and Android rotates the Bluetooth address too, so nobody else can recognise or follow
 * the phone. Non-connectable: nothing can connect to it.
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

    fun allowed(ctx: Context) =
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED

    @Synchronized
    fun start(ctx: Context, key: ByteArray) {
        if (job?.isActive == true || !allowed(ctx)) return
        job = scope.launch {
            while (isActive) {
                val window = System.currentTimeMillis() / 1000 / WINDOW_SECONDS
                advertise(ctx, token(key, window))
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
    private fun advertise(ctx: Context, token: ByteArray) {
        runCatching {
            val adapter = ctx.getSystemService(BluetoothManager::class.java)?.adapter ?: return
            if (!adapter.isEnabled || !allowed(ctx)) return
            val adv = adapter.bluetoothLeAdvertiser ?: return
            runCatching { advertiser?.stopAdvertising(callback) }
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED) // ~4 per second: responsive, still light
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_LOW)   // we only care about arm's length
                .setConnectable(false)
                .build()
            val data = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addServiceUuid(SERVICE)
                .addManufacturerData(COMPANY, token)
                .build()
            adv.startAdvertising(settings, data, callback)
            advertiser = adv
        }
    }
}
