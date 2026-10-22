import 'dart:async';

import 'package:flutter/material.dart';

import 'native.dart';
import 'screens/backup_screen.dart';
import 'screens/permissions_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/status_screen.dart';
import 'screens/whatsapp_screen.dart';

void main() => runApp(const BridgeApp());

const tjenaBlue = Color(0xFF295D9F);

class BridgeApp extends StatelessWidget {
  const BridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'tjena Bridge',
      theme: ThemeData(colorSchemeSeed: tjenaBlue, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: tjenaBlue, brightness: Brightness.dark, useMaterial3: true),
      home: const Root(),
    );
  }
}

/// Shows setup until the bridge is configured, then the main tabs.
class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  BridgeState? _state;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      final s = await Native.state();
      if (mounted) setState(() => _state = s);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    if (s == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!s.setUp) return SetupScreen(onDone: refresh);
    return HomeShell(state: s, refresh: refresh);
  }
}

class HomeShell extends StatefulWidget {
  final BridgeState state;
  final Future<void> Function() refresh;
  const HomeShell({required this.state, required this.refresh, super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      StatusScreen(state: widget.state, refresh: widget.refresh),
      WhatsAppScreen(state: widget.state),
      PermissionsScreen(state: widget.state, refresh: widget.refresh),
      SettingsScreen(state: widget.state, refresh: widget.refresh),
      BackupScreen(state: widget.state, refresh: widget.refresh),
    ];
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: _tab, children: pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.monitor_heart_outlined), label: 'Status'),
          NavigationDestination(icon: Icon(Icons.chat_outlined), label: 'WhatsApp'),
          NavigationDestination(icon: Icon(Icons.group_outlined), label: 'Access'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
          NavigationDestination(icon: Icon(Icons.save_outlined), label: 'Backup'),
        ],
      ),
    );
  }
}
