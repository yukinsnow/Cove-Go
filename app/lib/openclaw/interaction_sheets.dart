import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../ui/common/app_sheet.dart';
import '../ui/chat/widgets/plus_panel.dart' show AttachSource, PlusTile, PlusPanelMetrics;
import '../ui/theme/app_icons.dart';
import '../ui/theme/theme.dart';
import 'controller.dart';
import 'home.dart' show gatewayModelId, gatewayModelSelected;

/// Reuse DSH's visual tiles, never its providers or conversation modes.
Future<AttachSource?> showGatewayAttachmentPanel(BuildContext context) => showAppSheet<AttachSource>(
  context,
  isScrollControlled: true,
  builder: (sheet) => SafeArea(
    top: false,
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(PlusPanelMetrics.side, 4, PlusPanelMetrics.side, 20),
        child: Row(
          spacing: PlusPanelMetrics.gap,
          children: [
            for (final item in [
              (AttachSource.gallery, AppIcons.gallery, sheet.l10n.ocPhotosVideos, 0),
              (AttachSource.camera, AppIcons.camera, sheet.l10n.chatTakePhoto, 2),
              (AttachSource.files, AppIcons.files, sheet.l10n.chatFile, 4),
            ])
              Expanded(
                child: PlusTile(
                  key: ValueKey('gateway-pick-${item.$1 == AttachSource.gallery ? 'media' : item.$1.name}'),
                  icon: item.$2,
                  label: item.$3,
                  tint: item.$4,
                  onTap: () => Navigator.pop(sheet, item.$1),
                ),
              ),
          ],
        ),
      ),
    ),
  ),
);

Future<String?> showGatewayModelSheet(BuildContext context, ClawController controller) =>
    showAppSheet<String>(context, isScrollControlled: true, builder: (_) => _Models(controller: controller));

class _Models extends StatefulWidget {
  const _Models({required this.controller});
  final ClawController controller;
  @override
  State<_Models> createState() => _ModelsState();
}

class _ModelsState extends State<_Models> {
  String? provider;
  // A sheet belongs to the connection and conversation that opened it.
  late final epoch = widget.controller.workspaceEpoch;
  late final revision = widget.controller.selectionRevision;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final owned = c.workspaceEpoch == epoch && c.selectionRevision == revision;
      final groups = <String, List<Map<String, dynamic>>>{};
      for (final model in c.models) {
        final key = '${model['provider'] ?? ''}';
        (groups[key] ??= []).add(model);
      }
      final selectedProvider = groups.containsKey(provider)
          ? provider
          : groups.entries
                    .where((entry) => entry.value.any((model) => gatewayModelSelected(c, model)))
                    .firstOrNull
                    ?.key ??
                groups.keys.firstOrNull;
      final models = groups[selectedProvider] ?? [];
      return SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .75),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(context.l10n.ocModels, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 20),
                if (!owned)
                  Text(context.l10n.ocFeatureScopeChanged)
                else if (groups.isEmpty)
                  Text(context.l10n.ocModelsEmpty)
                else ...[
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      spacing: 8,
                      children: [
                        for (final name in groups.keys)
                          ChoiceChip(
                            key: ValueKey('gateway-provider-$name'),
                            label: Text(name.isEmpty ? 'OpenClaw' : name),
                            selected: name == selectedProvider,
                            onSelected: (_) => setState(() => provider = name),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = constraints.maxWidth < 300 || MediaQuery.textScalerOf(context).scale(16) > 24
                          ? 1
                          : 2;
                      final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final model in models)
                            SizedBox(
                              width: width,
                              child: GlassSurface(
                                tier: GlassTier.chrome,
                                child: Material(
                                  color: Colors.transparent,
                                  child: ListTile(
                                    key: ValueKey('gateway-model-${gatewayModelId(model)}'),
                                    selected: gatewayModelSelected(c, model),
                                    trailing: gatewayModelSelected(c, model) ? const Icon(AppIcons.done) : null,
                                    title: Text(
                                      '${model['name'] ?? model['id']}',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: model['description'] is String
                                        ? Text(
                                            model['description'] as String,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          )
                                        : null,
                                    onTap: () => Navigator.pop(context, gatewayModelId(model)),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}
