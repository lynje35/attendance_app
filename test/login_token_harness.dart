import 'dart:convert';

import 'package:attendance_app/employee_server_preview.dart';
import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Shared helpers for the login_status_token_*_test.dart files. Each of those files runs exactly ONE login
// flow: main.dart keeps process-wide state (the remembered-login write queue) that a finished login leaves
// pending inside the test's fake-async zone, so a second login in the same test process would wait forever.

const good = 'good-session-token';
const issued = 'newly-issued-token';

// A tiny stand-in for the employee API. A status request carrying `good` is authenticated by the session
// (no new token is issued); any other status request behaves like the server's password fallback and
// issues `issued`. Every wire body is recorded.
List<Map<String, dynamic>> installApi() {
  final bodies = <Map<String, dynamic>>[];
  employeeServerPreview = EmployeeServerPreview(
    endpoint: Uri.parse('http://test.invalid/employee/api'),
    client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      bodies.add(body);
      final Map<String, dynamic> result;
      switch (body['action']) {
        case 'bootstrap':
          result = {'success': true, 'stores': [{'storeName': '매장1'}],
            'employees': [{'employeeId': 'e1', 'name': '테스트직원', 'defaultStore': '매장1'}]};
        case 'status':
          result = {'success': true, 'attendance': {'status': 'NOT_IN'}, 'actionToken': body['actionToken'] == good ? '' : issued};
        default:
          result = {'success': true, 'records': [], 'attendance': {'status': 'NOT_IN'}};
      }
      return http.Response.bytes(utf8.encode(jsonEncode(result)), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }),
    read: (_) async => null,
    write: (_, _) async {},
    remove: (_) async {},
  );
  addTearDown(() => employeeServerPreview = null);
  return bodies;
}

void useWideView(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> settle(WidgetTester tester, {int steps = 20}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> login(WidgetTester tester, List<Map<String, dynamic>> bodies, {String pin = '1234'}) async {
  useWideView(tester);
  await tester.pumpWidget(const MaterialApp(home: LoginPage()));
  for (var i = 0; i < 50 && !bodies.any((b) => b['action'] == 'bootstrap'); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.tap(find.byType(DropdownButtonFormField<String>).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('테스트직원').last);
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), pin);
  await tester.tap(find.text('확인'));
  await settle(tester, steps: 10);
}

Map<String, dynamic> firstStatus(List<Map<String, dynamic>> bodies) => bodies.firstWhere((b) => b['action'] == 'status');

Future<String?> storedToken() => secureStorage.read(key: actionTokenKey('e1'));
