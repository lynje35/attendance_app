import 'dart:async';

import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

// 출퇴근 관리 메인 화면 레이아웃: 매장 카드, 오늘의 근무 상태 카드, 출근·퇴근(세로), 근무기록|계산기(가로 2열), 비밀번호 변경|로그아웃(가로 2열).
// 버튼의 활성 조건과 문구는 그대로이고, 화면이 좁아도 잘리거나 넘치지 않으며 스크롤이 적은지를 확인합니다.
final _now = DateTime.now().millisecondsSinceEpoch;
final Map<String, Map<String, dynamic>> attendances = {
  'NOT_IN': {'status': 'NOT_IN'},
  'WORKING': {'status': 'WORKING', 'recordId': 'employee_rec1', 'adjustedInText': '17:30', 'actualInMs': _now - 3 * 3600000, 'serverNowMs': _now},
  'COMPLETED': {'status': 'COMPLETED', 'adjustedInText': '09:00', 'adjustedOutText': '18:00', 'workedText': '8시간 0분', 'breakText': '1시간 0분',
    'grossWorkedText': '9시간 0분', 'showBreak': true},
  'VERIFYING': {'status': 'VERIFYING'},
};

Future<dynamic> open(WidgetTester tester, String status, {Size size = const Size(360, 800), String store = '제로백', String employee = '김린제', double textScale = 1.0}) async {
  FlutterSecureStorage.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(MaterialApp(theme: ThemeData(useMaterial3: true, fontFamilyFallback: const ['NotoSansKR']), home: WorkPage(
    store: store, employee: employee, employeeId: 'layout', password: '0000', attendance: attendances[status]!,
    loginFuture: Completer<Map<String, dynamic>>().future, rememberDevice: status != 'VERIFYING',
  )));
  await tester.pump(const Duration(milliseconds: 50));
  return tester.state(find.byType(WorkPage));
}

Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
}

Rect rectOf(WidgetTester tester, Finder f) => tester.getRect(f);
bool pressable(WidgetTester tester, Finder button) => (tester.widget(button) as dynamic).onPressed != null;
Finder button(String label) => find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));
double scrollExtent(WidgetTester tester) => tester.state<ScrollableState>(find.byType(Scrollable).first).position.maxScrollExtent;

