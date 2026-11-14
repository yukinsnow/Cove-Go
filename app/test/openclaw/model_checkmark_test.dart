import 'package:dsh_app/openclaw/home.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'send_test.dart' show SlowGateway, UiController, home;

class ModelGateway extends SlowGateway {
  bool rejectModel = false;
  String current = 'one/shared';
  String? patched;
  @override
  Future<dynamic> request(String method, [Map<String, dynamic> params = const {}]) async {
    if (method == 'sessions.patch') {
      if (rejectModel) throw StateError('not applied');
      patched = params['model'] as String;
      current = patched!;
      return {};
    }
    if (method == 'sessions.list') {
      return {
        'sessions': [
          {'key': 'a', 'model': current},
        ],
      };
    }
    return super.request(method, params);
  }
}

void main() {
  test('model check uses provider, qualified ids and only unique legacy ids', () {
    final c = UiController(ModelGateway())..sessionKey = 'a';
    addTearDown(c.dispose);
    c.models = [
      {'id': 'shared', 'provider': 'one'},
      {'id': 'shared', 'provider': 'two'},
      {'id': 'org/model', 'provider': 'three'},
    ];
    c.sessions = [
      {'key': 'a', 'model': 'shared', 'modelProvider': 'two'},
    ];
    expect(gatewayModelSelected(c, c.models[0]), false);
    expect(gatewayModelSelected(c, c.models[1]), true);
    c.sessions = [
      {'key': 'a', 'model': 'one/shared'},
    ];
    expect(gatewayModelSelected(c, c.models[0]), true);
    c.sessions = [
      {'key': 'a', 'model': 'shared'},
    ];
    expect(c.models.any((m) => gatewayModelSelected(c, m)), false);
    c.sessions = [
      {'key': 'a', 'model': 'org/model', 'modelProvider': 'three'},
    ];
    expect(gatewayModelSelected(c, c.models[2]), true);
    expect(gatewayModelId({'id': 'three/org/model', 'provider': 'three'}), 'three/org/model');
    c.sessions = [
      {'key': 'other', 'model': 'one/shared'},
    ];
    expect(c.models.any((m) => gatewayModelSelected(c, m)), false);
  });

  for (final reject in [false, true]) {
    testWidgets('model picker marks server current model and updates after patch ($reject)', (tester) async {
      final gateway = ModelGateway()..rejectModel = reject;
      final c = UiController(gateway)..sessionKey = 'a';
      c.sessions = [
        {'key': 'a', 'model': 'one/shared'},
      ];
      c.models = [
        {'id': 'shared', 'name': 'First', 'provider': 'one'},
        {'id': 'shared', 'name': 'Second', 'provider': 'two'},
      ];
      await tester.pumpWidget(home(c, buildLightTheme()));
      await tester.pumpAndSettle();
      final state = tester.state<ClawHomeState>(find.byType(ClawHome));
      var choosing = state.chooseModel();
      await tester.pumpAndSettle();
      ListTile row(String id) => tester.widget<ListTile>(find.byKey(ValueKey('gateway-model-$id')));
      expect(row('one/shared').trailing, isA<Icon>());
      expect(row('one/shared').selected, true);
      expect(find.byKey(const ValueKey('gateway-model-two/shared')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('gateway-provider-two')));
      await tester.pumpAndSettle();
      expect(row('two/shared').trailing, isNull);
      await tester.tap(find.byKey(const ValueKey('gateway-model-two/shared')));
      await tester.pumpAndSettle();
      await choosing;
      expect(gateway.patched, reject ? isNull : 'two/shared');
      choosing = state.chooseModel();
      await tester.pumpAndSettle();
      expect(row(reject ? 'one/shared' : 'two/shared').selected, true);
      await tester.tap(find.byKey(ValueKey('gateway-provider-${reject ? 'two' : 'one'}')));
      await tester.pumpAndSettle();
      expect(row(reject ? 'two/shared' : 'one/shared').selected, false);
      // Model changes received while the list is open are reflected live.
      c.error = '';
      c.sessions = [
        {'key': 'a', 'model': 'shared', 'modelProvider': 'two'},
      ];
      c.changed();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('gateway-provider-two')));
      await tester.pumpAndSettle();
      expect(row('two/shared').selected, true);
      expect(find.byKey(const ValueKey('gateway-model-one/shared')), findsNothing);
      Navigator.of(tester.element(find.byKey(const ValueKey('gateway-model-two/shared')))).pop();
      await tester.pumpAndSettle();
      await choosing;
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
