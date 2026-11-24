import 'package:attendance_app/main.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'attendance_sync_harness.dart';

// R3: a network error at login is not a wrong PIN (one login flow per file, see attendance_sync_harness.dart).
void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('R3 a network error at login keeps the pending clock-in and the remembered login', timeout: timeout, (tester) async {
    final fake = install({'status': 'NOT_IN'});
    fake.offline = true;
    await savePendingClockIn(employeeId: emp, store: '매장1');
    await saveRememberedLogin(store: '매장1', employeeId: emp, password: pin);
    // the failed login call settles before WorkPage starts awaiting it; ignore() only keeps the test zone from
    // reporting that early error, WorkPage still receives it
    final login = sendApiRequest({'action': 'status', 'employeeId': emp, 'password': pin, 'selectedStore': '매장1'})..ignore();
    await open(tester, {'status': 'VERIFYING'}, login: login, remember: true, hosted: true);
    await pumpFor(tester, 1500);
    expect(await hasRecentPendingClockIn(employeeId: emp, store: '매장1'), isTrue);
    expect(await readRememberedLogin(), isNotNull);
    expect(shows('서버 연결에 실패했습니다.'), isTrue);
    expect(onWorkPage(), isFalse);
    await finish(tester);
  });
}
