import 'dart:convert';

import 'package:attendance_app/employee_server_preview.dart';
import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// CLOCK_IN_* diagnostics: one best-effort attendanceDiag POST per tap / skip / cancel / local failure /
// non-retryable rejection. They observe the existing clockIn flow and never change its outcome.
const _pin = '7391';

class Harness {
  final bodies = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> get diags => bodies.where((b) => b['action'] == 'attendanceDiag').toList();
  List<String> get events => [for (final d in diags) d['event'] as String];
  Map<String, dynamic> diag(String event) => diags.firstWhere((d) => d['event'] == event);
  List<String> get actions => [for (final b in bodies) b['action'] as String];
}

Harness install({bool failWrite = false, Map<String, dynamic> Function(Map<String, dynamic>)? clockInReply}) {
  final h = Harness();
  employeeServerPreview = EmployeeServerPreview(
    endpoint: Uri.parse('http://test.invalid/employee/api'),
    client: MockClient((request) async {
      final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      h.bodies.add(body);
      final Map<String, dynamic> reply = switch (body['action']) {
        'attendanceDiag' => {'success': true},
        'clockIn' => clockInReply != null ? clockInReply(body) : {'success': true},
        _ => {'success': true, 'attendance': {'status': 'NOT_IN'}},
      };
      return http.Response.bytes(utf8.encode(jsonEncode(reply)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    }),
    // Same wiring as main(): the preview's intent storage is the app's own secure storage, which is also
    // where the app's diagnostics read the staged requestId back from.
    read: (key) => secureStorage.read(key: key),
    write: (key, value) async {
      if (failWrite) throw Exception('secure storage unavailable');
      await secureStorage.write(key: key, value: value);
    },
    remove: (key) => secureStorage.delete(key: key),
  );
  addTearDown(() => employeeServerPreview = null);
  return h;
}

Future<dynamic> openWorkPage(WidgetTester tester) async {
  FlutterSecureStorage.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    home: WorkPage(
      store: '매장1', employee: '직원', employeeId: 'diagtest', password: _pin,
      attendance: const {'status': 'NOT_IN'},
      loginFuture: Future.value({'success': true, 'attendance': {'status': 'NOT_IN'}}),
      rememberDevice: false,
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100));
  return tester.state(find.byType(WorkPage));
}

Future<void> tapClockIn(WidgetTester tester) async {
  await tester.ensureVisible(find.text('출근하기'));
  await tester.pump();
  await tester.tap(find.text('출근하기'));
  await tester.pumpAndSettle();
}

Future<void> answer(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text(label)));
  await tester.pumpAndSettle();
}

void expectNoSecrets(Harness h) {
  for (final d in h.diags) {
    expect(d.containsKey('password'), isFalse);
    expect(d.containsKey('actionToken'), isFalse);
    expect(d.values.any((v) => v == _pin), isFalse);
    expect((d['message']?.toString() ?? '').contains('password'), isFalse);
  }
}

