import 'dart:async';
import 'dart:convert';

import 'package:attendance_app/employee_server_preview.dart';
import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<void> openWorkPage(WidgetTester tester, String status, {Future<Map<String, dynamic>>? loginFuture}) async {
  FlutterSecureStorage.setMockInitialValues({});
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    home: WorkPage(
      store: 'test', employee: 'test', employeeId: 'test',
      password: '0000', attendance: {'status': status},
      loginFuture: loginFuture ?? Completer<Map<String, dynamic>>().future, rememberDevice: false,
    ),
  ));
  await tester.pump();
}

void expectCenteredQuestion(WidgetTester tester, String question) {
  final dialog = find.byType(AlertDialog);
  expect(dialog, findsOneWidget);
  expect(tester.widget<AlertDialog>(dialog).title, isNull);
  expect(find.descendant(of: dialog, matching: find.text('확인')), findsOneWidget);
  expect(find.descendant(of: dialog, matching: find.text('취소')), findsOneWidget);
  final question0 = find.descendant(of: dialog, matching: find.text(question));
  expect(question0, findsOneWidget);
  expect(tester.widget<Text>(question0).textAlign, TextAlign.center);
  final paragraph = tester.renderObject<RenderParagraph>(question0);
  final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: question.length));
  final left = boxes.first.left, right = paragraph.size.width - boxes.last.right;
  expect(left, greaterThan(1));
  expect((left - right).abs(), lessThan(1.5));

  // The 취소/확인 pair is centered on the same axis as the question (the content spans the dialog width).
  final cancel = tester.getRect(find.widgetWithText(TextButton, '취소'));
  final confirm = tester.getRect(find.widgetWithText(FilledButton, '확인'));
  expect(cancel.left, lessThan(confirm.left));
  expect(((cancel.left + confirm.right) / 2 - tester.getCenter(question0).dx).abs(), lessThan(1.0));
  final gap = confirm.left - cancel.right;
  expect(gap, inInclusiveRange(4, 24));
}

