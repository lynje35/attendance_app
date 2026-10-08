import 'dart:convert';

import 'package:attendance_app/employee_server_preview.dart';
import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// The header of the work screen names the store of the shift that is open right now (as the server reports it for
// that record), not just the store chosen at login. Requests keep using the chosen store.
const _pin = '7391';
const home = '제로백', other = '인쌩맥주';

Map<String, dynamic> working({String? store}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {'status': 'WORKING', 'recordId': 'employee_rec1', 'adjustedInText': '17:30', 'actualInMs': now - 3 * 3600000, 'serverNowMs': now,
    'store': ?store};
}

class Harness {
  final bodies = <Map<String, dynamic>>[];
  Map<String, dynamic> status = {};
  List<Map<String, dynamic>> get clockOuts => bodies.where((b) => b['action'] == 'clockOut').toList();
}

Harness install(Map<String, dynamic> serverStatus, {Map<String, dynamic>? clockOutReply}) {
  final h = Harness()..status = serverStatus;
  employeeServerPreview = EmployeeServerPreview(
    endpoint: Uri.parse('http://test.invalid/employee/api'),
    client: MockClient((request) async {
      final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      h.bodies.add(body);
      final Map<String, dynamic> reply = switch (body['action']) {
        'attendanceDiag' => {'success': true},
        'clockOut' => clockOutReply ?? {'success': true},
        _ => {'success': true, 'attendance': h.status},
      };
      return http.Response.bytes(utf8.encode(jsonEncode(reply)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    }),
    read: (key) => secureStorage.read(key: key),
    write: (key, value) => secureStorage.write(key: key, value: value),
    remove: (key) => secureStorage.delete(key: key),
  );
  addTearDown(() => employeeServerPreview = null);
  return h;
}

Future<dynamic> open(WidgetTester tester, Harness h, Map<String, dynamic> attendance) async {
  FlutterSecureStorage.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: WorkPage(
    store: home, employee: '직원', employeeId: 'storetest', password: _pin, attendance: attendance,
    loginFuture: sendApiRequest({'action': 'status', 'employeeId': 'storetest', 'password': _pin, 'selectedStore': home}),
    rememberDevice: false,
  )));
  await tester.pump(const Duration(milliseconds: 100));
  return tester.state(find.byType(WorkPage));
}

void main() {
  testWidgets('working at the chosen store: that store is shown', (tester) async {
    final h = install(working(store: home));
    await open(tester, h, working(store: home));
    expect(find.text(home), findsOneWidget);
    expect(find.text(other), findsNothing);
    expect(find.text('현재 근무중'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('working at another store (an admin added the shift there): that store is shown instead of the chosen one', (tester) async {
    final h = install(working(store: other));
    await open(tester, h, working(store: other));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text(other), findsOneWidget);
    expect(find.text(home), findsNothing);
    expect(find.text('현재 근무중'), findsOneWidget);
    // Everything that talks to the server still names the store chosen at login.
    expect(h.bodies.where((b) => b['action'] == 'status').every((b) => b['selectedStore'] == home), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a working state without a store name falls back to the chosen store', (tester) async {
    final h = install(working());
    await open(tester, h, working());
    expect(find.text(home), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('not working (no open shift): the chosen store, as before', (tester) async {
    final h = install({'status': 'NOT_IN', 'statusText': '미출근', 'serverNowMs': DateTime.now().millisecondsSinceEpoch});
    await open(tester, h, {'status': 'NOT_IN', 'serverNowMs': DateTime.now().millisecondsSinceEpoch});
    expect(find.text(home), findsOneWidget);
    expect(find.text(other), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('when the open shift ends (server says not working) the header goes back to the chosen store', (tester) async {
    final h = install(working(store: other));
    final dynamic state = await open(tester, h, working(store: other));
    expect(find.text(other), findsOneWidget);
    state.setState(() { state.applyAttendance({'status': 'NOT_IN', 'serverNowMs': DateTime.now().millisecondsSinceEpoch}); });
    await tester.pump();
    expect(find.text(home), findsOneWidget);
    expect(find.text(other), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('clocking out of a shift at another store works as before and the header returns to the chosen store', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final h = install(working(store: other), clockOutReply: {
      'success': true, 'requestId': 'x', 'recordId': 'employee_rec1', 'duplicate': false,
      'attendance': {'status': 'COMPLETED', 'recordId': 'employee_rec1', 'store': other, 'adjustedInText': '17:30', 'adjustedOutText': '03:00',
        'actualInMs': now - 3 * 3600000, 'actualOutMs': now, 'serverNowMs': now, 'workedText': '3시간 0분', 'breakText': '0시간 0분',
        'grossWorkedText': '3시간 0분', 'showBreak': false},
      'actionToken': '',
    });
    await open(tester, h, working(store: other));
    expect(find.text(other), findsOneWidget);
    await tester.ensureVisible(find.text('퇴근하기'));
    await tester.pump();
    await tester.tap(find.text('퇴근하기'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('확인')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.clockOuts, hasLength(1));
    expect(h.clockOuts.single['selectedStore'], home); // the request still carries the chosen store
    expect(h.clockOuts.single['recordId'], 'employee_rec1'); // and the open record's id
    expect(find.text('퇴근 완료'), findsOneWidget);
    expect(find.text(home), findsOneWidget);
    expect(find.text(other), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 25)); // the delayed completed-view timers fire harmlessly once the page is gone
  });
}
