import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

class GatewayToolEntry {
  const GatewayToolEntry({required this.name, required this.details});
  final String name;
  final String details;
}

/// One compact transcript row; verbose outputs stay in a separate sheet.
class GatewayToolActivity extends StatelessWidget {
  const GatewayToolActivity({super.key, required this.entries});
  final List<GatewayToolEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final names = entries.map((entry) => entry.name).toSet().take(3).join(' / ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: colors.onSurfaceVariant,
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          textStyle: theme.textTheme.labelMedium?.copyWith(fontSize: 13),
        ),
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (ctx) => SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(ctx).height * .7,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('${ctx.l10n.ocTools} · ${entries.length}', style: Theme.of(ctx).textTheme.titleSmall),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (_, index) {
                        final entry = entries[index];
                        return ExpansionTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          title: Text(entry.name, style: Theme.of(ctx).textTheme.bodySmall),
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                              child: Align(alignment: Alignment.centerLeft, child: SelectableText(entry.details)),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.terminal_rounded, size: 16),
            const SizedBox(width: 8),
            Text('${context.l10n.ocTools} · ${entries.length}'),
            const SizedBox(width: 12),
            Expanded(child: Text(names, maxLines: 1, overflow: TextOverflow.ellipsis)),
            const Icon(Icons.chevron_right_rounded, size: 16),
          ],
        ),
      ),
    );
  }
}
