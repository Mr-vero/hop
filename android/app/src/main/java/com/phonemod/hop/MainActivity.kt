package com.phonemod.hop

import android.Manifest
import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.os.Bundle
import android.provider.Settings
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning

@Composable
fun HopTheme(content: @Composable () -> Unit) {
    val ctx = LocalContext.current
    val scheme = runCatching { dynamicDarkColorScheme(ctx) }.getOrDefault(darkColorScheme())
    MaterialTheme(colorScheme = scheme) {
        // Text outside a Surface defaults to black; make it readable on the dark background
        CompositionLocalProvider(LocalContentColor provides scheme.onSurface, content = content)
    }
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        HopLink.init(this)
        HopLink.poke()
        setContent { HopTheme { Home() } }
    }

    private fun scan() {
        val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
        GmsBarcodeScanning.getClient(this, options).startScan()
            .addOnSuccessListener { code ->
                val pairing = Pairing.parse(code.rawValue.orEmpty())
                if (pairing == null) Toast.makeText(this, "That's not a Hop code. Use Pair Phone… in the Mac's menu bar.", Toast.LENGTH_LONG).show()
                else HopLink.repair(pairing)
            }
    }

    @Composable
    private fun Home() {
        val state by HopLink.state.collectAsState()
        val pairing = remember(state) { Pairing.load(this) }
        var resumes by remember { mutableIntStateOf(0) }
        LifecycleResumeEffect(Unit) { resumes++; HopLink.poke(); onPauseOrDispose { } }
        val notifPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { resumes++ }
        val nearPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { resumes++; HopLink.nearChanged() }

        Column(
            Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface).safeDrawingPadding()
                .verticalScroll(rememberScrollState()).padding(horizontal = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Spacer(Modifier.height(20.dp))
            Text("Hop", fontSize = 34.sp, fontWeight = FontWeight.Bold)
            Text("Codes, links and files between your Galaxy and your Mac. Direct over Wi-Fi, encrypted, no cloud.",
                color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 15.sp)

            StatusCard(state, pairing)

            if (pairing == null) {
                Button(onClick = ::scan, Modifier.fillMaxWidth().height(54.dp)) { Text("Pair with Mac", fontSize = 16.sp) }
                Text("On your Mac, open Hop's menu-bar icon → Pair Phone… and scan the code.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 14.sp)
            } else {
                FilledTonalButton(onClick = { startActivity(Intent(this@MainActivity, ClipboardActivity::class.java)) }, Modifier.fillMaxWidth().height(52.dp)) {
                    Text("Send clipboard to Mac")
                }
            }

            key(resumes) {
                Text("Set up", fontWeight = FontWeight.SemiBold, fontSize = 18.sp, modifier = Modifier.padding(top = 10.dp))
                val listenerOn = NotificationManagerCompat.getEnabledListenerPackages(this@MainActivity).contains(packageName)
                SetupRow(
                    "Codes to Mac", "Spots one-time codes in your notifications and copies just the code on your Mac. Nothing else is sent.",
                    done = listenerOn, action = "Allow",
                ) {
                    startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                        .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, ComponentName(this@MainActivity, OtpListener::class.java).flattenToString()))
                }
                // Android hides codes inside notifications from Hop, so SMS is how bank codes get through
                val smsOn = ContextCompat.checkSelfPermission(this@MainActivity, Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED
                SetupRow(
                    "Codes from SMS", "Reads incoming texts only to find verification codes. Needed because Android hides codes inside notifications.",
                    done = smsOn, action = "Allow",
                ) { notifPermission.launch(Manifest.permission.RECEIVE_SMS) }
                val notifOn = ContextCompat.checkSelfPermission(this@MainActivity, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
                SetupRow("Alerts from Mac", "Lets you know when a file or link arrives from your Mac.", done = notifOn, action = "Allow") {
                    notifPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                }
                val nearOn = NearBeacon.allowed(this@MainActivity)
                SetupRow(
                    "Near your Mac", "Next to your Mac, use its keyboard and mouse on this phone. Right up against it, the phone appears on the Mac's screen. Uses a private Bluetooth signal only your Mac recognises.",
                    done = nearOn, action = "Allow",
                ) { nearPermission.launch(Manifest.permission.BLUETOOTH_ADVERTISE) }
                SetupRow("Quick Settings tile", "One tap in the pull-down panel sends your clipboard to the Mac.", done = false, action = "Add") {
                    getSystemService(StatusBarManager::class.java).requestAddTileService(
                        ComponentName(this@MainActivity, ClipTile::class.java), "Send to Mac",
                        Icon.createWithResource(this@MainActivity, R.drawable.ic_hop), mainExecutor,
                    ) { resumes++ }
                }
            }

            Text("How to use", fontWeight = FontWeight.SemiBold, fontSize = 18.sp, modifier = Modifier.padding(top = 10.dp))
            Tip("Codes", "When a verification code arrives, it's already copied on your Mac. Just press ⌘V.")
            Tip("Links, text, photos, files", "Tap Share in any app → Send to Mac. Links open in your Mac's browser; files land in Downloads.")
            Tip("From the Mac", "Drag files onto Hop's menu-bar icon, or use its menu. They land in Downloads/Hop here.")
            if (pairing != null) OutlinedButton(onClick = ::scan, Modifier.padding(top = 6.dp)) { Text("Pair again") }
            Spacer(Modifier.height(24.dp))
        }
    }

    @Composable
    private fun StatusCard(state: LinkState, pairing: Pairing?) {
        val (dot, title, sub) = when {
            pairing == null -> Triple(Color(0xFF8A8A8A), "Not paired yet", "Pair once and Hop reconnects on its own.")
            state is LinkState.Connected -> Triple(Color(0xFF3DDC84), "Connected", state.macName)
            state is LinkState.NoWifi -> Triple(Color(0xFFFFB020), "Waiting for Wi-Fi", "Hop connects when you're on the same Wi-Fi as ${pairing.macName}.")
            else -> Triple(Color(0xFFFFB020), "Looking for ${pairing.macName}", "Make sure Hop is running on the Mac.")
        }
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(MaterialTheme.colorScheme.surfaceContainerHigh).padding(20.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(12.dp).clip(CircleShape).background(dot))
            Column(Modifier.padding(start = 14.dp)) {
                Text(title, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
                Text(sub, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 14.sp)
            }
        }
    }

    @Composable
    private fun SetupRow(title: String, body: String, done: Boolean, action: String, onClick: () -> Unit) {
        Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(MaterialTheme.colorScheme.surfaceContainer).padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(title, fontWeight = FontWeight.Medium, fontSize = 16.sp)
                Text(body, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp)
            }
            if (done) Text("On", color = Color(0xFF3DDC84), fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 12.dp))
            else FilledTonalButton(onClick = onClick, Modifier.padding(start = 12.dp)) { Text(action) }
        }
    }

    @Composable
    private fun Tip(title: String, body: String) {
        Column {
            Text(title, fontWeight = FontWeight.Medium, fontSize = 15.sp)
            Text(body, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 14.sp)
        }
    }
}
