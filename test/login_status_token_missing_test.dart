import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'login_token_harness.dart';

void main() {
  testWidgets('without a saved token the login status keeps the password fallback and the newly issued token is saved', (tester) async {
    FlutterSecureStorage.setMockInitialValues({verifiedPasswordKey('e1'): '1234'});
    final bodies = installApi();
    await login(tester, bodies);
    expect(firstStatus(bodies).containsKey('actionToken'), isFalse);
    expect(firstStatus(bodies)['password'], '1234');
    expect(await storedToken(), issued);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
