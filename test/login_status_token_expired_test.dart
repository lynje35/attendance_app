import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'login_token_harness.dart';

void main() {
  testWidgets('an expired or invalid saved token is still sent, falls back on the server, and the new token replaces it', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      verifiedPasswordKey('e1'): '1234',
      actionTokenKey('e1'): 'expired-token',
    });
    final bodies = installApi();
    await login(tester, bodies);
    expect(firstStatus(bodies)['actionToken'], 'expired-token');
    expect(await storedToken(), issued);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
