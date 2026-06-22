// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:isolate';
import 'dart:ui';

import 'package:collection/collection.dart';
import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/utils/client_manager.dart';
import 'package:fluffychat/utils/notification_background_handler.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tjena_bridge/bridge_room_store.dart' as tjena_bridge show BridgeRoomStore;
import 'package:tjena_bridge/tjena_bridge.dart' as tjena_bridge show TjenaBridge;

import 'utils/matrix_sdk_extensions/event_extension.dart';
import 'utils/wa_matrix_bridge.dart';
import 'utils/signal_matrix_bridge.dart';
import 'package:universal_html/universal_html.dart' as web;

import 'config/setting_keys.dart';
import 'utils/background_push.dart';
import 'widgets/fluffy_chat_app.dart';

ReceivePort? mainIsolateReceivePort;

bool _vodozemacInitialized = false;

bool isIntegrationTest = false;

void main(List<String> args) async {
  // Capture all uncaught exceptions so they appear in bridge logs rather than
  // silently crashing — helps diagnose startup crashes without ADB.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    Logs().e('[CRASH Flutter]', details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    Logs().e('[CRASH Uncaught]', error, stack);
    return true; // handled — keeps app alive for log inspection
  };

  isIntegrationTest = args.singleOrNull == 'integration_test';
  if (PlatformInfos.isAndroid) {
    final port = mainIsolateReceivePort = ReceivePort();
    IsolateNameServer.removePortNameMapping(AppConfig.mainIsolatePortName);
    IsolateNameServer.registerPortWithName(
      port.sendPort,
      AppConfig.mainIsolatePortName,
    );
    await waitForPushIsolateDone();
  }

  // Sanitize hash for OIDC:
  if (kIsWeb) {
    final hash = web.window.location.hash;
    if (hash.isNotEmpty && !hash.startsWith('/')) {
      web.window.location.hash = hash.replaceFirst('#', '#?');
    }
  }

  // Our background push shared isolate accesses flutter-internal things very early in the startup proccess
  // To make sure that the parts of flutter needed are started up already, we need to ensure that the
  // widget bindings are initialized already.
  WidgetsFlutterBinding.ensureInitialized();

  final store = await AppSettings.init();
  Logs().i('Welcome to ${AppSettings.applicationName.value} <3');

  if (!_vodozemacInitialized) {
    await vod.init(wasmPath: './assets/assets/vodozemac/');
    _vodozemacInitialized = true;
  }

  Logs().nativeColors = !PlatformInfos.isIOS;
  final clients = await ClientManager.getClients(store: store);

  // If the app starts in detached mode, we assume that it is in
  // background fetch mode for processing push notifications. This is
  // currently only supported on Android.
  if (PlatformInfos.isAndroid &&
      AppLifecycleState.detached == WidgetsBinding.instance.lifecycleState) {
    // Do not send online presences when app is in background fetch mode.
    for (final client in clients) {
      client.backgroundSync = false;
      client.syncPresence = PresenceType.offline;
    }

    // In the background fetch mode we do not want to waste ressources with
    // starting the Flutter engine but process incoming push notifications.
    BackgroundPush.clientOnly(clients);
    // To start the flutter engine afterwards we add an custom observer.
    WidgetsBinding.instance.addObserver(AppStarter(clients, store));
    Logs().i(
      '${AppSettings.applicationName.value} started in background-fetch mode. No GUI will be created unless the app is no longer detached.',
    );
    return;
  }

  // Started in foreground mode.
  Logs().i(
    '${AppSettings.applicationName.value} started in foreground mode. Rendering GUI...',
  );
  await startGui(clients, store);
}

/// Fetch the pincode for the applock and start the flutter engine.
Future<void> startGui(List<Client> clients, SharedPreferences store) async {
  // Fetch the pin for the applock if existing for mobile applications.
  String? pin;
  if (PlatformInfos.isMobile) {
    try {
      pin = await const FlutterSecureStorage().read(
        key: 'chat.fluffy.app_lock',
      );
    } catch (e, s) {
      Logs().d('Unable to read PIN from Secure storage', e, s);
    }
  }

  // Preload first client
  final firstClient = clients.firstOrNull;
  await firstClient?.roomsLoading;
  await firstClient?.accountDataLoading;

  // Start on-device bridges (non-blocking; errors are non-fatal).
  if (PlatformInfos.isAndroid) {
    if (firstClient != null) {
      await WaMatrixBridge.instance.init(firstClient);
      SignalMatrixBridge.instance.init(firstClient);
      _subscribeAutoSave(firstClient);
    }
    _startBridge(store);
  }

  runApp(FluffyChatApp(clients: clients, pincode: pin, store: store));
}

void _subscribeAutoSave(Client client) {
  // Auto-save incoming images/videos to gallery for regular Matrix rooms.
  // Bridge rooms (WA/Signal) handle auto-save in their own media-ready path.
  client.onTimelineEvent.stream.listen((event) {
    try {
      if (event.messageType != MessageTypes.Image &&
          event.messageType != MessageTypes.Video) {
        return;
      }
      final roomId = event.roomId ?? '';
      if (WaMatrixBridge.instance.isWaRoom(roomId) ||
          SignalMatrixBridge.instance.isSigRoom(roomId)) {
        return; // bridge rooms auto-save in their media-ready handler
      }
      event.autoSaveBackground();
    } catch (_) {}
  });
}

void _startBridge(SharedPreferences store) {
  try {
    tjena_bridge.BridgeRoomStore.instance.startListening();
    tjena_bridge.TjenaBridge.instance
        .start()
        .catchError((Object e) { Logs().w('[Bridge] start failed: $e'); });
  } catch (e) {
    Logs().w('[Bridge] init failed: $e');
  }
}

/// Watches the lifecycle changes to start the application when it
/// is no longer detached.
class AppStarter with WidgetsBindingObserver {
  final List<Client> clients;
  final SharedPreferences store;
  bool guiStarted = false;

  AppStarter(this.clients, this.store);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (guiStarted) return;
    if (state == AppLifecycleState.detached) return;

    Logs().i(
      '${AppSettings.applicationName.value} switches from the detached background-fetch mode to ${state.name} mode. Rendering GUI...',
    );
    // Switching to foreground mode needs to reenable send online sync presence.
    for (final client in clients) {
      client.backgroundSync = true;
      client.syncPresence = PresenceType.online;
    }
    startGui(clients, store);
    // We must make sure that the GUI is only started once.
    guiStarted = true;
  }
}