void main() {
  testWidgets('clock-in confirmation has no title and the question is centered; cancel closes it', (tester) async {
    await openWorkPage(tester, 'NOT_IN');
    await tester.ensureVisible(find.text('출근하기'));
    await tester.pump();
    await tester.tap(find.text('출근하기'));
    await tester.pumpAndSettle();
    expectCenteredQuestion(tester, '출근하시겠습니까?');
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('취소')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('cancelling clock-in re-enables the button even if the page rebuilt while the dialog was open, and calls no API', (tester) async {
    final actions = <String>[];
    employeeServerPreview = EmployeeServerPreview(
      endpoint: Uri.parse('http://test.invalid/employee/api'),
      client: MockClient((request) async {
        actions.add(jsonDecode(request.body)['action'] as String);
        return http.Response(jsonEncode({'success': false}), 200);
      }),
      read: (_) async => null,
      write: (_, _) async {},
      remove: (_) async {},
    );
    addTearDown(() => employeeServerPreview = null);

    final login = Completer<Map<String, dynamic>>();
    await openWorkPage(tester, 'NOT_IN', loginFuture: login.future);
    FilledButton clockIn() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, '출근하기'));
    expect(clockIn().onPressed, isNotNull);

    await tester.ensureVisible(find.text('출근하기'));
    await tester.pump();
    await tester.tap(find.text('출근하기'));
    await tester.pumpAndSettle();
    expect(find.text('출근하시겠습니까?'), findsOneWidget);

    // Login verification finishing while the dialog is open rebuilds the page with the queued flag set.
    login.complete({'success': true, 'attendance': {'status': 'NOT_IN'}});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(clockIn().onPressed, isNull);

    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('취소')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(clockIn().onPressed, isNotNull);
    expect(actions.where((a) => a == 'clockIn' || a == 'clockOut'), isEmpty);
    expect(actions, isNot(contains('status')));
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('clock-out confirmation has the same title-less centered style; cancel closes it', (tester) async {
    await openWorkPage(tester, 'WORKING');
    await tester.ensureVisible(find.text('퇴근하기'));
    await tester.pump();
    await tester.tap(find.text('퇴근하기'));
    await tester.pumpAndSettle();
    expectCenteredQuestion(tester, '퇴근하시겠습니까?');
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('취소')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  // ---- deep teal look of the two confirmation dialogs (clock-in / clock-out): colors, corners, buttons - and nothing but the question and two buttons
  final dialogCases = [
    ('NOT_IN', '출근하기', '출근하시겠습니까?'),
    ('WORKING', '퇴근하기', '퇴근하시겠습니까?'),
  ];
  for (final (status, button, question) in dialogCases) {
    testWidgets('$question dialog: white rounded card, bold dark question, mint cancel / deep teal confirm, nothing else, dimmed background', (tester) async {
      await openWorkPage(tester, status);
      await tester.ensureVisible(find.text(button));
      await tester.pump();
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
      expect(dialog.backgroundColor, Colors.white);
      expect(dialog.surfaceTintColor, Colors.transparent);
      expect((dialog.shape! as RoundedRectangleBorder).borderRadius, BorderRadius.circular(20));
      expect(dialog.title, isNull);
      final q = tester.widget<Text>(find.text(question)).style!;
      expect([q.color, q.fontWeight, q.fontSize], [const Color(0xFF25282B), FontWeight.w700, 18.0]);
      // cancel on the left: mint background, deep teal text. confirm on the right: deep teal background, white text.
      final cancel = tester.widget<TextButton>(find.widgetWithText(TextButton, '취소')).style!;
      final confirm = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '확인')).style!;
      const none = <WidgetState>{};
      expect([cancel.backgroundColor!.resolve(none), cancel.foregroundColor!.resolve(none)], [const Color(0xFFD7EBE8), const Color(0xFF0F5F59)]);
      expect([confirm.backgroundColor!.resolve(none), confirm.foregroundColor!.resolve(none)], [const Color(0xFF187D76), Colors.white]);
      final cancelRect = tester.getRect(find.widgetWithText(TextButton, '취소')), confirmRect = tester.getRect(find.widgetWithText(FilledButton, '확인'));
      expect(cancelRect.left, lessThan(confirmRect.left));
      expect(cancelRect.height, greaterThanOrEqualTo(48)); expect(confirmRect.height, greaterThanOrEqualTo(48));
      // only the question and the two button labels - no extra explanation
      final texts = tester.widgetList<Text>(find.descendant(of: find.byType(AlertDialog), matching: find.byType(Text))).map((t) => t.data).toList();
      expect(texts, [question, '취소', '확인']);
      expect(find.text('지금 출근 시간을 기록합니다.'), findsNothing); expect(find.text('지금 퇴근 시간을 기록합니다.'), findsNothing);
      // the screen behind is dimmed
      expect(tester.widgetList<ModalBarrier>(find.byType(ModalBarrier)).any((b) => b.color != null && b.color!.a > 0), isTrue);
      await tester.tap(find.widgetWithText(TextButton, '취소'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('$question dialog on a 320px phone with larger text: no overflow, both buttons inside the screen, cancel left of confirm', (tester) async {
      await openWorkPage(tester, status);
      tester.view.physicalSize = const Size(320, 640);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pump();
      await tester.ensureVisible(find.text(button));
      await tester.pump();
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      expect(find.text(question), findsOneWidget);
      for (final finder in [find.widgetWithText(TextButton, '취소'), find.widgetWithText(FilledButton, '확인')]) {
        final r = tester.getRect(finder);
        expect(r.left, greaterThanOrEqualTo(0)); expect(r.right, lessThanOrEqualTo(320)); expect(r.height, greaterThanOrEqualTo(48));
      }
      expect(tester.getRect(find.widgetWithText(TextButton, '취소')).left, lessThan(tester.getRect(find.widgetWithText(FilledButton, '확인')).left));
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(TextButton, '취소'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('confirming still sends the request, cancelling still sends nothing (clock-in)', (tester) async {
    final actions = <String>[];
    employeeServerPreview = EmployeeServerPreview(
      endpoint: Uri.parse('http://test.invalid/employee/api'),
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        actions.add(body['action'] as String);
        return http.Response.bytes(utf8.encode(jsonEncode({'success': true, 'attendance': {'status': 'NOT_IN'}})), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }),
      // same wiring as main(): the request intent is kept in the app's own secure storage and read back before the request is sent
      read: (key) => secureStorage.read(key: key),
      write: (key, value) => secureStorage.write(key: key, value: value),
      remove: (key) => secureStorage.delete(key: key),
    );
    addTearDown(() => employeeServerPreview = null);
    await openWorkPage(tester, 'NOT_IN', loginFuture: Future.value({'success': true, 'attendance': {'status': 'NOT_IN'}}));
    await tester.pump(const Duration(milliseconds: 100));
    actions.clear();
    await tester.ensureVisible(find.text('출근하기'));
    await tester.pump();
    await tester.tap(find.text('출근하기'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '취소'));
    await tester.pumpAndSettle();
    expect(actions, isNot(contains('clockIn'))); // cancelling asked the server for no clock-in
    await tester.tap(find.text('출근하기'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '확인'));
    for (var i = 0; i < 10; i++) { await tester.pump(const Duration(milliseconds: 100)); }
    expect(find.byType(AlertDialog), findsNothing);
    expect(actions, contains('clockIn')); // confirming runs the same request as before
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 90)); // a successful clock-in schedules its follow-up checks 20 s later: let them run out
  });

  testWidgets('the app Korean fallback font reaches the question and both buttons of the dialog (needed for the iPhone web app)', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true, fontFamilyFallback: const ['NotoSansKR']),
      home: WorkPage(store: 'test', employee: 'test', employeeId: 'test', password: '0000', attendance: const {'status': 'NOT_IN'},
        loginFuture: Completer<Map<String, dynamic>>().future, rememberDevice: false),
    ));
    await tester.pump();
    await tester.ensureVisible(find.text('출근하기'));
    await tester.pump();
    await tester.tap(find.text('출근하기'));
    await tester.pumpAndSettle();
    for (final text in ['출근하시겠습니까?', '취소', '확인']) {
      final style = DefaultTextStyle.of(tester.element(find.descendant(of: find.byType(AlertDialog), matching: find.text(text)))).style;
      expect(style.fontFamilyFallback, contains('NotoSansKR'), reason: text);
    }
    await tester.tap(find.widgetWithText(TextButton, '취소'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
