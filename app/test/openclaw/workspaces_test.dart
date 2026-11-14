import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/openclaw/controller.dart';
import 'package:dsh_app/openclaw/home.dart';
import 'package:dsh_app/openclaw/workspaces.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openclaw_client/openclaw_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_fonts.dart';
import 'host_catalog_test.dart' show MemoryStorage, NoSnapshots;

class WorkspaceGateway extends GatewayClient {
  List<String> names = ['Work', 'Research'];
  List<Map<String, dynamic>> rows = [
    {'key': 'a', 'displayName': 'Work chat', 'category': 'Work'},
    {'key': 'b', 'displayName': 'Research chat', 'category': 'Research'},
    {'key': 'c', 'displayName': 'Other chat'},
  ];
  final defaults = <String, Map<String, dynamic>>{};
  final calls = <(String, Map<String, dynamic>)>[];
  Object? failure;
  String? failMethod;
  Completer<void>? renameGate;
  Map<String, dynamic>? creation;
  bool paginated = false;
  @override
  Future<dynamic> request(String method, [Map<String, dynamic> params = const {}]) async {
    calls.add((method, params));
    if (method == failMethod) throw failure ?? GatewayException('FORBIDDEN', 'denied');
    switch (method) {
      case 'sessions.list':
        if (paginated && params['offset'] == null) {
          return {'sessions': rows.take(1).toList(), 'hasMore': true, 'nextOffset': 1};
        }
        return {
          'sessions': rows.skip(params['offset'] as int? ?? 0).map(Map<String, dynamic>.of).toList(),
          'hasMore': false,
        };
      case 'sessions.groups.list':
        return {
          'groups': [
            for (var i = 0; i < names.length; i++) {'name': names[i], 'position': i},
          ],
          'sectionOrder': [for (final n in names) 'category:$n'],
        };
      case 'sessions.groups.defaults':
        return {'defaults': defaults.values.toList()};
      case 'sessions.groups.put':
        names = List<String>.from(params['names'] as List);
      case 'sessions.groups.rename':
        await renameGate?.future;
        final old = params['name'], to = params['to'];
        names = names.map((n) => n == old ? to as String : n).toList();
        for (final row in rows) {
          if (row['category'] == old) row['category'] = to;
        }
      case 'sessions.groups.delete':
        names.remove(params['name']);
        for (final row in rows) {
          if (row['category'] == params['name']) row.remove('category');
        }
        defaults.remove(params['name']);
      case 'sessions.groups.update':
        defaults[params['name'] as String] = Map<String, dynamic>.from(params);
      case 'sessions.patch':
        rows.firstWhere((r) => r['key'] == params['key'])['category'] = params['category'];
      case 'sessions.create':
        creation = params;
        rows.add({'key': 'new', if (params['category'] != null) 'category': params['category']});
        return {'sessionKey': 'new'};
      case 'chat.history':
        return {'messages': []};
    }
    return <String, dynamic>{'ok': true};
  }
}

