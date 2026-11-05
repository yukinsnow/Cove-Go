import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../state/hosts_state.dart';
import '../ui/remote/remote_screen.dart';
import '../ui/web/mode_home.dart';
import '../ui/remote/host_switcher.dart';
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
  final clawKey = GlobalKey<ClawHomeState>();
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
    FocusManager.instance.primaryFocus?.unfocus();
    selectionVersion++;
    setState(() {
      selected = index;
      openedDsh |= index == 1;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('remote.backend', index == 1 ? 'dsh' : 'openclaw');
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        gatewayHostEntryProvider.overrideWithValue(
          GatewayHostEntry(
            name: () => clawKey.currentState?.hostName ?? context.l10n.commonRemoteHost,
            active: selected == 0,
            onPick: () => select(0),
            onRemotePick: () => select(1),
            onConfigure: () {
              select(0);
              clawKey.currentState?.settings();
            },
          ),
        ),
      ],
      child: IndexedStack(
        index: selected,
        children: [
          ClawHome(key: clawKey, onLanguage: widget.onLanguage),
          if (openedDsh)
            Navigator(
              key: dshNavigator,
              onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const DshRemoteHome()),
            )
          else
            const SizedBox.shrink(),
        ],
      ),
    );
  }
}

/// The original DSH Remote account, trust, P2P/TURN/relay and SSH stack is
/// retained intact. There is no Android runtime installation/auto-start here.
class DshRemoteHome extends ConsumerWidget {
  const DshRemoteHome({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(activeHostProvider);
    // ModeHome already owns its chat header and session drawer.
    if (!host.isLocal) return const ModeHome();
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.commonRemoteHost),
        actions: [
          IconButton(
            icon: const Icon(Icons.dns_outlined),
            tooltip: context.l10n.remoteSwitchHost,
            onPressed: () => showHostSheet(
              context,
              onManage: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RemoteScreen())),
            ),
          ),
        ],
      ),
      body: const RemoteScreen(),
    );
  }
}