void main() {
  testWidgets('NOT_IN: store card, status card, both clock buttons stacked, two columns of actions below - and nothing to scroll on a normal phone', (tester) async {
    await open(tester, 'NOT_IN');
    expect(find.text('출퇴근 관리'), findsOneWidget);
    expect(find.text('제로백'), findsOneWidget); expect(find.text('김린제'), findsOneWidget);
    expect(find.text('현재 미출근'), findsOneWidget);
    expect(find.text('출근 시간'), findsOneWidget); expect(find.text('퇴근 시간'), findsOneWidget); expect(find.text('-'), findsNWidgets(2));
    // no arrow on the store card: the card does nothing, so it must not look like it does
    for (final icon in [Icons.chevron_right, Icons.arrow_forward_ios, Icons.arrow_forward, Icons.keyboard_arrow_right, Icons.navigate_next]) {
      expect(find.byIcon(icon), findsNothing, reason: '$icon');
    }
    // clock buttons: full width, one under the other; only 출근하기 is usable before the first clock-in
    final clockIn = rectOf(tester, button('출근하기')), clockOut = rectOf(tester, button('퇴근하기'));
    expect(clockIn.left, clockOut.left); expect(clockIn.width, clockOut.width); expect(clockIn.bottom, lessThan(clockOut.top));
    expect(pressable(tester, button('출근하기')), isTrue); expect(pressable(tester, button('퇴근하기')), isFalse);
    expect(clockIn.height, greaterThanOrEqualTo(56)); expect(clockOut.height, greaterThanOrEqualTo(56));
    // 근무기록 | 계산기 side by side, then 비밀번호 변경 | 로그아웃 side by side below them
    final history = rectOf(tester, button('근무기록')), calculator = rectOf(tester, button('계산기'));
    expect(history.top, calculator.top); expect(history.right, lessThan(calculator.left)); expect(history.top, greaterThan(clockOut.bottom));
    final password = rectOf(tester, button('비밀번호 변경')), logout = rectOf(tester, button('로그아웃'));
    expect(password.top, logout.top); expect(password.right, lessThan(logout.left)); expect(password.top, greaterThan(history.bottom));
    for (final r in [history, calculator, password, logout]) { expect(r.height, greaterThanOrEqualTo(48)); } // touch targets
    for (final label in ['근무기록', '계산기', '비밀번호 변경', '로그아웃']) { expect(pressable(tester, button(label)), isTrue, reason: label); }
    expect(scrollExtent(tester), 0.0); // everything fits on a 360x800 phone
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('the app Korean fallback font reaches every kind of text on the screen (the title, a card, a tile, a button) - needed for the iPhone web app', (tester) async {
    await open(tester, 'NOT_IN');
    for (final text in ['출퇴근 관리', '제로백', '출근 시간', '출근하기', '근무기록', '로그아웃']) {
      final style = DefaultTextStyle.of(tester.element(find.text(text))).style;
      expect(style.fontFamilyFallback, contains('NotoSansKR'), reason: text);
    }
    await close(tester);
  });

  testWidgets('WORKING: status, clock-in time, live work time and the note field; 퇴근하기 is the usable button', (tester) async {
    await open(tester, 'WORKING');
    expect(find.text('현재 근무중'), findsOneWidget);
    expect(find.text('17:30'), findsOneWidget); // the rounded clock-in time, exactly as the server gave it
    expect(find.text('현재 근무시간'), findsOneWidget);
    expect(find.text('특이사항 (선택)'), findsOneWidget);
    expect(pressable(tester, button('출근하기')), isFalse); expect(pressable(tester, button('퇴근하기')), isTrue);
    expect(rectOf(tester, button('근무기록')).top, rectOf(tester, button('계산기')).top);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('COMPLETED: worked time, break, gross time and the hint; 출근하기 is usable again', (tester) async {
    await open(tester, 'COMPLETED');
    expect(find.text('퇴근 완료'), findsOneWidget);
    expect(find.text('오늘 근무시간'), findsOneWidget); expect(find.text('8시간 0분'), findsOneWidget);
    expect(find.text('09:00'), findsOneWidget); expect(find.text('18:00'), findsOneWidget);
    expect(find.text('휴게시간'), findsOneWidget); expect(find.text('1시간 0분'), findsOneWidget);
    expect(find.text('총근무시간'), findsOneWidget); expect(find.text('9시간 0분'), findsOneWidget);
    expect(find.text('출근하기 버튼은 바로 사용할 수 있습니다.'), findsOneWidget);
    expect(pressable(tester, button('출근하기')), isTrue); expect(pressable(tester, button('퇴근하기')), isFalse);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('VERIFYING: only the status line is shown (no times yet), buttons keep their rules', (tester) async {
    await open(tester, 'VERIFYING');
    expect(find.text('출근 상태 확인 중'), findsOneWidget);
    expect(find.text('출근 시간'), findsNothing); expect(find.text('퇴근 시간'), findsNothing);
    expect(pressable(tester, button('퇴근하기')), isFalse);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('a request in progress: the clock buttons are off, and the password-change wait notice covers the screen', (tester) async {
    final dynamic state = await open(tester, 'NOT_IN');
    state.setState(() { state.isProcessing = true; });
    await tester.pump();
    expect(pressable(tester, button('출근하기')), isFalse); expect(pressable(tester, button('퇴근하기')), isFalse);
    state.setState(() { state.isProcessing = false; state.isPasswordChanging = true; });
    await tester.pump();
    expect(find.text('잠시만 기다려주세요'), findsOneWidget);
    for (final label in ['출근하기', '퇴근하기', '근무기록', '계산기', '비밀번호 변경', '로그아웃']) { expect(pressable(tester, button(label)), isFalse, reason: label); }
    state.setState(() { state.isPasswordChanging = false; });
    await tester.pump();
    expect(find.text('잠시만 기다려주세요'), findsNothing);
    expect(pressable(tester, button('출근하기')), isTrue);
    await close(tester);
  });

  for (final status in ['NOT_IN', 'WORKING', 'COMPLETED', 'VERIFYING']) {
    testWidgets('$status at 320px wide with long names and larger text: nothing overflows, every button stays inside the screen', (tester) async {
      await open(tester, status, size: const Size(320, 640), store: '아주아주 긴 이름의 매장 서울특별시 강남구 지점', employee: '아주아주길고긴이름의직원님', textScale: 1.3);
      expect(tester.takeException(), isNull);
      for (final label in ['출근하기', '퇴근하기', '근무기록', '계산기', '비밀번호 변경', '로그아웃']) {
        final r = rectOf(tester, button(label));
        expect(r.left, greaterThanOrEqualTo(0), reason: label); expect(r.right, lessThanOrEqualTo(320), reason: label);
      }
      // the two-column rows stay two columns, and the label inside is the whole word (scaled down, not cut)
      expect(rectOf(tester, button('근무기록')).top, rectOf(tester, button('계산기')).top);
      expect(rectOf(tester, button('비밀번호 변경')).top, rectOf(tester, button('로그아웃')).top);
      expect(tester.takeException(), isNull);
      await close(tester);
    });
  }

  testWidgets('opening 근무기록 turns the label into 근무기록 닫기 inside the left column, shows the calendar below the two columns, and closes again', (tester) async {
    await open(tester, 'NOT_IN', size: const Size(320, 640));
    final calculatorBefore = rectOf(tester, button('계산기'));
    await tester.tap(find.text('근무기록'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('근무기록 닫기'), findsOneWidget); expect(find.text('근무기록'), findsNothing);
    final closeRect = rectOf(tester, button('근무기록 닫기'));
    expect(closeRect.right, lessThan(rectOf(tester, button('계산기')).left)); expect(rectOf(tester, button('계산기')), calculatorBefore);
    expect(find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '이전 달'), findsOneWidget); // the calendar is there
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('근무기록 닫기'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('근무기록'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '이전 달'), findsNothing);
    await close(tester);
  });

  testWidgets('비밀번호 변경 still opens its dialog from the bottom row', (tester) async {
    await open(tester, 'NOT_IN');
    await tester.tap(find.text('비밀번호 변경'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(PasswordChangeDialog), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the work-history calendar is deep teal: mint work days, teal numbers, teal today ring, teal arrows, white cards with a soft border - and it still counts and navigates', (tester) async {
    final dynamic state = await open(tester, 'NOT_IN');
    final today = DateTime.now();
    final workDay = today.day == 3 ? 4 : 3;
    await tester.tap(find.text('근무기록'));
    await tester.pump(const Duration(milliseconds: 50));
    state.setState(() {
      state.calendarRecords = <Map<String, dynamic>>[
        {'day': workDay, 'store': '제로백', 'inText': '09:00', 'outText': '18:00', 'breakText': '1시간 0분', 'workedText': '8시간 0분'},
        {'day': workDay, 'store': '제로백', 'inText': '19:00', 'outText': '20:30', 'breakText': '0분', 'workedText': '1시간 30분'},
      ];
      state.hasCalendarLoaded = true;
      state.calendarError = null;
    });
    await tester.pump();
    // arrows
    for (final tip in ['이전 달', '다음 달']) {
      expect(tester.widget<IconButton>(find.byWidgetPredicate((w) => w is IconButton && w.tooltip == tip)).color, const Color(0xFF187D76), reason: tip);
    }
    // a work day: mint cell, deep teal bold number
    final workCell = tester.widget<Material>(find.ancestor(of: find.text('$workDay'), matching: find.byType(Material)).first);
    expect(workCell.color, const Color(0xFFD7EBE8));
    final workText = tester.widget<Text>(find.text('$workDay'));
    expect(workText.style!.color, const Color(0xFF0F5F59)); expect(workText.style!.fontWeight, FontWeight.bold);
    // today: deep teal ring (2px) on its cell
    final todayCell = tester.widget<Material>(find.ancestor(of: find.text('${today.day}'), matching: find.byType(Material)).first);
    final ring = (todayCell.shape! as RoundedRectangleBorder).side;
    expect([ring.color, ring.width], [const Color(0xFF187D76), 2.0]);
    // every card on the screen: white, no shadow, the same soft border (no black outline)
    for (final card in tester.widgetList<Card>(find.byType(Card))) {
      expect(card.color, Colors.white); expect(card.elevation, 0);
      expect((card.shape! as RoundedRectangleBorder).side.color, const Color(0xFFE1ECEA));
    }
    // no leftover blue / purple of the old calendar on the screen's icons
    for (final icon in tester.widgetList<Icon>(find.byType(Icon))) {
      expect(icon.color, isNot(const Color(0xFF2563EB)));
    }
    // what the calendar says is unchanged: one work day (two records), 9시간 30분 in total
    expect(find.text('총 1일 근무'), findsOneWidget);
    expect(find.text('9시간 30분'), findsOneWidget);
    expect(tester.widget<Text>(find.text('9시간 30분')).style!.color, const Color(0xFF0F5F59));
    expect(find.text('근무일'), findsOneWidget); expect(find.text('오늘'), findsOneWidget);
    for (final label in ['일', '월', '화', '수', '목', '금', '토']) { expect(find.text(label), findsOneWidget, reason: label); }
    // touching a work day still opens its details
    await tester.ensureVisible(find.text('$workDay'));
    await tester.tap(find.text('$workDay'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('09:00'), findsWidgets);
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('the note field while working: soft teal border, deep teal when focused, white fill; icon, texts and input work as before', (tester) async {
    final dynamic state = await open(tester, 'WORKING');
    final field = find.byType(TextField);
    final decoration = tester.widget<TextField>(field).decoration!;
    const soft = Color(0xFFBFD6D3);
    for (final border in [decoration.border, decoration.enabledBorder, decoration.disabledBorder]) {
      expect((border! as OutlineInputBorder).borderSide.color, soft);
    }
    final focused = (decoration.focusedBorder! as OutlineInputBorder).borderSide;
    expect([focused.color, focused.width], [const Color(0xFF187D76), 2.0]);
    // the label (also the floated one) turns deep teal while typing, and is the grey of the other secondary texts otherwise
    for (final style in [decoration.labelStyle, decoration.floatingLabelStyle]) {
      final resolved = style! as WidgetStateProperty<TextStyle?>;
      expect(resolved.resolve({WidgetState.focused})!.color, const Color(0xFF187D76));
      expect(resolved.resolve(<WidgetState>{})!.color, const Color(0xFF777D83));
    }
    expect([decoration.filled, decoration.fillColor], [true, Colors.white]);
    expect(find.text('특이사항 (선택)'), findsOneWidget);
    expect(find.byIcon(Icons.edit_note), findsOneWidget);
    expect(tester.widget<TextField>(field).cursorColor, const Color(0xFF187D76));
    // it still takes the text and hands it to the clock-out request (the same controller as before)
    await tester.enterText(field, '재고 정리');
    expect(state.noteController.text, '재고 정리');
    expect(tester.widget<TextField>(field).enabled, isTrue);
    state.setState(() { state.isPasswordChanging = true; });
    await tester.pump();
    expect(tester.widget<TextField>(field).enabled, isFalse); // disabled together with everything else while the password changes
    state.setState(() { state.isPasswordChanging = false; });
    await tester.pump();
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('scroll length on a normal phone (360x800) for every state - printed so the change can be compared', (tester) async {
    for (final status in ['NOT_IN', 'WORKING', 'COMPLETED']) {
      await open(tester, status);
      final extent = scrollExtent(tester);
      debugPrint('[SCROLL] $status 360x800 extra=$extent');
      expect(extent, 0.0, reason: status);
      await close(tester);
    }
    for (final status in ['NOT_IN', 'WORKING', 'COMPLETED']) {
      await open(tester, status, size: const Size(360, 640));
      debugPrint('[SCROLL] $status 360x640 extra=${scrollExtent(tester)}');
      await close(tester);
    }
  });
}
