import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'login_token_harness.dart';

void main() {
  testWidgets('a saved token is sent with the login status when the typed password is the one already verified on this device', (tester) async {
    FlutterSecureStorage.setMockInitialValues({
      verifiedPasswordKey('e1'): '1234',
      actionTokenKey('e1'): good,
    });
    final bodies = installApi();
    await login(tester, bodies);
    expect(firstStatus(bodies)['actionToken'], good);
    expect(firstStatus(bodies)['password'], '1234');
    expect(firstStatus(bodies)['employeeId'], 'e1');
    // The session accepted the request, so no token is issued and the saved one is kept.
    expect(await storedToken(), good);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
