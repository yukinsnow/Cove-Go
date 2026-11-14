import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../state/hosts_state.dart';
import '../ui/remote/remote_screen.dart';
import '../ui/web/mode_home.dart';
import '../ui/remote/host_switcher.dart';
import 'home.dart';
import 'host_catalog.dart';
import 'controller.dart';
import 'notification_host.dart';
import 'notifications.dart';
import '../state/sessions_state.dart';
import '../ui/theme/theme.dart';

/// Separate protocol owners and navigators: switching never reuses a DSH
/// session identifier or credential for an OpenClaw Gateway.
class BackendHome extends ConsumerStatefulWidget {
  const BackendHome({super.key, required this.onLanguage, this.catalog});
  final GatewayHostCatalog? catalog;
  final VoidCallback onLanguage;
  @override
  ConsumerState<BackendHome> createState() => _BackendHomeState();
}

class _BackendHomeState extends ConsumerState<BackendHome> {
  int selected = 0;
  bool openedDsh = false;
  int selectionVersion = 0;
  late final catalog = widget.catalog ?? GatewayHostCatalog();
  final clawKeys = <String, GlobalKey<ClawHomeState>>{};
  final owners = <String, ClawController>{};
  String? catalogError;
  final dshNavigator = GlobalKey<NavigatorState>();
  @override
  void initState() {
    super.initState();
    catalog.addListener(update);
    catalog.load().catchError((Object _) {
      if (mounted) setState(() => catalogError = context.l10n.ocHostLoadFailed);
    });
    restore();
  }

  bool _updateQueued = false;
  void update() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      if (_updateQueued) return;
      _updateQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateQueued = false;
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    catalog.removeListener(update);
    catalog.dispose();
    super.dispose();
  }

  Future<void> addGateway(BuildContext page, {bool ssh = false}) async {
    final c = catalog.add();
    final id = c.profileId!;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !page.mounted) return;
    await clawKeys[id]?.currentState?.settings(from: page, requireSsh: ssh);
    if (!mounted) return;
    if (c.address.isEmpty) {
      await catalog.discardEmpty(id);
    } else {
      await catalog.pick(id);
      await select(0);
    }
  }

  GatewayHostEntry entry(String id) {
    final c = catalog.controllers[id]!;
    final key = clawKeys.putIfAbsent(id, () => GlobalKey<ClawHomeState>());
    return GatewayHostEntry(
      id: id,
      name: () => Uri.tryParse(c.address)?.host ?? context.l10n.commonRemoteHost,
      active: selected == 0 && catalog.selected == id,
      configured: () => c.address.isNotEmpty,
      configureInPlace: (page) async {
        await key.currentState?.settings(from: page);
      },
      openConsole: (page) => key.currentState?.openGatewayWeb(from: page),
      onRemove: () => catalog.remove(id),
      onPick: () {
        catalog.pick(id);
        select(0);
      },
      onRemotePick: () => select(1),
      onConfigure: () {
        catalog.pick(id);
        select(0);
        key.currentState?.settings();
      },
    );
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

  Future<void> openNotice(CoveNotificationTarget target) async {
    if (!mounted || target.host == 'settings') return;
    // Wait for the keychain catalog without inventing/recreating deleted hosts.
    if (!catalog.loaded) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !catalog.loaded) return;
    }
    if (target.backend == 'openclaw') {
      final owner = catalog.controllers[target.host];
      if (owner == null) return;
      Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
      await catalog.pick(target.host);
      if (!mounted) return;
      await select(0);
      if (target.session.isNotEmpty) await owner.guard(() => owner.select(target.session));
    } else {
      final host = HostRef.decode(target.host);
      final container = ProviderScope.containerOf(context, listen: false);
      await container.read(hostsProvider.notifier).ready;
      if (!mounted ||
          host.isLocal ||
          (host.kind == HostKind.ssh && container.read(hostsProvider).sshById(host.id) == null)) {
        return;
      }
      Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
      dshNavigator.currentState?.popUntil((route) => route.isFirst);
      container.read(activeHostProvider.notifier).select(host);
      container.read(currentSessionProvider.notifier).select(target.session);
      await select(1);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!catalog.loaded) {
      return AppBackdrop(
        child: Center(child: catalogError == null ? const CircularProgressIndicator() : Text(catalogError!)),
      );
    }
    clawKeys.removeWhere((id, _) => !catalog.controllers.containsKey(id));
    owners.removeWhere((id, _) => !catalog.controllers.containsKey(id));
    for (final id in catalog.controllers.keys) {
      if (!identical(owners[id], catalog.controllers[id])) {
        owners[id] = catalog.controllers[id]!;
        clawKeys[id] = GlobalKey<ClawHomeState>();
      }
    }
    final ids = catalog.controllers.keys.toList();
    final directory = GatewayHostEntry(
      name: () => entry(catalog.selected).name(),
      active: selected == 0,
      configured: () => catalog.controllers.values.any((c) => c.address.isNotEmpty),
      profiles: () => [
        for (final id in catalog.controllers.keys)
          if (catalog.controllers[id]!.address.isNotEmpty) entry(id),
      ],
      changes: catalog,
      addHost: (page) => addGateway(page),
      addSshHost: (page) => addGateway(page, ssh: true),
      onPick: () => select(0),
      onRemotePick: () => select(1),
      onConfigure: () => clawKeys[catalog.selected]?.currentState?.settings(),
    );
    return ProviderScope(
      overrides: [gatewayHostEntryProvider.overrideWithValue(directory)],
      child: CoveNotificationHost(
        catalog: catalog,
        onTap: openNotice,
        child: IndexedStack(
          index: selected == 1 ? ids.length : ids.indexOf(catalog.selected),
          children: [
            for (final id in ids)
              ClawHome(
                key: clawKeys[id],
                controller: catalog.controllers[id],
                ownsController: false,
                onLanguage: widget.onLanguage,
              ),
            if (openedDsh)
              Navigator(
                key: dshNavigator,
                onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const DshRemoteHome()),
              )
            else
              const SizedBox.shrink(),
          ],
        ),
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
    return const RemoteScreen();
  }
}
