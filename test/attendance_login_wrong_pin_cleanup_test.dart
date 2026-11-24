import 'package:attendance_app/main.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'attendance_sync_harness.dart';

// R3: a real wrong PIN at login keeps the existing cleanup (one login flow per file, see attendance_sync_harness.dart).
void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('R3 a real wrong PIN at login (INVALID_CREDENTIALS) still clears as before', timeout: timeout, (tester) async {
    final fake = install({'status': 'NOT_IN'});
    fake.statusReply = (_) => {'success': false, 'code': 'INVALID_CREDENTIALS', 'message': '비밀번호가 일치하지 않습니다.'};
    await savePendingClockIn(employeeId: emp, store: '매장1');
    await saveRememberedLogin(store: '매장1', employeeId: emp, password: pin);
    await saveVerifiedPassword(emp, pin);
    await open(tester, {'status': 'VERIFYING'}, remember: true, hosted: true);
    await pumpFor(tester, 1500);
    expect(await hasRecentPendingClockIn(employeeId: emp, store: '매장1'), isFalse);
    expect(await readRememberedLogin(), isNull);
    expect(await readVerifiedPassword(emp), isNull);
    expect(shows('비밀번호가 일치하지 않습니다.'), isTrue);
    expect(onWorkPage(), isFalse);
    await finish(tester);
  });
}
