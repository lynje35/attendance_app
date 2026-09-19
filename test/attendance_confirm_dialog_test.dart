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
}
