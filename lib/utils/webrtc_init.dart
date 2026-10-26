// SPDX-FileCopyrightText: 2026 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/utils/platform_infos.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:matrix/matrix.dart';

/// Sets up WebRTC before any call uses it (all call types share one factory).
///
/// Android: encode VP8 (and VP9, flutter_webrtc's default) in software. The
/// Exynos/Tensor hardware VP8 encoder (e.g. Pixel 9a, Samsung) sends broken,
/// green video to other clients, especially with LiveKit simulcast. H.264
/// (used for WhatsApp video) keeps the hardware encoder.
///
/// Must run before the first WebRTC call; later calls to
/// `WebRTC.initialize` (e.g. from LiveKit) are then no-ops.
Future<void> initWebRtc() async {
  if (!PlatformInfos.isAndroid) return;
  try {
    await WebRTC.initialize(
      options: {
        'forceSWCodecList': ['VP8', 'VP9'],
      },
    );
  } catch (e, s) {
    Logs().w('WebRTC init failed', e, s);
  }
}
