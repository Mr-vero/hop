# Hop protocol (v1)

Galaxy phone <-> Mac over the local network. No cloud, no accounts.

## Pairing
The Mac generates a random 32-byte pairing key once and shows it as a QR code:

    hop1|<base64 key>|<bonjour service name>|<mac ip>|<port>|<mac name>

The phone scans it and stores the key. Possessing the key is what proves a device is paired.

## Discovery
The Mac advertises Bonjour service `_hop._tcp` named `Hop-<id>` on TCP port 47900 (or any free port).
The phone finds it with NsdManager, falling back to the ip/port from the QR code.

## Framing
Every frame is `[u32 big-endian length][payload]`, payload at most 1 MiB.

## Handshake
1. phone -> mac, plaintext JSON: `{"t":"hi","v":1,"r":"<base64 32 random bytes>"}`
2. mac -> phone, plaintext JSON: `{"t":"hi","v":1,"r":"<base64 32 random bytes>"}`
3. Both derive `session = HMAC-SHA256(pairingKey, "hop-v1" || phoneR || macR)`.

From then on each payload is `nonce(12) || AES-256-GCM(session, plaintext) || tag(16)`.
Nonce = 4-byte sender prefix (phone 1, mac 2) + 8-byte big-endian counter starting at 0.
Receivers require the counter to increase by exactly one, so frames can't be replayed or reordered.

The first encrypted frame from each side is `{"t":"hello","name":"..."}`; failing to decrypt it ends the connection.

## Messages (encrypted plaintext = type byte + body)
Type 0 = UTF-8 JSON:
- `{"t":"hello","name":"Galaxy S25 Ultra"}`
- `{"t":"otp","code":"482913","from":"BCA"}` (phone -> mac only)
- `{"t":"text","text":"https://..."}` (either way; links open, other text is copied)
- `{"t":"file","name":"a.jpg","size":123,"mime":"image/jpeg"}`, followed by type-1 frames
- `{"t":"ping"}` / `{"t":"pong"}`

Type 1 = raw file bytes for the file announced most recently, sent until `size` bytes have arrived.
A sender never interleaves other frames inside a file transfer.

### Added in 1.1 (all type 0, over the same encrypted link)
Phone -> Mac:
- `{"t":"near","near":true|false|null,"rssi":-42}`: the phone's own verdict from the Mac's Bluetooth signal (null: it hasn't heard the Mac lately, so the Mac measures for itself).
- `{"t":"near-calibrated","ok":true,"rssi":-40}`: reply to `near-calibrate`.
- `{"t":"status","battery":82,"charging":true,"signal":3}`: on connect and when it changes.
- `{"t":"notif","id":"<key>","app":"WhatsApp","pkg":"com.whatsapp","title":"…","text":"…","reply":true,"icon":"<base64 PNG 64px>"}` and `{"t":"notif-gone","id":"<key>"}`.
- `{"t":"call","state":"ringing"|"active"|"ended","id":"<key>","name":"…","detail":"…"}` (only from the default dialer).

Mac -> phone:
- `{"t":"clip","text":"…"}`: universal clipboard (concealed/transient copies are never sent).
- `{"t":"notif-reply","id":"<key>","text":"…"}`, `{"t":"notif-dismiss","id":"<key>"}`, `{"t":"notif-open","id":"<key>"}`.
- `{"t":"call-answer"}`, `{"t":"call-decline"}`, `{"t":"ring"}`, `{"t":"ring-stop"}`, `{"t":"near-calibrate"}`.

## Near-Mac Bluetooth signals
Tokens are `HMAC-SHA256(pairingKey, label || window_u64be [|| flag_u8])`, truncated, with `window = unix_time / 300`; receivers accept the current window ±1.
- Mac advertises service `6B0F1E53-8D3A-4C7B-9E21-5A4F3C2D1B0E` with local name `"H" + hex(token("hop-mac"))[0..6]`. The phone requires the full name.
- Phone advertises (non-connectable, no service ID, no name) manufacturer data `0xFFFF` + `token("hop-near", flag)[0..6]`, flag 1 near, 2 away, absent when it isn't judging. The Mac only uses the flag to close the phone window; opening requires the `near` link message.
