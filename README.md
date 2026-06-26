<!--
SPDX-FileCopyrightText: 2019-Present Christian Kußowski
SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
SPDX-FileCopyrightText: 2024-Present Contributors to tjena!chat

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# tjena!chat

**tjena!chat** is a privacy-focused [[matrix](https://matrix.org)] messenger, **forked from
[FluffyChat](https://fluffy.chat)** and built with [Flutter](https://flutter.dev).
It keeps everything FluffyChat does and adds **on-device bridges to WhatsApp and Signal**
and a **private calling system** that lets you reach WhatsApp contacts without exposing
yourself to WhatsApp's calling — all running on your own infrastructure.

> tjena!chat is a community fork. It inherits FluffyChat's AGPL-3.0 license and credits the
> FluffyChat authors. See [LICENSE](./LICENSE).

---

## What's different from FluffyChat

On top of the full FluffyChat feature set (E2E-encrypted chats, spaces, voice messages,
push, group moderation, Material You, etc.), tjena!chat adds:

- **🟢 On-device WhatsApp bridge** — link WhatsApp as a companion device (QR scan, no
  server-side bridge). Chats, media, reactions, group member lists & @-mentions, read
  receipts, multiple WhatsApp accounts, and history backfill — all handled on the phone.
- **🔵 On-device Signal bridge** — link Signal and read your Signal chats inside tjena!chat.
- **📞 Private "call my WhatsApp contacts" feature** — you don't place a WhatsApp call.
  tjena!chat sends the contact a **web link**; they tap it (any browser, no app, no
  account) and *your* tjena!chat rings with the normal call UI. Calls run over **legacy
  Matrix VoIP (WebRTC)** and your own **STUN/coturn** — WhatsApp never carries the media.
  Voice or video, with proximity screen-off on voice calls.
- **🔁 Auto-reply / auto-decline WhatsApp calls** — when someone calls you on WhatsApp,
  tjena!chat can auto-reply with a "call me here" link and optionally decline the call so
  it stops ringing.
- **📍 Live location sharing**, **📸 stories**, **💾 auto-save received media**, and various
  branding/UX changes.

### Use cases

- **Stay reachable without WhatsApp's calling** — keep WhatsApp calls disabled for privacy
  but still let people call you, via your own encrypted relay.
- **One inbox** — read and reply to WhatsApp/Signal alongside your Matrix chats.
- **Self-hosted & private** — bridges run on your device; calls run on your homeserver and
  coturn. Nothing routes through a third-party bridge server.

> ⚠️ **Bridge & call availability:** the on-device WhatsApp/Signal bridges are **Android-only**
> (they ship as a native library — see below). The desktop/iOS/web builds are the standard
> FluffyChat client without the local bridges.

---

## Repository layout

| Path | What it is |
|---|---|
| `lib/`, `android/`, `ios/`, `linux/`, `macos/`, `windows/`, `web/` | The Flutter app (FluffyChat fork) |
| `bridge-go/` | The on-device WhatsApp/Signal bridge in Go (whatsmeow + signalmeow), compiled to a native Android library |
| `packages/tjena_bridge/` | Flutter plugin that wraps the native bridge (Android/Kotlin) |
| `call-provisioner/` | Go service that mints the temporary call room + guest link (self-hosted) |
| `call-web/` | Static web call page the recipient opens (Vite + matrix-js-sdk) |
| `deploy/` | `docker-compose.yml` + `.env.example` for the call services |
| `patches/` | Local source patches applied during the build |

---

## Building

### Prerequisites (all platforms)

- **Flutter** matching `pubspec.yaml` (`Dart SDK >= 3.11.1`). Run `flutter --version`.
- The Matrix SDK is pulled from git (`famedly/matrix-dart-sdk`, ref `main`) — see
  **SDK patches** below; they must be re-applied after every `flutter pub get`.

```bash
git clone <this-repo> tjena_chat && cd tjena_chat
flutter pub get
```

### ⚠️ SDK patches (required)

tjena!chat patches the Matrix Dart SDK (in the pub-cache git checkout) so the virtual
bridge rooms work and VoIP video renders correctly. **A fresh `flutter pub get` re-clones
the SDK and drops these patches**, so re-apply them before building:

1. **VoIP remote-stream fix** — apply `patches/voip_remote_stream_fix.py` to the SDK's
   `call_session.dart` (the script resolves the pub-cache path from
   `.dart_tool/package_config.json`).
2. **Virtual-room patches** (in `…/.pub-cache/git/matrix-dart-sdk-<ref>/lib/src/room.dart`),
   each marked `// TJENA PATCH`:
   - `_requestUser` short-circuits `:tjena.local` / `:local` users to local state (no
     homeserver lookup),
   - `searchEvents` returns local results for `:local` rooms (no `/messages` call),
   - `leave()` removes `:local` rooms locally without a server call.

Keep these in a small apply-script if you build often.

---

### Android (full build — includes the WhatsApp/Signal bridges)

Android needs the **native Go bridge** compiled to an AAR first.

**Bridge prerequisites:**
- Go **1.23+**
- `gomobile` (`go install golang.org/x/mobile/cmd/gomobile@latest && gomobile init`)
- Android **NDK 27**
- The build is **arm64-v8a only** (the Signal bridge links `libsignal_ffi.a`, only bundled
  for arm64 in `bridge-go/internal/signal_libs/arm64/`).

```bash
# 1) Build the native bridge → AAR (also copies it into android/app/libs)
cd bridge-go
# edit the exported paths at the top of build_aar.sh to match your machine
#   (GOPATH/gomobile, ANDROID_HOME, ANDROID_NDK_HOME)
./build_aar.sh
cd ..

# 2) Build the app (arm64)
flutter build apk --release            # or: flutter build appbundle --release
```

The AAR is written to **both** `packages/tjena_bridge/android/libs/` (compile-time) **and**
`android/app/libs/` (packaged into the APK). If you ever see a runtime `NoSuchMethodError`
from the bridge, the runtime copy is stale — re-run `build_aar.sh`.

> Re-run `build_aar.sh` whenever anything under `bridge-go/` changes; rebuild the APK
> whenever Dart changes.

### iOS

```bash
# optional: scripts/build-ios.sh adjusts the App Group / Team
flutter build ios --release
```
The native bridge is Android-only, so **WhatsApp/Signal local bridges are not available on
iOS**. Everything else (Matrix) works.

### macOS / Linux / Windows

```bash
flutter build macos --release      # see scripts/build-macos.sh for signing tweaks
flutter build linux --release
flutter build windows --release    # see scripts/build-windows.ps1
```
Desktop builds are the standard Matrix client (no local bridges).

### Web

```bash
scripts/prepare-web.sh   # if present, prepares web assets
flutter build web --release
```

---

## Call services (self-hosted)

The "call a WhatsApp contact" feature needs two small self-hosted services plus your
existing Synapse and coturn. Everything lives under `call-provisioner/`, `call-web/`, and
`deploy/`.

### Architecture

```
You (tjena!chat) ──m.call.*──► Synapse ◄──m.call.*── Recipient (browser, call.tjena.eu)
        │                                                      │
        └────────── WebRTC media (DTLS-SRTP) via coturn ───────┘
tjena!chat ──POST /api/calls (your Matrix token)──► call-provisioner ──► Synapse
```

- **`call-provisioner`** (Go) — authenticates with your Matrix token, **reuses one guest
  user + one call room per user** (via a room alias), and returns the web link. No database;
  no trash users.
- **`call-web`** (Vite + matrix-js-sdk) — the static page the recipient opens. Joins the
  call room and places the call; the screen stays awake during a call.

### Synapse / coturn requirements

In `homeserver.yaml`:
```yaml
registration_shared_secret: "<LONG_RANDOM>"   # backend only
turn_allow_guests: true                        # guests get your coturn creds
# turn_uris / turn_shared_secret (or turn_username/turn_password): your existing coturn
```
Create a `@callbot` service account and grab a **stable** access token (a plain password
login, *not* a token copied from another client — those rotate/expire).

### Build & run with Docker (recommended)

```bash
cd deploy
cp .env.example .env        # fill in SYNAPSE_BASE_URL, PUBLIC_HS_URL, PUBLIC_WEB_BASE,
                            #          ADMIN_TOKEN (@callbot), REGISTRATION_SHARED_SECRET, …
docker compose up -d --build
```
This builds both images from source. Point your reverse proxy / Cloudflare Tunnel:
- `call.tjena.eu` → the `web` service (it also proxies `/api/*` to the provisioner)
- `matrix.tjena.eu` → your Synapse
- coturn stays public/direct (never through the tunnel)

### Build the images standalone (e.g. for Portainer)

```bash
docker build -t tjena-call-provisioner:latest ./call-provisioner
docker build -t tjena-call-web:latest         ./call-web    # needs Node 18+ inside the image
```
Then point your stack at the images (use `pull_policy: never` if they're only local).

### In the app

Settings → **Local Bridges → WhatsApp calls**: enable the feature, set the provisioner URL
(default `https://call.tjena.eu`), and optionally turn on **auto-reply / auto-decline** for
incoming WhatsApp calls.

---

## Notes & limitations

- **WhatsApp history:** at link time tjena!chat requests a large history sync (configured in
  `bridge-go`); older messages are then backfillable per-chat. **Signal does not provide
  message history to linked devices** (a Signal design choice), so Signal history can't be
  backfilled.
- **Calls are 1:1** and unencrypted at the Matrix-room level (media is still DTLS-SRTP). The
  guest link is a short-lived capability; placing a new call invalidates the previous link.
- **Your WhatsApp/Signal account is never modified** by the bridges beyond what a normal
  linked companion device does.

---

## Credits

tjena!chat is a fork of **[FluffyChat](https://fluffy.chat)** by Christian Kußowski and
contributors, and stands on:
- [Flutter](https://flutter.dev) and the [Matrix Dart SDK](https://github.com/famedly/matrix-dart-sdk)
- [whatsmeow](https://github.com/tulir/whatsmeow) and
  [mautrix-signal / signalmeow](https://github.com/mautrix/signal) for the on-device bridges
- [matrix-js-sdk](https://github.com/matrix-org/matrix-js-sdk) for the web call client

Licensed under **AGPL-3.0-or-later**.
