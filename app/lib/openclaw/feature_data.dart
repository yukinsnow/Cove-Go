import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../ui/common/list_page_row.dart';
import '../ui/shell/page_frame.dart';
import '../ui/theme/app_icons.dart';
import 'controller.dart';

/// Captures protocol ownership once. Never repoints an open page to a new host
/// or conversation, or shows its delayed result after that scope has retired.
class GatewayFeatureScope {
  GatewayFeatureScope(this.controller, {this.session})
    : epoch = controller.workspaceEpoch,
      selection = controller.selectionRevision;
  final ClawController controller;
  final String? session;
  final int epoch, selection;
  bool get current =>
      !controller.disposed &&
      controller.connected &&
      controller.workspaceEpoch == epoch &&
      (session == null || (controller.sessionKey == session && controller.selectionRevision == selection));
  Future<dynamic> read(String method, [Map<String, dynamic> params = const {}]) async {
    if (!current) throw StateError(appL10n.ocFeatureScopeChanged);
    final methods = (controller.client.hello['features'] as Map?)?['methods'];
    if (methods is List && !methods.contains(method)) throw StateError(appL10n.ocFeatureUnavailable);
    try {
      final result = await controller.client.request(method, params);
      if (!current) throw StateError(appL10n.ocFeatureScopeChanged);
      return result;
    } catch (_) {
      if (!current) throw StateError(appL10n.ocFeatureScopeChanged);
      rethrow;
    }
  }
}

String safeFeatureError(Object error, ClawController c) =>
    c.token.isEmpty ? '$error' : '$error'.replaceAll(c.token, '[redacted]');

/// Explicit-key projection: inventories never dump credentials/configuration or
/// complete tool arguments into a generic JSON viewer.
class GatewayReadPage extends StatefulWidget {
  const GatewayReadPage({
    super.key,
    required this.scope,
    required this.title,
    required this.method,
    this.params = const {},
    this.collection,
    this.fields = const ['name', 'description', 'status'],
    this.onItem,
    this.note,
  });
  final GatewayFeatureScope scope;
  final String title, method;
  final Map<String, dynamic> params;
  final String? collection, note;
  final List<String> fields;
  final void Function(BuildContext, Map)? onItem;
  @override
  State<GatewayReadPage> createState() => _GatewayReadPageState();
}

class _GatewayReadPageState extends State<GatewayReadPage> {
  late Future<dynamic> result;
  @override
  void initState() {
    super.initState();
    widget.scope.controller.addListener(changed);
    result = load();
  }

  Future<dynamic> load() => widget.scope.read(widget.method, widget.params);
  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.scope.controller.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppPage.list(
    title: widget.title,
    children: [
      if (widget.note != null) Padding(padding: const EdgeInsets.all(20), child: Text(widget.note!)),
      if (!widget.scope.current)
        Padding(padding: const EdgeInsets.all(20), child: Text(context.l10n.ocFeatureScopeChanged))
      else
        FutureBuilder(
          future: result,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text(safeFeatureError(snapshot.error!, widget.scope.controller)),
                    Text(context.l10n.ocFeatureUnavailable),
                    TextButton(
                      onPressed: () => setState(() {
                        result = load();
                      }),
                      child: Text(context.l10n.commonRetry),
                    ),
                  ],
                ),
              );
            }
            dynamic value = snapshot.data;
            if (widget.collection != null && value is Map) value = value[widget.collection];
            if (value == null || (value is List && value.isEmpty)) {
              return Padding(padding: const EdgeInsets.all(20), child: Text(context.l10n.ocFeatureEmpty));
            }
            final rows = value is List
                ? value.whereType<Map>().toList()
                : value is Map
                ? [value]
                : <Map>[];
            return Column(
              children: [
                for (final row in rows) ...[
                  if (widget.onItem != null)
                    ListPageRow(
                      icon: row['kind'] == 'directory' ? AppIcons.workspace : AppIcons.files,
                      title: '${row['title'] ?? row['name'] ?? row['path'] ?? row['id'] ?? ''}',
                      subtitle: '${row['mimeType'] ?? row['kind'] ?? row['type'] ?? ''}',
                      onTap: () => widget.onItem!(context, row),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final field in widget.fields)
                            if (row[field] != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: SelectableText('$field: ${_display(row[field])}'),
                              ),
                        ],
                      ),
                    ),
                ],
              ],
            );
          },
        ),
      ListPageRow(
        icon: AppIcons.refresh,
        title: context.l10n.ocRefresh,
        onTap: widget.scope.current
            ? () => setState(() {
                result = load();
              })
            : null,
      ),
    ],
  );
}

String _display(dynamic value) => value is String ? value : const JsonEncoder.withIndent('  ').convert(value);

class GatewayFilePreview extends StatefulWidget {
  const GatewayFilePreview({super.key, required this.scope, required this.path});
  final GatewayFeatureScope scope;
  final String path;
  @override
  State<GatewayFilePreview> createState() => _GatewayFilePreviewState();
}

class _GatewayFilePreviewState extends State<GatewayFilePreview> {
  late final Future<dynamic> result;
  @override
  void initState() {
    super.initState();
    widget.scope.controller.addListener(changed);
    result = widget.scope.read('sessions.files.get', {'sessionKey': widget.scope.session, 'path': widget.path});
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.scope.controller.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppPage.list(
    title: widget.path.split('/').last,
    children: [
      if (!widget.scope.current)
        Padding(padding: const EdgeInsets.all(20), child: Text(context.l10n.ocFeatureScopeChanged))
      else
        FutureBuilder(
          future: result,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Padding(
                padding: const EdgeInsets.all(20),
                child: Text(safeFeatureError(snapshot.error!, widget.scope.controller)),
              );
            }
            final file = (snapshot.data as Map?)?['file'] as Map?;
            final content = file?['content'];
            if (file == null || content is! String || content.length > 8 * 1024 * 1024) {
              return Padding(padding: const EdgeInsets.all(20), child: Text(context.l10n.ocFeaturePreviewUnavailable));
            }
            if (file['contentEncoding'] == 'base64') {
              if (file['previewKind'] != 'image') {
                return Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(context.l10n.ocFeaturePreviewUnavailable),
                );
              }
              Uint8List bytes;
              try {
                bytes = base64Decode(content);
              } catch (_) {
                return Text(context.l10n.ocFeaturePreviewUnavailable);
              }
              return Image.memory(bytes, errorBuilder: (_, _, _) => Text(context.l10n.ocFeaturePreviewUnavailable));
            }
            return Padding(padding: const EdgeInsets.all(20), child: SelectableText(content));
          },
        ),
    ],
  );
}
