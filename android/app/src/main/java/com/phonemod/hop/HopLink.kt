package com.phonemod.hop

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.provider.Settings
import android.util.Base64
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import kotlin.coroutines.resume

sealed interface LinkState {
    data object Unpaired : LinkState
    data object NoWifi : LinkState
    data object Searching : LinkState
    data class Connected(val macName: String) : LinkState
}

/**
 * The one connection to the paired Mac. It only exists while the phone is on Wi-Fi, idles
 * between messages, and backs off quickly when the Mac is asleep, so it costs almost no battery.
 */
object HopLink {
    private lateinit var app: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO + CoroutineExceptionHandler { _, _ -> })
    private val _state = MutableStateFlow<LinkState>(LinkState.Unpaired)
    val state: StateFlow<LinkState> = _state
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private val writeLock = Mutex()
    private var loop: Job? = null
    private var socket: Socket? = null
    private var out: DataOutputStream? = null
    private var crypto: SessionCrypto? = null

    /** The current Wi-Fi network, tracked by callback. Wi-Fi may not be the default network (mobile data can be). */
    @Volatile private var wifi: Network? = null

    fun init(ctx: Context) {
        if (::app.isInitialized) return
        app = ctx.applicationContext
        val cm = app.getSystemService(ConnectivityManager::class.java)
        cm.registerNetworkCallback(
            NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(),
            object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) { wifi = network; wake.trySend(Unit) }
                override fun onLost(network: Network) { if (wifi == network) wifi = null }
            },
        )
    }

    /** Start (or nudge) the connection loop; cheap to call often. */
    fun poke() {
        if (loop?.isActive != true) loop = scope.launch { run() }
        wake.trySend(Unit)
    }

    fun repair(pairing: Pairing) {
        pairing.save(app)
        socket?.close()
        poke()
    }

    private suspend fun run() {
        var backoff = 3_000L
        while (scope.isActive) {
            val pairing = Pairing.load(app) ?: run { _state.value = LinkState.Unpaired; return }
            val net = wifi
            if (net == null) {
                // Sleep until Wi-Fi appears (the callback wakes us) or something wants to send
                _state.value = LinkState.NoWifi
                wake.receive()
                continue
            }
            _state.value = LinkState.Searching
            val target = discover(pairing) ?: (pairing.host to pairing.port)
            runCatching { session(net, pairing, target.first, target.second) }
            // A session that got as far as Connected was healthy; start retries fast again
            if (_state.value is LinkState.Connected) backoff = 3_000L
            _state.value = LinkState.Searching
            // Mac asleep or away: retry with growing gaps, or immediately when something wants to send
            withTimeoutOrNull(backoff) { wake.receive() }
            backoff = (backoff * 2).coerceAtMost(5 * 60_000L)
        }
    }

    // ------------------------------------------------------------------ session

    private suspend fun session(net: Network, pairing: Pairing, host: String, port: Int) {
        // Bind to Wi-Fi explicitly so the Mac is reached even while mobile data is the default route
        val s = net.socketFactory.createSocket()
        s.connect(InetSocketAddress(host, port), 4_000)
        s.tcpNoDelay = true
        s.keepAlive = true
        socket = s
        val input = DataInputStream(BufferedInputStream(s.getInputStream()))
        val output = DataOutputStream(BufferedOutputStream(s.getOutputStream()))
        try {
            val phoneRandom = ByteArray(32).also { SecureRandom().nextBytes(it) }
            Frames.write(output, JSONObject().put("t", "hi").put("v", 1).put("r", b64(phoneRandom)).toString().toByteArray())
            val hi = JSONObject(String(Frames.read(input)))
            val macRandom = Base64.decode(hi.getString("r"), Base64.DEFAULT)
            val c = SessionCrypto(pairing.key, phoneRandom, macRandom)
            crypto = c
            out = output
            writeLock.withLock { writeJson(JSONObject().put("t", "hello").put("name", deviceName())) }

            val hello = readJson(input, c) ?: throw IOException("no hello")
            if (hello.optString("t") != "hello") throw IOException("bad hello")
            if (host != pairing.host || port != pairing.port) pairing.withAddress(app, host, port)
            _state.value = LinkState.Connected(hello.optString("name", pairing.macName))

            val pinger = scope.launch {
                while (isActive) {
                    delay(120_000)
                    runCatching { writeLock.withLock { writeJson(JSONObject().put("t", "ping")) } }.onFailure { s.close() }
                }
            }
            try {
                Inbox(app).run(input, c)
            } finally {
                pinger.cancel()
            }
        } finally {
            out = null
            crypto = null
            socket = null
            runCatching { s.close() }
        }
    }

    private fun readJson(input: DataInputStream, c: SessionCrypto): JSONObject? {
        val plain = c.open(Frames.read(input))
        return if (plain[0].toInt() == 0) JSONObject(String(plain, 1, plain.size - 1)) else null
    }

    private fun writeJson(obj: JSONObject) {
        val o = out ?: throw IOException("not connected")
        val c = crypto ?: throw IOException("not connected")
        Frames.write(o, c.seal(byteArrayOf(0) + obj.toString().toByteArray()))
    }

    // ------------------------------------------------------------------ sending

    /** Waits briefly for a connection; returns false if the Mac can't be reached. */
    suspend fun awaitConnected(timeoutMs: Long = 8_000): Boolean {
        poke()
        return withTimeoutOrNull(timeoutMs) { state.first { it is LinkState.Connected } } != null
    }

    suspend fun sendOtp(code: String, from: String) = send { writeJson(JSONObject().put("t", "otp").put("code", code).put("from", from)) }

    suspend fun sendText(text: String) = send { writeJson(JSONObject().put("t", "text").put("text", text)) }

    suspend fun sendFile(name: String, size: Long, mime: String, data: InputStream, progress: (Float) -> Unit = {}) = send {
        writeJson(JSONObject().put("t", "file").put("name", name).put("size", size).put("mime", mime))
        val o = out!!
        val c = crypto!!
        val buf = ByteArray(256 * 1024)
        var sent = 0L
        data.use {
            while (sent < size) {
                val n = it.read(buf, 0, minOf(buf.size.toLong(), size - sent).toInt())
                if (n < 0) throw IOException("file ended early")
                Frames.write(o, c.seal(byteArrayOf(1) + buf.copyOf(n)))
                sent += n
                progress(sent.toFloat() / size.coerceAtLeast(1))
            }
        }
    }

    private suspend fun send(block: () -> Unit): Boolean {
        if (!awaitConnected()) return false
        return runCatching { writeLock.withLock { block() } }
            .onFailure { socket?.close() }
            .isSuccess
    }

    // ------------------------------------------------------------------ discovery & network

    private suspend fun discover(p: Pairing): Pair<String, Int>? = withTimeoutOrNull(5_000) {
        val nsd = app.getSystemService(NsdManager::class.java)
        val found = Channel<NsdServiceInfo>(Channel.CONFLATED)
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) { if (info.serviceName == p.service) found.trySend(info) }
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onServiceLost(info: NsdServiceInfo) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { found.close() }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }
        nsd.discoverServices("_hop._tcp", NsdManager.PROTOCOL_DNS_SD, listener)
        try {
            val info = found.receive()
            resolve(nsd, info)
        } catch (e: Exception) {
            null
        } finally {
            runCatching { nsd.stopServiceDiscovery(listener) }
        }
    }

    @Suppress("DEPRECATION")
    private suspend fun resolve(nsd: NsdManager, info: NsdServiceInfo): Pair<String, Int>? = suspendCancellableCoroutine { cont ->
        if (Build.VERSION.SDK_INT >= 34) {
            val cb = object : NsdManager.ServiceInfoCallback {
                override fun onServiceUpdated(s: NsdServiceInfo) {
                    val addr = s.hostAddresses.firstOrNull { it is java.net.Inet4Address } ?: s.hostAddresses.firstOrNull()
                    if (addr != null && cont.isActive) cont.resume(addr.hostAddress!! to s.port)
                    runCatching { nsd.unregisterServiceInfoCallback(this) }
                }
                override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) { if (cont.isActive) cont.resume(null) }
                override fun onServiceLost() {}
                override fun onServiceInfoCallbackUnregistered() {}
            }
            nsd.registerServiceInfoCallback(info, app.mainExecutor, cb)
        } else {
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onServiceResolved(s: NsdServiceInfo) { if (cont.isActive) cont.resume(s.host.hostAddress!! to s.port) }
                override fun onResolveFailed(s: NsdServiceInfo, errorCode: Int) { if (cont.isActive) cont.resume(null) }
            })
        }
    }

    private fun deviceName(): String =
        Settings.Global.getString(app.contentResolver, Settings.Global.DEVICE_NAME) ?: Build.MODEL

    private fun b64(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.NO_WRAP)
}
