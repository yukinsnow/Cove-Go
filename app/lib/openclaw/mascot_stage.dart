import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../ui/pets/pet_perch.dart';
import 'mascot_settings.dart';

/// Original pixel silhouettes, painted locally: no restricted upstream art,
/// network images or platform overlay permissions. Follows the shared perch
/// links, so growing inputs and the keyboard do not leave the pet behind.
class RemoteMascotStage extends ConsumerStatefulWidget {
  const RemoteMascotStage({super.key, required this.pet, required this.child});
  final RemoteMascot pet;
  final Widget child;

  @override
  ConsumerState<RemoteMascotStage> createState() => _RemoteMascotStageState();
}

class _RemoteMascotStageState extends ConsumerState<RemoteMascotStage> {
  final _registry = PerchRegistry();
  final _stage = GlobalKey();
  PetPerchState? _perch;
  bool _queued = false;
  int _taps = 0;

  @override
  void initState() {
    super.initState();
    _registry.leading.value = true;
    _registry.addListener(_refresh);
  }

  void _refresh() {
    if (_queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!mounted) return;
      final box = _stage.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final spots = _registry.spots(box)..sort((a, b) => a.rect.top.compareTo(b.rect.top));
      final next = spots.isEmpty || _registry.covered ? null : spots.first.perch;
      if (_perch != next) setState(() => _perch = next);
    });
  }

  @override
  void dispose() {
    _registry.removeListener(_refresh);
    _registry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(mascotSettingsProvider)[widget.pet]!;
    _refresh();
    final label = widget.pet == RemoteMascot.whale ? context.l10n.ocWhaleMascot : context.l10n.ocLobsterMascot;
    return PetPerchScope(
      registry: _registry,
      child: Stack(
        key: _stage,
        fit: StackFit.expand,
        children: [
          widget.child,
          if (enabled && _perch != null)
            Positioned.fill(
              child: CompositedTransformFollower(
                link: _perch!.link,
                targetAnchor: Alignment.topLeft,
                followerAnchor: Alignment.bottomLeft,
                offset: const Offset(62, -2),
                showWhenUnlinked: false,
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Semantics(
                    label: label,
                    button: true,
                    child: GestureDetector(
                      key: ValueKey('remote-mascot-${widget.pet.name}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _taps++),
                      child: TweenAnimationBuilder<double>(
                        key: ValueKey(_taps),
                        tween: Tween(begin: _taps == 0 ? 0 : 1, end: 0),
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 450),
                        builder: (_, value, child) => Transform.translate(offset: Offset(0, -12 * value), child: child),
                        child: CustomPaint(size: const Size(52, 40), painter: MascotPainter(widget.pet)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Deliberately different from Deepy: a turquoise rounded whale with a
/// two-pixel spout; the lobster has red claws, antennae and a segmented tail.
class MascotPainter extends CustomPainter {
  const MascotPainter(this.pet);
  final RemoteMascot pet;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 26, size.height / 20);
    void pixel(double x, double y, double w, double h, Color color) =>
        canvas.drawRect(Rect.fromLTWH(x, y, w, h), Paint()..color = color);
    if (pet == RemoteMascot.whale) {
      const body = Color(0xFF329FC0), shade = Color(0xFF21788F), light = Color(0xFFB8E4E5);
      pixel(4, 8, 14, 10, body);
      pixel(6, 6, 9, 2, body);
      pixel(2, 10, 2, 6, body);
      pixel(6, 18, 10, 2, shade);
      pixel(16, 13, 5, 4, body);
      pixel(20, 9, 3, 6, body);
      pixel(23, 7, 3, 4, body);
      pixel(5, 15, 9, 3, light);
      pixel(9, 10, 2, 2, const Color(0xFF102936));
      pixel(10, 10, 1, 1, Colors.white);
      pixel(4, 13, 2, 1, const Color(0xFFECACA7));
      pixel(9, 2, 2, 3, light);
      pixel(6, 1, 3, 2, light);
      pixel(11, 0, 3, 2, light);
    } else {
      const body = Color(0xFFDF6A57), shade = Color(0xFFAC453E), light = Color(0xFFFFB28C);
      pixel(10, 7, 7, 9, body);
      pixel(11, 16, 5, 2, shade);
      pixel(9, 18, 9, 2, body);
      pixel(5, 9, 5, 2, shade);
      pixel(17, 9, 5, 2, shade);
      pixel(2, 3, 5, 6, body);
      pixel(1, 1, 2, 4, light);
      pixel(6, 1, 2, 3, body);
      pixel(20, 3, 5, 6, body);
      pixel(19, 1, 2, 3, body);
      pixel(24, 1, 2, 4, light);
      pixel(10, 3, 1, 4, light);
      pixel(17, 3, 1, 4, light);
      pixel(11, 8, 2, 2, const Color(0xFF30232C));
      pixel(15, 8, 2, 2, const Color(0xFF30232C));
      pixel(12, 12, 3, 1, light);
      pixel(12, 15, 3, 1, light);
      for (final y in [12.0, 15.0]) {
        pixel(7, y, 3, 1, body);
        pixel(17, y, 3, 1, body);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(MascotPainter oldDelegate) => oldDelegate.pet != pet;
}
