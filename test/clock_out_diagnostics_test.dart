import 'dart:convert';

import 'package:attendance_app/employee_server_preview.dart';
import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// CLOCK_OUT_* diagnostics: the clockOut counterpart of clock_in_diagnostics_test.dart. One best-effort
// attendanceDiag POST per tap / skip / cancel / intent-save failure / local failure / non-retryable
// rejection. They observe the existing clockOut flow and never change its outcome.
const _pin = '7391';
const _recordId = 'employee_rec1';

class Harness {
  final bodies = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> get diags => bodies.where((b) => b['action'] == 'attendanceDiag').toList();
  List<String> get events => [for (final d in diags) d['event'] as String];
  Map<String, dynamic> diag(String event) => diags.firstWhere((d) => d['event'] == event);
  List<String> get actions => [for (final b in bodies) b['action'] as String];
}

Map<String, dynamic> workingAttendance() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {
    'status': 'WORKING', 'recordId': _recordId, 'adjustedInText': '18:50',
    'actualInMs': now - 7 * 3600000, 'serverNowMs': now,
  };
}

Harness install({bool failWrite = false, Map<String, dynamic> Function(Map<String, dynamic>)? clockOutReply}) {
  final h = Harness();
  employeeServerPreview = EmployeeServerPreview(
    endpoint: Uri.parse('http://test.invalid/employee/api'),
    client: MockClient((request) async {
      final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      h.bodies.add(body);
      final Map<String, dynamic> reply = switch (body['action']) {
        'attendanceDiag' => {'success': true},
        'clockOut' => clockOutReply != null ? clockOutReply(body) : {'success': true},
        _ => {'success': true, 'attendance': workingAttendance()},
      };
      return http.Response.bytes(utf8.encode(jsonEncode(reply)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    }),
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
      attendance: workingAttendance(),
      // The real login status call, so the preview learns the open record's id exactly as in production.
      loginFuture: sendApiRequest({'action': 'status', 'employeeId': 'diagtest', 'password': _pin, 'selectedStore': '매장1'}),
      rememberDevice: false,
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100));
  return tester.state(find.byType(WorkPage));
}

Future<void> tapClockOut(WidgetTester tester) async {
  await tester.ensureVisible(find.text('퇴근하기'));
  await tester.pump();
  await tester.tap(find.text('퇴근하기'));
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
  testWidgets('a tap that is then cancelled records TAPPED then CONFIRM_CANCELLED and sends no clockOut', (tester) async {
    final h = install();
    await openWorkPage(tester);
    await tapClockOut(tester);
    await answer(tester, '취소');
    expect(h.events, ['CLOCK_OUT_TAPPED', 'CLOCK_OUT_CONFIRM_CANCELLED']);
    expect(h.actions.where((a) => a == 'clockOut'), isEmpty);
    final tapped = jsonDecode(h.diag('CLOCK_OUT_TAPPED')['message'] as String) as Map;
    expect(tapped['st'], 'WORKING');
    expect(tapped['proc'], false);
    expect(h.diag('CLOCK_OUT_TAPPED')['employeeId'], 'diagtest');
    expect(h.diag('CLOCK_OUT_TAPPED')['expectedStatus'], 'COMPLETED');
    expectNoSecrets(h);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a call blocked by a guard records SKIPPED with the reason, without TAPPED or any clockOut request', (tester) async {
    final h = install();
    final dynamic state = await openWorkPage(tester);
    state.isProcessing = true;
    await state.requestClockOut();
    state.isProcessing = false;
    state.authActionPending = true;
    await state.requestClockOut();
    state.authActionPending = false;
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.events, ['CLOCK_OUT_SKIPPED', 'CLOCK_OUT_SKIPPED']);
    expect([for (final d in h.diags) d['code']], ['PROCESSING', 'AUTH_PENDING']);
    expect(h.actions.where((a) => a == 'clockOut'), isEmpty);
    expectNoSecrets(h);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an intent save failure and the resulting no-HTTP local failure are both recorded; behavior is unchanged', (tester) async {
    final h = install(failWrite: true);
    await openWorkPage(tester);
    await tapClockOut(tester);
    await answer(tester, '확인');
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.events, ['CLOCK_OUT_TAPPED', 'CLOCK_OUT_INTENT_SAVE_FAILED', 'CLOCK_OUT_LOCAL_FAIL']);
    final saveFailed = h.diag('CLOCK_OUT_INTENT_SAVE_FAILED');
    expect(saveFailed['code'], 'prepareIntent');
    expect(saveFailed['exceptionType'], isNotEmpty);
    expect(h.diag('CLOCK_OUT_LOCAL_FAIL')['code'], 'INTENT_MISSING');
    expect(h.actions.where((a) => a == 'clockOut'), isEmpty);
    // Same visible outcome as before: the existing message, and back to 근무중.
    expect(find.text('저장 요청 정보를 확인하지 못했습니다. 현재 상태를 다시 확인해 주세요.'), findsOneWidget);
    expect(find.text('현재 근무중'), findsOneWidget);
    expectNoSecrets(h);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a server rejection that is not retryable records NONRETRYABLE_FAIL with the requestId and recordId the request carried', (tester) async {
    final h = install(clockOutReply: (_) => {
          'success': false, 'code': 'RECORD_CHANGED', 'retryable': false,
          'message': '퇴근할 기록이 변경되었습니다. 현재 상태를 다시 확인해 주세요.',
        });
    await openWorkPage(tester);
    await tapClockOut(tester);
    await answer(tester, '확인');
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.events, ['CLOCK_OUT_TAPPED', 'CLOCK_OUT_NONRETRYABLE_FAIL']);
    final sent = h.bodies.firstWhere((b) => b['action'] == 'clockOut');
    final fail = h.diag('CLOCK_OUT_NONRETRYABLE_FAIL');
    expect(fail['requestId'], sent['requestId']);
    expect(fail['requestId'], matches(RegExp(r'^[a-f0-9]{32}$')));
    expect(fail['recordId'], sent['recordId']);
    expect(fail['recordId'], _recordId);
    expect([fail['code'], fail['success'], fail['retryable'], fail['expectedStatus']], ['RECORD_CHANGED', false, false, 'COMPLETED']);
    expect(fail['message'], '퇴근할 기록이 변경되었습니다. 현재 상태를 다시 확인해 주세요.');
    expect(find.text('퇴근할 기록이 변경되었습니다. 현재 상태를 다시 확인해 주세요.'), findsOneWidget);
    expect(find.text('현재 근무중'), findsOneWidget);
    expectNoSecrets(h);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a normal successful clockOut is unchanged and adds only the TAPPED row (no failure diagnostics)', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final h = install(clockOutReply: (body) => {
          'success': true, 'requestId': body['requestId'], 'recordId': body['recordId'], 'duplicate': false,
          'attendance': {
            'status': 'COMPLETED', 'recordId': body['recordId'], 'adjustedInText': '18:50', 'adjustedOutText': '02:00',
            'actualInMs': now - 7 * 3600000, 'actualOutMs': now, 'serverNowMs': now,
            'workedText': '7시간 10분', 'breakText': '0시간 0분', 'grossWorkedText': '7시간 10분', 'showBreak': false,
          },
          'actionToken': '',
        });
    await openWorkPage(tester);
    await tapClockOut(tester);
    await answer(tester, '확인');
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.actions.where((a) => a == 'clockOut'), hasLength(1));
    expect(h.events, ['CLOCK_OUT_TAPPED']);
    expect(find.text('퇴근 완료'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    // The delayed completed-view and post-save maintenance timers fire harmlessly once the page is gone.
    await tester.pump(const Duration(seconds: 25));
  });
}
