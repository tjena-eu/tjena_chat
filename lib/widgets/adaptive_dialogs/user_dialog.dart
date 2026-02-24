import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/date_time_extension.dart';
import 'package:fluffychat/utils/fluffy_share.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/presence_builder.dart';
import '../../utils/url_launcher.dart';
import '../future_loading_dialog.dart';
import '../hover_builder.dart';
import '../matrix.dart';
import '../mxc_image_viewer.dart';

class UserDialog extends StatelessWidget {
  static Future<void> show({
    required BuildContext context,
    required Profile profile,
    bool noProfileWarning = false,
  }) => showAdaptiveDialog(
    context: context,
    barrierDismissible: true,
    builder: (context) =>
        UserDialog(profile, noProfileWarning: noProfileWarning),
  );

  final Profile profile;
  final bool noProfileWarning;

  const UserDialog(this.profile, {this.noProfileWarning = false, super.key});

  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).client;
    final displayname =
        profile.displayName ??
        profile.userId.localpart ??
        L10n.of(context).user;
    var copied = false;
    final theme = Theme.of(context);
    final avatar = profile.avatarUrl;
    return AlertDialog.adaptive(
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 256),
        child: PresenceBuilder(
          userId: profile.userId,
          client: Matrix.of(context).client,
          builder: (context, presence) {
            if (presence == null) return const SizedBox.shrink();
            final statusMsg = presence.statusMsg;
            final lastActiveTimestamp = presence.lastActiveTimestamp;
            final presenceText = presence.currentlyActive == true
                ? L10n.of(context).currentlyActive
                : lastActiveTimestamp != null
                ? L10n.of(context).lastActiveAgo(
                    lastActiveTimestamp.localizedTimeShort(context),
                  )
                : null;
            return Column(
              spacing: 16,
              mainAxisSize: .min,
              crossAxisAlignment: .stretch,
              children: [
                Row(
                  spacing: 12,
                  children: [
                    Avatar(
                      mxContent: avatar,
                      name: displayname,
                      size: Avatar.defaultSize * 1.5,
                      onTap: avatar != null
                          ? () => showDialog(
                              context: context,
                              builder: (_) => MxcImageViewer(avatar),
                            )
                          : null,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: .start,
                        children: [
                          Text(
                            displayname,
                            maxLines: 1,
                            overflow: .ellipsis,
                            style: TextStyle(fontSize: 16),
                          ),
                          const SizedBox(height: 8),
                          HoverBuilder(
                            builder: (context, hovered) => StatefulBuilder(
                              builder: (context, setState) => MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: GestureDetector(
                                  onTap: () {
                                    Clipboard.setData(
                                      ClipboardData(text: profile.userId),
                                    );
                                    setState(() {
                                      copied = true;
                                    });
                                  },
                                  child: RichText(
                                    text: TextSpan(
                                      children: [
                                        WidgetSpan(
                                          child: Padding(
                                            padding: const EdgeInsets.only(
                                              right: 4.0,
                                            ),
                                            child: AnimatedScale(
                                              duration: FluffyThemes
                                                  .animationDuration,
                                              curve:
                                                  FluffyThemes.animationCurve,
                                              scale: hovered
                                                  ? 1.33
                                                  : copied
                                                  ? 1.25
                                                  : 1.0,
                                              child: Icon(
                                                copied
                                                    ? Icons.check_circle
                                                    : Icons.copy,
                                                size: 12,
                                                color: copied
                                                    ? Colors.green
                                                    : null,
                                              ),
                                            ),
                                          ),
                                        ),
                                        TextSpan(text: profile.userId),
                                      ],
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(fontSize: 10),
                                    ),
                                    maxLines: 1,
                                    overflow: .ellipsis,
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (presenceText != null)
                            Text(
                              presenceText,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontSize: 10,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),

                if (statusMsg != null)
                  SelectableLinkify(
                    text: statusMsg,
                    textScaleFactor: MediaQuery.textScalerOf(context).scale(1),
                    textAlign: TextAlign.start,
                    options: const LinkifyOptions(humanize: false),
                    linkStyle: TextStyle(
                      color: theme.colorScheme.primary,
                      decoration: TextDecoration.underline,
                      decorationColor: theme.colorScheme.primary,
                    ),
                    onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
                  ),
                Row(
                  mainAxisAlignment: .spaceBetween,
                  spacing: 4,
                  children: [
                    _IconTextButton(
                      label: L10n.of(context).chat,
                      icon: Icons.chat_outlined,
                      onTap: () async {
                        final router = GoRouter.of(context);
                        final roomIdResult = await showFutureLoadingDialog(
                          context: context,
                          future: () => client.startDirectChat(profile.userId),
                        );
                        final roomId = roomIdResult.result;
                        if (roomId == null) return;
                        if (context.mounted) Navigator.of(context).pop();
                        router.go('/rooms/$roomId');
                      },
                    ),
                    _IconTextButton(
                      label: L10n.of(context).block,
                      icon: Icons.block_outlined,
                      onTap: () {
                        final router = GoRouter.of(context);
                        Navigator.of(context).pop();
                        router.go(
                          '/rooms/settings/security/ignorelist',
                          extra: profile.userId,
                        );
                      },
                    ),
                    _IconTextButton(
                      label: L10n.of(context).share,
                      icon: Icons.adaptive.share,
                      onTap: () => FluffyShare.share(profile.userId, context),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _IconTextButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _IconTextButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: CupertinoButton(
        onPressed: onTap,
        borderRadius: BorderRadius.circular(AppConfig.borderRadius / 2),
        color: theme.colorScheme.surfaceBright,
        padding: EdgeInsets.all(8),
        child: Column(
          mainAxisSize: .min,
          children: [
            Icon(icon),
            Text(
              label,
              style: TextStyle(fontSize: 12),
              maxLines: 1,
              overflow: .ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
