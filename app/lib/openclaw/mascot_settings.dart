import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum RemoteMascot { whale, lobster }

class MascotSettings extends Notifier<Map<RemoteMascot, bool>> {
  @override
  Map<RemoteMascot, bool> build() {
    restore();
    return {for (final pet in RemoteMascot.values) pet: true};
  }

  // An early tap must win over an in-flight preferences read.
  final _edited = <RemoteMascot>{};
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted) return;
    state = {
      for (final pet in RemoteMascot.values)
        pet: _edited.contains(pet) ? state[pet]! : prefs.getBool('remote.mascot.${pet.name}') ?? true,
    };
  }

  Future<void> setEnabled(RemoteMascot pet, bool value) async {
    _edited.add(pet);
    state = {...state, pet: value};
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('remote.mascot.${pet.name}', value);
  }
}

final mascotSettingsProvider = NotifierProvider<MascotSettings, Map<RemoteMascot, bool>>(MascotSettings.new);

/// Non-null only under the dual-remote entry point. Keeps the original DSH
/// mascot/appearance settings untouched, including in native app builds.
final dualRemoteUiProvider = Provider<bool>((ref) => false);
