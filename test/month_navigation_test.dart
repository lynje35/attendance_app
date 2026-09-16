import 'dart:async';

import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final initialStatus in ['VERIFYING', 'NOT_IN', 'WORKING']) {
  testWidgets('month arrows respond with $initialStatus before authentication',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final login = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(MaterialApp(
      home: WorkPage(
        store: 'test', employee: 'test', employeeId: 'test',
        password: '0000', attendance: {'status': initialStatus},
        loginFuture: login.future, rememberDevice: initialStatus != 'VERIFYING',
      ),
    ));
    final dynamic state = tester.state(find.byType(WorkPage));
    state.setState(() {
      state.calendarMonth = DateTime(2026, 9, 1);
      state.serverClockOffsetMs = DateTime(2026, 9, 6)
          .difference(DateTime.now()).inMilliseconds;
      state.isCalendarLoading = true;
      state.backgroundStatusInFlight = true;
      state.isProcessing = true;
    });
    await tester.pump();
    await tester.tap(find.text('근무기록'));
    await tester.pump();
    final previous = find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '이전 달');
    await tester.ensureVisible(previous);
    await tester.pump();
    expect(tester.widget<IconButton>(previous).onPressed, isNotNull);
    expect(tester.widget<IconButton>(find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '다음 달')).onPressed,
        isNull);
    await tester.tap(previous);
    await tester.pump();
    expect(find.text('2026년 8월'), findsOneWidget);
    expect(login.isCompleted, isFalse);
    expect(state.isLoginVerified, isFalse);
    expect(state.isCalendarLoading, isTrue);
    expect(tester.widget<IconButton>(previous).onPressed, isNull);
    await tester.tap(find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '다음 달'));
    await tester.pump();
    expect(find.text('2026년 9월'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  }
}
