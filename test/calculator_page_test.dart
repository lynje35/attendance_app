import 'dart:async';

import 'package:attendance_app/calculator_page.dart';
import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

// Fixed "current" month used by most tests below, matching the CalculatorPage.now contract
// (server-corrected clock) without depending on the real wall clock.
final _now = DateTime(2026, 10, 15);

Map<String, dynamic> _monthData(List<String> workedTexts) => {
  'success': true,
  'records': [for (final t in workedTexts) {'workedText': t}],
};

Widget _page({
  required Future<Map<String, dynamic>> Function(int year, int month) loadMonthCalendar,
  DateTime? initialMonth,
  DateTime? now,
  Future<String?> Function()? readSavedWage,
  Future<void> Function(String)? saveWage,
}) => MaterialApp(home: CalculatorPage(
  loadMonthCalendar: loadMonthCalendar,
  initialMonth: initialMonth ?? _now,
  now: now ?? _now,
  readSavedWage: readSavedWage ?? (() async => null),
  saveWage: saveWage ?? ((_) async {}),
));

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

  testWidgets('shows total worked time from the selected month and computes 3.3%-deducted pay', (tester) async {
    final savedWages = <String>[];
    await tester.pumpWidget(_page(
      loadMonthCalendar: (year, month) async => _monthData(['80시간 0분', '6시간 30분', '']),
      saveWage: (value) async => savedWages.add(value),
    ));
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
    await tester.pumpWidget(_page(
      loadMonthCalendar: (year, month) async => _monthData([]),
      readSavedWage: () async => '9860',
      saveWage: (value) async => savedWages.add(value),
    ));
    await tester.pumpAndSettle();

    expect((tester.widget(find.byType(TextField)) as TextField).controller!.text, '9860');

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(savedWages.last, '');
  });

  testWidgets('shows the load error message instead of a total when the fetch fails', (tester) async {
    await tester.pumpWidget(_page(
      loadMonthCalendar: (year, month) async => {'success': false, 'message': '접근 불가'},
    ));
    await tester.pumpAndSettle();

    expect(find.text('접근 불가'), findsOneWidget);
    expect(find.textContaining('현재 총 근무 시간'), findsNothing);
    // The month selector itself must still be usable after a failed load.
    expect(find.text('2026년 10월'), findsOneWidget);
  });

  testWidgets('shows the fixed guidance text, warning, and call contact', (tester) async {
    await tester.pumpWidget(_page(
      loadMonthCalendar: (year, month) async => _monthData([]),
    ));
    await tester.pumpAndSettle();

    expect(find.text('자동으로 3.3% 계산이 돼요.'), findsOneWidget);
    expect(find.text('월급은 매월 10일에 지급돼요'), findsOneWidget);
    expect(find.text('(주말이나 공휴일 껴있는 경우 10일 전후 2일 정도 차이 날 수 있어요.)'), findsOneWidget);
    expect(find.text('본인 외 다른 직원에게 보여주지 마세요'), findsOneWidget);
    expect(find.text('문의: 01097465633'), findsOneWidget);
    expect(find.byIcon(Icons.call), findsOneWidget);
  });

  group('월별 근무시간 선택', () {
    testWidgets('shows the initial month next to the total on entry', (tester) async {
      await tester.pumpWidget(_page(
        initialMonth: DateTime(2026, 9),
        loadMonthCalendar: (year, month) async => _monthData([]),
      ));
      await tester.pumpAndSettle();
      expect(find.text('2026년 9월'), findsOneWidget);
    });

    testWidgets('defaults to the current month when no other month is passed in', (tester) async {
      await tester.pumpWidget(_page(
        loadMonthCalendar: (year, month) async => _monthData([]),
      ));
      await tester.pumpAndSettle();
      expect(find.text('2026년 10월'), findsOneWidget);
    });

    testWidgets('picking a different month loads and displays that month\'s total', (tester) async {
      final requestedMonths = <String>[];
      await tester.pumpWidget(_page(
        loadMonthCalendar: (year, month) async {
          requestedMonths.add('$year-$month');
          return _monthData(month == 9 ? ['126시간 30분'] : ['38시간 20분']);
        },
      ));
      await tester.pumpAndSettle();
      expect(find.text('현재 총 근무 시간: 38시간 20분'), findsOneWidget);

      await tester.tap(find.text('2026년 10월'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('9월'));
      await tester.pumpAndSettle();

      expect(find.text('2026년 9월'), findsOneWidget);
      expect(find.text('현재 총 근무 시간: 126시간 30분'), findsOneWidget);
      expect(requestedMonths, ['2026-10', '2026-9']);
    });

    testWidgets('a month with zero worked minutes shows 0시간 correctly', (tester) async {
      await tester.pumpWidget(_page(
        loadMonthCalendar: (year, month) async => _monthData([]),
      ));
      await tester.pumpAndSettle();
      expect(find.text('현재 총 근무 시간: 0시간'), findsOneWidget);
    });

    testWidgets('minutes are shown in the existing format when present', (tester) async {
      await tester.pumpWidget(_page(
        loadMonthCalendar: (year, month) async => _monthData(['3시간 5분']),
      ));
      await tester.pumpAndSettle();
      expect(find.text('현재 총 근무 시간: 3시간 5분'), findsOneWidget);
    });

    testWidgets('changing month recomputes 예상 실 지급액 from the new total', (tester) async {
      await tester.pumpWidget(_page(
        loadMonthCalendar: (year, month) async => _monthData(month == 9 ? ['100시간 0분'] : ['10시간 0분']),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '10000');
      await tester.pumpAndSettle();
      // 10h * 10000 * 0.967 = 96700
      expect(find.text('96,700원'), findsOneWidget);

      await tester.tap(find.text('2026년 10월'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('9월'));
      await tester.pumpAndSettle();

      // 100h * 10000 * 0.967 = 967000
      expect(find.text('967,000원'), findsOneWidget);
    });

    testWidgets('the hourly wage stays the same across a month change', (tester) async {
      await tester.pumpWidget(_page(
        loadMonthCalendar: (year, month) async => _monthData([]),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '12345');
      await tester.pumpAndSettle();

      await tester.tap(find.text('2026년 10월'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('9월'));
      await tester.pumpAndSettle();

      expect((tester.widget(find.byType(TextField)) as TextField).controller!.text, '12345');
    });

    testWidgets('open (미퇴근) shifts follow the same 근무기록 rule: workedText is empty and contributes 0', (tester) async {
      // The calendar API never sends a workedText for an open shift (see lib/main.dart
      // _buildCalendar/_recordsByDay), so an empty string must not be parsed as a real duration.
      await tester.pumpWidget(_page(
        loadMonthCalendar: (year, month) async => _monthData(['5시간 0분', '']),
      ));
      await tester.pumpAndSettle();
      expect(find.text('현재 총 근무 시간: 5시간'), findsOneWidget);
    });

    testWidgets('a stale response for an abandoned month never overwrites the latest selection', (tester) async {
      final septemberGate = Completer<void>();
      await tester.pumpWidget(_page(
        loadMonthCalendar: (year, month) async {
          if (month == 9) {
            await septemberGate.future; // September resolves last, after October already replaced it.
            return _monthData(['1시간 0분']);
          }
          return _monthData(['38시간 20분']);
        },
      ));
      await tester.pumpAndSettle();

      // September's own load is gated (never resolves yet), so its indeterminate loading
      // spinner keeps scheduling frames from here on — pumpAndSettle would hang on it, so
      // every step until the gate is released below uses bounded pump()s instead.
      await tester.tap(find.text('2026년 10월'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('9월')); // triggers the slow September request
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300)); // let the dialog's close animation finish
      await tester.tap(find.text('2026년 9월'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300)); // let the reopened dialog's entrance animation finish
      await tester.tap(find.text('10월')); // then immediately switches back to October
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300)); // let October's (ungated) load and the close animation finish

      expect(find.text('2026년 10월'), findsOneWidget);
      expect(find.text('현재 총 근무 시간: 38시간 20분'), findsOneWidget);

      septemberGate.complete();
      await tester.pumpAndSettle();

      // The late September response must not retroactively overwrite the October total.
      expect(find.text('2026년 10월'), findsOneWidget);
      expect(find.text('현재 총 근무 시간: 38시간 20분'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('months before the earliest work month or after the current month cannot be picked', (tester) async {
      await tester.pumpWidget(_page(
        initialMonth: DateTime(2026, 8),
        now: DateTime(2026, 8, 20),
        loadMonthCalendar: (year, month) async => _monthData([]),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('2026년 8월'));
      await tester.pumpAndSettle();
      // August 2026 is both the floor and the current month: every other month cell is disabled,
      // and neither year chevron can move.
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_left)).onPressed, isNull);
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_right)).onPressed, isNull);
      InkWell monthInkWell(String label) => tester.widget<InkWell>(find.ancestor(of: find.text(label), matching: find.byType(InkWell)));
      expect(monthInkWell('7월').onTap, isNull);
      expect(monthInkWell('9월').onTap, isNull);
      // The current month itself is still pickable (re-selecting it is a no-op, not disabled).
      expect(monthInkWell('8월').onTap, isNotNull);
    });

    testWidgets('month cells form an exact 3x4 grid with identical size, and selecting a month does not distort it', (tester) async {
      await tester.pumpWidget(_page(
        initialMonth: DateTime(2026, 1),
        loadMonthCalendar: (year, month) async => _monthData([]),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2026년 1월'));
      await tester.pumpAndSettle();

      Finder cellOf(String label) => find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first;
      Size cellSize(String label) => tester.getSize(cellOf(label));
      Offset cellTopLeft(String label) => tester.getTopLeft(cellOf(label));

      const months = ['1월', '2월', '3월', '4월', '5월', '6월', '7월', '8월', '9월', '10월', '11월', '12월'];
      final reference = cellSize('1월');
      for (final label in months) {
        final size = cellSize(label);
        expect(size.width, closeTo(reference.width, 0.5), reason: label);
        expect(size.height, closeTo(reference.height, 0.5), reason: label);
      }

      // 3 columns x 4 rows, in reading order: 1~3월 share a row, 4월 starts the next one
      // directly under 1월, and so on down to 10~12월.
      expect(cellTopLeft('1월').dy, cellTopLeft('2월').dy);
      expect(cellTopLeft('2월').dy, cellTopLeft('3월').dy);
      expect(cellTopLeft('1월').dx, closeTo(cellTopLeft('4월').dx, 0.5));
      expect(cellTopLeft('4월').dy, greaterThan(cellTopLeft('1월').dy));
      expect(cellTopLeft('10월').dy, cellTopLeft('11월').dy);
      expect(cellTopLeft('11월').dy, cellTopLeft('12월').dy);

      // Selecting a different month (which turns its check mark on) must not resize or
      // reposition any cell, including the newly- and previously-selected ones.
      await tester.tap(find.text('10월'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2026년 10월'));
      await tester.pumpAndSettle();
      for (final label in ['1월', '9월', '10월', '12월']) {
        final size = cellSize(label);
        expect(size.width, closeTo(reference.width, 0.5), reason: label);
        expect(size.height, closeTo(reference.height, 0.5), reason: label);
      }
      expect(cellTopLeft('10월').dy, cellTopLeft('11월').dy);
      expect(tester.takeException(), isNull);
    });

    testWidgets('mobile width (320px): the total and the month selector fit on one line without overflow', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_page(
        loadMonthCalendar: (year, month) async => _monthData(['126시간 30분']),
      ));
      await tester.pumpAndSettle();
      expect(find.text('현재 총 근무 시간: 126시간 30분'), findsOneWidget);
      expect(find.text('2026년 10월'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('2026년 10월'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
