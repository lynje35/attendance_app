import 'dart:async';
import 'dart:convert';

import 'package:attendance_app/employee_server_preview.dart';
import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Shared helpers for the attendance_*_test.dart regression files (R1-R7). Everything runs against a fake local
// server through the real EmployeeServerPreview bridge (requestId / recordId / note come from the stored intent).
// main.dart keeps process-wide write queues (remembered login, verified PIN) that a finished test leaves pending in
// its fake-async zone, so a test that awaits those queues gets a file of its own (as login_token_harness.dart does).
const pin = '7391';
const emp = 'regress';
const intentKey = 'employee_server_preview_request_clockOut_$emp';

Map<String, dynamic> working({String recordId = 'employee_rec1'}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {'status': 'WORKING', 'recordId': recordId, 'adjustedInText': '18:50', 'actualInMs': now - 3 * 3600000, 'serverNowMs': now, 'store': '매장1'};
}

Map<String, dynamic> completed() => {'status': 'COMPLETED', 'adjustedInText': '18:50', 'adjustedOutText': '22:00', 'workedText': '3시간 10분',
  'breakText': '0분', 'grossWorkedText': '3시간 10분', 'showBreak': false};

class FakeServer {
  FakeServer(this.status);
  Map<String, dynamic> status;
  bool offline = false;
  int statusHttp = 200;
  Map<String, dynamic> Function(Map<String, dynamic>)? clockIn, clockOut, statusReply;
  Completer<void>? statusGate; // the next status answer is computed now but delivered only when the gate opens
  final bodies = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> of(String action) => bodies.where((b) => b['action'] == action).toList();
}

FakeServer install(Map<String, dynamic> status) {
  final fake = FakeServer(status);
  employeeServerPreview = EmployeeServerPreview(
    endpoint: Uri.parse('http://test.invalid/employee/api'),
    client: MockClient((request) async {
      if (fake.offline) throw http.ClientException('offline');
      final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      fake.bodies.add(body);
      final Map<String, dynamic> reply = switch (body['action']) {
        'attendanceDiag' => {'success': true},
        'clockIn' => fake.clockIn?.call(body) ?? () { fake.status = working(recordId: 'employee_${body['requestId']}'); return {'success': true, 'requestId': body['requestId'], 'duplicate': false, 'attendance': fake.status}; }(),
        'clockOut' => fake.clockOut?.call(body) ?? () { fake.status = completed(); return {'success': true, 'requestId': body['requestId'], 'duplicate': false, 'attendance': fake.status}; }(),
        _ => fake.statusReply?.call(body) ?? {'success': true, 'attendance': fake.status},
      };
      if (body['action'] == 'status' && fake.statusGate != null) {
        final gate = fake.statusGate!;
        fake.statusGate = null;
        await gate.future;
      }
      final code = body['action'] == 'status' ? fake.statusHttp : 200;
      return http.Response.bytes(utf8.encode(jsonEncode(reply)), code, headers: {'content-type': 'application/json; charset=utf-8'});
    }),
    read: (key) => secureStorage.read(key: key),
    write: (key, value) => secureStorage.write(key: key, value: value),
    remove: (key) => secureStorage.delete(key: key),
  );
  addTearDown(() => employeeServerPreview = null);
  return fake;
}

// hosted: WorkPage is pushed over a login stand-in, as in the app, so going back to the login screen is observable.
Future<dynamic> open(WidgetTester tester, Map<String, dynamic> shown, {Future<Map<String, dynamic>>? login, bool remember = false, bool hosted = false}) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // the login call starts when the page opens, as in the app, so a failing login is always awaited by WorkPage
  WorkPage makePage() => WorkPage(store: '매장1', employee: '직원', employeeId: emp, password: pin, attendance: shown,
      loginFuture: login ?? sendApiRequest({'action': 'status', 'employeeId': emp, 'password': pin, 'selectedStore': '매장1'}), rememberDevice: remember);
  if (hosted) {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
        onPressed: () { final page = makePage(); Navigator.of(context).push(MaterialPageRoute<Object?>(builder: (_) => page)); }, child: const Text('열기'))))));
    await tester.tap(find.text('열기'));
    for (var i = 0; i < 6; i++) { await tester.pump(const Duration(milliseconds: 100)); }
  } else {
    await tester.pumpWidget(MaterialApp(home: makePage()));
  }
  await tester.pump(const Duration(milliseconds: 100));
  return onWorkPage() ? tester.state(find.byType(WorkPage)) : null;
}

Future<void> pumpFor(WidgetTester tester, int ms) async { final step = ms >= 10000 ? 1000 : 100; for (var t = 0; t < ms; t += step) { await tester.pump(Duration(milliseconds: step)); } }
bool shows(String text) => find.text(text).evaluate().isNotEmpty;
bool onWorkPage() => find.byType(WorkPage).evaluate().isNotEmpty;
bool enabled(WidgetTester tester, String label) => tester.widget<FilledButton>(find.widgetWithText(FilledButton, label)).onPressed != null;
Future<void> finish(WidgetTester tester) async { await tester.pumpWidget(const SizedBox.shrink()); await tester.pump(const Duration(seconds: 90)); }

Future<void> tapAndConfirm(WidgetTester tester, String button) async {
  await tester.ensureVisible(find.text(button));
  await tester.tap(find.text(button));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, '확인'));
}

Future<String?> storedIntentRequestId() async {
  final raw = await secureStorage.read(key: intentKey);
  return raw == null ? null : (jsonDecode(raw) as Map)['requestId']?.toString();
}

const timeout = Timeout(Duration(minutes: 2));
