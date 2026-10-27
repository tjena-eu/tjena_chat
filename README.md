<!--
SPDX-FileCopyrightText: 2019-Present Christian Kußowski
SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
SPDX-FileCopyrightText: 2024-Present Contributors to tjena!chat

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# tjena!chat

**tjena!chat** is a privacy-focused [[matrix](https://matrix.org)] messenger, **forked from
[FluffyChat](https://fluffy.chat)** and built with [Flutter](https://flutter.dev).
It keeps everything FluffyChat does and adds **WhatsApp through your own bridge at home**
(chats and calls), running on your own infrastructure.

> tjena!chat is a community fork. It inherits FluffyChat's AGPL-3.0 license and credits the
> FluffyChat authors. See [LICENSE](./LICENSE).

---

## What's different from FluffyChat

On top of the full FluffyChat feature set (E2E-encrypted chats, spaces, voice messages,
push, group moderation, Material You, etc.), tjena!chat adds:

- **🏠 Personal WhatsApp bridge** — an unmodified mautrix-whatsapp running in the tjena
  Bridge app on a phone at home ([tjena_bridge](https://github.com/tjena-eu/tjena_bridge), its own repo).
- **📞 WhatsApp calls** — call WhatsApp contacts from tjena!chat and answer their calls,
  through the personal bridge (1:1 voice and video, one calls device per WhatsApp account;
  see `wacall/` in tjena_bridge).
- **📞 Matrix calls** — MatrixRTC (LiveKit) calls from FluffyChat when the server
  advertises a LiveKit service, with the old 1:1 calls kept as fallback (`matrixrtc/`).
- **📍 Live location sharing**, **📸 stories**, **💾 auto-save received media**, and various
  branding/UX changes.

### Use cases

- **One inbox** — read and reply to WhatsApp (and Signal through a server bridge)
  alongside your Matrix chats.
- **Self-hosted & private** — your WhatsApp bridge runs on your own phone at home;
  nothing routes through a third-party bridge server.

---

## Repository layout

| Path | What it is |
|---|---|
| `lib/`, `android/`, `ios/`, `linux/`, `macos/`, `windows/`, `web/` | The Flutter app (FluffyChat fork) |
| `patches/` | Local source patches applied during the build |

---

## Install & updates (Android)

- **Obtainium (automatic updates):** add `https://github.com/tjena-eu/tjena_chat` in
  [Obtainium](https://github.com/ImranR98/Obtainium), or open
  `obtainium://add/https://github.com/tjena-eu/tjena_chat` on the phone.
- **APK:** [latest release](https://github.com/tjena-eu/tjena_chat/releases/latest) ·
  website: <https://tjena.eu/download/>
- Signing certificate SHA-256:
  `A9:4B:EA:04:5D:79:00:38:94:8B:9C:57:B3:39:AE:E5:79:D9:9B:0E:0C:08:FF:44:06:DC:EB:BC:A2:1F:44:46`

Releases are published with fastlane: see [android/fastlane/README.md](android/fastlane/README.md).

---

## Building

### Prerequisites (all platforms)

- **Flutter 3.47.7** (the version in `.fvmrc`). Run `flutter --version`.
- The Matrix SDK comes from pub.dev (`matrix: ^14.1.0`). See **SDK patches** below; they
  must be re-applied after every `flutter pub get`.

```bash
git clone <this-repo> tjena_chat && cd tjena_chat
flutter pub get
```

### ⚠️ SDK patches (required)

tjena!chat patches the Matrix Dart SDK (in the pub cache) so video in the old 1:1 calls
renders correctly. **A fresh SDK download drops the patch**, so re-apply it before
building: run `patches/voip_remote_stream_fix.py` on the SDK's `call_session.dart`
(`build_android` does this; it resolves the path from `.dart_tool/package_config.json`).

---

### Android

```bash
flutter build apk --release            # or: flutter build appbundle --release
```

### iOS

```bash
# optional: scripts/build-ios.sh adjusts the App Group / Team
flutter build ios --release
```
WhatsApp through your own bridge works on iOS too.

### macOS / Linux / Windows

```bash
flutter build macos --release      # see scripts/build-macos.sh for signing tweaks
flutter build linux --release
flutter build windows --release    # see scripts/build-windows.ps1
```
Desktop builds work the same way.

### Web

```bash
scripts/prepare-web.sh   # if present, prepares web assets
flutter build web --release
```

---

## Notes & limitations

- **WhatsApp history** is copied by your own bridge when you link an account (settings in
  the tjena Bridge app).
- **WhatsApp calls are 1:1** (voice and video) and need the personal bridge with calls set
  up in the Bridge app (docs in [tjena_bridge](https://github.com/tjena-eu/tjena_bridge)).
- **Matrix group calls** need a LiveKit service; see `matrixrtc/README.md`. Without it the
  app uses the old 1:1 calls.
- **Your WhatsApp account is never modified** by the bridge beyond what a normal
  linked companion device does.

---

## Credits

tjena!chat is a fork of **[FluffyChat](https://fluffy.chat)** by Christian Kußowski and
contributors, and stands on:
- [Flutter](https://flutter.dev) and the [Matrix Dart SDK](https://github.com/famedly/matrix-dart-sdk)
- [mautrix-whatsapp](https://github.com/mautrix/whatsapp) for the personal bridge,
  [meowcaller](https://github.com/purpshell/meowcaller) and [Pion](https://github.com/pion/webrtc)
  for WhatsApp calls

Licensed under **AGPL-3.0-or-later**.
