import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../state/hosts_state.dart';
import '../ui/remote/remote_screen.dart';
import '../ui/web/mode_home.dart';
import 'home.dart';

/// Separate protocol owners and navigators: switching never reuses a DSH
/// session identifier or credential for an OpenClaw Gateway.
class BackendHome extends StatefulWidget {
  const BackendHome({super.key, required this.onLanguage});
  final VoidCallback onLanguage;
  @override
  State<BackendHome> createState() => _BackendHomeState();
}

class _BackendHomeState extends State<BackendHome> {
  int selected = 0;
  bool openedDsh = false;
  int selectionVersion = 0;
  final dshNavigator = GlobalKey<NavigatorState>();
  @override
  void initState() {
    super.initState();
    restore();
  }

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final backend = prefs.getString('remote.backend');
    if (!mounted || selectionVersion != 0 || backend != 'dsh') return;
    setState(() {
      selected = 1;
      openedDsh = true;
    });
  }

  Future<void> select(int index) async {
    selectionVersion++;
    setState(() {
      selected = index;
      openedDsh |= index == 1;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('remote.backend', index == 1 ? 'dsh' : 'openclaw');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: selected,
      children: [
        ClawHome(onLanguage: widget.onLanguage),
        if (openedDsh)
          Navigator(
            key: dshNavigator,
            onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const DshRemoteHome()),
          )
        else
          const SizedBox.shrink(),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: selected,
      onDestinationSelected: select,
      destinations: const [
        NavigationDestination(icon: Icon(Icons.hub_outlined), label: 'OpenClaw'),
        NavigationDestination(icon: Icon(Icons.devices_outlined), label: 'DSH Remote'),
      ],
    ),
  );
}

/// The original DSH Remote account, trust, P2P/TURN/relay and SSH stack is
/// retained intact. There is no Android runtime installation/auto-start here.
class DshRemoteHome extends ConsumerWidget {
  const DshRemoteHome({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(activeHostProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('DSH Remote'),
        actions: [
          IconButton(
            tooltip: context.l10n.commonRemoteHost,
            icon: const Icon(Icons.dns_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RemoteScreen())),
          ),
        ],
      ),
      body: host.isLocal ? const RemoteScreen() : const ModeHome(),
    );
  }
}
