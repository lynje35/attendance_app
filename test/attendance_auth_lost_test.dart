import 'package:attendance_app/main.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'attendance_sync_harness.dart';

// R4: a PIN rejected during the background refresh (one login flow per file, see attendance_sync_harness.dart).
void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('R4 PIN reset elsewhere: the first INVALID_CREDENTIALS stops the 60 s polling, explains, and returns to the login screen', timeout: timeout, (tester) async {
    final fake = install(working());
    await saveRememberedLogin(store: '매장1', employeeId: emp, password: pin);
    await saveVerifiedPassword(emp, pin);
    await open(tester, working(), remember: true, hosted: true);
    await pumpFor(tester, 500);
    expect(onWorkPage(), isTrue);
    fake.statusReply = (_) => {'success': false, 'code': 'INVALID_CREDENTIALS', 'message': '로그인 정보가 변경되었습니다. 다시 로그인해 주세요.'};
    final start = fake.of('status').length;
    var sawMessage = false, sawUnstable = false;
    for (var second = 0; second < 300; second++) {
      await tester.pump(const Duration(seconds: 1));
      if (shows('로그인 정보가 변경되었습니다. 다시 로그인해 주세요.')) sawMessage = true;
      if (shows('서버 연결이 불안정합니다. 현재 화면은 마지막 확인 상태입니다.')) sawUnstable = true;
    }
    expect(fake.of('status').length - start, 1, reason: 'only the one call that learned of the rejection, no repeats with the old PIN');
    expect(sawMessage, isTrue);
    expect(sawUnstable, isFalse, reason: 'a rejected PIN is not a connection problem');
    expect(onWorkPage(), isFalse, reason: 'back on the login screen');
    expect(await readRememberedLogin(), isNull, reason: 'same cleanup as a rejected login');
    expect(await readVerifiedPassword(emp), isNull);
    await finish(tester);
  });
}
