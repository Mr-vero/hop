<p align="center">
  <img src="art/icon-1024.png" width="140" alt="Hop icon">
</p>

<h1 align="center">Hop</h1>

<p align="center">
  <b>The Continuity your Android phone never had.</b><br>
  Bring your Android phone near your Mac and it appears on screen. Notifications and calls in the notch, one shared clipboard, files and codes.<br>
  It connects directly over your Wi-Fi, hotspot or cable, and its link is encrypted end to end. No cloud, no account, no tracking.
</p>

<p align="center">
  <a href="../../releases/latest"><img alt="Download" src="https://img.shields.io/github/v/release/Mr-vero/hop?label=download&color=4a66ff"></a>
  <img alt="Android 12+" src="https://img.shields.io/badge/Android-12%2B-3ddc84">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111">
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

<p align="center"><a href="https://mr-vero.github.io/hop/"><b>mr-vero.github.io/hop</b></a></p>

---

iPhone owners get AirDrop, auto-filled SMS codes and iPhone Mirroring for free. Hop gives an Android phone the same tricks with a Mac. It's two small apps: a menu-bar app on the Mac and a companion app on the phone.

## What it does

| | |
|---|---|
| 📱 **Bring it near, it's on your Mac** | Set the phone beside your Mac and it springs onto the screen in a slim phone window (with a hover toolbar: close, back, home, recents). Walk away and it tucks back into the notch. The phone's own screen goes dark while you use it, like iPhone Mirroring. |
| 🔔 **Notifications in the notch** | Phone notifications slide out of the notch with the app's icon. **Reply** from the Mac, **dismiss** them, or **click** one to open that chat on the phone, right inside the phone window. |
| 📞 **Calls** | An incoming call shows the caller in the notch with **Answer** and **Decline**. You still talk on the phone. |
| 📋 **One clipboard** | Copy on one device, paste on the other. Passwords (copies password managers mark private) are never synced. |
| 🔑 **Codes, instantly** | A verification code arrives by text and it's **already on your Mac's clipboard**. Press ⌘V. It clears itself after 2 minutes. |
| 🖥 **Dock mode** | ⌘D opens a full Android desktop (taskbar, app windows) in a resizable Mac window that can go full screen. Your phone stays free to use. |
| 📁 **Files, both ways** | Drop files onto the phone window or the menu-bar icon, or share from the phone with **Send to Mac**. Links open in your Mac's browser. |
| 🔋 **At a glance** | Battery, charging and signal in Hop's menu, plus recent codes and **Find My Phone**, which rings it at full volume even on silent. |

## How it works

```
 Android phone                                   Mac
┌──────────────┐   Bonjour (_hop._tcp) + QR    ┌──────────────┐
│  Hop app     │ ───────────────────────────►  │  Hop.app     │
│  SMS codes   │   TCP, AES-256-GCM per        │  menu bar    │
│  share sheet │   session, same Wi-Fi only    │  clipboard   │
│  QS tile     │ ◄───────────────────────────► │  Downloads   │
└──────────────┘                               └──────┬───────┘
        ▲            adb + scrcpy server              │
        └─────────── (USB or wireless debugging) ─────┘
                       phone screen mirroring
```

