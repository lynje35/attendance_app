import 'dart:convert';

import 'package:attendance_app/employee_server_preview.dart';
import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// 출근 성공! / 퇴근 성공! 알림: 서버가 저장 성공을 확정한 응답(clockIn / clockOut 의 success)에서만 뜬다.
// 취소, 서버 거절, 인증 실패, 네트워크 오류, 결과가 확정되지 않은 경우에는 뜨지 않고, 기존 실패 안내는 그대로다.
const _pin = '7391';
const _toast = ValueKey('attendance-success-toast');
final toastFinder = find.byKey(_toast);

Map<String, dynamic> working() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {'status': 'WORKING', 'recordId': 'employee_rec1', 'adjustedInText': '18:50', 'actualInMs': now - 3 * 3600000, 'serverNowMs': now, 'store': '매장1'};
}

Map<String, dynamic> completed() => {'status': 'COMPLETED', 'adjustedInText': '18:50', 'adjustedOutText': '22:00', 'workedText': '3시간 10분',
  'breakText': '0분', 'grossWorkedText': '3시간 10분', 'showBreak': false};

class Fake {
  Fake(this.status);
  Map<String, dynamic> status;
  bool offline = false;
  Map<String, dynamic> Function(Map<String, dynamic>)? clockIn, clockOut;
  final bodies = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> of(String action) => bodies.where((b) => b['action'] == action).toList();
}

Fake install(Map<String, dynamic> status) {
  final fake = Fake(status);
  employeeServerPreview = EmployeeServerPreview(
    endpoint: Uri.parse('http://test.invalid/employee/api'),
    client: MockClient((request) async {
      if (fake.offline) throw http.ClientException('offline');
      final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      fake.bodies.add(body);
      final Map<String, dynamic> reply = switch (body['action']) {
        'attendanceDiag' => {'success': true},
        'clockIn' => fake.clockIn?.call(body) ?? {'success': true, 'requestId': body['requestId'], 'duplicate': false, 'attendance': working()},
        'clockOut' => fake.clockOut?.call(body) ?? {'success': true, 'requestId': body['requestId'], 'duplicate': false, 'attendance': completed()},
        _ => {'success': true, 'attendance': fake.status},
      };
      return http.Response.bytes(utf8.encode(jsonEncode(reply)), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    }),
    // same wiring as main(): the request intent lives in the app's own secure storage
    read: (key) => secureStorage.read(key: key),
    write: (key, value) => secureStorage.write(key: key, value: value),
    remove: (key) => secureStorage.delete(key: key),
  );
  addTearDown(() => employeeServerPreview = null);
  return fake;
}

Future<dynamic> open(WidgetTester tester, Map<String, dynamic> status, {Size size = const Size(360, 800), double textScale = 1.0, bool themed = false}) async {
  FlutterSecureStorage.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(MaterialApp(
    theme: themed ? ThemeData(useMaterial3: true, fontFamilyFallback: const ['NotoSansKR']) : null,
    home: WorkPage(
      store: '매장1', employee: '직원', employeeId: 'toasttest', password: _pin, attendance: status,
      // the real login status call, so the preview learns the open record's id exactly as in production
      loginFuture: sendApiRequest({'action': 'status', 'employeeId': 'toasttest', 'password': _pin, 'selectedStore': '매장1'}),
      rememberDevice: false,
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100));
  return tester.state(find.byType(WorkPage));
}

Future<void> pumpFor(WidgetTester tester, int ms, {int step = 50}) async {
  for (var spent = 0; spent < ms; spent += step) { await tester.pump(Duration(milliseconds: step)); }
}

Future<void> tapAndAnswer(WidgetTester tester, String button, String answer) async {
  await tester.ensureVisible(find.text(button));
  await tester.pump();
  await tester.tap(find.text(button));
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text(answer)));
}

double toastOpacity(WidgetTester tester) => tester.widget<Opacity>(find.ancestor(of: toastFinder, matching: find.byType(Opacity)).first).opacity;

Future<void> finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 90)); // a successful clock-in / clock-out schedules follow-up checks
}

