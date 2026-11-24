import 'package:attendance_app/main.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'attendance_sync_harness.dart';

// R3: a server outage (JSON 503) at login is not a wrong PIN (one login flow per file, see attendance_sync_harness.dart).
void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('R3 a JSON 503 at login keeps the pending clock-in, the remembered login and the verified PIN, and says it is a server problem', timeout: timeout, (tester) async {
    final fake = install({'status': 'NOT_IN'});
    fake.statusHttp = 503;
    fake.statusReply = (_) => {'success': false, 'code': 'EMPLOYEE_UNAVAILABLE', 'message': '잠시 후 다시 시도해 주세요.'};
    await savePendingClockIn(employeeId: emp, store: '매장1');
    await saveRememberedLogin(store: '매장1', employeeId: emp, password: pin);
    await saveVerifiedPassword(emp, pin);
    await open(tester, {'status': 'VERIFYING'}, remember: true, hosted: true);
    await pumpFor(tester, 1500);
    expect(await hasRecentPendingClockIn(employeeId: emp, store: '매장1'), isTrue);
    expect(await readRememberedLogin(), isNotNull);
    expect(await readVerifiedPassword(emp), pin);
    expect(shows('서버 연결에 실패했습니다. 잠시 후 다시 시도해 주세요.'), isTrue);
    expect(onWorkPage(), isFalse);
    await finish(tester);
  });
}
