// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/utils/live_location/live_location_manager.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/adaptive_dialog_action.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:matrix/matrix.dart';

/// Lets the user pick how long to share their live location and starts the
/// share (after ensuring location permission, including background access).
class SendLiveLocationDialog extends StatefulWidget {
  final Room room;

  const SendLiveLocationDialog({required this.room, super.key});

  @override
  State<SendLiveLocationDialog> createState() => _SendLiveLocationDialogState();
}

class _SendLiveLocationDialogState extends State<SendLiveLocationDialog> {
  static const _durations = <String, Duration>{
    '15 minutes': Duration(minutes: 15),
    '1 hour': Duration(hours: 1),
    '8 hours': Duration(hours: 8),
  };

  Duration _selected = const Duration(hours: 1);
  String? _error;

  Future<bool> _ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() => _error = 'Location services are disabled on this device.');
      return false;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      setState(() => _error = 'Location permission was denied.');
      return false;
    }
    // whileInUse is enough to start; background continuation needs "Allow all
    // the time", which the OS grants via a second prompt / app settings.
    if (permission == LocationPermission.whileInUse) {
      // Trigger the background-permission prompt where supported. If the user
      // doesn't grant it, foreground sharing still works.
      await Geolocator.requestPermission();
    }
    return true;
  }

  Future<void> _start() async {
    if (!await _ensurePermission()) return;
    if (!mounted) return;
    await showFutureLoadingDialog(
      context: context,
      future: () => LiveLocationManager.instance.startSharing(
        widget.room,
        duration: _selected,
      ),
    );
    if (!mounted) return;
    Navigator.of(context, rootNavigator: false).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog.adaptive(
      title: const Text('Share live location'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Your location will be shared and updated for:'),
          const SizedBox(height: 8),
          ..._durations.entries.map(
            (e) => RadioListTile<Duration>(
              contentPadding: EdgeInsets.zero,
              title: Text(e.key),
              value: e.value,
              groupValue: _selected,
              onChanged: (v) => setState(() => _selected = v!),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        AdaptiveDialogAction(
          onPressed: () => Navigator.of(context, rootNavigator: false).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        AdaptiveDialogAction(
          onPressed: _start,
          child: const Text('Start'),
        ),
      ],
    );
  }
}