void main() {
  testWidgets('clock-in confirmed and saved by the server: 출근 성공! appears, in deep teal with a white check, and the screen shows 근무중', (tester) async {
    final fake = install({'status': 'NOT_IN'});
    await open(tester, {'status': 'NOT_IN'});
    await tapAndAnswer(tester, '출근하기', '확인');
    await pumpFor(tester, 600);
    expect(find.text('출근 성공!'), findsOneWidget);
    expect(find.text('퇴근 성공!'), findsNothing);
    expect(find.text('현재 근무중'), findsOneWidget);
    expect(fake.of('clockIn'), hasLength(1));
    final box = tester.widget<Container>(toastFinder).decoration! as BoxDecoration;
    expect([box.color, box.borderRadius], [const Color(0xFF187D76), BorderRadius.circular(16)]);
    final text = tester.widget<Text>(find.text('출근 성공!')).style!;
    expect([text.color, text.fontWeight], [Colors.white, FontWeight.w700]);
    final icon = tester.widget<Icon>(find.descendant(of: toastFinder, matching: find.byType(Icon)));
    expect([icon.icon, icon.color], [Icons.check_rounded, Colors.white]);
    await pumpFor(tester, 2500);
    expect(toastFinder, findsNothing);
    await finish(tester);
  });

  testWidgets('clock-out confirmed and saved: 퇴근 성공! appears and the note typed by the employee is still sent to the server', (tester) async {
    final fake = install(working());
    await open(tester, working());
    await tester.enterText(find.byType(TextField), '재고 정리');
    await tapAndAnswer(tester, '퇴근하기', '확인');
    await pumpFor(tester, 600);
    expect(find.text('퇴근 성공!'), findsOneWidget);
    expect(find.text('출근 성공!'), findsNothing);
    expect(find.text('퇴근 완료'), findsOneWidget);
    expect(fake.of('clockOut'), hasLength(1));
    expect(fake.of('clockOut').single['note'], '재고 정리');
    await pumpFor(tester, 2500);
    expect(toastFinder, findsNothing);
    await finish(tester);
  });

  for (final (label, status, button) in [('출근', {'status': 'NOT_IN'}, '출근하기'), ('퇴근', working(), '퇴근하기')]) {
    testWidgets('$label confirmation cancelled: no success notice, no request', (tester) async {
      final fake = install(status);
      await open(tester, status);
      await tapAndAnswer(tester, button, '취소');
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(toastFinder, findsNothing);
      }
      expect(fake.of('clockIn'), isEmpty); expect(fake.of('clockOut'), isEmpty);
      await finish(tester);
    });
  }

  testWidgets('a rejection from the server (already working / record changed): no success notice, the existing message is shown', (tester) async {
    final fake = install({'status': 'NOT_IN'});
    fake.clockIn = (_) => {'success': false, 'code': 'ALREADY_WORKING', 'message': '이미 근무 중입니다. 현재 상태를 다시 확인해 주세요.'};
    await open(tester, {'status': 'NOT_IN'});
    await tapAndAnswer(tester, '출근하기', '확인');
    for (var i = 0; i < 30; i++) { await tester.pump(const Duration(milliseconds: 100)); expect(toastFinder, findsNothing); }
    expect(find.text('이미 근무 중입니다. 현재 상태를 다시 확인해 주세요.'), findsOneWidget);
    await finish(tester);

    final fake2 = install(working());
    fake2.clockOut = (_) => {'success': false, 'code': 'RECORD_CHANGED', 'message': '퇴근할 기록이 변경되었습니다. 현재 상태를 다시 확인해 주세요.'};
    await open(tester, working());
    await tapAndAnswer(tester, '퇴근하기', '확인');
    for (var i = 0; i < 30; i++) { await tester.pump(const Duration(milliseconds: 100)); expect(toastFinder, findsNothing); }
    expect(find.text('퇴근할 기록이 변경되었습니다. 현재 상태를 다시 확인해 주세요.'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('authentication failure: no success notice, the existing message is shown', (tester) async {
    final fake = install({'status': 'NOT_IN'});
    fake.clockIn = (_) => {'success': false, 'code': 'INVALID_CREDENTIALS', 'message': '로그인 정보가 변경되었습니다. 다시 로그인해 주세요.'};
    await open(tester, {'status': 'NOT_IN'});
    await tapAndAnswer(tester, '출근하기', '확인');
    for (var i = 0; i < 30; i++) { await tester.pump(const Duration(milliseconds: 100)); expect(toastFinder, findsNothing); }
    expect(find.text('로그인 정보가 변경되었습니다. 다시 로그인해 주세요.'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('network failure: no success notice, the app still tells the employee it could not confirm the record', (tester) async {
    final fake = install({'status': 'NOT_IN'});
    await open(tester, {'status': 'NOT_IN'});
    fake.offline = true; // the connection drops after the login was verified
    await tapAndAnswer(tester, '출근하기', '확인');
    var sawMessage = false; // the existing message stays on screen for a few seconds and then goes by itself
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(toastFinder, findsNothing);
      if (find.text('기록 결과를 확인하지 못했습니다. 잠시 후 다시 눌러주세요.').evaluate().isNotEmpty) sawMessage = true;
    }
    expect(sawMessage, isTrue);
    await finish(tester);
  });

  testWidgets('an unclear answer (retryable) that a later status check shows as working: still no success notice - the app does not guess', (tester) async {
    final fake = install({'status': 'NOT_IN'});
    fake.clockIn = (_) {
      fake.status = working(); // the server did save it, but this answer says "try again"
      return {'success': false, 'retryable': true, 'code': 'TEMPORARY', 'message': '잠시 후 다시 확인해 주세요.'};
    };
    await open(tester, {'status': 'NOT_IN'});
    await tapAndAnswer(tester, '출근하기', '확인');
    for (var i = 0; i < 40; i++) { await tester.pump(const Duration(milliseconds: 100)); expect(toastFinder, findsNothing); }
    expect(find.text('현재 근무중'), findsOneWidget); // the existing check still updated the screen
    await finish(tester);
  });

  testWidgets('the server answered success for a request it had already saved (duplicate): that is a confirmed save, the notice shows', (tester) async {
    final fake = install({'status': 'NOT_IN'});
    fake.clockIn = (body) => {'success': true, 'requestId': body['requestId'], 'duplicate': true, 'attendance': working()};
    await open(tester, {'status': 'NOT_IN'});
    await tapAndAnswer(tester, '출근하기', '확인');
    await pumpFor(tester, 600);
    expect(find.text('출근 성공!'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('timing: fades in over 0.2 s, stays fully visible, starts fading at 1.7 s and is gone at 2.0 s', (tester) async {
    install({'status': 'NOT_IN'});
    final dynamic state = await open(tester, {'status': 'NOT_IN'});
    state.showAttendanceSuccessToast('출근 성공!');
    await tester.pump();
    expect(find.text('출근 성공!'), findsOneWidget);
    expect(toastOpacity(tester), lessThan(0.05)); // just starting
    await tester.pump(const Duration(milliseconds: 200));
    expect(toastOpacity(tester), greaterThan(0.99));
    await tester.pump(const Duration(milliseconds: 800)); // 1.0 s
    expect(toastOpacity(tester), 1.0);
    await tester.pump(const Duration(milliseconds: 650)); // 1.65 s
    expect(toastOpacity(tester), 1.0);
    await tester.pump(const Duration(milliseconds: 200)); // 1.85 s: halfway through the fade-out
    expect(toastOpacity(tester), allOf(greaterThan(0.05), lessThan(0.95)));
    await tester.pump(const Duration(milliseconds: 100)); // 1.95 s
    expect(toastOpacity(tester), lessThan(0.3));
    await tester.pump(const Duration(milliseconds: 100)); // 2.05 s
    expect(toastFinder, findsNothing);
    await finish(tester);
  });

  testWidgets('quick successive calls never stack: one notice on screen, showing the latest text, timer restarted', (tester) async {
    install({'status': 'NOT_IN'});
    final dynamic state = await open(tester, {'status': 'NOT_IN'});
    state.showAttendanceSuccessToast('출근 성공!');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1500));
    state.showAttendanceSuccessToast('퇴근 성공!');
    await tester.pump(const Duration(milliseconds: 100));
    expect(toastFinder, findsOneWidget);
    expect(find.text('퇴근 성공!'), findsOneWidget); expect(find.text('출근 성공!'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1500)); // 1.6 s after the second call, 3.1 s after the first: only a restart keeps it
    expect(toastFinder, findsOneWidget); expect(toastOpacity(tester), 1.0);
    await pumpFor(tester, 600);
    expect(toastFinder, findsNothing);
    await finish(tester);
  });

  testWidgets('an error message shown while the notice is on screen takes its place: the notice is removed, the message stays visible', (tester) async {
    final fake = install({'status': 'NOT_IN'});
    fake.clockIn = (_) => {'success': false, 'code': 'ALREADY_WORKING', 'message': '이미 근무 중입니다. 현재 상태를 다시 확인해 주세요.'};
    final dynamic state = await open(tester, {'status': 'NOT_IN'});
    state.showAttendanceSuccessToast('출근 성공!');
    await tester.pump();
    expect(toastFinder, findsOneWidget);
    await tapAndAnswer(tester, '출근하기', '확인');
    await pumpFor(tester, 1500);
    expect(toastFinder, findsNothing);
    expect(find.text('이미 근무 중입니다. 현재 상태를 다시 확인해 주세요.'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('the screen is closed while the notice is showing: no error, nothing left running', (tester) async {
    install({'status': 'NOT_IN'});
    final dynamic state = await open(tester, {'status': 'NOT_IN'});
    state.showAttendanceSuccessToast('출근 성공!');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  for (final (name, size, status) in [
    ('360x800', const Size(360, 800), {'status': 'NOT_IN'}),
    ('360x800 working', const Size(360, 800), working()),
    ('320x640', const Size(320, 640), {'status': 'NOT_IN'}),
    ('320x640 working', const Size(320, 640), working()),
  ]) {
    testWidgets('position at $name: exactly in the middle of the screen (both ways), inside the screen, and it never blocks a tap', (tester) async {
      install(status);
      final dynamic state = await open(tester, status, size: size);
      state.showAttendanceSuccessToast('출근 성공!');
      await pumpFor(tester, 300);
      final toast = tester.getRect(toastFinder);
      expect(toast.left, greaterThanOrEqualTo(0)); expect(toast.right, lessThanOrEqualTo(size.width)); expect(toast.bottom, lessThanOrEqualTo(size.height));
      expect(toast.center.dx, closeTo(size.width / 2, 1.0));
      // the middle of the body: from under the app bar to the bottom of the screen
      final bodyTop = tester.getRect(find.byType(AppBar)).bottom;
      expect(toast.center.dy, closeTo((bodyTop + size.height) / 2, 1.0));
      final ignoring = find.ancestor(of: toastFinder, matching: find.byWidgetPredicate((w) => w is IgnorePointer && w.ignoring));
      expect(ignoring, findsWidgets);
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  }

  testWidgets('the notice sits over the middle of the content, yet a tap on a button under it still goes through to the button', (tester) async {
    install({'status': 'NOT_IN'});
    final dynamic state = await open(tester, {'status': 'NOT_IN'}, size: const Size(360, 640)); // here the middle of the screen is where 출근하기 is
    state.showAttendanceSuccessToast('출근 성공!');
    await pumpFor(tester, 300);
    final button = tester.getRect(find.ancestor(of: find.text('출근하기'), matching: find.byType(FilledButton)).first);
    expect(tester.getRect(toastFinder).overlaps(button), isTrue); // really covering it
    await tester.tap(find.text('출근하기'));
    await tester.pumpAndSettle();
    expect(find.text('출근하시겠습니까?'), findsOneWidget); // the button received the tap
    await tester.tap(find.widgetWithText(TextButton, '취소'));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('320 px wide with larger text: no overflow and the Korean fallback font reaches the notice', (tester) async {
    install({'status': 'NOT_IN'});
    final dynamic state = await open(tester, {'status': 'NOT_IN'}, size: const Size(320, 640), textScale: 1.3, themed: true);
    state.showAttendanceSuccessToast('퇴근 성공!');
    await pumpFor(tester, 300);
    final toast = tester.getRect(toastFinder);
    expect(toast.left, greaterThanOrEqualTo(0)); expect(toast.right, lessThanOrEqualTo(320));
    expect(DefaultTextStyle.of(tester.element(find.text('퇴근 성공!'))).style.fontFamilyFallback, contains('NotoSansKR'));
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
}
