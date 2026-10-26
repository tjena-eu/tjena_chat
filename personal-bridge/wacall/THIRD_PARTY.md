# wacall: third-party code and licences

wacall itself is part of tjena and licensed AGPL-3.0-or-later, like the rest
of the project. It is built from the Go modules below, without changes; the
exact versions are pinned in `go.mod` / `go.sum`. All of these licences allow
use and redistribution inside an AGPL-3.0 program. The permissive ones
(MIT, BSD, ISC, Apache-2.0) need their copyright notice kept, which the
LICENSE files in each module's source provide; ship this file and those
notices with binary builds.

| Module | Licence | What it does here |
|---|---|---|
| github.com/purpshell/meowcaller (commit c48c3e2) | MIT, © 2026 Rajeh Taher | WhatsApp call signalling, media relay, MLow codec, SRTP |
| github.com/polymorfa/hypermeow | MPL-2.0 (fork of tulir/whatsmeow) | WhatsApp multi-device client used by meowcaller |
| github.com/polymorfa/libsignal-protocol-go | GPL-3.0 | Signal protocol (same licence as go.mau.fi/libsignal used by the bridge) |
| go.mau.fi/util | MPL-2.0 | helpers used by hypermeow |
| github.com/pion/webrtc/v4 and pion/* (ice, dtls, srtp, sctp, rtp, rtcp, sdp, stun, turn, transport, interceptor, mdns, datachannel, logging, randutil, opus) | MIT | WebRTC to the tjena app |
| github.com/gotranspile/g722 | BSD / public domain (Goncharov, Underwood, CMU; see its README) | G.722 audio codec |
| github.com/wlynxg/anet | BSD-3-Clause | network interfaces on Android |
| github.com/coder/websocket | ISC | websocket to the gateway |
| github.com/mattn/go-sqlite3 (includes SQLite, public domain) | MIT | device store |
| github.com/rs/zerolog, mattn/go-colorable, mattn/go-isatty | MIT | logging |
| github.com/hajimehoshi/go-mp3, github.com/petermattis/goid | Apache-2.0 | dependencies of meowcaller / hypermeow |
| filippo.io/edwards25519, github.com/google/uuid, golang.org/x/*, google.golang.org/protobuf | BSD-3-Clause | crypto, ids, protobuf |

The G.711 µ-law codec and the resampler in `audio.go` are our own code.

## Notes

- MPL-2.0 and GPL-3.0 parts are used unmodified. If you ever patch them, the
  patched source files must be published under their own licence (MPL: per
  file; GPL: as part of the whole program, which AGPL already requires).
- meowcaller is an independent, unofficial implementation of WhatsApp's call
  protocol (see its DISCLAIMER.md). The licences above cover the code; they
  say nothing about WhatsApp's terms of service, which apply to any
  unofficial client, including the bridge itself.