class WorkspaceController extends ClawController {
  WorkspaceController(WorkspaceGateway client)
    : super(client: client, storage: MemoryStorage(), snapshots: NoSnapshots());
  @override
  Future<void> load() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WorkspaceGateway gateway;
  late WorkspaceController c;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    gateway = WorkspaceGateway()..connected = true;
    c = WorkspaceController(gateway)..address = 'wss://test.example';
    await c.refreshSessions();
  });
  tearDown(() => c.dispose());

  test('scope counts all, named and ungrouped without altering current conversation', () {
    c.sessionKey = 'b';
    c.selectGroup('Work');
    expect(c.scopedSessions.single['key'], 'a');
    expect(c.sessionKey, 'b');
    c.selectGroup('');
    expect(c.scopedSessions.single['key'], 'c');
    c.selectGroup(null);
    expect(c.scopedSessions, hasLength(3));
  });
  test('fetches every page rather than treating first 100 as all conversations', () async {
    gateway.paginated = true;
    await c.refreshSessions();
    expect(c.sessions, hasLength(3));
    expect(gateway.calls.any((call) => call.$1 == 'sessions.list' && call.$2['offset'] == 1), true);
  });
  test('add merges fresh catalog and rename/delete preserve member conversations', () async {
    gateway.names.add('External');
    await c.addGroup('New');
    expect(c.sessionGroups, containsAll(['Work', 'Research', 'External', 'New']));
    expect(c.selectedGroup, 'New');
    await c.renameGroup('New', 'Renamed');
    expect(c.selectedGroup, 'Renamed');
    await c.moveSessionGroup('a', 'Renamed');
    expect(c.scopedSessions.single['key'], 'a');
    await c.deleteGroup('Renamed');
    expect(c.sessions, hasLength(3));
    expect(c.sessions.firstWhere((r) => r['key'] == 'a')['category'], isNull);
    expect(c.selectedGroup, isNull);
    expect(gateway.calls.any((call) => call.$1 == 'sessions.delete'), false);
  });
  test('new chat receives selected category and verified directory/worktree defaults', () async {
    gateway.defaults['Work'] = {'name': 'Work', 'cwd': '/projects/work', 'worktree': true};
    c.selectGroup('Work');
    await c.newSession();
    expect(gateway.creation?['category'], 'Work');
    expect(gateway.creation?['cwd'], '/projects/work');
    expect(gateway.creation?['worktree'], true);
    expect(c.sessionKey, 'new');
    c.selectGroup(null);
    await c.newSession();
    expect(gateway.creation?.containsKey('category'), false);
    expect(gateway.creation?.containsKey('cwd'), false);
  });
  test('directory update verifies readback and clearing uses agent default', () async {
    await c.updateGroupDirectory('Work', '/projects/work');
    expect(gateway.defaults['Work']?['cwd'], '/projects/work');
    expect(gateway.defaults['Work']?['worktree'], false);
    await c.updateGroupDirectory('Work', null);
    expect(gateway.defaults['Work']?['cwd'], isNull);
  });
  test('write errors do not fake rename or change membership', () async {
    c.selectGroup('Work');
    gateway.failMethod = 'sessions.groups.rename';
    await c.guard(() => c.renameGroup('Work', 'Lost'));
    expect(c.error, contains('FORBIDDEN'));
    expect(c.sessionGroups, contains('Work'));
    expect(c.selectedGroup, 'Work');
    expect(c.sessions.first['category'], 'Work');
  });
  test('late group write after host removal cannot update local selection', () async {
    c.selectGroup('Work');
    gateway.renameGate = Completer<void>();
    final rename = c.renameGroup('Work', 'Late');
    await c.removeHost();
    gateway.renameGate!.complete();
    await expectLater(rename, throwsStateError);
    expect(c.selectedGroup, isNull);
    expect(c.sessionGroups, isEmpty);
  });
  test('old server keeps category filtering without fake management support', () async {
    gateway.failMethod = 'sessions.groups.list';
    gateway.failure = GatewayException('METHOD_NOT_FOUND', 'unknown method');
    await c.refreshSessions();
    expect(c.groupCatalogSupported, false);
    c.selectGroup('Work');
    expect(c.scopedSessions.single['key'], 'a');
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(402, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: withTestFonts(buildDarkTheme()),
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocale.supported,
          localizationsDelegates: L10n.localizationsDelegates,
          home: ClawHome(controller: c, ownsController: false, onLanguage: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester.state<ClawHomeState>(find.byType(ClawHome)).scaffoldKey.currentState!.openDrawer();
    await tester.pumpAndSettle();
  }

  testWidgets('all-conversation label opens actual selector with counts and filters drawer', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('gateway-workspace-switcher')));
    await tester.pumpAndSettle();
    expect(find.text('工作区'), findsOneWidget);
    expect(find.byKey(const ValueKey('gateway-group-all')), findsOneWidget);
    expect(find.text('添加工作区'), findsOneWidget);
    expect(find.text('管理工作区'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('gateway-group-Work')));
    await tester.pumpAndSettle();
    expect(c.selectedGroup, 'Work');
    expect(find.text('Work chat'), findsOneWidget);
    expect(find.text('Research chat'), findsNothing);
    expect(find.text('Other chat'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('add and manage flow persists names with server and checks selected scope', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('gateway-workspace-switcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加工作区'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Mobile');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(c.sessionGroups, contains('Mobile'));
    expect(c.selectedGroup, 'Mobile');
    await tester.tap(find.byKey(const ValueKey('gateway-workspace-switcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理工作区'));
    await tester.pumpAndSettle();
    expect(find.byType(GatewayWorkspaceManager), findsOneWidget);
    expect(find.text('Mobile'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('long press moves a conversation and sheet shows membership selection', (tester) async {
    await pump(tester);
    await tester.longPress(find.text('Work chat'));
    await tester.pumpAndSettle();
    expect(find.text('将对话移至分组'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('gateway-group-Research')));
    await tester.pumpAndSettle();
    expect(c.sessions.firstWhere((s) => s['key'] == 'a')['category'], 'Research');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('management edits server directory and confirms group-only removal', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('gateway-workspace-switcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理工作区'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新对话工作目录').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '/projects/work');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(gateway.defaults['Work']?['cwd'], '/projects/work');
    await tester.tap(find.text('移除工作区').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('不会删除目录或文件'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(c.sessionGroups, contains('Work'));
    await tester.tap(find.text('移除工作区').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(c.sessionGroups, isNot(contains('Work')));
    expect(c.sessions, hasLength(3));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
