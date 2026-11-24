import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'attendance_sync_harness.dart';

// Regression tests for the reproduced clock in/out issues R1-R7 (fake local server only).
void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('phase 1: authentication failure and server outage', () {

    testWidgets('R4 a 5xx or network failure during the background refresh is not an authentication failure: polling continues on the work screen', timeout: timeout, (tester) async {
      final fake = install(working());
      await open(tester, working(), hosted: true);
      await pumpFor(tester, 500);
      fake.statusHttp = 503;
      fake.statusReply = (_) => {'success': false, 'code': 'EMPLOYEE_UNAVAILABLE', 'message': '잠시 후 다시 시도해 주세요.'};
      final start = fake.of('status').length;
      await pumpFor(tester, 121000);
      expect(fake.of('status').length - start, 2);
      fake.offline = true;
      await pumpFor(tester, 61000);
      expect(onWorkPage(), isTrue);
      expect(shows('현재 근무중'), isTrue);
      expect(shows('로그인 정보가 변경되었습니다. 다시 로그인해 주세요.'), isFalse);
      fake.offline = false;
      fake.statusHttp = 200;
      fake.statusReply = null;
      final resumed = fake.of('status').length;
      await pumpFor(tester, 61000);
      expect(fake.of('status').length - resumed, 1, reason: 'the 60 s refresh is still running');
      await finish(tester);
    });

    testWidgets('R4 clockIn answered AUTH_CHANGED: no success notice, the message, and back to the login screen', timeout: timeout, (tester) async {
      final fake = install({'status': 'NOT_IN'});
      await open(tester, {'status': 'NOT_IN'}, hosted: true);
      fake.clockIn = (_) => {'success': false, 'code': 'AUTH_CHANGED', 'message': '로그인 정보가 변경되었습니다. 다시 로그인해 주세요.'};
      await tapAndConfirm(tester, '출근하기');
      var toast = false;
      for (var i = 0; i < 15; i++) { await tester.pump(const Duration(milliseconds: 100)); if (shows('출근 성공!')) toast = true; }
      expect(toast, isFalse);
      expect(shows('로그인 정보가 변경되었습니다. 다시 로그인해 주세요.'), isTrue);
      expect(onWorkPage(), isFalse);
      await finish(tester);
    });



  });

  group('phase 2: status sync', () {
    testWidgets('R1 login finishes WORKING while the clock-in dialog is open: the screen keeps 근무중, 퇴근 is enabled, no clockIn is sent', timeout: timeout, (tester) async {
      final fake = install(working());
      final login = Completer<Map<String, dynamic>>();
      await open(tester, {'status': 'NOT_IN'}, login: login.future);
      await tester.tap(find.text('출근하기'));
      await tester.pumpAndSettle();
      login.complete({'success': true, 'attendance': working()});
      await tester.pump(); await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.widgetWithText(FilledButton, '확인'));
      await pumpFor(tester, 1500);
      expect(shows('현재 근무중'), isTrue);
      expect(shows('현재 미출근'), isFalse);
      expect(shows('18:50'), isTrue, reason: 'the server clock-in time, not a local guess');
      expect(enabled(tester, '퇴근하기'), isTrue);
      expect(fake.of('clockIn'), isEmpty);
      expect(shows('출근 성공!'), isFalse);
      await finish(tester);
    });

    testWidgets('R2 ALREADY_WORKING (clocked in on another device): the message stays, the screen shows the server shift and 퇴근 works', timeout: timeout, (tester) async {
      final fake = install({'status': 'NOT_IN'});
      await open(tester, {'status': 'NOT_IN'});
      fake.status = working();
      fake.clockIn = (_) => {'success': false, 'code': 'ALREADY_WORKING', 'message': '이미 근무 중입니다. 현재 상태를 다시 확인해 주세요.'};
      await tapAndConfirm(tester, '출근하기');
      await pumpFor(tester, 1500);
      expect(shows('이미 근무 중입니다. 현재 상태를 다시 확인해 주세요.'), isTrue);
      expect(shows('현재 근무중'), isTrue);
      expect(shows('현재 미출근'), isFalse);
      expect(shows('출근 성공!'), isFalse);
      expect(enabled(tester, '퇴근하기'), isTrue);
      expect(fake.of('clockIn').length, 1);
      await pumpFor(tester, 4000); // let the message go
      await tapAndConfirm(tester, '퇴근하기');
      await pumpFor(tester, 1000);
      expect(fake.of('clockOut').single['recordId'], 'employee_rec1', reason: 'the clock-out targets the shift the server reported');
      expect(shows('퇴근 성공!'), isTrue);
      await finish(tester);
    });

    testWidgets('R2 ALREADY_WORKING and the follow-up status check fails: still 근무중 (the server already said so), never 미출근', timeout: timeout, (tester) async {
      final fake = install({'status': 'NOT_IN'});
      await open(tester, {'status': 'NOT_IN'});
      fake.clockIn = (_) { fake.offline = true; return {'success': false, 'code': 'ALREADY_WORKING', 'message': '이미 근무 중입니다. 현재 상태를 다시 확인해 주세요.'}; };
      await tapAndConfirm(tester, '출근하기');
      await pumpFor(tester, 1500);
      expect(shows('현재 근무중'), isTrue);
      expect(shows('현재 미출근'), isFalse);
      expect(enabled(tester, '퇴근하기'), isTrue);
      fake.offline = false;
      fake.status = working();
      await pumpFor(tester, 3000); // the scheduled re-check picks up the server times
      expect(shows('18:50'), isTrue);
      await finish(tester);
    });

    testWidgets('R7 a slow status answer computed before the clock-in arrives after it: the screen stays 근무중', timeout: timeout, (tester) async {
      final fake = install({'status': 'NOT_IN'});
      final dynamic state = await open(tester, {'status': 'NOT_IN'});
      await pumpFor(tester, 500);
      fake.statusGate = Completer<void>();
      final gate = fake.statusGate!;
      unawaited(state.refreshAttendanceStatus());
      await tester.pump();
      await tapAndConfirm(tester, '출근하기');
      await pumpFor(tester, 800);
      expect(shows('현재 근무중'), isTrue);
      gate.complete();
      await pumpFor(tester, 500);
      expect(shows('현재 근무중'), isTrue);
      expect(shows('현재 미출근'), isFalse);
      await pumpFor(tester, 61000); // the regular 60 s refresh still runs and agrees with the server
      expect(shows('현재 근무중'), isTrue);
      await finish(tester);
    });

    testWidgets('R7 a slow WORKING answer arriving after a clock-out does not reopen the shift on screen', timeout: timeout, (tester) async {
      final fake = install(working());
      final dynamic state = await open(tester, working());
      await pumpFor(tester, 500);
      fake.statusGate = Completer<void>();
      final gate = fake.statusGate!;
      unawaited(state.refreshAttendanceStatus());
      await tester.pump();
      await tapAndConfirm(tester, '퇴근하기');
      await pumpFor(tester, 800);
      expect(shows('퇴근 완료'), isTrue);
      gate.complete();
      await pumpFor(tester, 500);
      expect(shows('퇴근 완료'), isTrue);
      expect(shows('현재 근무중'), isFalse);
      await finish(tester);
    });

    testWidgets('R7 logout while a status answer is still on its way: the late answer is dropped safely', timeout: timeout, (tester) async {
      final fake = install(working());
      final dynamic state = await open(tester, working(), hosted: true);
      await pumpFor(tester, 500);
      fake.statusGate = Completer<void>();
      final gate = fake.statusGate!;
      unawaited(state.refreshAttendanceStatus());
      await tester.pump();
      await tester.ensureVisible(find.text('로그아웃'));
      await tester.tap(find.text('로그아웃'));
      await pumpFor(tester, 1000);
      expect(onWorkPage(), isFalse);
      gate.complete();
      await pumpFor(tester, 500);
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  });

  group('phase 3: retries and the success notice', () {
    Future<String?> failFirstClockOut(WidgetTester tester, FakeServer fake, String note) async {
      await tester.enterText(find.byType(TextField), note);
      fake.offline = true;
      await tapAndConfirm(tester, '퇴근하기');
      await pumpFor(tester, 3000);
      expect(shows('현재 근무중'), isTrue, reason: 'unconfirmed, so the shift is shown again');
      fake.offline = false;
      return storedIntentRequestId();
    }

    testWidgets('R5 note edited after a failed clock-out that the server never received: the new note is sent with a new requestId', timeout: timeout, (tester) async {
      final fake = install(working());
      await open(tester, working());
      await pumpFor(tester, 500);
      final firstId = await failFirstClockOut(tester, fake, 'A 메모');
      expect(firstId, isNotNull);
      await pumpFor(tester, 4000);
      await tester.enterText(find.byType(TextField), 'B 수정한 메모');
      await tapAndConfirm(tester, '퇴근하기');
      await pumpFor(tester, 1500);
      final sent = fake.of('clockOut');
      expect(sent.length, 1);
      expect(sent.single['note'], 'B 수정한 메모');
      expect(sent.single['requestId'], isNot(firstId));
      expect(sent.single['recordId'], 'employee_rec1');
      expect(shows('퇴근 성공!'), isTrue);
      await finish(tester);
    });

    testWidgets('R5 note edited after a clock-out the server DID save (answer lost): nothing new is sent and the app says the edit was not saved', timeout: timeout, (tester) async {
      final fake = install(working());
      await open(tester, working());
      await pumpFor(tester, 500);
      await tester.enterText(find.byType(TextField), 'A 메모');
      fake.clockOut = (body) { fake.status = completed(); fake.offline = true; throw http.ClientException('answer lost'); };
      await tapAndConfirm(tester, '퇴근하기');
      await pumpFor(tester, 3000);
      fake.offline = false;
      fake.clockOut = null;
      await pumpFor(tester, 4000);
      await tester.enterText(find.byType(TextField), 'B 수정한 메모');
      await tapAndConfirm(tester, '퇴근하기');
      var toast = false;
      for (var i = 0; i < 15; i++) { await tester.pump(const Duration(milliseconds: 100)); if (shows('퇴근 성공!')) toast = true; }
      expect(fake.of('clockOut').map((b) => b['note']).toList(), ['A 메모'], reason: 'no second clock-out request');
      expect(shows('이전 퇴근 요청이 이미 저장되어 수정한 특이사항은 반영되지 않았습니다.'), isTrue);
      expect(toast, isFalse);
      expect(shows('퇴근 완료'), isTrue);
      await finish(tester);
    });

    testWidgets('R5 note edited but the earlier result cannot be checked: nothing is sent, the requestId is kept and the app says so', timeout: timeout, (tester) async {
      final fake = install(working());
      await open(tester, working());
      await pumpFor(tester, 500);
      final firstId = await failFirstClockOut(tester, fake, 'A 메모');
      await pumpFor(tester, 4000);
      fake.offline = true;
      await tester.enterText(find.byType(TextField), 'B 수정한 메모');
      await tapAndConfirm(tester, '퇴근하기');
      await pumpFor(tester, 1500);
      expect(fake.of('clockOut'), isEmpty);
      expect(shows('이전 퇴근 요청 결과를 확인하지 못해 수정한 특이사항으로 보낼 수 없습니다. 잠시 후 다시 시도해 주세요.'), isTrue);
      expect(await storedIntentRequestId(), firstId);
      expect(shows('현재 근무중'), isTrue);
      expect(find.text('B 수정한 메모'), findsOneWidget, reason: 'the typed note stays');
      await finish(tester);
    });

    testWidgets('requestId idempotency: a retry with the same note reuses the same requestId and note', timeout: timeout, (tester) async {
      final fake = install(working());
      await open(tester, working());
      await pumpFor(tester, 500);
      final firstId = await failFirstClockOut(tester, fake, 'A 메모');
      await pumpFor(tester, 4000);
      await tapAndConfirm(tester, '퇴근하기');
      await pumpFor(tester, 1500);
      final sent = fake.of('clockOut').single;
      expect(sent['requestId'], firstId);
      expect(sent['note'], 'A 메모');
      await finish(tester);
    });

    testWidgets('R6 an old clock-out replayed (duplicate) while a new shift is open: no 퇴근 성공!, 근무중 and the note stay, the next tap is a new request', timeout: timeout, (tester) async {
      final fake = install(working());
      await open(tester, working());
      await pumpFor(tester, 500);
      await tester.enterText(find.byType(TextField), '메모');
      fake.clockOut = (body) => {'success': true, 'requestId': body['requestId'], 'duplicate': true, 'attendance': completed()};
      await tapAndConfirm(tester, '퇴근하기');
      var toast = false;
      for (var i = 0; i < 15; i++) { await tester.pump(const Duration(milliseconds: 100)); if (shows('퇴근 성공!')) toast = true; }
      expect(toast, isFalse);
      expect(shows('현재 근무중'), isTrue);
      expect(shows('이전 퇴근 요청은 이미 처리되어 있었습니다. 현재 근무중이니 퇴근하려면 다시 눌러 주세요.'), isTrue);
      expect(find.text('메모'), findsOneWidget);
      expect(enabled(tester, '퇴근하기'), isTrue);
      final firstId = fake.of('clockOut').single['requestId'];
      fake.clockOut = null;
      await pumpFor(tester, 4000);
      await tapAndConfirm(tester, '퇴근하기');
      await pumpFor(tester, 1000);
      expect(fake.of('clockOut').length, 2);
      expect(fake.of('clockOut').last['requestId'], isNot(firstId));
      expect(shows('퇴근 성공!'), isTrue, reason: 'a real save still shows the notice');
      await finish(tester);
    });

    testWidgets('R6 an old clock-in replayed (duplicate) after that shift already ended: no 출근 성공!, the screen follows the server', timeout: timeout, (tester) async {
      final fake = install({'status': 'NOT_IN'});
      await open(tester, {'status': 'NOT_IN'});
      fake.clockIn = (body) => {'success': true, 'requestId': body['requestId'], 'duplicate': true, 'attendance': working()};
      await tapAndConfirm(tester, '출근하기');
      var toast = false;
      for (var i = 0; i < 15; i++) { await tester.pump(const Duration(milliseconds: 100)); if (shows('출근 성공!')) toast = true; }
      expect(toast, isFalse);
      expect(shows('현재 미출근'), isTrue);
      expect(shows('이전 출근 요청은 이미 처리되어 있었습니다. 출근하려면 다시 눌러 주세요.'), isTrue);
      expect(enabled(tester, '출근하기'), isTrue);
      await finish(tester);
    });

    testWidgets('a normal clock-in then clock-out still shows both success notices and the server times', timeout: timeout, (tester) async {
      final fake = install({'status': 'NOT_IN'});
      await open(tester, {'status': 'NOT_IN'});
      await tapAndConfirm(tester, '출근하기');
      await pumpFor(tester, 600);
      expect(shows('출근 성공!'), isTrue);
      expect(shows('현재 근무중'), isTrue);
      await pumpFor(tester, 2500);
      await tapAndConfirm(tester, '퇴근하기');
      await pumpFor(tester, 600);
      expect(shows('퇴근 성공!'), isTrue);
      expect(shows('퇴근 완료'), isTrue);
      expect(shows('3시간 10분'), isTrue);
      expect(fake.of('clockOut').single['recordId'], 'employee_${fake.of('clockIn').single['requestId']}');
      await finish(tester);
    });

    testWidgets('a cancelled confirm dialog sends nothing and shows no notice', timeout: timeout, (tester) async {
      final fake = install({'status': 'NOT_IN'});
      await open(tester, {'status': 'NOT_IN'});
      await tester.tap(find.text('출근하기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('취소'));
      await pumpFor(tester, 1000);
      expect(fake.of('clockIn'), isEmpty);
      expect(shows('출근 성공!'), isFalse);
      expect(shows('현재 미출근'), isTrue);
      await finish(tester);
    });
  });
}
