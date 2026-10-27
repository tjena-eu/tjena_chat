// SPDX-FileCopyrightText: 2024 Tjena Contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/media_auto_download.dart';
import 'package:fluffychat/utils/platform_infos.dart';

/// Settings ▸ Chat: which media downloads by itself on Wi-Fi, on mobile data
/// and under Android's Data Saver. Saving to the gallery is the separate
/// auto-save switch below it.
class MediaAutoDownloadSettings extends StatelessWidget {
  const MediaAutoDownloadSettings({super.key});

  static String _networkTitle(MediaNetwork n) => switch (n) {
    MediaNetwork.wifi => 'On Wi-Fi',
    MediaNetwork.mobile => 'On mobile data',
    MediaNetwork.dataSaver => 'With Data Saver on',
  };

  static IconData _networkIcon(MediaNetwork n) => switch (n) {
    MediaNetwork.wifi => Icons.wifi,
    MediaNetwork.mobile => Icons.signal_cellular_alt,
    MediaNetwork.dataSaver => Icons.data_saver_on_outlined,
  };

  static String _summary(MediaNetwork n) {
    final photos = MediaAutoDownload.settingFor(n, video: false).value;
    final videos = MediaAutoDownload.settingFor(n, video: true).value;
    if (photos && videos) return 'Photos and videos';
    if (photos) return 'Photos';
    if (videos) return 'Videos';
    return 'Nothing (tap to load)';
  }

  Future<void> _edit(BuildContext context, MediaNetwork n) async {
    var photos = MediaAutoDownload.settingFor(n, video: false).value;
    var videos = MediaAutoDownload.settingFor(n, video: true).value;
    final ok = await showAdaptiveDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(_networkTitle(n)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CheckboxListTile(
                value: photos,
                title: const Text('Photos'),
                onChanged: (v) => setState(() => photos = v ?? false),
              ),
              CheckboxListTile(
                value: videos,
                title: const Text('Videos'),
                onChanged: (v) => setState(() => videos = v ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await MediaAutoDownload.setSetting(n, video: false, value: photos);
    await MediaAutoDownload.setSetting(n, video: true, value: videos);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Only Android tells us the network type and Data Saver state.
    final networks = PlatformInfos.isAndroid
        ? MediaNetwork.values
        : const [MediaNetwork.wifi];
    return ValueListenableBuilder<int>(
      valueListenable: MediaAutoDownload.revision,
      builder: (context, _, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            title: Text(
              'Auto-download media',
              style: TextStyle(
                color: theme.colorScheme.secondary,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: PlatformInfos.isAndroid
                ? Text(
                    'Now: ${_networkTitle(MediaAutoDownload.network).toLowerCase()}'
                    '${MediaAutoDownload.dataSaverActive ? ' (Android limits tjena on mobile data: Data Saver, or Background data turned off for tjena)' : ''}. '
                    'Anything not downloaded waits for a tap. '
                    'Each chat can override this in its details.',
                  )
                : null,
          ),
          for (final n in networks)
            ListTile(
              leading: Icon(_networkIcon(n)),
              title: Text(
                PlatformInfos.isAndroid
                    ? _networkTitle(n)
                    : 'Download automatically',
              ),
              subtitle: Text(_summary(n)),
              trailing:
                  n == MediaAutoDownload.network && PlatformInfos.isAndroid
                  ? Icon(
                      Icons.check_circle,
                      color: theme.colorScheme.primary,
                      size: 18,
                    )
                  : null,
              onTap: () => _edit(context, n),
            ),
        ],
      ),
    );
  }
}
