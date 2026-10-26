#!/usr/bin/env python3
"""Patch the matrix-dart-sdk so 1:1 call remote video renders on Android.

Root cause (confirmed via logcat): on Android, libwebrtc returns remote
MediaStream ids wrapped in curly braces ("{uuid}"), while the peer's
sdp_stream_metadata is keyed by the bare uuid (and is sometimes absent
entirely). The SDK's `_addRemoteStream` looks up metadata by the braced id,
misses, and drops the remote stream — so `remoteUserMediaStream` stays null and
no video is shown. Audio is unaffected (wired natively).

This patch:
  * makes the metadata lookup brace-tolerant, and
  * falls back to assuming a usermedia stream when metadata is missing (like
    matrix-js-sdk) instead of dropping it, and
  * exposes a public `addReconstructedRemoteStream` so the app can inject a
    remote stream rebuilt from RtpReceiver tracks if flutter_webrtc's onTrack
    ever fails to deliver one.

IMPORTANT: matrix is a *git* dependency (famedly/matrix-dart-sdk), so its source
lives at ~/.pub-cache/git/matrix-dart-sdk-<ref>/, NOT hosted/pub.dev. build_android
resolves the real path from .dart_tool/package_config.json before calling this.

The script is idempotent and re-appliable (anchor-based, version-tagged), so it
survives `flutter pub get`. It also strips diagnostic log lines left by earlier
patch versions.
"""
import sys

# Bump when REPLACEMENT changes so an already-patched SDK gets re-patched.
PATCH_VERSION = "v7"
VERSION_TAG = f"// tjena-patch-version: {PATCH_VERSION}"

# Anchors bounding the region we own (pristine or previously patched). We
# replace from the method signature up to and including the `final videoMuted`
# line.
START_ANCHOR = "  Future<void> _addRemoteStream(MediaStream stream) async {"
END_ANCHOR = "    final videoMuted = metadata.video_muted;"

# Diagnostic line inserted by older patch versions (v5/v6); removed on apply.
STALE_ONTRACK_LOG = (
    "      Logs().i('[VOIP] onTrack FIRE streams=' + event.streams.length.toString()"
    " + ' kind=' + event.track.kind.toString() + ' trackId=' + event.track.id.toString());\n"
)

REPLACEMENT = """  // tjena patch: public entrypoint to inject a remote stream reconstructed
  // from RtpReceiver tracks, used when flutter_webrtc's onTrack never fires
  // (the track is present on the receiver but no MediaStream is delivered).
  Future<void> addReconstructedRemoteStream(MediaStream stream) =>
      _addRemoteStream(stream);

  Future<void> _addRemoteStream(MediaStream stream) async {
    // tjena patch: brace-tolerant remote stream metadata lookup.
    """ + VERSION_TAG + """
    // Android libwebrtc returns remote stream ids as "{uuid}" but
    // sdp_stream_metadata is keyed by the bare uuid. Try both, and if still
    // missing, assume usermedia so the remote video renders.
    final rawId = stream.id;
    final cleanId = rawId?.replaceAll(RegExp(r'[{}]'), '');
    var metadata = _remoteSDPStreamMetadata?.sdpStreamMetadatas[rawId] ??
        _remoteSDPStreamMetadata?.sdpStreamMetadatas[cleanId];
    metadata ??= SDPStreamPurpose(
      purpose: SDPStreamMetadataPurpose.Usermedia,
      audio_muted: stream.getAudioTracks().isEmpty,
      video_muted: stream.getVideoTracks().isEmpty,
    );

    final purpose = metadata.purpose;
    final audioMuted = metadata.audio_muted;
    final videoMuted = metadata.video_muted;"""


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: voip_remote_stream_fix.py <path-to-call_session.dart>")
        return 2
    path = sys.argv[1]
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    # Always strip stale diagnostic lines from earlier patch versions.
    if STALE_ONTRACK_LOG in content:
        content = content.replace(STALE_ONTRACK_LOG, "")

    if VERSION_TAG in content:
        # Still write back in case we stripped stale diagnostics above.
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"  matrix VoIP patch {PATCH_VERSION} already applied")
        return 0

    start = content.find(START_ANCHOR)
    if start == -1:
        print(
            "  ERROR: could not find _addRemoteStream signature to patch.\n"
            "  The matrix SDK version may have changed; update "
            "patches/voip_remote_stream_fix.py."
        )
        return 1
    end = content.find(END_ANCHOR, start)
    if end == -1:
        print(
            "  ERROR: could not find the end anchor of the _addRemoteStream "
            "block; update patches/voip_remote_stream_fix.py."
        )
        return 1
    end += len(END_ANCHOR)

    content = content[:start] + REPLACEMENT + content[end:]
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"  applied matrix VoIP remote-stream metadata patch {PATCH_VERSION}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
