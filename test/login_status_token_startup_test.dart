import 'dart:convert';

import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'login_token_harness.dart';

void main() {
  testWidgets('remembered-login startup status also carries the saved token', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      rememberStoreKey: '매장1',
      rememberEmployeeIdKey: 'e1',
      rememberPasswordKey: '1234',
      verifiedPasswordKey('e1'): '1234',
      actionTokenKey('e1'): good,
      bootstrapCacheKey: jsonEncode({'stores': [{'storeName': '매장1'}],
        'employees': [{'employeeId': 'e1', 'name': '테스트직원', 'defaultStore': '매장1'}]}),
    });
    final bodies = installApi();
    useWideView(tester);
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await settle(tester, steps: 10);
    expect(firstStatus(bodies)['actionToken'], good);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
