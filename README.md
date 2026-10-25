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
  Bridge app on a phone at home (`personal-bridge/`).
- **📞 WhatsApp calls** — call WhatsApp contacts from tjena!chat and answer their calls,
  through the personal bridge (1:1 voice, one calls device per WhatsApp account; see
  `personal-bridge/wacall/`).
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
| `personal-bridge/` | Personal WhatsApp bridge: gateway (server), relay, calls daemon and the Bridge app |
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

tjena!chat patches the Matrix Dart SDK (in the pub-cache git checkout) so VoIP video
renders correctly. **A fresh `flutter pub get` re-clones the SDK and drops the patch**, so
re-apply it before building: run `patches/voip_remote_stream_fix.py` on the SDK's
`call_session.dart` (the script resolves the pub-cache path from
`.dart_tool/package_config.json`).

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
- **WhatsApp calls are 1:1 voice** and need the personal bridge with calls set up in the
  Bridge app (`docs/personal-bridge/`).
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
