// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/intro/flows/restore_backup_flow.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/layouts/login_scaffold.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';

class IntroPage extends StatelessWidget {
  final bool isLoading, hasPresetHomeserver;
  final String? loggingInToHomeserver, welcomeText;
  final VoidCallback login;
  final VoidCallback changeServer;

  const IntroPage({
    required this.isLoading,
    required this.loggingInToHomeserver,
    super.key,
    required this.hasPresetHomeserver,
    required this.welcomeText,
    required this.login,
    required this.changeServer,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final addMultiAccount = Matrix.of(
      context,
    ).widget.clients.any((client) => client.isLogged());
    final loggingInToHomeserver = this.loggingInToHomeserver;

    return LoginScaffold(
      appBar: AppBar(
        centerTitle: true,
        title: addMultiAccount ? Text(L10n.of(context).addAccount) : null,
        actions: [
          PopupMenuButton(
            useRootNavigator: true,
            itemBuilder: (_) => [
              PopupMenuItem(
                onTap: isLoading ? null : () => restoreBackupFlow(context),
                child: Row(
                  mainAxisSize: .min,
                  children: [
                    const Icon(Icons.import_export_outlined),
                    const SizedBox(width: 12),
                    Text(L10n.of(context).hydrate),
                  ],
                ),
              ),
              PopupMenuItem(
                onTap: () => launchUrlString(AppSettings.privacyPolicy.value),
                child: Row(
                  mainAxisSize: .min,
                  children: [
                    const Icon(Icons.privacy_tip_outlined),
                    const SizedBox(width: 12),
                    Text(L10n.of(context).privacy),
                  ],
                ),
              ),
              PopupMenuItem(
                onTap: () => PlatformInfos.showDialog(context),
                child: Row(
                  mainAxisSize: .min,
                  children: [
                    const Icon(Icons.info_outlined),
                    const SizedBox(width: 12),
                    Text(L10n.of(context).about),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: isLoading
          ? Center(
              child: Column(
                mainAxisAlignment: .center,
                children: [
                  CircularProgressIndicator.adaptive(),
                  if (loggingInToHomeserver != null)
                    Text(L10n.of(context).logInTo(loggingInToHomeserver)),
                ],
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: IntrinsicHeight(
                      child: Column(
                        children: [
                          Container(
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8.0,
                            ),
                            child: Hero(
                              tag: 'info-logo',
                              child: Image.asset(
                                './assets/logo/mini/logo_favicon_mini.png',
                                width: 156,
                                height: 156,
                              ),
                            ),
                          ),
                          Center(
                            child: Text(
                              'tjena!chat',
                              style: theme.textTheme.headlineMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            L10n.of(context).appSubtitle,
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 18),
                          ),
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Text(
                              L10n.of(context).appDescription,
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          const Spacer(),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Column(
                              mainAxisSize: .min,
                              crossAxisAlignment: .stretch,
                              children: [
                                if (!hasPresetHomeserver)
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor:
                                          theme.colorScheme.secondary,
                                      foregroundColor:
                                          theme.colorScheme.onSecondary,
                                    ),
                                    onPressed: () => launchUrl(
                                      Uri.parse('https://tjena.eu/register'),
                                      mode: LaunchMode.inAppBrowserView,
                                    ),
                                    child: Text(
                                      L10n.of(context).createNewAccount,
                                    ),
                                  ),
                                SizedBox(height: 16),
                                ElevatedButton(
                                  onPressed: login,
                                  child: Text(L10n.of(context).signIn),
                                ),
                                TextButton(
                                  onPressed: changeServer,
                                  child: const Text(
                                    'Change server / use another Matrix server',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 36),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
