import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../l10n/l10n.dart';
import '../theme/app_icons.dart';

/// A reversible reveal, not dismiss-to-delete. A swipe never deletes a host;
/// the revealed action or long-press menu still goes through confirmation.
class HostDeleteGesture extends StatefulWidget {
  const HostDeleteGesture({super.key, required this.child, required this.onDelete});
  final Widget child;
  final Future<void> Function() onDelete;

  @override
  State<HostDeleteGesture> createState() => _HostDeleteGestureState();
}

class _HostDeleteGestureState extends State<HostDeleteGesture> {
  double _reveal = 0;
  bool _deleting = false;
  Future<void> remove() async {
    if (_deleting) return;
    setState(() {
      _deleting = true;
      _reveal = 0;
    });
    try {
      await widget.onDelete();
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> menu() async {
    final delete = await showModalBottomSheet<bool>(
      context: context,
      builder: (sheet) => SafeArea(
        child: ListTile(
          leading: const Icon(AppIcons.delete),
          title: Text(sheet.l10n.commonDelete),
          onTap: () => Navigator.pop(sheet, true),
        ),
      ),
    );
    if (mounted && delete == true) await remove();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRect(
      child: Stack(
        children: [
          if (_reveal > 0)
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: 88,
                  height: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                      shape: const RoundedRectangleBorder(),
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: _deleting ? null : () => unawaited(remove()),
                    child: Text(context.l10n.commonDelete),
                  ),
                ),
              ),
            ),
          Transform.translate(
            offset: Offset(-_reveal, 0),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPress: () => unawaited(menu()),
              onHorizontalDragUpdate: (event) => setState(() => _reveal = (_reveal - event.delta.dx).clamp(0.0, 88.0)),
              onHorizontalDragEnd: (_) => setState(() => _reveal = _reveal > 40 ? 88 : 0),
              child: Semantics(
                customSemanticsActions: {
                  CustomSemanticsAction(label: context.l10n.commonDelete): () => unawaited(remove()),
                },
                child: widget.child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
