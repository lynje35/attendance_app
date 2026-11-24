import 'dart:async';
import 'dart:convert';

import 'package:attendance_app/employee_server_preview.dart';
import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// 앱을 켜자마자(로그인 status 응답이 오기 전) 퇴근을 누르면, 확인 시점에 만든 퇴근 intent에는 아직
// recordId가 없다. 이후 도착한 로그인 status 응답이 recordId를 알려줘도 intent 생성이 올린 세대 때문에
// 캐시에 반영되지 않아 clockOut이 RECORD_ID_MISSING으로 로컬 실패하던 문제의 회귀 테스트.
const _pin = '7391';
const _recordId = 'employee_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  testWidgets('퇴근 확인 후 늦게 도착한 로그인 status의 recordId로 첫 시도에 퇴근이 서버까지 나간다', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final statusGate = Completer<void>();
    final bodies = <Map<String, dynamic>>[];
    final working = {'status': 'WORKING', 'recordId': _recordId, 'adjustedInText': '20:30',
      'actualInMs': DateTime.now().millisecondsSinceEpoch, 'serverNowMs': DateTime.now().millisecondsSinceEpoch};
    employeeServerPreview = EmployeeServerPreview(
      endpoint: Uri.parse('http://test.invalid/employee/api'),
      client: MockClient((request) async {
        final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
        bodies.add(body);
        Map<String, dynamic> reply;
        switch (body['action']) {
          case 'status':
            await statusGate.future;
            reply = {'success': true, 'attendance': working, 'actionToken': ''};
          case 'clockOut':
            reply = {'success': true, 'requestId': body['requestId'], 'recordId': body['recordId'], 'duplicate': false,
              'attendance': {'status': 'COMPLETED', 'adjustedInText': '20:30', 'adjustedOutText': '00:10',
                'workedText': '3시간 40분', 'breakText': '0시간 0분', 'grossWorkedText': '3시간 40분',
                'actualInMs': DateTime.now().millisecondsSinceEpoch, 'serverNowMs': DateTime.now().millisecondsSinceEpoch},
              'actionToken': ''};
          default:
            reply = {'success': true};
        }
        return http.Response.bytes(utf8.encode(jsonEncode(reply)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }),
      read: (key) => secureStorage.read(key: key),
      write: (key, value) => secureStorage.write(key: key, value: value),
      remove: (key) => secureStorage.delete(key: key),
    );
    addTearDown(() => employeeServerPreview = null);

    // main.dart의 로그인과 같은 방식: 로그인 status 요청이 preview를 거쳐 응답을 기다리는 중.
    final login = employeeServerPreview!.send({
      'action': 'status', 'employeeId': 'racetest', 'password': _pin, 'selectedStore': '매장1',
    });
    await tester.pumpWidget(MaterialApp(
      home: WorkPage(
        store: '매장1', employee: '직원', employeeId: 'racetest', password: _pin,
        attendance: const {'status': 'WORKING'}, loginFuture: login, rememberDevice: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.ensureVisible(find.text('퇴근하기'));
    await tester.pump();
    await tester.tap(find.text('퇴근하기'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('확인')));
    // 퇴근 intent 저장(prepareIntent)까지 끝나 "로그인 status 응답보다 확인이 먼저"인 상태를 만든다.
    await tester.pumpAndSettle();
    expect(bodies.where((b) => b['action'] == 'clockOut'), isEmpty, reason: '로그인 검증 전에는 퇴근 API가 나가면 안 된다');
    expect(find.text('퇴근 완료'), findsOneWidget);

    statusGate.complete();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    final clockOuts = bodies.where((b) => b['action'] == 'clockOut').toList();
    expect(clockOuts, hasLength(1), reason: '퇴근 요청이 서버로 나가야 한다');
    expect(clockOuts.single['recordId'], _recordId);
    expect(bodies.where((b) => b['event'] == 'CLOCK_OUT_LOCAL_FAIL'), isEmpty);
    expect(find.text('퇴근 완료'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 25));
  });
}
