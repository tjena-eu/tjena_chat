#!/usr/bin/env python3
"""Patch the matrix-dart-sdk so 1:1 call remote video renders on Android.

Root cause (confirmed via logcat): on Android, libwebrtc returns remote
MediaStream ids wrapped in curly braces ("{uuid}"), while the peer's
sdp_stream_metadata is keyed by the bare uuid. The SDK's `_addRemoteStream`
looks up metadata by the braced id, misses, and drops the remote stream — so
`remoteUserMediaStream` stays null and no video is shown. Audio is unaffected
because it is wired at the native track level, independent of this lookup.

This patch makes the lookup tolerant of the braces and, if metadata is still
missing, assumes a usermedia stream instead of dropping it (same behaviour as
matrix-js-sdk).

The script is idempotent and re-appliable: it replaces the region between the
method signature and the `final videoMuted` line regardless of whether the file
is pristine or already carries an older version of this patch. `build_android`
runs it before each build so the fix survives `flutter pub get` regenerating
pub-cache.
"""
import sys

# Bump when REPLACEMENT changes so an already-patched SDK gets re-patched.
PATCH_VERSION = "v6"

# A log line inserted right after the onTrack handler opens, to confirm whether
# onTrack fires and whether event.streams is populated.
ONTRACK_ANCHOR = "    pc.onTrack = (RTCTrackEvent event) async {\n"
ONTRACK_LOG = (
    "      Logs().i('[VOIP] onTrack FIRE streams=' + event.streams.length.toString()"
    " + ' kind=' + event.track.kind.toString() + ' trackId=' + event.track.id.toString());\n"
)
VERSION_TAG = f"// tjena-patch-version: {PATCH_VERSION}"

# Anchors bounding the region we own (pristine or previously patched). We
# replace from the method signature up to and including the `final videoMuted`
# line.
START_ANCHOR = "  Future<void> _addRemoteStream(MediaStream stream) async {"
END_ANCHOR = "    final videoMuted = metadata.video_muted;"

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
    Logs().i(
      '[VOIP] _addRemoteStream ENTER id=$rawId '
      'video=${stream.getVideoTracks().length} '
      'audio=${stream.getAudioTracks().length} '
      'metaKeys=${_remoteSDPStreamMetadata?.sdpStreamMetadatas.keys.toList()}',
    );
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

    if VERSION_TAG in content:
        print(f"  matrix VoIP patch {PATCH_VERSION} already applied, skipping")
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

    # Insert onTrack diagnostic log right after the handler opens.
    if ONTRACK_LOG not in content:
        idx = content.find(ONTRACK_ANCHOR)
        if idx != -1:
            insert_at = idx + len(ONTRACK_ANCHOR)
            content = content[:insert_at] + ONTRACK_LOG + content[insert_at:]
        else:
            print("  WARNING: onTrack anchor not found; skipping onTrack log")

    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"  applied matrix VoIP remote-stream metadata patch {PATCH_VERSION}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
