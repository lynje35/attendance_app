import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'employee_server_preview.dart';
import 'main.dart' as app;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb || Uri.base.host != '127.0.0.1' || Uri.base.port != 8789) {
    throw StateError('직원 서버 테스트는 PC의 127.0.0.1:8789에서만 실행합니다.');
  }
  app.employeeServerPreview = EmployeeServerPreview(
    endpoint: Uri.base.resolve('/employee/api'),
    client: app.apiClient,
    read: (key) => app.secureStorage.read(key: key),
    write: (key, value) => app.secureStorage.write(key: key, value: value),
    remove: (key) => app.secureStorage.delete(key: key),
  );
  app.main();
}
