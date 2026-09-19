import 'dart:async';

import 'package:attendance_app/calculator_page.dart';
import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('tapping the calculator menu item on the work page opens CalculatorPage', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final login = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(MaterialApp(
      home: WorkPage(
        store: 'test', employee: 'test', employeeId: 'test',
        password: '0000', attendance: {'status': 'WORKING'},
        loginFuture: login.future, rememberDevice: false,
      ),
    ));
    await tester.pump();
    final calculatorButton = find.text('계산기');
    await tester.ensureVisible(calculatorButton);
    await tester.pump();
    await tester.tap(calculatorButton);
    await tester.pumpAndSettle();
    expect(find.byType(CalculatorPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('workedTextToMinutes parses hours and minutes, e.g. 86 hours 30 minutes', () {
    expect(workedTextToMinutes('86시간 30분'), 86 * 60 + 30);
    expect(workedTextToMinutes('0시간 0분'), 0);
    expect(workedTextToMinutes(''), 0);
  });

  test('formatWon adds thousands separators', () {
    expect(formatWon(0), '0');
    expect(formatWon(999), '999');
    expect(formatWon(1000), '1,000');
    expect(formatWon(1234567), '1,234,567');
  });

  testWidgets('shows total worked time from current-month records and computes 3.3%-deducted pay', (tester) async {
    final savedWages = <String>[];
    await tester.pumpWidget(MaterialApp(home: CalculatorPage(
      loadCurrentMonthCalendar: () async => {
        'success': true,
        'records': [
          {'workedText': '80시간 0분'},
          {'workedText': '6시간 30분'},
          {'workedText': ''},
        ],
      },
      readSavedWage: () async => null,
      saveWage: (value) async => savedWages.add(value),
    )));
    await tester.pumpAndSettle();

    expect(find.text('현재 총 근무 시간: 86시간 30분'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '10000');
    await tester.pumpAndSettle();

    // A = 86.5h * 10000 = 865000, deduction = 865000*0.033 = 28545, net = 836455
    expect(find.text('836,455원'), findsOneWidget);
    expect(savedWages.last, '10000');
  });

  testWidgets('prefills a previously saved wage and clears it when the field is emptied', (tester) async {
    final savedWages = <String>[];
    await tester.pumpWidget(MaterialApp(home: CalculatorPage(
      loadCurrentMonthCalendar: () async => {'success': true, 'records': <Map<String, dynamic>>[]},
      readSavedWage: () async => '9860',
      saveWage: (value) async => savedWages.add(value),
    )));
    await tester.pumpAndSettle();

    expect((tester.widget(find.byType(TextField)) as TextField).controller!.text, '9860');

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(savedWages.last, '');
  });

  testWidgets('shows the load error message instead of a total when the fetch fails', (tester) async {
    await tester.pumpWidget(MaterialApp(home: CalculatorPage(
      loadCurrentMonthCalendar: () async => {'success': false, 'message': '접근 불가'},
      readSavedWage: () async => null,
      saveWage: (_) async {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('접근 불가'), findsOneWidget);
    expect(find.textContaining('현재 총 근무 시간'), findsNothing);
  });

  testWidgets('shows the fixed guidance text, warning, and call contact', (tester) async {
    await tester.pumpWidget(MaterialApp(home: CalculatorPage(
      loadCurrentMonthCalendar: () async => {'success': true, 'records': <Map<String, dynamic>>[]},
      readSavedWage: () async => null,
      saveWage: (_) async {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('자동으로 3.3% 계산이 돼요.'), findsOneWidget);
    expect(find.text('월급은 매월 10일에 지급돼요'), findsOneWidget);
    expect(find.text('(주말이나 공휴일 껴있는 경우 10일 전후 2일 정도 차이 날 수 있어요.)'), findsOneWidget);
    expect(find.text('본인 외 다른 직원에게 보여주지 마세요'), findsOneWidget);
    expect(find.text('문의: 01097465633'), findsOneWidget);
    expect(find.byIcon(Icons.call), findsOneWidget);
  });
}
