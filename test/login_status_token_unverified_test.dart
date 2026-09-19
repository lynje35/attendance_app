import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'login_token_harness.dart';

void main() {
  // The server never re-checks the typed password once a session token is accepted, so a saved token must
  // not be sent for a password that has not been verified on this device yet.
  testWidgets('first login on this device sends no saved token, so the server verifies the password', (tester) async {
    FlutterSecureStorage.setMockInitialValues({actionTokenKey('e1'): good});
    final bodies = installApi();
    await login(tester, bodies);
    expect(firstStatus(bodies).containsKey('actionToken'), isFalse);
    expect(firstStatus(bodies)['password'], '1234');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
