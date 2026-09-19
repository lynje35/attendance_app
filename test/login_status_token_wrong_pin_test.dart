import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'login_token_harness.dart';

void main() {
  testWidgets('a different password than the verified one sends no saved token', (tester) async {
    FlutterSecureStorage.setMockInitialValues({verifiedPasswordKey('e1'): '1234', actionTokenKey('e1'): good});
    final bodies = installApi();
    await login(tester, bodies, pin: '9999');
    expect(firstStatus(bodies).containsKey('actionToken'), isFalse);
    expect(firstStatus(bodies)['password'], '9999');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
