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
import kotlinx.coroutines.async
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
        // Let the paired Mac sense how close the phone is. This doesn't depend on the Wi-Fi link:
        // keyboard sharing and the phone window run over USB or wireless debugging instead
        nearChanged()
    }

    /** (Re)starts the near-Mac signal for the current pairing, e.g. after Nearby devices is granted or re-pairing. */
    fun nearChanged() = NearService.update(app)

    /** Start (or nudge) the connection loop; cheap to call often. */
    fun poke() {
        if (loop?.isActive != true) loop = scope.launch { run() }
        wake.trySend(Unit)
    }

    fun repair(pairing: Pairing) {
        pairing.save(app)
        socket?.close()
        nearChanged()
        poke()
    }

    private suspend fun run() {
        var backoff = 3_000L
        while (scope.isActive) {
            val pairing = Pairing.load(app) ?: run { _state.value = LinkState.Unpaired; return }
            val net = wifi
            if (net == null && hotspotSubnets().isEmpty()) {
                // Sleep until Wi-Fi appears (the callback wakes us), something wants to send, or a hotspot may have started
                _state.value = LinkState.NoWifi
                withTimeoutOrNull(30_000) { wake.receive() }
                continue
            }
            _state.value = LinkState.Searching
            // Try each way of finding the Mac until one connects: Bonjour on the Wi-Fi, this phone's own hotspot,
            // then the last known address. (Anyone on the Wi-Fi can advertise our Mac's name, and old addresses go
            // stale, so one failing never stops the others.)
            val saved = pairing.host to pairing.port
            val tried = mutableSetOf<Pair<String, Int>>()
            var connected = false
            // Discovery can hang on some phones; a separate task with a hard limit keeps the loop moving
            val bonjour: suspend () -> Pair<String, Int>? = { withTimeoutOrNull(6_000) { scope.async { discover(pairing) }.await() } }
            val hotspot: suspend () -> Pair<String, Int>? = { findOnHotspot(pairing.port) }
            val order = if (hotspotSubnets().isNotEmpty()) listOf(hotspot, bonjour) else listOf(bonjour, hotspot)
            for (find in order + listOf<suspend () -> Pair<String, Int>?>({ saved })) {
                val target = runCatching { find() }.getOrNull() ?: continue
                if (!tried.add(target)) continue
                runCatching { session(net, pairing, target.first, target.second) }
                if (_state.value is LinkState.Connected) { connected = true; break }
            }
            // A session that got as far as Connected was healthy; start retries fast again
            if (connected) backoff = 3_000L
            _state.value = LinkState.Searching
            // Mac asleep or away: retry with growing gaps, or immediately when something wants to send
            withTimeoutOrNull(backoff) { wake.receive() }
            backoff = (backoff * 2).coerceAtMost(5 * 60_000L)
        }
    }

    // ------------------------------------------------------------------ session

    private suspend fun session(net: Network?, pairing: Pairing, host: String, port: Int) {
        // Bind to Wi-Fi explicitly so the Mac is reached even while mobile data is the default route.
        // A Mac on this phone's own hotspot is reached directly instead (it's on the hotspot's subnet).
        val onHotspot = hotspotSubnets().any { (prefix, len) -> sameSubnet(host, prefix, len) }
        val s = if (net != null && !onHotspot) net.socketFactory.createSocket() else Socket()
        s.connect(InetSocketAddress(host, port), 4_000)
        s.tcpNoDelay = true
        s.keepAlive = true
        // A peer that stops answering mid-handshake must not stall the link forever
        s.soTimeout = 10_000
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
            // We ping every 2 minutes and the Mac answers, so silence for 5 means the link is dead
            s.soTimeout = 300_000

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

    /**
     * Android's service discovery doesn't look inside the phone's own hotspot, so check the few devices on it
     * for Hop's port directly. Only this phone's hotspot (a /24 or smaller) is ever checked.
     */
    private suspend fun findOnHotspot(port: Int): Pair<String, Int>? = withTimeoutOrNull(4_000) {
        val hosts = hotspotSubnets().filter { it.second >= 24 }.flatMap { (addr, _) ->
            val b = addr.address
            val own = b[3].toInt() and 255
            (1..254).filter { it != own }.map { "${b[0].toInt() and 255}.${b[1].toInt() and 255}.${b[2].toInt() and 255}.$it" }
        }
        if (hosts.isEmpty()) return@withTimeoutOrNull null
        val found = Channel<String>(Channel.CONFLATED)
        val jobs = hosts.map { h ->
            scope.launch {
                runCatching { Socket().use { it.connect(InetSocketAddress(h, port), 600) }; found.trySend(h) }
            }
        }
        try { found.receive() to port } finally { jobs.forEach { it.cancel() } }
    }

    /** IPv4 subnets (address, prefix length) of this phone's own hotspot, if it's sharing one. */
    private fun hotspotSubnets(): List<Pair<java.net.Inet4Address, Int>> = runCatching {
        java.net.NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback && (it.name.startsWith("swlan") || it.name.startsWith("ap") || it.name.startsWith("softap")) }
            .flatMap { i -> i.interfaceAddresses.mapNotNull { a -> (a.address as? java.net.Inet4Address)?.let { it to a.networkPrefixLength.toInt() } } }
    }.getOrDefault(emptyList())

    private fun sameSubnet(host: String, prefix: java.net.Inet4Address, len: Int): Boolean = runCatching {
        val h = java.net.InetAddress.getByName(host).address
        val p = prefix.address
        val mask = if (len == 0) 0 else -1 shl (32 - len)
        fun Int(b: ByteArray) = (b[0].toInt() and 255 shl 24) or (b[1].toInt() and 255 shl 16) or (b[2].toInt() and 255 shl 8) or (b[3].toInt() and 255)
        (Int(h) and mask) == (Int(p) and mask)
    }.getOrDefault(false)

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
