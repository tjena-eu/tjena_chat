// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ui';

abstract class AppConfig {
  static const Color primaryColor = Color(0xFF295d9f);

  static const Color chatColor = primaryColor;
  static const double messageFontSize = 16.0;
  static const bool allowOtherHomeservers = true;
  static const bool enableRegistration = true;
  static const bool hideTypingUsernames = false;

  static const String inviteLinkPrefix = 'https://matrix.to/#/';
  static const String deepLinkPrefix = 'tjena.tjenachat://chat/';
  static const String schemePrefix = 'matrix:';
  static const String pushNotificationsChannelId = 'tjena_push';
  static const String pushNotificationsAppId = 'tjena.tjenachat';
  static const double borderRadius = 18.0;
  static const double spaceBorderRadius = 11.0;
  static const double columnWidth = 360.0;

  static const String enablePushTutorial =
      'https://ko-fi.com/post/How-can-I-get-Push-Notifications-without-Google-N7Q825URG6?fromEditor=true';
  static const String encryptionTutorial =
      'https://ko-fi.com/post/How-to-use-end-to-end-encryption-in-FluffyChat-A5O725WDR5';
  static const String howDoIGetStickersTutorial =
      'https://ko-fi.com/post/How-to-add-a-sticker-pack-to-FluffyChat-N4N01OXATI';
  static const String appId = 'tjena.tjenachat';
  static const String appOpenUrlScheme = 'tjena.tjenachat';
  static const String appSsoUrlScheme = 'tjena.tjenachat.auth';
  // Identifies the notification activation callback on Windows. Never change!
  static const String windowsNotificationGuid =
      '4894dfda-c70a-4ebc-b139-acae55f3988d';

  static const String sourceCodeUrl = 'https://github.com/tjena-eu/tjena_chat';
  static const String supportUrl =
      'https://github.com/tjena-eu/tjena_chat/issues';
  static const String changelogUrl = 'https://tjena.eu/news/';
  static const String latestReleaseApiUrl =
      'https://api.github.com/repos/tjena-eu/tjena_chat/releases/latest';
  static const String helpUrl =
      'https://tjena.eu/support';

  static const Set<String> defaultReactions = {'👍', '❤️', '😂', '😮', '😢'};

  static final Uri newIssueUrl = Uri(
    scheme: 'https',
    host: 'github.com',
    path: '/tjena-eu/tjena_chat/issues/new',
  );

  static final Uri homeserverList = Uri(
    scheme: 'https',
    host: 'raw.githubusercontent.com',
    path: 'tjena-eu/tjena_chat/refs/heads/main/recommended_homeservers.json',
  );

  static final Uri crashReportEndpoint = Uri(
    scheme: 'https',
    host: 'crash.fluffy.chat',
  );

  static const String mainIsolatePortName = 'main_isolate';
  static const String pushIsolatePortName = 'push_isolate';
  static const String pushHelperCrashReportKey = 'push_helper_crash_report';

  static const String vodozemacVersion = '0.8.1';
}