void main() {
  testWidgets('a tap that is then cancelled records TAPPED then CONFIRM_CANCELLED and sends no clockIn', (tester) async {
    final h = install();
    await openWorkPage(tester);
    await tapClockIn(tester);
    await answer(tester, '취소');
    expect(h.events, ['CLOCK_IN_TAPPED', 'CLOCK_IN_CONFIRM_CANCELLED']);
    expect(h.actions.where((a) => a == 'clockIn'), isEmpty);
    final tapped = jsonDecode(h.diag('CLOCK_IN_TAPPED')['message'] as String) as Map;
    expect(tapped['st'], 'NOT_IN');
    expect(tapped['proc'], false);
    expect(tapped['tok'], false);
    expect(h.diag('CLOCK_IN_TAPPED')['employeeId'], 'diagtest');
    expectNoSecrets(h);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a call blocked by a guard records SKIPPED with the reason, without TAPPED or any request', (tester) async {
    final h = install();
    final dynamic state = await openWorkPage(tester);
    state.authActionPending = true;
    await state.requestClockIn();
    state.authActionPending = false;
    state.isProcessing = true;
    await state.requestClockIn();
    state.isProcessing = false;
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.events, ['CLOCK_IN_SKIPPED', 'CLOCK_IN_SKIPPED']);
    expect([for (final d in h.diags) d['code']], ['AUTH_PENDING', 'PROCESSING']);
    expect(h.actions.where((a) => a != 'attendanceDiag'), isEmpty);
    expectNoSecrets(h);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an intent save failure and the resulting no-HTTP local failure are both recorded; behavior is unchanged', (tester) async {
    final h = install(failWrite: true);
    await openWorkPage(tester);
    await tapClockIn(tester);
    await answer(tester, '확인');
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.events, ['CLOCK_IN_TAPPED', 'CLOCK_IN_INTENT_SAVE_FAILED', 'CLOCK_IN_LOCAL_FAIL']);
    final saveFailed = h.diag('CLOCK_IN_INTENT_SAVE_FAILED');
    expect(saveFailed['code'], 'prepareIntent');
    expect(saveFailed['exceptionType'], isNotEmpty);
    expect(h.diag('CLOCK_IN_LOCAL_FAIL')['code'], 'INTENT_MISSING');
    expect(h.actions.where((a) => a == 'clockIn'), isEmpty);
    // Same visible outcome as before: the existing message, and back to 미출근.
    expect(find.text('저장 요청 정보를 확인하지 못했습니다. 현재 상태를 다시 확인해 주세요.'), findsOneWidget);
    expect(find.text('현재 미출근'), findsOneWidget);
    expectNoSecrets(h);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a server rejection that is not retryable records NONRETRYABLE_FAIL with the same requestId the request carried', (tester) async {
    final h = install(clockInReply: (_) => {
          'success': false, 'code': 'ALREADY_WORKING', 'retryable': false,
          'message': '이미 근무 중입니다. 현재 상태를 다시 확인해 주세요.',
        });
    await openWorkPage(tester);
    await tapClockIn(tester);
    await answer(tester, '확인');
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.events, ['CLOCK_IN_TAPPED', 'CLOCK_IN_NONRETRYABLE_FAIL']);
    final sent = h.bodies.firstWhere((b) => b['action'] == 'clockIn');
    final fail = h.diag('CLOCK_IN_NONRETRYABLE_FAIL');
    expect(fail['requestId'], sent['requestId']);
    expect(fail['requestId'], matches(RegExp(r'^[a-f0-9]{32}$')));
    expect([fail['code'], fail['success'], fail['retryable'], fail['expectedStatus']], ['ALREADY_WORKING', false, false, 'WORKING']);
    expect(fail['message'], '이미 근무 중입니다. 현재 상태를 다시 확인해 주세요.');
    expect(find.text('이미 근무 중입니다. 현재 상태를 다시 확인해 주세요.'), findsOneWidget);
    expect(find.text('현재 미출근'), findsOneWidget);
    expectNoSecrets(h);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a normal successful clockIn is unchanged and adds only the TAPPED row (no failure diagnostics)', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final h = install(clockInReply: (body) => {
          'success': true, 'requestId': body['requestId'], 'recordId': 'employee_${body['requestId']}', 'duplicate': false,
          'attendance': {'status': 'WORKING', 'recordId': 'employee_${body['requestId']}', 'adjustedInText': '20:30', 'actualInMs': now, 'serverNowMs': now},
          'actionToken': '',
        });
    await openWorkPage(tester);
    await tapClockIn(tester);
    await answer(tester, '확인');
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.actions.where((a) => a == 'clockIn'), hasLength(1));
    expect(h.events, ['CLOCK_IN_TAPPED']);
    expect(find.text('현재 근무중'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    // The delayed post-save maintenance timer (20s) fires harmlessly once the page is gone.
    await tester.pump(const Duration(seconds: 25));
  });
}