- **Pairing:** pair once by scanning a QR code. It carries a random 32-byte key that never leaves your two devices.
- **Encryption:** each connection derives a fresh session key (HMAC-SHA256) and encrypts every frame with AES-256-GCM. Frame counters stop anything being replayed or reordered. The full spec is in [PROTOCOL.md](PROTOCOL.md).
- **Near or away:** the Mac sends a small Bluetooth signal named with a token from the pairing key that changes every 5 minutes. The phone measures its strength, decides "near" or "away" itself, and tells the Mac over the encrypted link (a backup copy rides in the phone's own signed signal, which can only ever *close* the window). Fine-tune the distance with **Calibrate Distance…**.
- **Battery:** the phone listens for the Mac in short bursts, and continuously only while the Mac is in range. The link idles with a ping every two minutes. A quiet notification keeps Hop from being put to sleep.
- **Mirroring:** a direct client for the [scrcpy](https://github.com/Genymobile/scrcpy) server. It decodes the H.264 stream with VideoToolbox and plays raw PCM audio.

## Install

Download both from the **[latest release](../../releases/latest)**.

### Mac (macOS 14 Sonoma or later; Apple silicon or Intel)
1. Unzip `Hop-mac.zip` and drag **Hop.app** to **Applications**.
2. Hop isn't notarized yet, so the first time, **right-click → Open → Open**. If macOS says the app is damaged, run this in Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Hop.app
   ```
3. When asked, allow **Local Network** and **Notifications**.

### Android (Android 12 or later)
1. Download `Hop-android.apk` on the phone and install it. You'll need to allow installs from your browser or file manager.
2. Open Hop → **Pair with Mac**, then on the Mac choose **Hop menu → Pair Phone…** and scan the code.
3. Under **Set up**, turn on:
   - **Codes & notifications to Mac:** shows notifications in the notch and catches codes from apps. If Android says it's a **restricted setting**, open **Settings → Apps → Hop → ⋮ → Allow restricted settings** first. A switch lets you keep notifications off if you only want codes.
   - **Codes from SMS:** Android 15+ hides codes inside notifications from other apps, so Hop reads incoming texts instead. It looks only for the code, and only the code is sent.
   - **Near your Mac:** the private Bluetooth signal (Android calls it "Nearby devices").
   - **Calls on Mac**, **Alerts from Mac** and the **Quick Settings tile** are optional.
4. On the Mac, turn on **Show Phone When It's Near** in Hop's menu and allow **Bluetooth** when asked.

> **"Harmful app blocked"?** Google Play Protect warns about any app from outside the Play Store that reads SMS and notifications, because code-stealing malware does the same. Hop's full source is in this repo, so you can check exactly what it does. Tap **More details → Install anyway**.
>
> In some countries Google blocks these installs with no override. Install over USB from your Mac instead: turn on **USB debugging**, plug in, and run `adb install Hop-android.apk` (`brew install android-platform-tools` gets you `adb`).

### Phone on your Mac and dock mode
These use Android's debugging bridge, so they need a one-time setup:
1. Install the tools on the Mac:
   ```bash
   brew install scrcpy
   ```
2. On the phone, turn on **Developer options → USB debugging**. Plug the phone into the Mac and accept the prompt.
3. Choose **Show Phone Screen** (⌘M). While the cable is in, Hop also switches on wireless debugging, so after that it works over Wi-Fi or the phone's hotspot (while Hop on the phone is connected) until the phone restarts.

| In the phone window | |
|---|---|
| Click / drag / scroll | Touch, swipe, scroll |
| Right-click | Back |
| Middle-click | Home |
| ⌘H · ⌘B · ⌘S | Home · Back · Recent apps |
| ⌘N | Pull down notifications |
| ⌘V | Paste the Mac clipboard into the phone |
| ⌘O | Turn the phone's own screen on or off |
| ⌘+ / ⌘− | Bigger / smaller window |
| ⌘W | Close (locks the phone) |
| Hover over the phone | Toolbar: close, back, home, recents |
| Drop files on it | Sends them to the phone's Downloads/Hop |

## Build from source

**Mac:** requires Xcode 16 or later (or its command-line tools).
```bash
cd mac
./build.sh            # universal, ad-hoc signed build/Hop.app
open build/Hop.app
```

**Android:** requires JDK 17+ and the Android SDK (platform 36).
```bash
cd android
./gradlew installDebug       # onto a connected phone
./gradlew assembleRelease    # signed only if keystore.properties exists
```
For signed release builds, create `android/keystore.properties` with the four keys `storeFile`, `storePassword`, `keyAlias` and `keyPassword`. Never commit it.

### Releasing
One command on a Mac builds both apps, signs the APK, tags the commit and publishes the GitHub release with checksums:
```bash
./release.sh 1.0.2              # or add --dry-run to only build into dist/dry-run/
```
It needs Xcode, the Android SDK, a logged-in `gh`, and `android/keystore.properties` pointing at the release key.

The same build can run on GitHub Actions (`.github/workflows/`), started by hand. It needs the repository secrets `ANDROID_KEYSTORE_BASE64` and `ANDROID_KEYSTORE_PASSWORD`.

### Project layout
```
mac/        Swift package: menu-bar app, link server, near sensor, island, clipboard sync, phone window
android/    Kotlin + Jetpack Compose app: link, near signals, notifications/calls bridge, codes, share targets
art/        Icon source (SVG)
PROTOCOL.md Wire protocol
```

## Privacy

- Nothing touches a server. Hop has no analytics, no crash reporting, no accounts and no cloud relay.
- Bluetooth signals are signed with the pairing key and change identity every 5 minutes, so they can't be used to follow you, and they carry no personal data. A replayed signal alone can't open the phone window: that takes the paired phone connected over the encrypted link, and an unlocked Mac.
- Codes, notifications, replies, calls, clipboard text and files all travel over the AES-256-GCM link. The phone window and dock mode use Android's debugging connection instead, which is private over USB but not encrypted over Wi-Fi (see Limitations).
- Notifications marked secret never leave the phone; private ones show only their lock-screen version. The notch island is hidden from screen sharing and recordings.
- Only the phone's real dialer can show a call. Phone clipboard changes are announced on the Mac and marked so clipboard managers don't keep them.
- The phone window and clipboard use wireless debugging only at the address the encrypted link vouches for; otherwise only the USB cable.
- From texts and notifications, **only the extracted code** (plus the sender's name) is sent, and only to your paired Mac.
- Shares always ask before sending, so another app can't quietly push links or files to your Mac. Hop never sends its own private files.
- Files received on the Mac get macOS's download quarantine, so Gatekeeper checks anything runnable before it opens.
- OTPs are marked as concealed on the Mac clipboard, so clipboard managers don't keep them. They also clear after 2 minutes.
- Received files stay in `~/Downloads` on the Mac and `Downloads/Hop` on the phone.
- Unpair anytime from **Pair Phone… → Unpair & Make New Code** on the Mac. The old key stops working immediately.

## Limitations

- Both devices must be on the same Wi-Fi (or the Mac on the phone's hotspot). Many guest and hotel networks block devices from seeing each other.
- Codes that only appear inside app notifications are hidden by Android 15+ unless they also come by SMS.
- The phone window needs USB debugging, and wireless use has to be re-enabled with the cable after each phone restart. Android's legacy wireless debugging isn't encrypted, so on untrusted networks prefer the cable or your phone's hotspot.
- Bluetooth distance is approximate; use **Calibrate Distance…** to suit your desk.
- Phone-shaped window styling is tuned for Galaxy phones, but any Android 12+ phone works.

## Credits

Screen mirroring uses the on-phone server from [scrcpy](https://github.com/Genymobile/scrcpy) by Genymobile (Apache 2.0). It's installed separately through Homebrew, not bundled.

## License

[MIT](LICENSE)
