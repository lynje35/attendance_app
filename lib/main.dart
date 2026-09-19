import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'employee_server_preview.dart';
import 'calculator_page.dart';

EmployeeServerPreview? employeeServerPreview;

final http.Client apiClient = http.Client();

// 모든 화면이 같은 네트워크 구현과 제한시간을 사용합니다.
// 서버가 응답하지 않거나 네트워크가 끊긴 경우 앱 상태가 무기한 잠기지 않도록
// 한 API 호출 전체를 12초로 제한합니다.
const Duration apiCallTimeout = Duration(seconds: 12);

Future<Map<String, dynamic>> sendApiRequest(
  Map<String, dynamic> body,
) {
  final action = body['action']?.toString() ?? '';
  final preview = employeeServerPreview;

  if (preview == null) {
    throw StateError(
      'employeeServerPreview가 초기화되지 않았습니다. EMPLOYEE_API_URL 설정을 확인하세요.',
    );
  }

  return preview.send(body).timeout(
    apiCallTimeout,
    onTimeout: () {
      debugPrint('[네트워크][$action] ${apiCallTimeout.inSeconds}초 제한시간 초과');
      throw TimeoutException(
        '서버 응답 시간이 ${apiCallTimeout.inSeconds}초를 초과했습니다.',
      );
    },
  );
}

final FlutterSecureStorage secureStorage = FlutterSecureStorage();

const String rememberStoreKey = 'attendance_remember_store';
const String rememberEmployeeIdKey = 'attendance_remember_employee_id';
const String rememberPasswordKey = 'attendance_remember_password';

// 서버에서 한 번 성공 확인된 비밀번호를 기기 보안 저장소에 검증용으로만 보관합니다.
// 자동입력/자동로그인과는 별개이며, 로그인 화면에서 잘못된 비밀번호로
// WorkPage가 먼저 열리는 문제를 막으면서 정상 재로그인은 즉시 처리하는 용도입니다.
String verifiedPasswordKey(String employeeId) {
  return 'attendance_verified_password_v1_$employeeId';
}

// 메모리에서 먼저 세대를 갱신하고 보안 저장소 쓰기는 직원별 순서대로 처리합니다.
final Map<String, int> _verifiedPasswordGenerations = {};
final Map<String, String?> _verifiedPasswordValues = {};
final Map<String, Future<void>> _verifiedPasswordWrites = {};

int _verifiedPasswordGeneration(String employeeId) =>
    _verifiedPasswordGenerations[employeeId] ?? 0;

Future<void> _writeVerifiedPassword(String employeeId, String? value) {
  _verifiedPasswordGenerations[employeeId] =
      _verifiedPasswordGeneration(employeeId) + 1;
  _verifiedPasswordValues[employeeId] = value;
  final previous = _verifiedPasswordWrites[employeeId] ?? Future<void>.value();
  final write = previous.then((_) async {
    if (value == null) {
      await secureStorage.delete(key: verifiedPasswordKey(employeeId));
    } else {
      await secureStorage.write(key: verifiedPasswordKey(employeeId), value: value);
    }
  });
  // 이전 저장 실패가 이후의 새 비밀번호 저장을 막지 않도록 합니다.
  _verifiedPasswordWrites[employeeId] = write.then<void>(
    (_) {}, onError: (Object _, StackTrace _) {},
  );
  return write;
}

Future<void> saveVerifiedPassword(
  String employeeId,
  String password, {
  int? expectedGeneration,
}) async {
  if (employeeId.isEmpty || !RegExp(r'^\d{4}$').hasMatch(password)) {
    return;
  }

  if (expectedGeneration != null &&
      expectedGeneration != _verifiedPasswordGeneration(employeeId)) {
    return;
  }
  await _writeVerifiedPassword(employeeId, password);
}

Future<String?> readVerifiedPassword(String employeeId) async {
  if (employeeId.isEmpty) return null;

  if (_verifiedPasswordValues.containsKey(employeeId)) {
    return _verifiedPasswordValues[employeeId];
  }
  final value = await secureStorage.read(
    key: verifiedPasswordKey(employeeId),
  );

  if (_verifiedPasswordValues.containsKey(employeeId)) {
    return _verifiedPasswordValues[employeeId];
  }
  if (value == null || !RegExp(r'^\d{4}$').hasMatch(value)) {
    return null;
  }

  return value;
}

Future<void> clearVerifiedPassword(String employeeId, {int? expectedGeneration}) async {
  if (employeeId.isEmpty) return;
  if (expectedGeneration != null &&
      expectedGeneration != _verifiedPasswordGeneration(employeeId)) {
    return;
  }
  await _writeVerifiedPassword(employeeId, null);
}

// 매장/직원 목록은 민감한 비밀번호 정보가 포함되지 않는 bootstrap 결과만
// 기기에 보관해 다음 앱 실행 때 서버를 기다리지 않고 즉시 화면에 사용합니다.
const String bootstrapCacheKey = 'attendance_bootstrap_cache_v1';

Future<void> _rememberedLoginWrite = Future<void>.value();

Future<void> _queueRememberedLoginWrite(Future<void> Function() action) {
  final write = _rememberedLoginWrite.then((_) => action());
  _rememberedLoginWrite = write.then<void>(
    (_) {}, onError: (Object _, StackTrace _) {},
  );
  return write;
}

Future<void> saveRememberedLogin({
  required String store,
  required String employeeId,
  required String password,
}) => _queueRememberedLoginWrite(() async {
  await secureStorage.write(
    key: rememberStoreKey,
    value: store,
  );
  await secureStorage.write(
    key: rememberEmployeeIdKey,
    value: employeeId,
  );
  await secureStorage.write(
    key: rememberPasswordKey,
    value: password,
  );
});

Future<void> clearRememberedLogin() => _queueRememberedLoginWrite(() async {
  await secureStorage.delete(key: rememberStoreKey);
  await secureStorage.delete(key: rememberEmployeeIdKey);
  await secureStorage.delete(key: rememberPasswordKey);
});

Future<Map<String, String>?> readRememberedLogin() async {
  await _rememberedLoginWrite;
  final store = await secureStorage.read(key: rememberStoreKey);
  final employeeId =
      await secureStorage.read(key: rememberEmployeeIdKey);
  final password =
      await secureStorage.read(key: rememberPasswordKey);

  if (store == null ||
      store.isEmpty ||
      employeeId == null ||
      employeeId.isEmpty ||
      password == null ||
      !RegExp(r'^\d{4}$').hasMatch(password)) {
    return null;
  }

  return {
    'store': store,
    'employeeId': employeeId,
    'password': password,
  };
}


String lastConfirmedAttendanceKey(String employeeId) {
  return 'attendance_last_confirmed_v1_$employeeId';
}

Future<void> saveLastConfirmedAttendance({
  required String employeeId,
  required String store,
  required Map<String, dynamic> attendance,
}) async {
  if (employeeId.isEmpty || store.isEmpty) return;

  final status = attendance['status']?.toString() ?? '';
  if (status != 'WORKING' &&
      status != 'NOT_IN' &&
      status != 'COMPLETED') {
    return;
  }

  // 재실행 첫 화면에서는 완료화면보다 현재 출근 가능 상태가 더 중요하므로
  // 서버의 COMPLETED 응답은 시작 캐시에 NOT_IN으로 정규화합니다.
  final cachedAttendance = status == 'COMPLETED'
      ? <String, dynamic>{
          'status': 'NOT_IN',
          if (attendance['serverNowMs'] != null)
            'serverNowMs': attendance['serverNowMs'],
        }
      : Map<String, dynamic>.from(attendance);

  final payload = <String, dynamic>{
    'store': store,
    'cachedAtMs': DateTime.now().millisecondsSinceEpoch,
    'attendance': cachedAttendance,
  };

  await secureStorage.write(
    key: lastConfirmedAttendanceKey(employeeId),
    value: jsonEncode(payload),
  );
}

Future<Map<String, dynamic>?> readLastConfirmedAttendance({
  required String employeeId,
  required String store,
}) async {
  if (employeeId.isEmpty || store.isEmpty) return null;

  final raw = await secureStorage.read(
    key: lastConfirmedAttendanceKey(employeeId),
  );

  if (raw == null || raw.isEmpty) return null;

  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;

    final map = Map<String, dynamic>.from(decoded);
    if (map['store']?.toString() != store) return null;

    final cachedAtMs = map['cachedAtMs'];
    final cachedAt = cachedAtMs is num
        ? cachedAtMs.toInt()
        : int.tryParse(cachedAtMs?.toString() ?? '');

    if (cachedAt == null) return null;

    // 지나치게 오래된 상태를 첫 화면에 확정값처럼 보여주지 않습니다.
    const maxCacheAge = Duration(hours: 24);
    final ageMs =
        DateTime.now().millisecondsSinceEpoch - cachedAt;
    if (ageMs < 0 || ageMs > maxCacheAge.inMilliseconds) {
      return null;
    }

    final attendance = map['attendance'];
    if (attendance is! Map) return null;

    final result = Map<String, dynamic>.from(attendance);
    final status = result['status']?.toString() ?? '';
    if (status != 'WORKING' && status != 'NOT_IN') {
      return null;
    }

    return result;
  } catch (_) {
    return null;
  }
}

String recentAttendanceIntentKey(String employeeId) {
  return 'attendance_recent_intent_v1_$employeeId';
}

Future<void> saveRecentAttendanceIntent({
  required String employeeId,
  required String store,
  required String status,
}) async {
  if (employeeId.isEmpty || store.isEmpty) return;
  if (status != 'WORKING' && status != 'NOT_IN') return;

  try {
    await secureStorage.write(
      key: recentAttendanceIntentKey(employeeId),
      value: jsonEncode({
        'store': store,
        'status': status,
        'createdAtMs': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  } catch (_) {}
}

Future<Map<String, dynamic>?> readRecentAttendanceIntent({
  required String employeeId,
  required String store,
}) async {
  if (employeeId.isEmpty || store.isEmpty) return null;

  try {
    final raw = await secureStorage.read(
      key: recentAttendanceIntentKey(employeeId),
    );
    if (raw == null || raw.isEmpty) return null;

    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;

    final map = Map<String, dynamic>.from(decoded);
    if (map['store']?.toString() != store) return null;

    final status = map['status']?.toString() ?? '';
    if (status != 'WORKING' && status != 'NOT_IN') return null;

    final createdAtRaw = map['createdAtMs'];
    final createdAtMs = createdAtRaw is num
        ? createdAtRaw.toInt()
        : int.tryParse(createdAtRaw?.toString() ?? '');
    if (createdAtMs == null) return null;

    const displayWindow = Duration(minutes: 5);
    final ageMs = DateTime.now().millisecondsSinceEpoch - createdAtMs;
    if (ageMs < 0 || ageMs > displayWindow.inMilliseconds) {
      await secureStorage.delete(
        key: recentAttendanceIntentKey(employeeId),
      );
      return null;
    }

    return <String, dynamic>{
      'status': status,
    };
  } catch (_) {
    return null;
  }
}

String pendingClockInKey(String employeeId) {
  return 'attendance_pending_clock_in_v1_$employeeId';
}

Future<void> savePendingClockIn({
  required String employeeId,
  required String store,
}) async {
  if (employeeId.isEmpty || store.isEmpty) return;

  try {
    if (employeeServerPreview != null) {
      await employeeServerPreview!.prepareIntent('clockIn', employeeId, store);
    }
    await Future.wait<void>([
      secureStorage.write(
        key: pendingClockInKey(employeeId),
        value: jsonEncode({
          'store': store,
          'createdAtMs': DateTime.now().millisecondsSinceEpoch,
        }),
      ),
      saveRecentAttendanceIntent(
        employeeId: employeeId,
        store: store,
        status: 'WORKING',
      ),
    ]);
  } catch (_) {}
}

Future<bool> hasRecentPendingClockIn({
  required String employeeId,
  required String store,
}) async {
  if (employeeId.isEmpty || store.isEmpty) return false;

  try {
    final raw = await secureStorage.read(
      key: pendingClockInKey(employeeId),
    );
    if (raw == null || raw.isEmpty) return false;

    final decoded = jsonDecode(raw);
    if (decoded is! Map) return false;

    final map = Map<String, dynamic>.from(decoded);
    if (map['store']?.toString() != store) return false;

    final createdAtRaw = map['createdAtMs'];
    final createdAtMs = createdAtRaw is num
        ? createdAtRaw.toInt()
        : int.tryParse(createdAtRaw?.toString() ?? '');
    if (createdAtMs == null) return false;

    const recoveryWindow = Duration(minutes: 5);
    final ageMs = DateTime.now().millisecondsSinceEpoch - createdAtMs;
    if (ageMs < 0 || ageMs > recoveryWindow.inMilliseconds) {
      await secureStorage.delete(
        key: pendingClockInKey(employeeId),
      );
      return false;
    }

    return true;
  } catch (_) {
    return false;
  }
}

Future<void> clearPendingClockIn(String employeeId) async {
  if (employeeId.isEmpty) return;

  try {
    if (employeeServerPreview != null) {
      await employeeServerPreview!.clearIntent('clockIn', employeeId);
    }
    await secureStorage.delete(
      key: pendingClockInKey(employeeId),
    );
  } catch (_) {}
}

String pendingClockOutKey(String employeeId) {
  return 'attendance_pending_clock_out_v1_$employeeId';
}

Future<void> savePendingClockOut({
  required String employeeId,
  required String store,
  required String note,
}) async {
  if (employeeId.isEmpty || store.isEmpty) return;

  try {
    if (employeeServerPreview != null) {
      await employeeServerPreview!.prepareIntent('clockOut', employeeId, store, note: note);
    }
    await Future.wait<void>([
      secureStorage.write(
        key: pendingClockOutKey(employeeId),
        value: jsonEncode({
          'store': store,
          'note': note,
          'createdAtMs': DateTime.now().millisecondsSinceEpoch,
        }),
      ),
      saveRecentAttendanceIntent(
        employeeId: employeeId,
        store: store,
        status: 'NOT_IN',
      ),
    ]);
  } catch (_) {}
}

Future<Map<String, dynamic>?> readRecentPendingClockOut({
  required String employeeId,
  required String store,
}) async {
  if (employeeId.isEmpty || store.isEmpty) return null;

  try {
    final raw = await secureStorage.read(
      key: pendingClockOutKey(employeeId),
    );
    if (raw == null || raw.isEmpty) return null;

    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;

    final map = Map<String, dynamic>.from(decoded);
    if (map['store']?.toString() != store) return null;

    final createdAtRaw = map['createdAtMs'];
    final createdAtMs = createdAtRaw is num
        ? createdAtRaw.toInt()
        : int.tryParse(createdAtRaw?.toString() ?? '');
    if (createdAtMs == null) return null;

    const recoveryWindow = Duration(minutes: 5);
    final ageMs = DateTime.now().millisecondsSinceEpoch - createdAtMs;
    if (ageMs < 0 || ageMs > recoveryWindow.inMilliseconds) {
      await secureStorage.delete(
        key: pendingClockOutKey(employeeId),
      );
      return null;
    }

    return <String, dynamic>{
      'note': map['note']?.toString() ?? '',
    };
  } catch (_) {
    return null;
  }
}

Future<void> clearPendingClockOut(String employeeId) async {
  if (employeeId.isEmpty) return;

  try {
    if (employeeServerPreview != null) {
      await employeeServerPreview!.clearIntent('clockOut', employeeId);
    }
    await secureStorage.delete(
      key: pendingClockOutKey(employeeId),
    );
  } catch (_) {}
}

String hourlyWageKey(String employeeId) {
  return 'attendance_hourly_wage_v1_$employeeId';
}

String actionTokenKey(String employeeId) {
  return 'attendance_action_token_v1_$employeeId';
}

// Diagnostics only: mirrors EmployeeServerPreview's own (private) pending-intent
// key so a request/response log line can show the requestId/recordId already
// staged for this clockIn/clockOut, without changing that class's behavior.
Future<Map<String, dynamic>?> _readAttendanceIntentForDiag(
  String action,
  String employeeId,
) async {
  try {
    final raw = await secureStorage.read(
      key: 'employee_server_preview_request_${action}_$employeeId',
    );
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return Map<String, dynamic>.from(decoded);
  } catch (_) {
    return null;
  }
}

// Optional, set via --dart-define=APP_VERSION=... at build time; empty by
// default so no existing build command needs to change for this to work.
const String _appVersionForDiag = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '',
);

String get _platformForDiag {
  if (kIsWeb) return 'web';
  return defaultTargetPlatform.name;
}

// Best-effort, fire-and-forget diagnostic upload for attendance FAILURE paths
// only (never for an ordinary success, and never for status polling). This
// must never throw into, delay, or otherwise affect the real
// clockIn/clockOut/verify flow, and it deliberately posts directly instead of
// going through callApi/EmployeeServerPreview.send so a diagnostic failure
// can never recursively trigger another diagnostic send.
void _sendAttendanceDiag(Map<String, dynamic> fields) {
  final preview = employeeServerPreview;
  if (preview == null) return;

  unawaited(() async {
    try {
      final body = <String, dynamic>{
        'action': 'attendanceDiag',
        'appVersion': _appVersionForDiag,
        'platform': _platformForDiag,
        'timestamp': DateTime.now().toIso8601String(),
        ...fields,
      };
      await preview.client
          .post(
            preview.endpoint,
            headers: {'Content-Type': 'text/plain; charset=UTF-8'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      debugPrint('[ATTENDANCE_CLIENT_DIAG_SEND_FAILED] $e');
    }
  }());
}

Future<void> saveBootstrapCache(Map<String, dynamic> data) async {
  final stores = data['stores'];
  final employees = data['employees'];

  if (stores is! List || employees is! List) {
    return;
  }

  final cache = <String, dynamic>{
    'stores': stores,
    'employees': employees,
  };

  await secureStorage.write(
    key: bootstrapCacheKey,
    value: jsonEncode(cache),
  );
}

Future<Map<String, dynamic>?> readBootstrapCache() async {
  final raw = await secureStorage.read(key: bootstrapCacheKey);

  if (raw == null || raw.isEmpty) {
    return null;
  }

  try {
    final decoded = jsonDecode(raw);

    if (decoded is! Map) {
      return null;
    }

    final data = Map<String, dynamic>.from(decoded);

    if (data['stores'] is! List || data['employees'] is! List) {
      return null;
    }

    return data;
  } catch (_) {
    return null;
  }
}

void main() {
  const employeeApiUrl = String.fromEnvironment(
    'EMPLOYEE_API_URL',
    defaultValue: '',
  );

  if (employeeApiUrl.isNotEmpty) {
    final endpoint = Uri.parse(employeeApiUrl);

    if (!endpoint.isAbsolute ||
        (endpoint.scheme != 'http' && endpoint.scheme != 'https')) {
      throw StateError(
        'EMPLOYEE_API_URL must be an absolute http/https URL: $employeeApiUrl',
      );
    }

    employeeServerPreview = EmployeeServerPreview(
      endpoint: endpoint,
      client: apiClient,
      read: (key) => secureStorage.read(key: key),
      write: (key, value) => secureStorage.write(key: key, value: value),
      remove: (key) => secureStorage.delete(key: key),
    );
  }

  runApp(const AttendanceApp());
}

class Employee {
  final String id;
  final String name;
  final String defaultStore;

  const Employee({
    required this.id,
    required this.name,
    required this.defaultStore,
  });
}

class AttendanceApp extends StatelessWidget {
  const AttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '출퇴근 관리',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        fontFamilyFallback: const ['NotoSansKR'],
      ),
      home: const LoginPage(),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with WidgetsBindingObserver {
  String? selectedStore;
  String? selectedEmployeeId;

  final TextEditingController pinController = TextEditingController();
  bool showLoginPassword = false;

  List<String> stores = [];
  List<Employee> employees = [];

  // 로그인 버튼을 누른 뒤 SecureStorage를 다시 읽지 않도록
  // 앱 시작 시 검증 완료 비밀번호를 메모리에 미리 올려둡니다.
  final Map<String, String> verifiedPasswordMemory = {};
  Future<void>? verifiedPasswordPreloadFuture;

  // 첫 프레임은 서버를 기다리지 않고 즉시 로그인 화면을 그립니다.
  bool isLoading = false;
  bool rememberDevice = false;
  bool autoLoginTriggered = false;
  bool loginStarted = false;
  String? loadError;
  String? loginNotice;
  bool loginNoticeVisible = false;
  Timer? loginNoticeTimer;
  Timer? bootstrapRefreshTimer;
  bool bootstrapRefreshInFlight = false;

  // 자동로그인용: 앱 시작과 동시에 기억된 직원의 현재 출퇴근 상태를 먼저 조회합니다.
  String? startupStatusEmployeeId;
  String? startupStatusStore;
  String? startupStatusPassword;
  Future<Map<String, dynamic>>? startupStatusFuture;
  int? startupStatusPasswordGeneration;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    loadData();
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    loginNoticeTimer?.cancel();
    bootstrapRefreshTimer?.cancel();
    pinController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        !loginStarted &&
        !bootstrapRefreshInFlight) {
      _scheduleBootstrapRefresh(
        delay: const Duration(milliseconds: 300),
      );
    }
  }

  Future<Map<String, dynamic>> callApi(
    Map<String, dynamic> body,
  ) async {
    return sendApiRequest(
      Map<String, dynamic>.from(body),
    );
  }

  // 이 직원의 저장된 세션 토큰(없거나 읽기 실패 시 null). 서버가 검증하므로 만료/무효여도 안전합니다.
  Future<String?> _readSavedActionToken(String employeeId) async {
    try {
      final saved = await secureStorage.read(key: actionTokenKey(employeeId));
      if (saved != null && saved.isNotEmpty && saved.length <= 512) return saved;
    } catch (_) {}
    return null;
  }

  bool _matchesStartupStatusRequest({
    required String employeeId,
    required String password,
    required String store,
  }) {
    return startupStatusEmployeeId == employeeId &&
        startupStatusPassword == password &&
        startupStatusStore == store &&
        startupStatusPasswordGeneration == _verifiedPasswordGeneration(employeeId) &&
        startupStatusFuture != null;
  }


  Future<void> _preloadVerifiedPasswords(
    List<Employee> employeeList,
  ) async {
    final generations = {
      for (final employee in employeeList)
        employee.id: _verifiedPasswordGeneration(employee.id),
    };
    final results = await Future.wait(
      employeeList.map((employee) async {
        try {
          final password = await readVerifiedPassword(employee.id);
          return MapEntry<String, String?>(employee.id, password);
        } catch (_) {
          return MapEntry<String, String?>(employee.id, null);
        }
      }),
    );

    for (final entry in results) {
      final password = entry.value;
      if (password != null &&
          generations[entry.key] == _verifiedPasswordGeneration(entry.key)) {
        verifiedPasswordMemory[entry.key] = password;
      }
    }
  }



  void _scheduleBootstrapRefresh({
    Duration delay = const Duration(milliseconds: 750),
  }) {
    bootstrapRefreshTimer?.cancel();
    bootstrapRefreshTimer = Timer(delay, () {
      if (!mounted || loginStarted || bootstrapRefreshInFlight) {
        return;
      }

      unawaited(_refreshBootstrapFromServer());
    });
  }

  Future<void> _refreshBootstrapFromServer() async {
    if (!mounted || loginStarted || bootstrapRefreshInFlight) {
      return;
    }

    bootstrapRefreshInFlight = true;

    try {
      final data = await callApi({
        'action': 'bootstrap',
      });

      if (data['success'] != true ||
          data['stores'] is! List ||
          data['employees'] is! List) {
        return;
      }

      // 최신 목록은 다음 실행에도 바로 쓰도록 캐시에 먼저 저장합니다.
      unawaited(saveBootstrapCache(data));

      // 갱신 도중 사용자가 로그인을 시작했다면 현재 화면은 건드리지 않습니다.
      if (!mounted || loginStarted) {
        return;
      }

      final storeList = (data['stores'] as List)
          .map((item) => item['storeName'].toString())
          .toList();
      final employeeList = (data['employees'] as List)
          .map(
            (item) => Employee(
              id: item['employeeId'].toString(),
              name: item['name'].toString(),
              defaultStore:
                  item['defaultStore']?.toString().trim() ?? '',
            ),
          )
          .toList();

      final previousStore = selectedStore;
      final previousEmployeeId = selectedEmployeeId;
      final storeStillExists = previousStore == null ||
          storeList.contains(previousStore);
      final employeeStillExists = previousEmployeeId == null ||
          employeeList.any((employee) => employee.id == previousEmployeeId);
      final rememberedSelectionBecameInvalid =
          (previousStore != null && !storeStillExists) ||
          (previousEmployeeId != null && !employeeStillExists);

      if (rememberedSelectionBecameInvalid) {
        unawaited(clearRememberedLogin());
      }

      setState(() {
        stores = storeList;
        employees = employeeList;
        selectedStore = storeStillExists ? previousStore : null;
        selectedEmployeeId =
            employeeStillExists ? previousEmployeeId : null;
        loadError = null;

        if (rememberedSelectionBecameInvalid) {
          rememberDevice = false;
          autoLoginTriggered = false;
          pinController.clear();
        }
      });

      // 새로 추가된 직원의 검증값도 이후 로그인에 대비해 미리 올립니다.
      verifiedPasswordPreloadFuture =
          _preloadVerifiedPasswords(employeeList);

      debugPrint('[목록캐시갱신] 매장/직원 최신 목록 반영 완료');
    } catch (e) {
      // 기존 캐시가 있으므로 갱신 실패는 로그인 화면을 막지 않습니다.
      debugPrint('[목록캐시갱신] 서버 갱신 생략: $e');
    } finally {
      bootstrapRefreshInFlight = false;
    }
  }

  void _scheduleBootstrapCacheOnlyRefresh({
    Duration delay = const Duration(seconds: 30),
  }) {
    bootstrapRefreshTimer?.cancel();
    bootstrapRefreshTimer = Timer(delay, () {
      if (!mounted || bootstrapRefreshInFlight) {
        return;
      }

      unawaited(_refreshBootstrapCacheOnly());
    });
  }

  Future<void> _refreshBootstrapCacheOnly() async {
    if (!mounted || bootstrapRefreshInFlight) {
      return;
    }

    bootstrapRefreshInFlight = true;

    try {
      final data = await callApi({
        'action': 'bootstrap',
      });

      if (data['success'] == true &&
          data['stores'] is List &&
          data['employees'] is List) {
        await saveBootstrapCache(data);
        debugPrint('[목록캐시갱신] 로그인 후 최신 목록 캐시 저장 완료');
      }
    } catch (e) {
      debugPrint('[목록캐시갱신] 로그인 후 캐시 저장 생략: $e');
    } finally {
      bootstrapRefreshInFlight = false;
    }
  }

  Future<void> loadData() async {
    // 앱 시작 시에는 서버 요청보다 로컬 캐시를 먼저 사용합니다.
    // 캐시가 있으면 로그인과 bootstrap 요청을 동시에 보내지 않습니다.
    final rememberedFuture = readRememberedLogin();
    final cacheFuture = readBootstrapCache();

    Map<String, String>? remembered;
    Map<String, dynamic>? cachedData;

    try {
      remembered = await rememberedFuture;
    } catch (_) {
      remembered = null;
    }

    // 자동로그인 정보가 확인되는 즉시 현재 출퇴근 상태 조회를 먼저 시작합니다.
    // 매장/직원 캐시를 적용하고 자동로그인 화면 전환을 준비하는 동안 서버 조회가 병렬로 진행됩니다.
    if (remembered != null) {
      final employeeId = remembered['employeeId'];
      final password = remembered['password'];
      final store = remembered['store'];

      if (employeeId != null &&
          employeeId.isNotEmpty &&
          password != null &&
          RegExp(r'^\d{4}$').hasMatch(password) &&
          store != null &&
          store.isNotEmpty) {
        startupStatusEmployeeId = employeeId;
        startupStatusPassword = password;
        startupStatusStore = store;
        startupStatusPasswordGeneration = _verifiedPasswordGeneration(employeeId);
        // 기억된 비밀번호는 이전에 서버 인증을 통과한 값이므로 저장된 세션 토큰을 함께 보냅니다.
        // 토큰이 없거나 무효면 서버가 기존처럼 비밀번호 검증 후 새 토큰을 발급합니다.
        startupStatusFuture = () async {
          final savedToken = await _readSavedActionToken(employeeId);
          return callApi({
            'action': 'status',
            'employeeId': employeeId,
            'password': password,
            'selectedStore': store,
            'actionToken': ?savedToken,
          });
        }();

        // 자동로그인 화면 준비보다 서버 오류가 먼저 도착해도
        // Future 오류가 미처리 상태로 남지 않게 감시만 붙여 둡니다.
        unawaited(
          startupStatusFuture!.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          ),
        );

        debugPrint('[앱시작상태] 자동로그인 직원 status 선조회 시작');
      }
    }

    try {
      cachedData = await cacheFuture;
    } catch (_) {
      cachedData = null;
    }

    Future<void> applyInitialData(
      Map<String, dynamic> data,
    ) async {
      final storeList = (data['stores'] as List? ?? [])
          .map(
            (item) => item['storeName'].toString(),
          )
          .toList();

      final employeeList = (data['employees'] as List? ?? [])
          .map(
            (item) => Employee(
              id: item['employeeId'].toString(),
              name: item['name'].toString(),
              defaultStore:
                  item['defaultStore']?.toString().trim() ?? '',
            ),
          )
          .toList();

      // 로그인 화면을 사용하는 동안 보안 저장소의 검증값을 미리 메모리에 올립니다.
      verifiedPasswordPreloadFuture =
          _preloadVerifiedPasswords(employeeList);

      String? restoredStore;
      String? restoredEmployeeId;
      String? restoredPassword;
      var shouldAutoLogin = false;
      var shouldClearRemembered = false;

      if (remembered != null) {
        final savedStore = remembered['store'];
        final savedEmployeeId = remembered['employeeId'];
        final savedPassword = remembered['password'];

        Employee? rememberedEmployee;

        if (savedEmployeeId != null) {
          for (final employee in employeeList) {
            if (employee.id == savedEmployeeId) {
              rememberedEmployee = employee;
              break;
            }
          }
        }

        if (rememberedEmployee != null &&
            savedPassword != null &&
            RegExp(r'^\d{4}$').hasMatch(savedPassword)) {
          // 기존 로그인 유지 정보는 서버 인증 성공 뒤에만 저장되므로
          // 메모리 검증값으로 바로 사용할 수 있습니다.
          if (_verifiedPasswordGeneration(savedEmployeeId!) == 0) {
            verifiedPasswordMemory.putIfAbsent(savedEmployeeId, () => savedPassword);
          }

          final currentDefaultStore =
              rememberedEmployee.defaultStore;

          if (currentDefaultStore.isNotEmpty &&
              storeList.contains(currentDefaultStore)) {
            restoredStore = currentDefaultStore;
          } else if (savedStore != null &&
              storeList.contains(savedStore)) {
            restoredStore = savedStore;
          }

          if (restoredStore != null) {
            restoredEmployeeId = savedEmployeeId;
            restoredPassword = savedPassword;
            shouldAutoLogin = true;
          } else {
            shouldClearRemembered = true;
          }
        } else {
          shouldClearRemembered = true;
        }
      }

      if (shouldClearRemembered) {
        unawaited(clearRememberedLogin());
      }

      if (!mounted) return;

      setState(() {
        stores = storeList;
        employees = employeeList;
        selectedStore = restoredStore;
        selectedEmployeeId = restoredEmployeeId;
        rememberDevice = shouldAutoLogin;
        loadError = null;

        if (restoredPassword != null) {
          pinController.text = restoredPassword;
        }
      });

      if (shouldAutoLogin && !autoLoginTriggered) {
        autoLoginTriggered = true;

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            login();
          }
        });
      }
    }

    // 캐시가 있으면 화면과 자동로그인을 즉시 준비합니다.
    // 자동로그인이 없는 로그인 화면에서는 2초 뒤 서버 최신 목록을 조용히 갱신합니다.
    // 그 전에 사용자가 로그인을 시작하면 타이머를 취소해 로그인 속도를 우선합니다.
    if (cachedData != null) {
      await applyInitialData(cachedData);

      if (!autoLoginTriggered) {
        _scheduleBootstrapRefresh();
      }
      return;
    }

    // 첫 설치처럼 캐시가 전혀 없을 때만 bootstrap을 즉시 요청합니다.
    try {
      final data = await callApi({
        'action': 'bootstrap',
      });

      unawaited(saveBootstrapCache(data));
      await applyInitialData(data);
    } catch (e) {
      if (!mounted) return;

      setState(() {
        loadError = 'V1 데이터를 불러오지 못했습니다.\n$e';
      });
    }
  }

  // 목록 갱신은 로그인 화면이 잠깐 유휴 상태일 때만 수행하고,
  // 실제 로그인 시작 시에는 예약된 갱신을 취소해 인증 요청을 최우선으로 둡니다.

  Future<void> login() async {
    if (loginStarted) return;

    if (selectedStore == null) {
      showMessage('매장을 선택해주세요.');
      return;
    }

    if (selectedEmployeeId == null) {
      showMessage('직원을 선택해주세요.');
      return;
    }

    if (pinController.text.length != 4) {
      showMessage('비밀번호 4자리를 입력해주세요.');
      return;
    }

    bootstrapRefreshTimer?.cancel();

    final employee = employees.firstWhere(
      (item) => item.id == selectedEmployeeId,
    );

    final employeeId = selectedEmployeeId!;
    final store = selectedStore!;
    final password = pinController.text;
    int passwordGeneration = _verifiedPasswordGeneration(employeeId);

    final canReuseStartupStatus = _matchesStartupStatusRequest(
      employeeId: employeeId,
      password: password,
      store: store,
    );

    String? savedActionToken;

    Future<Map<String, dynamic>> makeStatusFuture() {
      if (canReuseStartupStatus) {
        passwordGeneration = startupStatusPasswordGeneration ?? passwordGeneration;
        debugPrint('[앱시작상태] 앱 시작 때 선조회한 status 요청 재사용');
        return startupStatusFuture!;
      }

      return callApi({
        'action': 'status',
        'employeeId': employeeId,
        'password': password,
        'selectedStore': store,
        'actionToken': ?savedActionToken,
      });
    }

    if (loginNotice != null) {
      loginNoticeTimer?.cancel();
      setState(() {
        loginNotice = null;
        loginNoticeVisible = false;
      });
    }

    Future<Map<String, dynamic>> statusFuture;
    Map<String, dynamic>? alreadyConfirmedAttendance;

    setState(() { loginStarted = true; });
    Map<String, dynamic>? serverConfirmedAttendance;
    bool locallyVerified = false;
    try {
      final savedTokenFuture = _readSavedActionToken(employeeId);
      // 전체 직원 프리로드를 기다리지 않고 선택한 직원의 검증값만 확인합니다.
      String? localPassword = _verifiedPasswordValues.containsKey(employeeId)
          ? _verifiedPasswordValues[employeeId]
          : verifiedPasswordMemory[employeeId];
      if (localPassword == null) {
        try {
          localPassword = await readVerifiedPassword(employeeId);
        } catch (_) {
          // 저장소를 읽지 못하면 서버 인증으로 판단합니다.
        }
      }
      final savedToken = await savedTokenFuture;
      if (!mounted) return;
      passwordGeneration = _verifiedPasswordGeneration(employeeId);
      locallyVerified = localPassword == password;
      // 서버는 세션 토큰이 유효하면 입력한 비밀번호를 다시 대조하지 않습니다.
      // 그래서 이 기기에서 이미 서버 인증된 비밀번호와 같을 때만 저장된 토큰을 씁니다.
      // 처음 입력하거나 다른 비밀번호면 토큰 없이 보내 기존처럼 서버가 비밀번호를 검증합니다.
      savedActionToken = locallyVerified ? savedToken : null;
      statusFuture = makeStatusFuture();
      // 캐시 읽기 중 서버 오류가 먼저 도착해도 미처리 오류로 남기지 않습니다.
      unawaited(statusFuture.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
      if (!locallyVerified) {
        final data = await statusFuture;
        if (!mounted) return;
        if (passwordGeneration != _verifiedPasswordGeneration(employeeId)) {
          setState(() { loginStarted = false; });
          showMessage('비밀번호 정보가 변경되었습니다. 다시 로그인해주세요.');
          return;
        }
        if (data['success'] != true) {
          if (canReuseStartupStatus) startupStatusFuture = null;
          setState(() { loginStarted = false; });
          showMessage(data['message']?.toString() ?? '로그인에 실패했습니다.');
          return;
        }
        try {
          await saveVerifiedPassword(employeeId, password,
              expectedGeneration: passwordGeneration);
        } catch (_) {
          if (!mounted) return;
          setState(() { loginStarted = false; });
          showMessage('로그인 정보 저장에 실패했습니다. 다시 시도해주세요.');
          return;
        }
        if (!mounted) return;
        if (_verifiedPasswordGeneration(employeeId) != passwordGeneration + 1) {
          setState(() { loginStarted = false; });
          showMessage('비밀번호 정보가 변경되었습니다. 다시 로그인해주세요.');
          return;
        }
        passwordGeneration = _verifiedPasswordGeneration(employeeId);
        verifiedPasswordMemory[employeeId] = password;
        if (data['attendance'] is Map) {
          serverConfirmedAttendance = Map<String, dynamic>.from(data['attendance']);
        }
      }
    } catch (_) {
      if (!mounted) return;
      if (canReuseStartupStatus) startupStatusFuture = null;
      setState(() { loginStarted = false; });
      showMessage('서버 연결에 실패했습니다.');
      return;
    }

    debugPrint(
      locallyVerified
          ? '[즉시로그인V5] 로컬 검증 성공 - 즉시 WorkPage 이동'
          : '[로그인검증] 서버 인증 성공 후 WorkPage 이동',
    );

    if (!mounted) return;

    // 직접 로그인과 자동로그인 모두 저장된 상태를 먼저 표시합니다.
    // 마지막으로 서버에서 확정된 상태가 있으면 그 값을 첫 화면에 즉시 사용하고,
    // 위에서 이미 시작한 statusFuture가 뒤에서 최신 상태로 조용히 교정합니다.
    try {
      final confirmedFuture = readLastConfirmedAttendance(
        employeeId: employeeId,
        store: store,
      );
      final recentIntentFuture = readRecentAttendanceIntent(
        employeeId: employeeId,
        store: store,
      );

      alreadyConfirmedAttendance = await confirmedFuture;
      final recentIntent = await recentIntentFuture;
      if (recentIntent != null) {
        alreadyConfirmedAttendance = recentIntent;
      }
    } catch (_) {
      alreadyConfirmedAttendance = null;
    }

    if (alreadyConfirmedAttendance != null) {
      debugPrint('[앱시작상태] 마지막 서버 확정 상태로 WorkPage 즉시 진입');
    } else {
      debugPrint('[앱시작상태] 저장된 확정 상태 없음 - VERIFYING으로 즉시 진입');
    }

    Map<String, dynamic> initialAttendance = const {
      'status': 'VERIFYING',
    };

    if (alreadyConfirmedAttendance != null) {
      initialAttendance =
          Map<String, dynamic>.from(alreadyConfirmedAttendance);
    }
    if (serverConfirmedAttendance != null) {
      initialAttendance = serverConfirmedAttendance;
    }

    if (!mounted) return;
    if (passwordGeneration != _verifiedPasswordGeneration(employeeId)) {
      setState(() { loginStarted = false; });
      showMessage('비밀번호 정보가 변경되었습니다. 다시 로그인해주세요.');
      return;
    }

    // 빠르게 로그인한 경우에도 캐시가 영구히 고정되지 않도록
    // 로그인 후 30초 뒤 최신 목록을 캐시에만 조용히 저장합니다.
    // 로그인 화면으로 먼저 돌아오면 아래 복귀 갱신이 이 예약을 대체합니다.
    _scheduleBootstrapCacheOnlyRefresh();

    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => WorkPage(
          store: store,
          employee: employee.name,
          employeeId: employeeId,
          password: password,
          attendance: initialAttendance,
          loginFuture: statusFuture,
          loginPasswordGeneration: passwordGeneration,
          rememberDevice: rememberDevice,
          onPasswordChanged: (newPassword) {
            if (!mounted) return;

            // 서버에서 변경 성공이 확정된 새 비밀번호를 메모리에도 즉시 반영합니다.
            verifiedPasswordMemory[employeeId] = newPassword;

            setState(() {
              rememberDevice = false;
              pinController.clear();
              autoLoginTriggered = false;
            });
          },
          onRememberCleared: () {
            if (!mounted) return;

            setState(() {
              rememberDevice = false;
              selectedStore = null;
              selectedEmployeeId = null;
              pinController.clear();
              autoLoginTriggered = false;
            });
          },
        ),
      ),
    );

    if (!mounted) return;

    setState(() {
      loginStarted = false;
    });

    // 로그아웃/인증실패/비밀번호변경으로 로그인 화면에 돌아오면
    // 곧바로 최신 매장/직원 목록을 다시 확인합니다.
    _scheduleBootstrapRefresh(
      delay: const Duration(milliseconds: 500),
    );

    if (result == 'loginInvalid') {
      // 로컬 검증값이 오래돼 서버에서 거부된 경우 다음 로그인부터 재검증합니다.
      verifiedPasswordMemory.remove(employeeId);
      pinController.clear();
      return;
    }

    if (result == 'passwordChanged') {
      // 비밀번호 변경 완료 문구를 즉시 보여주고,
      // 1초 뒤부터 0.4초 동안 서서히 사라지게 합니다.
      loginNoticeTimer?.cancel();
      setState(() {
        loginNotice = '비밀번호 변경 완료';
        loginNoticeVisible = true;
      });

      loginNoticeTimer = Timer(const Duration(seconds: 1), () {
        if (!mounted) return;

        setState(() {
          loginNoticeVisible = false;
        });

        Future.delayed(const Duration(milliseconds: 400), () {
          if (!mounted || loginNoticeVisible) return;

          setState(() {
            loginNotice = null;
          });
        });
      });
    }
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 450,
              ),
              child: Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: isLoading
                      ? const Center(
                          child: CircularProgressIndicator(),
                        )
                      : loadError != null
                          ? Column(
                              children: [
                                const Icon(
                                  Icons.error_outline,
                                  size: 60,
                                ),
                                const SizedBox(height: 16),
                                Text(loadError!),
                                const SizedBox(height: 20),
                                FilledButton(
                                  onPressed: () {
                                    setState(() {
                                      loadError = null;
                                    });
                                    loadData();
                                  },
                                  child: const Text('다시 시도'),
                                ),
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Icon(
                                  Icons.access_time_filled,
                                  size: 64,
                                  color: Color(0xFF2563EB),
                                ),
                                const SizedBox(height: 16),
                                const Text(
                                  '출퇴근 관리',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '직원 선택 시 기본 근무 매장이 자동으로 설정돼요.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Colors.grey,
                                  ),
                                ),
                                if (loginNotice != null) ...[
                                  const SizedBox(height: 16),
                                  AnimatedOpacity(
                                    opacity: loginNoticeVisible ? 1.0 : 0.0,
                                    duration: const Duration(milliseconds: 400),
                                    curve: Curves.easeOut,
                                    child: Text(
                                      loginNotice!,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                ] else
                                  const SizedBox(height: 32),
                                DropdownButtonFormField<String>(
                                  key: ValueKey(
                                    'store-${selectedStore ?? ''}',
                                  ),
                                  initialValue: selectedStore,
                                  decoration: InputDecoration(
                                    labelText: '근무 매장',
                                    labelStyle: const TextStyle(
                                      color: Color(0xFF24365B),
                                      fontWeight: FontWeight.w600,
                                    ),
                                    prefixIcon: const Icon(
                                      Icons.store,
                                      color: Color(0xFF2563EB),
                                    ),
                                    filled: true,
                                    fillColor: Colors.white,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 18,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: const BorderSide(
                                        color: Color(0xFFD6DCE8),
                                      ),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: const BorderSide(
                                        color: Color(0xFFD6DCE8),
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: const BorderSide(
                                        color: Color(0xFF2563EB),
                                        width: 1.6,
                                      ),
                                    ),
                                  ),
                                  items: stores
                                      .map(
                                        (store) => DropdownMenuItem(
                                          value: store,
                                          child: Text(store),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (value) {
                                    setState(() {
                                      selectedStore = value;
                                    });
                                  },
                                ),
                                const SizedBox(height: 16),
                                DropdownButtonFormField<String>(
                                  initialValue: selectedEmployeeId,
                                  decoration: InputDecoration(
                                    labelText: '직원 선택',
                                    labelStyle: const TextStyle(
                                      color: Color(0xFF24365B),
                                      fontWeight: FontWeight.w600,
                                    ),
                                    prefixIcon: const Icon(
                                      Icons.person,
                                      color: Color(0xFF2563EB),
                                    ),
                                    filled: true,
                                    fillColor: Colors.white,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 18,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: const BorderSide(
                                        color: Color(0xFFD6DCE8),
                                      ),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: const BorderSide(
                                        color: Color(0xFFD6DCE8),
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: const BorderSide(
                                        color: Color(0xFF2563EB),
                                        width: 1.6,
                                      ),
                                    ),
                                  ),
                                  items: employees
                                      .map(
                                        (employee) => DropdownMenuItem(
                                          value: employee.id,
                                          child: Text(employee.name),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (value) {
                                    String? employeeStore;

                                    if (value != null) {
                                      for (final employee in employees) {
                                        if (employee.id == value) {
                                          final defaultStore =
                                              employee.defaultStore.trim();

                                          if (defaultStore.isNotEmpty &&
                                              stores.contains(defaultStore)) {
                                            employeeStore = defaultStore;
                                          }

                                          break;
                                        }
                                      }
                                    }

                                    setState(() {
                                      selectedEmployeeId = value;

                                      // 기존 V2.3 동작과 동일:
                                      // 직원을 고르면 직원DB D열의 기본매장을 적용합니다.
                                      // 등록된 매장과 일치하지 않으면 매장 선택을 비웁니다.
                                      selectedStore = employeeStore;
                                    });
                                  },
                                ),
                                const SizedBox(height: 16),
                                TextField(
                                  controller: pinController,
                                  obscureText: !showLoginPassword,
                                  keyboardType: TextInputType.number,
                                  maxLength: 4,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly,
                                    LengthLimitingTextInputFormatter(4),
                                  ],
                                  decoration: InputDecoration(
                                    labelText: '비밀번호 4자리',
                                    labelStyle: const TextStyle(
                                      color: Color(0xFF24365B),
                                      fontWeight: FontWeight.w600,
                                    ),
                                    prefixIcon: const Icon(
                                      Icons.lock,
                                      color: Color(0xFF2563EB),
                                    ),
                                    suffixIcon: IconButton(
                                      onPressed: () {
                                        setState(() {
                                          showLoginPassword = !showLoginPassword;
                                        });
                                      },
                                      icon: Icon(
                                        showLoginPassword
                                            ? Icons.visibility_off
                                            : Icons.visibility,
                                        color: const Color(0xFF7C859A),
                                      ),
                                    ),
                                    filled: true,
                                    fillColor: Colors.white,
                                    counterText: '',
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 18,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: const BorderSide(
                                        color: Color(0xFFD6DCE8),
                                      ),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: const BorderSide(
                                        color: Color(0xFFD6DCE8),
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: const BorderSide(
                                        color: Color(0xFF2563EB),
                                        width: 1.6,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                CheckboxListTile(
                                  value: rememberDevice,
                                  contentPadding: EdgeInsets.zero,
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  title: const Text(
                                    '이 기기 기억하기',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  onChanged: (value) {
                                    final checked = value ?? false;

                                    setState(() {
                                      rememberDevice = checked;
                                    });

                                    if (!checked) {
                                      clearRememberedLogin();
                                    }
                                  },
                                ),
                                const SizedBox(height: 12),
                                SizedBox(
                                  height: 56,
                                  child: FilledButton(
                                    onPressed: loginStarted
                                        ? null
                                        : () => unawaited(login()),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: const Color(0xFF5568A9),
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(28),
                                      ),
                                    ),
                                    child: Text(
                                      loginStarted ? '로그인 확인 중...' : '확인',
                                      style: const TextStyle(
                                        fontSize: 17,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PasswordChangeDialog extends StatefulWidget {
  final String currentPassword;

  const PasswordChangeDialog({
    super.key,
    required this.currentPassword,
  });

  @override
  State<PasswordChangeDialog> createState() =>
      _PasswordChangeDialogState();
}

class _PasswordChangeDialogState
    extends State<PasswordChangeDialog> {
  final TextEditingController currentController =
      TextEditingController();
  final TextEditingController newController =
      TextEditingController();
  final TextEditingController confirmController =
      TextEditingController();

  bool showCurrentPassword = false;
  bool showNewPassword = false;
  bool showConfirmPassword = false;

  String? dialogError;

  void _validateNewPasswordMatchLive() {
    final next = newController.text.trim();
    final confirm = confirmController.text.trim();

    final isSameAsCurrent =
        next.length == 4 && next == widget.currentPassword;

    if (isSameAsCurrent) {
      if (dialogError !=
          '현재 사용중인 비밀번호입니다. 다른 비밀번호를 입력해주세요.') {
        setState(() {
          dialogError =
              '현재 사용중인 비밀번호입니다. 다른 비밀번호를 입력해주세요.';
        });
      }
      return;
    }

    final shouldShowMismatch =
        next.length == 4 && confirm.length == 4 && next != confirm;

    if (shouldShowMismatch) {
      if (dialogError != '새 비밀번호가 일치하지 않습니다.') {
        setState(() {
          dialogError = '새 비밀번호가 일치하지 않습니다.';
        });
      }
      return;
    }

    if (dialogError == '새 비밀번호가 일치하지 않습니다.' ||
        dialogError ==
            '현재 사용중인 비밀번호입니다. 다른 비밀번호를 입력해주세요.') {
      setState(() {
        dialogError = null;
      });
    }
  }

  @override
  void dispose() {
    currentController.dispose();
    newController.dispose();
    confirmController.dispose();
    super.dispose();
  }

  void submit() {
    final current = currentController.text.trim();
    final next = newController.text.trim();
    final confirm = confirmController.text.trim();

    if (!RegExp(r'^\d{4}$').hasMatch(current) ||
        !RegExp(r'^\d{4}$').hasMatch(next) ||
        !RegExp(r'^\d{4}$').hasMatch(confirm)) {
      setState(() {
        dialogError = '비밀번호는 숫자 4자리입니다.';
      });
      return;
    }

    if (next == widget.currentPassword) {
      setState(() {
        dialogError = '현재 사용중인 비밀번호입니다. 다른 비밀번호를 입력해주세요.';
      });
      return;
    }

    if (next != confirm) {
      setState(() {
        dialogError = '새 비밀번호가 일치하지 않습니다.';
      });
      return;
    }

    FocusScope.of(context).unfocus();

    // 입력값 검사는 앱에서 즉시 끝냅니다.
    // 서버 저장 확인은 근무 화면에서 백그라운드로 진행합니다.
    Navigator.of(context).pop(<String, String>{
      'current': current,
      'next': next,
      'confirm': confirm,
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final dialogContentWidth =
        screenWidth > 560 ? 480.0 : screenWidth - 48;

    const compactInputDecorationPadding = EdgeInsets.symmetric(
      horizontal: 14,
      vertical: 11,
    );

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 10,
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 2),
      actionsPadding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
      title: const Text(
        '비밀번호 변경',
        style: TextStyle(fontSize: 20),
      ),
      content: SizedBox(
        width: dialogContentWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '비밀번호는 숫자 4자리입니다.',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey,
              ),
            ),
            if (dialogError != null) ...[
              const SizedBox(height: 4),
              Text(
                dialogError!,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 9),
            TextField(
              controller: currentController,
              onChanged: (_) => _validateNewPasswordMatchLive(),
              obscureText: !showCurrentPassword,
              keyboardType: TextInputType.number,
              maxLength: 4,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              decoration: InputDecoration(
                labelText: '현재 비밀번호',
                border: const OutlineInputBorder(),
                counterText: '',
                isDense: true,
                contentPadding: compactInputDecorationPadding,
                suffixIcon: IconButton(
                  onPressed: () {
                    setState(() {
                      showCurrentPassword = !showCurrentPassword;
                    });
                  },
                  icon: Icon(
                    showCurrentPassword
                        ? Icons.visibility_off
                        : Icons.visibility,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: newController,
              obscureText: !showNewPassword,
              keyboardType: TextInputType.number,
              maxLength: 4,
              onChanged: (_) => _validateNewPasswordMatchLive(),
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              decoration: InputDecoration(
                labelText: '새 비밀번호',
                border: const OutlineInputBorder(),
                counterText: '',
                isDense: true,
                contentPadding: compactInputDecorationPadding,
                suffixIcon: IconButton(
                  onPressed: () {
                    setState(() {
                      showNewPassword = !showNewPassword;
                    });
                  },
                  icon: Icon(
                    showNewPassword
                        ? Icons.visibility_off
                        : Icons.visibility,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: confirmController,
              obscureText: !showConfirmPassword,
              keyboardType: TextInputType.number,
              maxLength: 4,
              onChanged: (_) => _validateNewPasswordMatchLive(),
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              decoration: InputDecoration(
                labelText: '새 비밀번호 확인',
                border: const OutlineInputBorder(),
                counterText: '',
                isDense: true,
                contentPadding: compactInputDecorationPadding,
                suffixIcon: IconButton(
                  onPressed: () {
                    setState(() {
                      showConfirmPassword = !showConfirmPassword;
                    });
                  },
                  icon: Icon(
                    showConfirmPassword
                        ? Icons.visibility_off
                        : Icons.visibility,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            FocusScope.of(context).unfocus();
            Navigator.of(context).pop();
          },
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: submit,
          child: const Text('변경'),
        ),
      ],
    );
  }
}

class WorkPage extends StatefulWidget {
  final String store;
  final String employee;
  final String employeeId;
  final String password;
  final Map<String, dynamic> attendance;
  final Future<Map<String, dynamic>> loginFuture;
  final int? loginPasswordGeneration;
  final bool rememberDevice;
  final ValueChanged<String>? onPasswordChanged;
  final VoidCallback? onRememberCleared;

  const WorkPage({
    super.key,
    required this.store,
    required this.employee,
    required this.employeeId,
    required this.password,
    required this.attendance,
    required this.loginFuture,
    this.loginPasswordGeneration,
    required this.rememberDevice,
    this.onPasswordChanged,
    this.onRememberCleared,
  });

  @override
  State<WorkPage> createState() => _WorkPageState();
}

class _WorkPageState extends State<WorkPage>
    with WidgetsBindingObserver {
  bool isWorking = false;
  bool isProcessing = false;
  bool isLoginVerified = false;
  bool isPasswordChanging = false;
  bool authActionPending = false;
  bool attendanceActionQueued = false;
  bool clockOutQueuedAfterClockIn = false;
  bool clockInQueuedAfterClockOut = false;

  // 화면은 즉시 열어 두되, 실제 보호 기능은 로그인 검증이 끝난 뒤 실행합니다.
  // 버튼은 눌릴 수 있지만 잘못된 비밀번호라면 어떤 보호 API도 보내지 않습니다.
  final Completer<bool> loginReadyCompleter = Completer<bool>();

  // 서버 상태를 아직 모를 때는 미출근으로 단정하지 않습니다.
  // 이미 서버에서 확인된 상태가 있으면 initState에서 첫 프레임부터 바로 적용합니다.
  String attendanceStatus = 'VERIFYING';
  String statusText = '출근 상태 확인 중';
  String clockInText = '-';
  String clockOutText = '-';

  String liveWorkedText = '';
  String completedWorkedText = '';
  String completedBreakText = '';
  String completedGrossText = '';
  bool showBreak = false;
  bool completedViewHidden = false;

  int? actualInMs;
  DateTime? ignoreRecentCompletedUntil;

  late String currentPassword;

  // 로그인/status에서 서버가 발급한 짧은 수명의 출퇴근 액션 토큰입니다.
  // 토큰이 없거나 만료되면 서버가 기존 비밀번호 인증으로 자동 복귀합니다.
  String? actionToken;

  final TextEditingController noteController =
      TextEditingController();

  Timer? statusRefreshTimer;
  Timer? liveWorkedTimer;
  Timer? completedViewTimer;
  Timer? completedViewHideTimer;
  Timer? resumeStatusTimer;

  bool backgroundStatusInFlight = false;
  int backgroundStatusFailureCount = 0;
  bool backgroundStatusFailureNoticeShown = false;
  bool logoutInProgress = false;

  // 로그인 status 응답에서 확인된 실제 출퇴근 상태를 따로 보관합니다.
  // 로그인 확인 전에 출근 버튼을 먼저 누른 경우 중복 clockIn 전송을 막는 용도입니다.
  String? verifiedLoginAttendanceStatus;

  bool showWorkHistory = false;
  bool isCalendarLoading = false;
  bool hasCalendarLoaded = false;
  bool calendarNeedsRefresh = true;
  Timer? calendarRetryTimer;
  String? calendarError;
  List<Map<String, dynamic>> calendarRecords = [];

  late DateTime calendarMonth;
  int serverClockOffsetMs = 0;
  DateTime? _lastBackPressedAt;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    currentPassword = widget.password;

    final now = DateTime.now();
    calendarMonth = DateTime(now.year, now.month, 1);

    final initialAttendance =
        Map<String, dynamic>.from(widget.attendance);
    final initialStatus =
        initialAttendance['status']?.toString() ?? 'VERIFYING';

    if (initialStatus != 'VERIFYING') {
      applyAttendance(initialAttendance);
      debugPrint('[앱시작상태] WorkPage 첫 프레임에 서버 확인 상태 즉시 적용');
    }

    // 이전에 받아 둔 이번 달 근무기록은 로컬에서 먼저 복원합니다.
    // 서버 최신 조회는 사용자가 근무기록을 열었을 때 뒤에서 갱신합니다.
    unawaited(_restoreCalendarCache());

    // 로그인 화면에서 이미 시작해 둔 서버 요청의 결과만 기다립니다.
    // 화면은 먼저 열린 상태이고, 확인중/로딩 문구 없이
    // 서버 결과만 뒤에서 조용히 반영합니다.
    unawaited(_restoreActionTokenThenFinishLogin());
  }

  // 저장된 actionToken을 먼저 복원한 뒤에만 로그인 검증(및 그 안에서 이어지는
  // 미완료 출퇴근 복구)을 진행합니다 — 그래야 이 화면에서 나가는 첫 요청부터
  // 세션을 재사용하고, 매번 새로 비밀번호 인증을 타지 않습니다.
  Future<void> _restoreActionTokenThenFinishLogin() async {
    try {
      final saved = await secureStorage.read(
        key: actionTokenKey(widget.employeeId),
      );
      if (saved != null && saved.isNotEmpty) {
        actionToken = saved;
      }
    } catch (_) {
      debugPrint('[ACTION_TOKEN] restored=false');
    }

    await _finishLoginVerification();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    statusRefreshTimer?.cancel();
    liveWorkedTimer?.cancel();
    completedViewTimer?.cancel();
    completedViewHideTimer?.cancel();
    calendarRetryTimer?.cancel();
    resumeStatusTimer?.cancel();

    noteController.dispose();

    super.dispose();
  }

  void _scheduleResumeStatusRefresh({int attempt = 0}) {
    resumeStatusTimer?.cancel();
    resumeStatusTimer = Timer(
      const Duration(seconds: 2),
      () {
        if (!mounted) return;

        final busy = !isLoginVerified ||
            isProcessing ||
            authActionPending ||
            attendanceActionQueued ||
            isPasswordChanging ||
            backgroundStatusInFlight;

        if (busy) {
          if (attempt < 2) {
            debugPrint('[출퇴근최우선] 앱복귀 status 재예약 - 중요 작업 우선');
            _scheduleResumeStatusRefresh(attempt: attempt + 1);
          } else {
            debugPrint('[출퇴근최우선] 앱복귀 status 재확인 종료 - 다음 주기조회 사용');
          }
          return;
        }

        unawaited(refreshAttendanceStatus());
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 복귀 직후 중요 작업과 겹치면 버리지 않고 최대 두 번 더 재예약합니다.
      _scheduleResumeStatusRefresh();
    }
  }

  Future<void> _recoverPendingClockInAfterLogin(
    Map<String, dynamic>? loginAttendance,
  ) async {
    // 같은 화면에서 이미 출근 처리가 진행 중이면 기존 흐름이 그대로 마무리합니다.
    if (attendanceActionQueued || isProcessing) return;

    final hasPending = await hasRecentPendingClockIn(
      employeeId: widget.employeeId,
      store: widget.store,
    );
    if (!mounted || !hasPending) return;

    final status = loginAttendance?['status']?.toString() ??
        verifiedLoginAttendanceStatus ??
        attendanceStatus;

    // 이전 요청이 서버에 이미 저장됐다면 재전송하지 않고 대기 표시만 정리합니다.
    if (status == 'WORKING') {
      await clearPendingClockIn(widget.employeeId);
      return;
    }

    // 출근 가능한 상태일 때만, 종료 때문에 전송되지 못한 요청을 한 번 이어 보냅니다.
    if (status != 'NOT_IN' && status != 'COMPLETED') return;

    setState(() {
      attendanceActionQueued = true;
    });

    unawaited(clockIn());
  }

  Future<void> _recoverPendingClockOutAfterLogin(
    Map<String, dynamic>? loginAttendance,
  ) async {
    if (attendanceActionQueued || isProcessing) return;

    final pending = await readRecentPendingClockOut(
      employeeId: widget.employeeId,
      store: widget.store,
    );
    if (!mounted || pending == null) return;

    final status = loginAttendance?['status']?.toString() ??
        verifiedLoginAttendanceStatus ??
        attendanceStatus;

    // 서버가 이미 퇴근 상태라면 재전송하지 않고 대기 표시만 정리합니다.
    if (status == 'NOT_IN' || status == 'COMPLETED') {
      await clearPendingClockOut(widget.employeeId);
      return;
    }

    if (status != 'WORKING') return;

    setState(() {
      attendanceActionQueued = true;
    });

    unawaited(
      clockOut(
        recoveryNote: pending['note']?.toString() ?? '',
      ),
    );
  }

  Future<void> _recoverPendingAttendanceAfterLogin(
    Map<String, dynamic>? loginAttendance,
  ) async {
    await _recoverPendingClockInAfterLogin(loginAttendance);
    if (!mounted || attendanceActionQueued || isProcessing) return;
    await _recoverPendingClockOutAfterLogin(loginAttendance);
  }

  Future<void> _finishLoginVerification() async {
    final passwordGeneration = widget.loginPasswordGeneration ??
        _verifiedPasswordGeneration(widget.employeeId);
    try {
      final data = await widget.loginFuture;
      if (passwordGeneration != _verifiedPasswordGeneration(widget.employeeId)) {
        if (!loginReadyCompleter.isCompleted) loginReadyCompleter.complete(false);
        if (mounted) Navigator.of(context).pop('loginSuperseded');
        return;
      }
      _captureActionToken(data);

      final loginDiag = data['_apiDiag'];
      if (loginDiag is Map) {
        debugPrint(
          '[로그인구간진단] 인증=${loginDiag['authMs'] ?? '-'}ms / '
          '상태=${loginDiag['statusMs'] ?? '-'}ms / '
          'API내부=${loginDiag['totalMs'] ?? '-'}ms',
        );
      }

      if (!mounted) {
        if (!loginReadyCompleter.isCompleted) {
          loginReadyCompleter.complete(false);
        }
        return;
      }

      if (data['success'] != true) {
        if (!loginReadyCompleter.isCompleted) {
          loginReadyCompleter.complete(false);
        }

        // 로컬 즉시 로그인 뒤 서버에서 인증 실패가 확인되면
        // 오래된 검증값을 즉시 폐기합니다.
        unawaited(
          clearVerifiedPassword(widget.employeeId,
              expectedGeneration: passwordGeneration),
        );
        unawaited(clearPendingClockIn(widget.employeeId));
        unawaited(clearPendingClockOut(widget.employeeId));

        final message =
            data['message']?.toString() ?? '로그인에 실패했습니다.';

        // 잘못된 비밀번호면 현재 화면을 오래 유지하지 않습니다.
        if (widget.rememberDevice) {
          unawaited(clearRememberedLogin());
          widget.onRememberCleared?.call();
        }

        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
        Navigator.of(context).pop('loginInvalid');
        return;
      }

      final rawAttendance = data['attendance'];
      Map<String, dynamic>? loginAttendanceForRecovery;

      setState(() {
        isLoginVerified = true;

        // 첫 로그인 응답에 이미 현재 근무상태가 들어 있으므로
        // 별도의 status 요청 없이 바로 화면에 적용합니다.
        if (rawAttendance is Map) {
          final loginAttendance =
              Map<String, dynamic>.from(rawAttendance);
          loginAttendanceForRecovery = loginAttendance;
          verifiedLoginAttendanceStatus =
              loginAttendance['status']?.toString();
          unawaited(
            saveLastConfirmedAttendance(
              employeeId: widget.employeeId,
              store: widget.store,
              attendance: loginAttendance,
            ),
          );
          applyAttendance(loginAttendance);
        }
      });

      if (!loginReadyCompleter.isCompleted) {
        loginReadyCompleter.complete(true);
      }

      // 출퇴근 확인 직후 앱 종료로 실제 요청이 끝나지 못한 경우만 복구합니다.
      unawaited(
        _recoverPendingAttendanceAfterLogin(loginAttendanceForRecovery),
      );

      // 서버 인증 성공 시 로컬 검증값도 최신 상태로 유지합니다.
      unawaited(
        saveVerifiedPassword(
          widget.employeeId,
          currentPassword,
          expectedGeneration: passwordGeneration,
        ),
      );

      if (widget.rememberDevice) {
        unawaited(
          saveRememberedLogin(
            store: widget.store,
            employeeId: widget.employeeId,
            password: currentPassword,
          ),
        );
      }
    } catch (e) {
      if (!loginReadyCompleter.isCompleted) {
        loginReadyCompleter.complete(false);
      }

      if (!mounted ||
          passwordGeneration != _verifiedPasswordGeneration(widget.employeeId)) {
        return;
      }
      if (widget.rememberDevice) {
        unawaited(clearRememberedLogin());
        widget.onRememberCleared?.call();
      }

      debugPrint('[로그인 인증 통신 오류] $e');

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('서버 연결에 실패했습니다.'),
        ),
      );
      Navigator.of(context).pop();
    }
  }

  Future<bool> _waitForLoginReady() async {
    if (isLoginVerified) return true;

    try {
      return await loginReadyCompleter.future;
    } catch (_) {
      return false;
    }
  }

  void _captureActionToken(Map<String, dynamic> data) {
    final token = data['actionToken']?.toString().trim() ?? '';

    if (token.isNotEmpty) {
      actionToken = token;

      final employeeId = widget.employeeId;
      unawaited(() async {
        try {
          await secureStorage.write(
            key: actionTokenKey(employeeId),
            value: token,
          );
        } catch (_) {
          debugPrint('[ACTION_TOKEN] saved=false');
        }
      }());
    }
  }

  int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  DateTime _serverNow() {
    return DateTime.now().add(
      Duration(milliseconds: serverClockOffsetMs),
    );
  }

  void _syncServerClock(Map<String, dynamic> attendance) {
    final serverNowMs = _toInt(attendance['serverNowMs']);
    if (serverNowMs == null) return;

    serverClockOffsetMs =
        serverNowMs - DateTime.now().millisecondsSinceEpoch;
  }

  String _formatElapsedWorkedText(int startedAtMs) {
    final elapsedMinutes = (
      (_serverNow().millisecondsSinceEpoch - startedAtMs) / 60000
    ).floor();

    final safeMinutes = elapsedMinutes < 0 ? 0 : elapsedMinutes;
    final hours = safeMinutes ~/ 60;
    final minutes = safeMinutes % 60;

    if (hours > 0) {
      return '$hours시간 $minutes분';
    }

    return '$minutes분';
  }

  void _stopLiveWorkedTimer() {
    liveWorkedTimer?.cancel();
    liveWorkedTimer = null;
  }

  void _startLiveWorkedTimer() {
    _stopLiveWorkedTimer();

    final startedAt = actualInMs;

    if (startedAt == null) {
      liveWorkedText = '진행 중...';
      return;
    }

    liveWorkedText = _formatElapsedWorkedText(startedAt);

    liveWorkedTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        if (!mounted || attendanceStatus != 'WORKING') {
          _stopLiveWorkedTimer();
          return;
        }

        setState(() {
          liveWorkedText =
              _formatElapsedWorkedText(startedAt);
        });
      },
    );
  }

  void _stopStatusRefresh() {
    statusRefreshTimer?.cancel();
    statusRefreshTimer = null;
  }

  void _startStatusRefresh() {
    _stopStatusRefresh();

    if (!isLoginVerified ||
        attendanceStatus == 'COMPLETED') {
      return;
    }

    statusRefreshTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) {
        if (!mounted ||
            isProcessing ||
            authActionPending ||
            attendanceActionQueued ||
            isPasswordChanging ||
            backgroundStatusInFlight) {
          debugPrint('[출퇴근최우선] 60초 status 생략 - 중요 작업 우선');
          return;
        }

        unawaited(refreshAttendanceStatus());
      },
    );
  }

  void _clearCompletedViewTimer() {
    completedViewTimer?.cancel();
    completedViewTimer = null;
  }

  void _scheduleCompletedViewHide() {
    completedViewHideTimer?.cancel();
    completedViewHideTimer = Timer(
      const Duration(seconds: 3),
      () {
        if (!mounted || attendanceStatus != 'COMPLETED') return;
        setState(() {
          completedViewHidden = true;
        });
      },
    );
  }

  void _scheduleCompletedViewReset() {
    _clearCompletedViewTimer();

    completedViewTimer = Timer(
      const Duration(seconds: 3),
      () {
        if (!mounted ||
            attendanceStatus != 'COMPLETED') {
          return;
        }

        setState(() {
          attendanceStatus = 'NOT_IN';
          isWorking = false;
          statusText = '현재 미출근';
          clockInText = '-';
          clockOutText = '-';

          actualInMs = null;
          liveWorkedText = '';
          completedWorkedText = '';
          completedBreakText = '';
          completedGrossText = '';
          showBreak = false;

          // 서버는 퇴근 직후 약 1분간 COMPLETED를 반환할 수 있습니다.
          // 완료화면을 3초만 보여주기 위해 그 짧은 구간의
          // 자동 상태조회 COMPLETED 응답은 무시합니다.
          ignoreRecentCompletedUntil =
              DateTime.now().add(const Duration(seconds: 65));
        });

        _startStatusRefresh();
      },
    );
  }

  void applyAttendance(Map<String, dynamic> attendance) {
    _syncServerClock(attendance);

    final status =
        attendance['status']?.toString() ?? 'NOT_IN';

    attendanceStatus = status;
    isWorking = status == 'WORKING';

    if (status == 'WORKING') {
      _clearCompletedViewTimer();

      statusText = '현재 근무중';
      clockInText =
          attendance['adjustedInText']?.toString() ?? '-';
      clockOutText = '-';

      actualInMs = _toInt(attendance['actualInMs']);

      completedWorkedText = '';
      completedBreakText = '';
      completedGrossText = '';
      showBreak = false;
      ignoreRecentCompletedUntil = null;

      _startLiveWorkedTimer();
      _startStatusRefresh();
      return;
    }

    _stopLiveWorkedTimer();
    actualInMs = null;
    liveWorkedText = '';

    if (status == 'COMPLETED') {
      _stopStatusRefresh();

      statusText = '퇴근 완료';
      clockInText =
          attendance['adjustedInText']?.toString() ?? '-';
      clockOutText =
          attendance['adjustedOutText']?.toString() ?? '-';

      completedWorkedText =
          attendance['workedText']?.toString() ??
              '0시간 0분';
      completedBreakText =
          attendance['breakText']?.toString() ??
              '0시간 0분';
      completedGrossText =
          attendance['grossWorkedText']?.toString() ??
              completedWorkedText;
      showBreak = attendance['showBreak'] == true;

      completedViewHidden = false;
      _scheduleCompletedViewHide();
      _scheduleCompletedViewReset();
      return;
    }

    _clearCompletedViewTimer();

    statusText = '현재 미출근';
    clockInText = '-';
    clockOutText = '-';

    completedWorkedText = '';
    completedBreakText = '';
    completedGrossText = '';
    showBreak = false;

    noteController.clear();

    _startStatusRefresh();
  }

  String _currentMonthKey() {
    final now = _serverNow();

    return '${now.year}_'
        '${now.month.toString().padLeft(2, '0')}';
  }

  void _clearBackgroundStatusFailure() {
    backgroundStatusFailureCount = 0;
    backgroundStatusFailureNoticeShown = false;
  }

  void _recordBackgroundStatusFailure() {
    backgroundStatusFailureCount += 1;

    if (!mounted ||
        backgroundStatusFailureCount < 2 ||
        backgroundStatusFailureNoticeShown) {
      return;
    }

    backgroundStatusFailureNoticeShown = true;
    _showAttendanceMessage(
      '서버 연결이 불안정합니다. 현재 화면은 마지막 확인 상태입니다.',
    );
  }

  Future<void> refreshAttendanceStatus() async {
    if (!mounted ||
        !isLoginVerified ||
        isProcessing ||
        authActionPending ||
        attendanceActionQueued ||
        isPasswordChanging ||
        backgroundStatusInFlight ||
        attendanceStatus == 'COMPLETED') {
      return;
    }

    backgroundStatusInFlight = true;

    try {
      final data = await callApi({
        'action': 'status',
        'employeeId': widget.employeeId,
        'password': currentPassword,
        'selectedStore': widget.store,
      });

      if (!mounted) return;

      if (data['success'] != true) {
        _recordBackgroundStatusFailure();
        return;
      }

      _clearBackgroundStatusFailure();

      // status 요청을 보낸 뒤 사용자가 출퇴근을 시작했다면
      // 정상 응답이어도 늦게 도착한 값으로 사용자의 진행 중 화면을 덮지 않습니다.
      if (attendanceActionQueued || isProcessing) {
        return;
      }

      final attendance = Map<String, dynamic>.from(
        data['attendance'] ?? {},
      );

      final status =
          attendance['status']?.toString() ?? 'NOT_IN';

      if (
        status == 'COMPLETED' &&
        ignoreRecentCompletedUntil != null &&
        DateTime.now().isBefore(ignoreRecentCompletedUntil!)
      ) {
        return;
      }

      unawaited(
        saveLastConfirmedAttendance(
          employeeId: widget.employeeId,
          store: widget.store,
          attendance: attendance,
        ),
      );

      setState(() {
        applyAttendance(attendance);
      });
    } catch (_) {
      // 한 번의 순간적인 실패는 조용히 넘기고, 연속 실패 시에만 한 번 안내합니다.
      _recordBackgroundStatusFailure();
    } finally {
      backgroundStatusInFlight = false;
    }
  }

  Future<bool> _showAttendanceConfirmDialog(
    String message,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          content: Text(message, textAlign: TextAlign.center),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text('확인'),
            ),
          ],
        );
      },
    );

    return result ?? false;
  }

  Future<void> requestClockIn() async {
    final canUseClockIn =
        attendanceStatus == 'NOT_IN' ||
        attendanceStatus == 'COMPLETED';

    if (authActionPending ||
        isPasswordChanging ||
        clockInQueuedAfterClockOut ||
        !canUseClockIn ||
        isProcessing ||
        (attendanceActionQueued && clockOutQueuedAfterClockIn)) {
      return;
    }

    // 퇴근 저장 확인이 끝난 완료 화면에서만 새 출근 요청을 받습니다.
    if (attendanceStatus == 'COMPLETED') {
      final confirmed = await _showAttendanceConfirmDialog(
        '출근하시겠습니까?',
      );

      if (!confirmed || !mounted) {
        return;
      }

      await savePendingClockIn(
        employeeId: widget.employeeId,
        store: widget.store,
      );
      if (!mounted) return;

      clockInQueuedAfterClockOut = true;
      resumeStatusTimer?.cancel();

      final deadline = DateTime.now().add(
        const Duration(seconds: 30),
      );

      while (mounted &&
          isProcessing &&
          DateTime.now().isBefore(deadline)) {
        await Future.delayed(
          const Duration(milliseconds: 50),
        );
      }

      if (!mounted) return;

      if (isProcessing ||
          (attendanceStatus != 'COMPLETED' &&
              attendanceStatus != 'NOT_IN')) {
        setState(() {
          clockInQueuedAfterClockOut = false;
          attendanceActionQueued = false;
        });
        _showAttendanceMessage(
          '퇴근 저장 확인이 아직 끝나지 않았습니다. 상태를 다시 확인합니다.',
        );
        _scheduleResumeStatusRefresh();
        return;
      }

      _clearCompletedViewTimer();

      setState(() {
        clockInQueuedAfterClockOut = false;
        attendanceActionQueued = true;
      });

      unawaited(clockIn());
      return;
    }

    // 확인창을 띄우는 순간부터 출근 요청을 최우선 예약합니다.
    attendanceActionQueued = true;
    resumeStatusTimer?.cancel();

    final confirmed = await _showAttendanceConfirmDialog(
      '출근하시겠습니까?',
    );

    if (!confirmed || !mounted) {
      // 확인창이 열려 있는 동안 다른 setState가 이미 버튼을 비활성으로 그렸을 수 있으므로
      // 취소 시 되돌린 값을 화면에도 즉시 반영합니다.
      if (mounted) {
        setState(() {
          attendanceActionQueued = false;
        });
      } else {
        attendanceActionQueued = false;
      }
      return;
    }

    final statusBeforeClockIn = attendanceStatus;

    // 출근 화면을 바꾸기 전에 로컬 복구표시를 먼저 확정해
    // 직후 앱이 종료돼도 다음 실행에서 출근 요청을 이어갈 수 있게 합니다.
    await savePendingClockIn(
      employeeId: widget.employeeId,
      store: widget.store,
    );
    if (!mounted) return;

    // 로컬 복구표시가 저장된 뒤 화면을 즉시 근무중으로 전환합니다.
    _showClockInPending();

    if (!isLoginVerified) {
      setState(() {
        authActionPending = true;
      });

      final loginOk = await _waitForLoginReady();
      if (!mounted) return;

      setState(() {
        authActionPending = false;
      });

      if (!loginOk) {
        _restoreAfterUnconfirmedClockIn();
        return;
      }

      // 로그인 확인 전에 출근을 눌렀는데 서버가 이미 WORKING이라고 확인했다면
      // 화면은 서버 상태를 그대로 유지하고 중복 clockIn API는 보내지 않습니다.
      if (verifiedLoginAttendanceStatus == 'WORKING') {
        unawaited(clearPendingClockIn(widget.employeeId));
        setState(() {
          isProcessing = false;
          attendanceActionQueued = false;
        });
        return;
      }
    }

    if (statusBeforeClockIn != 'NOT_IN' &&
        statusBeforeClockIn != 'VERIFYING') {
      unawaited(clearPendingClockIn(widget.employeeId));
      _restoreAfterUnconfirmedClockIn();
      return;
    }

    unawaited(clockIn(showPending: false));
  }

  Future<void> requestClockOut() async {
    // 출근 저장/결과 확인 중에는 새 퇴근 요청을 받지 않습니다.
    if (isProcessing) return;

    // 로그인 직후 서버 status가 아직 끝나지 않았어도 퇴근 확인창은 즉시 사용할 수 있습니다.
    // 실제 clockOut API는 아래 loginReady 게이트를 통과한 뒤, 서버가 최종적으로
    // WORKING 상태라고 확인된 경우에만 전송합니다.
    final canUseClockOut =
        attendanceStatus == 'WORKING' || !isLoginVerified;

    // 출근 확인 직후 화면이 WORKING으로 먼저 바뀐 상태라면
    // 로그인 확인/출근 저장이 진행 중이어도 퇴근 예약은 즉시 허용합니다.
    // 실제 clockOut API는 아래에서 출근 저장 완료 뒤 순차 실행됩니다.
    final waitingForClockInSave =
        attendanceStatus == 'WORKING' && isProcessing;

    if ((authActionPending && !waitingForClockInSave) ||
        isPasswordChanging ||
        !canUseClockOut) {
      return;
    }

    // 출근 저장이 아직 진행 중이어도 퇴근 확인창은 즉시 띄웁니다.
    // 실제 clockOut API만 출근 저장 완료 뒤에 이어서 보내 충돌을 막습니다.

    if (waitingForClockInSave) {
      final confirmed = await _showAttendanceConfirmDialog(
        '퇴근하시겠습니까?',
      );

      if (!confirmed || !mounted) {
        return;
      }

      await savePendingClockOut(
        employeeId: widget.employeeId,
        store: widget.store,
        note: noteController.text.trim(),
      );
      if (!mounted) return;

      // 출근 저장이 끝나기 전이어도 사용자가 보는 화면은 즉시 퇴근 완료로 전환합니다.
      // isProcessing은 기존 출근 저장이 끝날 때까지 그대로 유지됩니다.
      clockOutQueuedAfterClockIn = true;
      attendanceActionQueued = true;
      resumeStatusTimer?.cancel();
      _showClockOutPending();

      debugPrint('[즉시퇴근] 퇴근완료 UI + 출근버튼 즉시 활성 / 서버는 순차 처리');

      final deadline = DateTime.now().add(
        const Duration(seconds: 30),
      );

      while (mounted &&
          isProcessing &&
          DateTime.now().isBefore(deadline)) {
        await Future.delayed(
          const Duration(milliseconds: 50),
        );
      }

      if (!mounted) return;

      if (isProcessing || attendanceStatus != 'COMPLETED') {
        setState(() {
          clockOutQueuedAfterClockIn = false;
          attendanceActionQueued = false;
        });
        _showAttendanceMessage(
          '출근 저장 확인이 아직 끝나지 않았습니다. 상태를 다시 확인합니다.',
        );
        _scheduleResumeStatusRefresh();
        return;
      }

      clockOutQueuedAfterClockIn = false;
      attendanceActionQueued = true;
      unawaited(clockOut());
      return;
    }

    // 평소 퇴근 동작은 기존 로직 그대로 유지합니다.
    attendanceActionQueued = true;
    resumeStatusTimer?.cancel();

    final confirmed = await _showAttendanceConfirmDialog(
      '퇴근하시겠습니까?',
    );

    if (!confirmed || !mounted) {
      attendanceActionQueued = false;
      return;
    }

    await savePendingClockOut(
      employeeId: widget.employeeId,
      store: widget.store,
      note: noteController.text.trim(),
    );
    if (!mounted) return;

    if (!isLoginVerified) {
      // 로그인 검증이 뒤에서 진행 중이어도 퇴근 확인 직후 완료 화면은 즉시 보여줍니다.
      // 실제 clockOut API는 기존처럼 로그인 검증 성공 뒤에만 전송합니다.
      _showClockOutPending();

      setState(() {
        authActionPending = true;
      });

      final loginOk = await _waitForLoginReady();
      if (!mounted) return;

      setState(() {
        authActionPending = false;
      });

      if (!loginOk) {
        _restoreAfterUnconfirmedClockOut(null);
        return;
      }

      if (attendanceStatus != 'WORKING') {
        setState(() {
          isProcessing = false;
          attendanceActionQueued = false;
        });
        _showAttendanceMessage(
          '현재 근무중 상태가 아니라 퇴근 요청을 보내지 않았습니다.',
        );
        return;
      }

      unawaited(clockOut(showPending: false));
      return;
    }

    if (attendanceStatus != 'WORKING') {
      unawaited(clearPendingClockOut(widget.employeeId));
      attendanceActionQueued = false;
      _showAttendanceMessage(
        '현재 근무중 상태가 아니라 퇴근 요청을 보내지 않았습니다.',
      );
      return;
    }

    unawaited(clockOut());
  }

  void _logout() {
    if (isPasswordChanging || logoutInProgress) {
      return;
    }

    logoutInProgress = true;
    unawaited(_completeLogout());
  }

  Future<void> _completeLogout() async {
    _stopStatusRefresh();
    _stopLiveWorkedTimer();
    _clearCompletedViewTimer();
    resumeStatusTimer?.cancel();

    var cleared = false;

    for (var attempt = 0; attempt < 2 && !cleared; attempt++) {
      try {
        await clearRememberedLogin();
        cleared = true;
      } catch (_) {
        if (attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 120));
        }
      }
    }

    try {
      await secureStorage.delete(key: hourlyWageKey(widget.employeeId));
    } catch (_) {}

    try {
      await secureStorage.delete(key: actionTokenKey(widget.employeeId));
    } catch (_) {}

    if (!mounted) return;

    widget.onRememberCleared?.call();
    Navigator.of(context).pop();
  }

  void _runAttendanceMaintenance(
    String? monthKey, {
    int attempt = 0,
  }) {
    final key = (monthKey == null || monthKey.trim().isEmpty)
        ? _currentMonthKey()
        : monthKey.trim();

    // 저장 성공 응답 직후에는 서버를 출퇴근 전용으로 비워 둡니다.
    // 20초 뒤 시작하고, 그때 다른 중요 요청이 있으면 최대 2회 더 미룹니다.
    Future.delayed(
      Duration(seconds: attempt == 0 ? 20 : 15),
      () async {
        if (!mounted) return;

        if (isProcessing ||
            authActionPending ||
            attendanceActionQueued ||
            isPasswordChanging ||
            backgroundStatusInFlight ||
            isCalendarLoading) {
          if (attempt < 2) {
            debugPrint('[출퇴근최우선] maintenance 재예약 - 중요 작업 우선');
            _runAttendanceMaintenance(key, attempt: attempt + 1);
          } else {
            debugPrint('[출퇴근최우선] maintenance 이번 회차 생략');
          }
          return;
        }

        try {
          debugPrint('[출퇴근최우선] 지연 maintenance 시작');
          await callApi({
            'action': 'maintenance',
            'employeeId': widget.employeeId,
            'password': currentPassword,
            'monthKey': key,
          });
          debugPrint('[출퇴근최우선] 지연 maintenance 완료');
        } catch (_) {
          // 이미 저장된 직원 출퇴근 결과에는 영향을 주지 않습니다.
        }
      },
    );
  }

  void _refreshVisibleCalendarAfterAttendance() {
    // 출퇴근 후에는 기존 달력 데이터를 지우지 않고 '갱신 필요'만 표시합니다.
    // 닫혀 있으면 서버를 부르지 않고, 다음에 열 때 기존 기록을 즉시 보여준 뒤 갱신합니다.
    calendarNeedsRefresh = true;

    if (!showWorkHistory) {
      debugPrint('[출퇴근최우선] 숨은 달력 자동조회 생략 / 기존 캐시 유지');
      return;
    }

    Future.delayed(
      const Duration(seconds: 2),
      () {
        if (!mounted ||
            isProcessing ||
            authActionPending ||
            attendanceActionQueued ||
            isPasswordChanging ||
            backgroundStatusInFlight ||
            isCalendarLoading ||
            !showWorkHistory) {
          calendarNeedsRefresh = true;
          debugPrint('[출퇴근최우선] 달력 갱신 생략 - 중요 작업 우선');
          return;
        }

        unawaited(
          loadWorkCalendar(showLoading: !hasCalendarLoaded),
        );
      },
    );
  }

  void _showAttendanceMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _formatClockText(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  DateTime _roundToTenMinutesForDisplay(DateTime time) {
    final remainder = time.minute % 10;
    final adjustedMinute = remainder <= 6
        ? time.minute - remainder
        : time.minute + (10 - remainder);

    return DateTime(
      time.year,
      time.month,
      time.day,
      time.hour,
      adjustedMinute,
    );
  }

  void _showClockInPending() {
    final now = _serverNow();
    final adjustedNow = _roundToTenMinutesForDisplay(now);

    // 내부 대기 상태(isProcessing 등)는 그대로 유지하되, 화면은 "저장 중" 문구 없이
    // 서버 확인 전부터 바로 최종 근무중 화면을 보여줍니다.
    setState(() {
      isProcessing = true;
      attendanceStatus = 'WORKING';
      isWorking = true;
      statusText = '현재 근무중';
      clockInText = _formatClockText(adjustedNow);
      clockOutText = '-';
      actualInMs = now.millisecondsSinceEpoch;
      liveWorkedText = '0분';
    });

    _startLiveWorkedTimer();
  }

  void _restoreAfterUnconfirmedClockIn() {
    if (!mounted) return;

    setState(() {
      isProcessing = false;
      attendanceActionQueued = false;
      clockOutQueuedAfterClockIn = false;
      attendanceStatus = 'NOT_IN';
      isWorking = false;
      statusText = '현재 미출근';
      clockInText = '-';
      clockOutText = '-';
      actualInMs = null;
      liveWorkedText = '';
    });

    _stopLiveWorkedTimer();
    _startStatusRefresh();
  }

  void _showClockOutPending() {
    final shouldStartCompletedView = attendanceStatus != 'COMPLETED';
    final now = _serverNow();
    final adjustedNow = _roundToTenMinutesForDisplay(now);
    final startedAt = actualInMs;
    final elapsedMinutes = startedAt == null
        ? 0
        : ((_serverNow().millisecondsSinceEpoch - startedAt) / 60000).floor();
    final safeMinutes = elapsedMinutes < 0 ? 0 : elapsedMinutes;
    final optimisticWorked =
        '${safeMinutes ~/ 60}시간 ${safeMinutes % 60}분';

    // 내부 대기 상태(isProcessing 등)는 그대로 유지하되, 화면은 "저장 중" 문구 없이
    // 서버 확인 전부터 바로 최종 완료 화면(임시 시간 포함)을 보여줍니다.
    setState(() {
      if (shouldStartCompletedView) {
        completedViewHidden = false;
      }
      isProcessing = true;
      attendanceStatus = 'COMPLETED';
      isWorking = false;
      statusText = '퇴근 완료';
      clockOutText = _formatClockText(adjustedNow);
      completedWorkedText = optimisticWorked;
      completedBreakText = '0시간 0분';
      completedGrossText = optimisticWorked;
      showBreak = false;
    });

    _stopLiveWorkedTimer();
  }

  void _restoreAfterUnconfirmedClockOut(String? noteBackup) {
    if (!mounted) return;

    setState(() {
      isProcessing = false;
      attendanceActionQueued = false;
      attendanceStatus = 'WORKING';
      isWorking = true;
      statusText = '현재 근무중';
      clockOutText = '-';
    });

    if (noteBackup != null) {
      noteController.text = noteBackup;
    }

    _startLiveWorkedTimer();
    _startStatusRefresh();
  }

  Future<void> _verifyAttendanceResult(
    String expectedStatus,
    String? noteBackup, {
    int attempt = 0,
  }) async {
    final diagIntent = await _readAttendanceIntentForDiag(
      expectedStatus == 'WORKING' ? 'clockIn' : 'clockOut',
      widget.employeeId,
    );

    if (attempt == 0) {
      debugPrint(
        '[ATTENDANCE_VERIFY_START] expectedStatus=$expectedStatus '
        'employeeId=${widget.employeeId} requestId=${diagIntent?['requestId']} '
        'recordId=${diagIntent?['recordId']}',
      );
    }

    await Future.delayed(
      Duration(
        milliseconds: 500,
      ),
    );

    if (!mounted) return;

    try {
      final data = await callApi({
        'action': 'status',
        'employeeId': widget.employeeId,
        'password': currentPassword,
        'selectedStore': widget.store,
      });
      debugPrint(
        '[ATTENDANCE_VERIFY_RESPONSE] success=${data['success']} '
        'code=${data['code']} '
        'status=${(data['attendance'] is Map) ? (data['attendance'] as Map)['status'] : null} '
        'message=${data['message']}',
      );

      if (data['success'] != true) {
        _sendAttendanceDiag({
          'event': 'ATTENDANCE_VERIFY_RESPONSE',
          'employeeId': widget.employeeId,
          'storeId': widget.store,
          'requestId': diagIntent?['requestId'],
          'recordId': diagIntent?['recordId'],
          'expectedStatus': expectedStatus,
          'success': data['success'],
          'code': data['code'],
          'message': data['message'],
        });
      }

      if (!mounted) return;

      if (data['success'] != true) {
        if (expectedStatus == 'WORKING') {
          _restoreAfterUnconfirmedClockIn();
        } else {
          _restoreAfterUnconfirmedClockOut(noteBackup);
        }

        _showAttendanceMessage(
          '기록 결과를 확인하지 못했습니다. 잠시 후 다시 확인해주세요.',
        );
        return;
      }

      final attendance = Map<String, dynamic>.from(
        data['attendance'] ?? {},
      );

      final currentStatus =
          attendance['status']?.toString() ?? 'NOT_IN';

      unawaited(
        saveLastConfirmedAttendance(
          employeeId: widget.employeeId,
          store: widget.store,
          attendance: attendance,
        ),
      );

      if (
        expectedStatus == 'COMPLETED' &&
        currentStatus == 'NOT_IN' &&
        attempt < 1
      ) {
        await _verifyAttendanceResult(
          expectedStatus,
          noteBackup,
          attempt: attempt + 1,
        );
        return;
      }

      final expectedMatched =
          currentStatus == expectedStatus;

      if (expectedStatus == 'WORKING' && currentStatus == 'WORKING') {
        unawaited(clearPendingClockIn(widget.employeeId));
      }
      if (expectedStatus == 'COMPLETED' && currentStatus == 'COMPLETED') {
        unawaited(clearPendingClockOut(widget.employeeId));
      }

      final keepQueuedClockOutUi =
          expectedStatus == 'WORKING' &&
          currentStatus == 'WORKING' &&
          clockOutQueuedAfterClockIn;

      setState(() {
        if (keepQueuedClockOutUi) {
          _syncServerClock(attendance);
          isProcessing = false;
          attendanceActionQueued = true;
        } else {
          applyAttendance(attendance);
          isProcessing = false;
          attendanceActionQueued = false;
        }
      });

      if (keepQueuedClockOutUi) {
        return;
      }

      if (
        expectedStatus == 'COMPLETED' &&
        currentStatus == 'COMPLETED'
      ) {
        noteController.clear();
      } else if (
        noteBackup != null &&
        currentStatus != 'COMPLETED'
      ) {
        noteController.text = noteBackup;
      }

      _refreshVisibleCalendarAfterAttendance();

      if (expectedMatched) {
        _runAttendanceMaintenance(null);
      } else {
        _showAttendanceMessage(
          '현재 기록 상태가 예상과 달라 다시 확인했습니다.',
        );
      }
    } catch (e, st) {
      debugPrint(
        '[ATTENDANCE_VERIFY_EXCEPTION] expectedStatus=$expectedStatus '
        'employeeId=${widget.employeeId} exceptionType=${e.runtimeType} '
        'exceptionMessage=$e',
      );
      debugPrint('$st');

      _sendAttendanceDiag({
        'event': 'ATTENDANCE_VERIFY_EXCEPTION',
        'employeeId': widget.employeeId,
        'storeId': widget.store,
        'requestId': diagIntent?['requestId'],
        'recordId': diagIntent?['recordId'],
        'expectedStatus': expectedStatus,
        'exceptionType': e.runtimeType.toString(),
        'exceptionMessage': e.toString(),
      });

      if (!mounted) return;

      if (expectedStatus == 'WORKING') {
        _restoreAfterUnconfirmedClockIn();
      } else {
        _restoreAfterUnconfirmedClockOut(noteBackup);
      }

      _showAttendanceMessage(
        '기록 결과를 확인하지 못했습니다. 잠시 후 다시 눌러주세요.',
      );
    }
  }

  Future<Map<String, dynamic>> callApi(
    Map<String, dynamic> body,
  ) async {
    final requestBody = Map<String, dynamic>.from(body);
    final action = requestBody['action']?.toString() ?? '';
    final shouldDiagNetwork = action == 'clockIn' || action == 'clockOut';

    final currentActionToken = actionToken;
    if (currentActionToken != null && currentActionToken.isNotEmpty) {
      requestBody['actionToken'] = currentActionToken;
    }

    final clientSentAtMs = DateTime.now().millisecondsSinceEpoch;

    if (shouldDiagNetwork) {
      requestBody['_clientSentAtMs'] = clientSentAtMs;
    }

    final decoded = await sendApiRequest(
      requestBody,
    );

    if (shouldDiagNetwork) {
      decoded['_clientSentAtMs'] = clientSentAtMs;
      decoded['_clientReceivedAtMs'] =
          DateTime.now().millisecondsSinceEpoch;
    }

    _captureActionToken(decoded);
    return decoded;
  }


  void _printServerErrorIfAny(
    String action,
    Map<String, dynamic> data,
  ) {
    final detail = data['_serverError']?.toString().trim() ?? '';
    if (detail.isNotEmpty) {
      debugPrint('[서버오류][$action] $detail');
    }
  }

  void _printAttendanceActionDiag(
    String label,
    Map<String, dynamic> data,
    int clientMs,
  ) {
    final apiDiagRaw = data['_apiDiag'];
    final actionDiagRaw = data['_actionDiag'];

    final apiDiag = apiDiagRaw is Map
        ? Map<String, dynamic>.from(apiDiagRaw)
        : <String, dynamic>{};
    final actionDiag = actionDiagRaw is Map
        ? Map<String, dynamic>.from(actionDiagRaw)
        : <String, dynamic>{};

    debugPrint('');
    debugPrint('========== $label 구간진단 ==========');
    debugPrint('[앱왕복전체] ${clientMs}ms');
    debugPrint(
      '[API] 인증=${apiDiag['authMs'] ?? '-'}ms / '
      '출퇴근함수=${apiDiag['actionMs'] ?? '-'}ms / '
      'API내부전체=${apiDiag['totalMs'] ?? '-'}ms / '
      '인증경로=${apiDiag['authSource'] ?? '-'}',
    );

    final clientSentAtMs = data['_clientSentAtMs'];
    final commitEpochMs = actionDiag['commitEpochMs'];
    final apiEntryEpochMs = apiDiag['apiEntryEpochMs'];
    final apiReturnEpochMs = apiDiag['apiReturnEpochMs'];

    if (clientSentAtMs is num &&
        commitEpochMs is num &&
        apiEntryEpochMs is num &&
        apiReturnEpochMs is num) {
      final buttonToCommitMs =
          commitEpochMs.toInt() - clientSentAtMs.toInt();
      final apiEntryToCommitMs =
          commitEpochMs.toInt() - apiEntryEpochMs.toInt();
      final commitToApiReturnMs =
          apiReturnEpochMs.toInt() - commitEpochMs.toInt();

      debugPrint(
        '[실제시트확정] 버튼요청→flush완료≈${buttonToCommitMs}ms / '
        'API진입→확정=${apiEntryToCommitMs}ms / '
        '확정→API응답준비=${commitToApiReturnMs}ms',
      );
    } else {
      // 출근 함수가 매장 검증/중복 처리 등에서 flush 전에 끝난 경우에도
      // 진단 줄 자체가 사라지지 않도록 명확히 표시합니다.
      debugPrint(
        '[실제시트확정] flush 미도달 / '
        'clientSent=${clientSentAtMs is num ? 'OK' : '없음'} / '
        'commit=${commitEpochMs is num ? 'OK' : '없음'} / '
        'apiEntry=${apiEntryEpochMs is num ? 'OK' : '없음'} / '
        'apiReturn=${apiReturnEpochMs is num ? 'OK' : '없음'}',
      );
    }

    if (label == '출근') {
      debugPrint(
        '[출근함수] 직원DB=${actionDiag['employeeMs'] ?? '-'}ms / '
        '매장DB=${actionDiag['storeMs'] ?? '-'}ms / '
        '잠금=${actionDiag['lockMs'] ?? '-'}ms / '
        '열린기록검색=${actionDiag['findOpenMs'] ?? '-'}ms / '
        '시트준비=${actionDiag['sheetMs'] ?? '-'}ms / '
        '저장=${actionDiag['writeMs'] ?? '-'}ms / '
        '함수전체=${actionDiag['totalMs'] ?? '-'}ms',
      );

      final sheetDetailRaw = actionDiag['sheetDetail'];
      final sheetDetail = sheetDetailRaw is Map
          ? Map<String, dynamic>.from(sheetDetailRaw)
          : <String, dynamic>{};

      if (sheetDetail.isNotEmpty) {
        debugPrint(
          '[시트준비상세1] 월경로=${sheetDetail['monthPath'] ?? '-'} / '
          '캐시=${sheetDetail['monthCacheReadMs'] ?? '-'}ms / '
          '속성=${sheetDetail['monthPropertyReadMs'] ?? '-'}ms / '
          '시트ID=${sheetDetail['monthGetByIdMs'] ?? '-'}ms / '
          '폴백탐색=${sheetDetail['monthFallbackLookupMs'] ?? '-'}ms / '
          '생성준비=${sheetDetail['monthCreateSetupMs'] ?? '-'}ms / '
          '힌트쓰기=${sheetDetail['monthHintWriteMs'] ?? '-'}ms / '
          '월시트전체=${sheetDetail['monthSheetTotalMs'] ?? '-'}ms',
        );
        debugPrint(
          '[시트준비상세2] 행경로=${sheetDetail['nextRowPath'] ?? '-'} / '
          '캐시=${sheetDetail['nextRowCacheReadMs'] ?? '-'}ms / '
          '속성=${sheetDetail['nextRowPropertyReadMs'] ?? '-'}ms / '
          'getLastRow=${sheetDetail['nextRowGetLastRowMs'] ?? '-'}ms / '
          'probe=${sheetDetail['nextRowProbeMs'] ?? '-'}ms / '
          '힌트삭제=${sheetDetail['nextRowClearHintMs'] ?? '-'}ms / '
          '폴백getLastRow=${sheetDetail['nextRowFallbackGetLastRowMs'] ?? '-'}ms / '
          'A열전체=${sheetDetail['nextRowFullScanMs'] ?? '-'}ms / '
          '힌트쓰기=${sheetDetail['nextRowHintWriteMs'] ?? '-'}ms / '
          '다음행전체=${sheetDetail['nextRowTotalMs'] ?? '-'}ms',
        );
      }

      debugPrint(
        '[확정후상세] 행힌트=${actionDiag['postCommitLastRowHintMs'] ?? '-'}ms / '
        '열린행힌트=${actionDiag['postCommitOpenHintMs'] ?? '-'}ms / '
        '상태캐시=${actionDiag['postCommitStatusCacheMs'] ?? '-'}ms / '
        '응답조립=${actionDiag['postCommitResultBuildMs'] ?? '-'}ms / '
        '확정후전체=${actionDiag['postCommitTotalMs'] ?? '-'}ms',
      );
    } else {
      debugPrint(
        '[퇴근함수] 직원DB=${actionDiag['employeeMs'] ?? '-'}ms / '
        '잠금=${actionDiag['lockMs'] ?? '-'}ms / '
        '열린기록검색=${actionDiag['findOpenMs'] ?? '-'}ms / '
        '행읽기=${actionDiag['rowReadMs'] ?? '-'}ms / '
        '저장=${actionDiag['writeMs'] ?? '-'}ms / '
        '함수전체=${actionDiag['totalMs'] ?? '-'}ms',
      );
    }

    final apiTotal = apiDiag['totalMs'];
    if (apiTotal is num) {
      final outsideMs = clientMs - apiTotal.toInt();
      debugPrint('[Apps Script/네트워크 바깥구간] 약 ${outsideMs}ms');
    }
    debugPrint('=======================================');
  }

  Future<void> clockIn({bool showPending = true}) async {
    if ((isProcessing && showPending) || isPasswordChanging) return;

    if (showPending) {
      _showClockInPending();
    }

    Map<String, dynamic>? diagIntent;

    try {
      diagIntent = await _readAttendanceIntentForDiag('clockIn', widget.employeeId);
      debugPrint(
        '[ATTENDANCE_REQUEST] action=clockIn employeeId=${widget.employeeId} '
        'storeId=${widget.store} requestId=${diagIntent?['requestId']} '
        'recordId=${diagIntent?['recordId']} '
        'hasActionToken=${actionToken != null && actionToken!.isNotEmpty}',
      );

      final actionWatch = Stopwatch()..start();
      final data = await callApi({
        'action': 'clockIn',
        'employeeId': widget.employeeId,
        'password': currentPassword,
        'selectedStore': widget.store,
      });
      debugPrint(
        '[ATTENDANCE_RESPONSE] action=clockIn success=${data['success']} '
        'code=${data['code']} retryable=${data['retryable']} '
        'message=${data['message']} requestId=${data['requestId']} '
        'recordId=${data['recordId']}',
      );
      if (data['success'] != true && data['retryable'] == true) {
        _sendAttendanceDiag({
          'event': 'ATTENDANCE_RESPONSE',
          'employeeId': widget.employeeId,
          'storeId': widget.store,
          'requestId': data['requestId'] ?? diagIntent?['requestId'],
          'recordId': data['recordId'] ?? diagIntent?['recordId'],
          'expectedStatus': 'WORKING',
          'success': data['success'],
          'code': data['code'],
          'retryable': data['retryable'],
          'message': data['message'],
        });
      }
      actionWatch.stop();
      _printServerErrorIfAny('clockIn', data);
      _printAttendanceActionDiag(
        '출근',
        data,
        actionWatch.elapsedMilliseconds,
      );

      if (!mounted) return;

      if (data['success'] != true) {
        if (data['retryable'] == true) {
          await _verifyAttendanceResult(
            'WORKING',
            null,
          );
          return;
        }

        unawaited(clearPendingClockIn(widget.employeeId));
        _restoreAfterUnconfirmedClockIn();

        _showAttendanceMessage(
          data['message']?.toString() ??
              '출근 처리에 실패했습니다.',
        );
        return;
      }

      final attendance = Map<String, dynamic>.from(
        data['attendance'] ?? {},
      );

      unawaited(clearPendingClockIn(widget.employeeId));

      unawaited(
        saveLastConfirmedAttendance(
          employeeId: widget.employeeId,
          store: widget.store,
          attendance: attendance,
        ),
      );

      final hasQueuedClockOut = clockOutQueuedAfterClockIn;

      setState(() {
        if (hasQueuedClockOut) {
          // 퇴근 확인까지 이미 끝난 상태라면 늦게 도착한 출근 성공 응답으로
          // 화면을 다시 '현재 근무중'으로 되돌리지 않습니다.
          _syncServerClock(attendance);
          isProcessing = false;
          attendanceActionQueued = true;
        } else {
          applyAttendance(attendance);
          isProcessing = false;
          attendanceActionQueued = false;
        }
      });

      if (!hasQueuedClockOut) {
        _runAttendanceMaintenance(
          data['maintenanceMonthKey']?.toString(),
        );
        _refreshVisibleCalendarAfterAttendance();
      }

    } catch (e, st) {
      debugPrint(
        '[ATTENDANCE_REQUEST_EXCEPTION] action=clockIn '
        'employeeId=${widget.employeeId} requestId=${diagIntent?['requestId']} '
        'exceptionType=${e.runtimeType} exceptionMessage=$e',
      );
      debugPrint('$st');

      _sendAttendanceDiag({
        'event': 'ATTENDANCE_REQUEST_EXCEPTION',
        'employeeId': widget.employeeId,
        'storeId': widget.store,
        'requestId': diagIntent?['requestId'],
        'recordId': diagIntent?['recordId'],
        'expectedStatus': 'WORKING',
        'exceptionType': e.runtimeType.toString(),
        'exceptionMessage': e.toString(),
      });

      await _verifyAttendanceResult(
        'WORKING',
        null,
      );
    }
  }

  Future<void> clockOut({
    bool showPending = true,
    String? recoveryNote,
  }) async {
    if ((isProcessing && showPending) || isPasswordChanging) return;

    final noteBackup = recoveryNote ?? noteController.text.trim();

    // 기존 근무정보는 유지한 채 퇴근 저장중 표시를 즉시 보여줍니다.
    // 로그인 검증 대기 중 이미 표시한 경우에는 중복 적용하지 않습니다.
    if (showPending) {
      _showClockOutPending();
    }

    Map<String, dynamic>? diagIntent;

    try {
      diagIntent = await _readAttendanceIntentForDiag('clockOut', widget.employeeId);
      debugPrint(
        '[ATTENDANCE_REQUEST] action=clockOut employeeId=${widget.employeeId} '
        'storeId=${widget.store} requestId=${diagIntent?['requestId']} '
        'recordId=${diagIntent?['recordId']} '
        'hasActionToken=${actionToken != null && actionToken!.isNotEmpty}',
      );

      final actionWatch = Stopwatch()..start();
      final data = await callApi({
        'action': 'clockOut',
        'employeeId': widget.employeeId,
        'password': currentPassword,
        'selectedStore': widget.store,
        'note': noteBackup,
      });
      debugPrint(
        '[ATTENDANCE_RESPONSE] action=clockOut success=${data['success']} '
        'code=${data['code']} retryable=${data['retryable']} '
        'message=${data['message']} requestId=${data['requestId']} '
        'recordId=${data['recordId']}',
      );
      if (data['success'] != true && data['retryable'] == true) {
        _sendAttendanceDiag({
          'event': 'ATTENDANCE_RESPONSE',
          'employeeId': widget.employeeId,
          'storeId': widget.store,
          'requestId': data['requestId'] ?? diagIntent?['requestId'],
          'recordId': data['recordId'] ?? diagIntent?['recordId'],
          'expectedStatus': 'COMPLETED',
          'success': data['success'],
          'code': data['code'],
          'retryable': data['retryable'],
          'message': data['message'],
        });
      }
      actionWatch.stop();
      _printServerErrorIfAny('clockOut', data);
      _printAttendanceActionDiag(
        '퇴근',
        data,
        actionWatch.elapsedMilliseconds,
      );

      if (!mounted) return;

      if (data['success'] != true) {
        if (data['retryable'] == true) {
          await _verifyAttendanceResult(
            'COMPLETED',
            noteBackup,
          );
          return;
        }

        unawaited(clearPendingClockOut(widget.employeeId));
        _restoreAfterUnconfirmedClockOut(noteBackup);

        _showAttendanceMessage(
          data['message']?.toString() ??
              '퇴근 처리에 실패했습니다.',
        );
        return;
      }

      final attendance = Map<String, dynamic>.from(
        data['attendance'] ?? {},
      );

      unawaited(clearPendingClockOut(widget.employeeId));

      unawaited(
        saveLastConfirmedAttendance(
          employeeId: widget.employeeId,
          store: widget.store,
          attendance: attendance,
        ),
      );

      noteController.clear();

      setState(() {
        applyAttendance(attendance);
        isProcessing = false;
        // 퇴근 완료 화면에서도 출근 버튼은 이미 활성화되어 있습니다.
        attendanceActionQueued = false;
        clockOutQueuedAfterClockIn = false;
      });

      _runAttendanceMaintenance(
        data['maintenanceMonthKey']?.toString(),
      );
      _refreshVisibleCalendarAfterAttendance();

    } catch (e, st) {
      debugPrint(
        '[ATTENDANCE_REQUEST_EXCEPTION] action=clockOut '
        'employeeId=${widget.employeeId} requestId=${diagIntent?['requestId']} '
        'exceptionType=${e.runtimeType} exceptionMessage=$e',
      );
      debugPrint('$st');

      _sendAttendanceDiag({
        'event': 'ATTENDANCE_REQUEST_EXCEPTION',
        'employeeId': widget.employeeId,
        'storeId': widget.store,
        'requestId': diagIntent?['requestId'],
        'recordId': diagIntent?['recordId'],
        'expectedStatus': 'COMPLETED',
        'exceptionType': e.runtimeType.toString(),
        'exceptionMessage': e.toString(),
      });

      await _verifyAttendanceResult(
        'COMPLETED',
        noteBackup,
      );
    }
  }

  String _calendarCacheKey(DateTime month) {
    return 'attendance_calendar_cache_'
        '${widget.employeeId}_${month.year}_'
        '${month.month.toString().padLeft(2, '0')}';
  }

  Future<void> _restoreCalendarCache() async {
    final requestedMonth = calendarMonth;
    try {
      final raw = await secureStorage.read(
        key: _calendarCacheKey(requestedMonth),
      );

      if (!mounted || raw == null || raw.isEmpty || !calendarNeedsRefresh) {
        return;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['records'] is! List) {
        return;
      }

      final records = <Map<String, dynamic>>[];
      for (final item in decoded['records'] as List) {
        if (item is Map) {
          records.add(Map<String, dynamic>.from(item));
        }
      }

      if (!mounted || calendarMonth != requestedMonth || !calendarNeedsRefresh) return;

      setState(() {
        calendarRecords = records;
        hasCalendarLoaded = true;
        calendarError = null;
      });

      debugPrint('[근무기록캐시] 선택한 월 근무기록 로컬 즉시 복원');
    } catch (_) {
      // 캐시가 없거나 깨져 있어도 서버 조회에는 영향을 주지 않습니다.
    }
  }

  Future<void> _saveCalendarCache(
    List<Map<String, dynamic>> records,
    DateTime month,
  ) async {
    try {
      await secureStorage.write(
        key: _calendarCacheKey(month),
        value: jsonEncode({
          'records': records,
        }),
      );
    } catch (_) {
      // 로컬 캐시 저장 실패는 근무기록 조회 결과에 영향을 주지 않습니다.
    }
  }

  bool get _canChangeCalendarMonth => !logoutInProgress;

  void _scheduleCalendarRetry() {
    calendarRetryTimer?.cancel();
    calendarRetryTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted || !showWorkHistory || logoutInProgress) return;
      unawaited(_prepareWorkHistoryAfterLogin());
    });
  }

  Future<void> _changeCalendarMonth(int offset) async {
    if (!_canChangeCalendarMonth) return;

    final nextMonth = DateTime(
      calendarMonth.year,
      calendarMonth.month + offset,
      1,
    );
    final now = _serverNow();
    if (nextMonth.isBefore(DateTime(2026, 8, 1)) ||
        nextMonth.isAfter(DateTime(now.year, now.month, 1))) {
      return;
    }

    setState(() {
      calendarMonth = nextMonth;
      calendarRecords = [];
      hasCalendarLoaded = false;
      calendarNeedsRefresh = true;
      calendarError = null;
    });
    await _restoreCalendarCache();
    if (!mounted || calendarMonth != nextMonth) return;
    await _prepareWorkHistoryAfterLogin();
  }

  void toggleWorkHistory() {
    final next = !showWorkHistory;

    setState(() {
      showWorkHistory = next;
      calendarError = null;
    });

    if (!next) {
      calendarRetryTimer?.cancel();
      return;
    }

    // 달력 틀은 즉시 열되, 실제 개인 근무기록 조회는
    // 로그인 성공이 확인된 뒤에만 시작합니다.
    unawaited(_prepareWorkHistoryAfterLogin());
  }

  Future<void> _prepareWorkHistoryAfterLogin() async {
    final loginOk = await _waitForLoginReady();
    if (!mounted || !loginOk || !showWorkHistory) {
      return;
    }

    // 퇴근완료 화면에서는 근무이력 UI/캐시는 즉시 열고,
    // 실제 calendar API만 퇴근 저장이 끝난 뒤 순서대로 보냅니다.
    if (attendanceStatus == 'COMPLETED' &&
        (isProcessing || attendanceActionQueued)) {
      final deadline = DateTime.now().add(
        const Duration(seconds: 30),
      );

      while (mounted &&
          showWorkHistory &&
          (isProcessing || attendanceActionQueued) &&
          DateTime.now().isBefore(deadline)) {
        await Future.delayed(
          const Duration(milliseconds: 50),
        );
      }
    }

    if (!mounted || !showWorkHistory || logoutInProgress) return;

    if (isProcessing ||
        authActionPending ||
        attendanceActionQueued ||
        isPasswordChanging ||
        backgroundStatusInFlight) {
      _scheduleCalendarRetry();
      return;
    }

    if ((calendarNeedsRefresh || !hasCalendarLoaded) &&
        !isCalendarLoading) {
      unawaited(
        loadWorkCalendar(showLoading: !hasCalendarLoaded),
      );
    }
  }

  Future<void> loadWorkCalendar({
    bool showLoading = true,
  }) async {
    if (!mounted ||
        isCalendarLoading ||
        isProcessing ||
        authActionPending ||
        attendanceActionQueued ||
        isPasswordChanging ||
        backgroundStatusInFlight) {
      calendarNeedsRefresh = true;
      if (mounted && showWorkHistory && !isCalendarLoading) {
        _scheduleCalendarRetry();
      }
      return;
    }

    if (showLoading && mounted) {
      setState(() {
        isCalendarLoading = true;
        calendarError = null;
      });
    } else {
      // 캐시를 화면에 그대로 보여주는 조용한 갱신도
      // 중복 API가 겹치지 않도록 내부적으로는 로딩 중으로 표시합니다.
      isCalendarLoading = true;
    }

    final requestedMonth = calendarMonth;
    try {
      final data = await callApi({
        'action': 'calendar',
        'employeeId': widget.employeeId,
        'password': currentPassword,
        'year': requestedMonth.year,
        'month': requestedMonth.month,
      });

      if (!mounted || calendarMonth != requestedMonth) return;

      if (data['success'] != true) {
        setState(() {
          if (!hasCalendarLoaded) {
            calendarRecords = [];
          }
          calendarError =
              data['message']?.toString() ??
                  '근무기록을 불러오지 못했습니다.';
        });
        return;
      }

      final rawRecords = data['records'];
      final records = <Map<String, dynamic>>[];

      if (rawRecords is List) {
        for (final item in rawRecords) {
          if (item is Map) {
            records.add(
              Map<String, dynamic>.from(item),
            );
          }
        }
      }

      setState(() {
        calendarRecords = records;
        calendarError = null;
        hasCalendarLoaded = true;
        calendarNeedsRefresh = false;
      });

      unawaited(_saveCalendarCache(records, requestedMonth));
    } catch (e) {
      if (!mounted || calendarMonth != requestedMonth) return;

      debugPrint('[근무기록조회][${requestedMonth.year}-${requestedMonth.month}] $e');
      setState(() {
        if (!hasCalendarLoaded) {
          calendarRecords = [];
        }
        calendarError = e is TimeoutException
            ? '근무기록 조회 응답이 늦어지고 있습니다. 다시 시도해주세요.'
            : '근무기록을 불러오는 중 오류가 발생했습니다.';
      });
    } finally {
      if (mounted) {
        setState(() {
          isCalendarLoading = false;
        });
        // 조회 중 월을 바꿨다면 이전 응답은 버리고 마지막 선택 월을 조회합니다.
        if (calendarMonth != requestedMonth && showWorkHistory) {
          unawaited(_prepareWorkHistoryAfterLogin());
        }
      }
    }
  }

  int _durationTextToMinutes(String text) {
    final hourMatch =
        RegExp(r'(-?\d+)\s*시간').firstMatch(text);
    final minuteMatch =
        RegExp(r'(-?\d+)\s*분').firstMatch(text);

    final hours = int.tryParse(
          hourMatch?.group(1) ?? '0',
        ) ??
        0;

    final minutes = int.tryParse(
          minuteMatch?.group(1) ?? '0',
        ) ??
        0;

    final total = hours * 60 + minutes;
    return total < 0 ? 0 : total;
  }

  String _formatDurationDisplay(String text) {
    final minutes = _durationTextToMinutes(text);

    if (minutes <= 0) {
      return '';
    }

    final hours = minutes ~/ 60;
    final minutePart = minutes % 60;

    if (hours > 0 && minutePart > 0) {
      return '$hours시간 $minutePart분';
    }

    if (hours > 0) {
      return '$hours시간';
    }

    return '$minutePart분';
  }

  String _totalWorkedText() {
    var totalMinutes = 0;

    for (final record in calendarRecords) {
      totalMinutes += _durationTextToMinutes(
        record['workedText']?.toString() ?? '',
      );
    }

    final hours = totalMinutes ~/ 60;
    final minutePart = totalMinutes % 60;

    if (minutePart > 0) {
      return '$hours시간 $minutePart분';
    }

    return '$hours시간';
  }

  int _workedDayCount() {
    final days = <int>{};

    for (final record in calendarRecords) {
      final day = _toInt(record['day']);
      if (day != null) {
        days.add(day);
      }
    }

    return days.length;
  }

  Map<int, List<Map<String, dynamic>>> _recordsByDay() {
    final result =
        <int, List<Map<String, dynamic>>>{};

    for (final record in calendarRecords) {
      final day = _toInt(record['day']);
      if (day == null) continue;

      result.putIfAbsent(
        day,
        () => <Map<String, dynamic>>[],
      );

      result[day]!.add(record);
    }

    return result;
  }

  bool _isPositiveBreakTime(String text) {
    return _durationTextToMinutes(text) > 0;
  }

  Future<void> _showDayDetail(
    int day,
    List<Map<String, dynamic>> records,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              24,
              8,
              24,
              28,
            ),
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${calendarMonth.year}년 '
                  '${calendarMonth.month}월 '
                  '$day일',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 18),
                for (
                  var index = 0;
                  index < records.length;
                  index++
                ) ...[
                  if (index > 0) const Divider(height: 28),
                  _detailRow(
                    '근무 매장',
                    records[index]['store']
                            ?.toString() ??
                        '-',
                  ),
                  _detailRow(
                    '출근',
                    records[index]['inText']
                            ?.toString() ??
                        '-',
                  ),
                  _detailRow(
                    '퇴근',
                    records[index]['outText']
                            ?.toString() ??
                        '-',
                  ),
                  if (_isPositiveBreakTime(
                    records[index]['breakText']
                            ?.toString() ??
                        '',
                  ))
                    _detailRow(
                      '휴게시간',
                      _formatDurationDisplay(
                        records[index]['breakText']
                                ?.toString() ??
                            '',
                      ),
                    ),
                  _detailRow(
                    '근무시간',
                    _formatDurationDisplay(
                              records[index]
                                      ['workedText']
                                  ?.toString() ??
                              '',
                            )
                            .isEmpty
                        ? '-'
                        : _formatDurationDisplay(
                            records[index]
                                    ['workedText']
                                ?.toString() ??
                            '',
                          ),
                  ),
                  _detailRow(
                    '특이사항',
                    records[index]['note']
                            ?.toString() ??
                        '',
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _detailRow(
    String label,
    String value,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: 6,
      ),
      child: Row(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.grey,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openCalculator() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CalculatorPage(
        loadCurrentMonthCalendar: () {
          final now = DateTime.now();
          return callApi({
            'action': 'calendar',
            'employeeId': widget.employeeId,
            'password': currentPassword,
            'year': now.year,
            'month': now.month,
          });
        },
        readSavedWage: () => secureStorage.read(
          key: hourlyWageKey(widget.employeeId),
        ),
        saveWage: (value) => value.isEmpty
            ? secureStorage.delete(key: hourlyWageKey(widget.employeeId))
            : secureStorage.write(
                key: hourlyWageKey(widget.employeeId),
                value: value,
              ),
      ),
    ));
  }

  Future<void> openPasswordChangeDialog() async {
    if (isPasswordChanging) return;

    // 로그인 확인/출퇴근 저장이 뒤에서 진행 중이어도 창 자체는 즉시 엽니다.
    // 실제 비밀번호 변경 API는 아래에서 로그인 검증과 중요 작업 종료를 기다립니다.
    final request = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) {
        return PasswordChangeDialog(
          currentPassword: currentPassword,
        );
      },
    );

    if (!mounted || request == null) {
      return;
    }

    // 실제 비밀번호 변경 요청은 로그인 성공 확인 뒤에만 보냅니다.
    final loginOk = await _waitForLoginReady();
    if (!mounted || !loginOk) return;

    // 창은 즉시 열지만 실제 비밀번호 변경 API는 현재 출퇴근 저장이
    // 끝난 뒤 보내서 서버 요청이 겹치지 않게 합니다.
    // 중요: 기존 출퇴근 요청이 끝나기 전에 isPasswordChanging을 켜면
    // clockIn/clockOut이 막혀 attendanceActionQueued가 풀리지 않는 교착이 생길 수 있습니다.
    if (isProcessing || attendanceActionQueued) {
      final deadline = DateTime.now().add(
        const Duration(seconds: 30),
      );

      while (mounted &&
          (isProcessing || attendanceActionQueued) &&
          DateTime.now().isBefore(deadline)) {
        await Future.delayed(
          const Duration(milliseconds: 50),
        );
      }

      if (!mounted) return;

      if (isProcessing || attendanceActionQueued) {
        setState(() {
          isPasswordChanging = false;
        });

        _showAttendanceMessage(
          '출퇴근 저장 확인이 아직 끝나지 않았습니다. 잠시 후 다시 시도해주세요.',
        );
        return;
      }
    }

    if (!mounted) return;

    setState(() {
      isPasswordChanging = true;
    });

    unawaited(_completePasswordChange(request));
  }

  Future<void> _completePasswordChange(
    Map<String, String> request,
  ) async {
    final current = request['current'] ?? '';
    final next = request['next'] ?? '';
    final confirm = request['confirm'] ?? '';

    try {
      final data = await callApi({
        'action': 'changePassword',
        'employeeId': widget.employeeId,
        'currentPassword': current,
        'newPassword': next,
        'confirmPassword': confirm,
      });

      if (!mounted) return;

      if (data['success'] != true) {
        setState(() {
          isPasswordChanging = false;
        });

        _showAttendanceMessage(
          data['message']?.toString() ??
              '비밀번호 변경에 실패했습니다.',
        );
        return;
      }

      final changedPassword =
          data['newPassword']?.toString() ?? next;

      // 비밀번호 변경이 서버에서 확정되면 현재 인증 화면을 끝내고
      // 로그인 전 화면으로 돌아갑니다. 매장/직원 선택은 부모 화면에서
      // 유지하고, 비밀번호와 자동로그인 정보만 초기화합니다.
      _stopStatusRefresh();
      _stopLiveWorkedTimer();
      _clearCompletedViewTimer();

      widget.onPasswordChanged?.call(changedPassword);
      unawaited(clearRememberedLogin());

      // 서버에서 변경 성공이 확정된 새 비밀번호는 이미 검증된 값이므로
      // 로그인 화면으로 돌아간 뒤 첫 로그인부터 즉시 사용할 수 있습니다.
      unawaited(
        saveVerifiedPassword(
          widget.employeeId,
          changedPassword,
        ),
      );

      if (!mounted) return;

      // 서버에서 비밀번호 변경 성공이 확정되면 즉시 로그인 화면으로 복귀합니다.
      // 안내 멘트는 부모 로그인 화면이 다시 보인 뒤 표시됩니다.
      Navigator.of(context).pop('passwordChanged');
    } catch (_) {
      if (!mounted) return;

      setState(() {
        isPasswordChanging = false;
      });

      _showAttendanceMessage(
        '서버 연결에 실패했습니다. 비밀번호를 다시 확인해주세요.',
      );
    }
  }

  Widget _buildCalendar() {
    final grouped = _recordsByDay();

    final firstDay = DateTime(
      calendarMonth.year,
      calendarMonth.month,
      1,
    );

    final leadingEmptyCells =
        firstDay.weekday % 7;

    final daysInMonth = DateTime(
      calendarMonth.year,
      calendarMonth.month + 1,
      0,
    ).day;

    final totalCells =
        leadingEmptyCells + daysInMonth;

    final now = _serverNow();

    final isCurrentMonth =
        now.year == calendarMonth.year &&
        now.month == calendarMonth.month;

    const weekLabels = [
      '일',
      '월',
      '화',
      '수',
      '목',
      '금',
      '토',
    ];

    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              children: [
                Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                    IconButton(
                      tooltip: '이전 달',
                      onPressed: _canChangeCalendarMonth &&
                              calendarMonth.isAfter(DateTime(2026, 8, 1))
                          ? () => _changeCalendarMonth(-1)
                          : null,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Flexible(
                      child: Text(
                        '${calendarMonth.year}년 '
                        '${calendarMonth.month}월',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '다음 달',
                      onPressed: _canChangeCalendarMonth &&
                              calendarMonth.isBefore(DateTime(now.year, now.month, 1))
                          ? () => _changeCalendarMonth(1)
                          : null,
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    for (var i = 0;
                        i < weekLabels.length;
                        i++)
                      Expanded(
                        child: Center(
                          child: Text(
                            weekLabels[i],
                            style: TextStyle(
                              fontWeight:
                                  FontWeight.w700,
                              color: i == 0
                                  ? Colors.red
                                  : i == 6
                                      ? Colors.blue
                                      : Colors.grey,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                GridView.builder(
                  shrinkWrap: true,
                  physics:
                      const NeverScrollableScrollPhysics(),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 7,
                    crossAxisSpacing: 6,
                    mainAxisSpacing: 6,
                  ),
                  itemCount: totalCells,
                  itemBuilder: (context, index) {
                    if (index <
                        leadingEmptyCells) {
                      return const SizedBox.shrink();
                    }

                    final day =
                        index - leadingEmptyCells + 1;

                    final dayRecords =
                        grouped[day] ??
                            <Map<String, dynamic>>[];

                    final worked =
                        dayRecords.isNotEmpty;

                    final today =
                        isCurrentMonth &&
                            now.day == day;

                    return Material(
                      color: worked
                          ? const Color(0xFFE8F0FE)
                          : Colors.transparent,
                      shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(10),
                        side: BorderSide(
                          color: today
                              ? const Color(0xFF2563EB)
                              : Colors.transparent,
                          width: today ? 2 : 1,
                        ),
                      ),
                      child: InkWell(
                        borderRadius:
                            BorderRadius.circular(10),
                        onTap: worked
                            ? () => _showDayDetail(
                                  day,
                                  dayRecords,
                                )
                            : null,
                        child: Center(
                          child: Text(
                            '$day',
                            style: TextStyle(
                              fontWeight: worked ||
                                      today
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: worked
                                  ? const Color(
                                      0xFF1D4ED8,
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 14),
                const Row(
                  mainAxisAlignment:
                      MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.circle,
                      size: 10,
                      color: Color(0xFF2563EB),
                    ),
                    SizedBox(width: 5),
                    Text(
                      '근무일',
                      style: TextStyle(fontSize: 12),
                    ),
                    SizedBox(width: 18),
                    Icon(
                      Icons.radio_button_unchecked,
                      size: 13,
                      color: Color(0xFF2563EB),
                    ),
                    SizedBox(width: 5),
                    Text(
                      '오늘',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (calendarError != null)
                  Text(
                    calendarError!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context)
                          .colorScheme
                          .error,
                    ),
                  )
                else if (hasCalendarLoaded)
                  Text(
                    calendarRecords.isEmpty
                        ? '이 달의 근무기록이 없습니다.'
                        : '총 ${_workedDayCount()}일 근무',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontWeight: calendarRecords.isEmpty
                          ? FontWeight.normal
                          : FontWeight.w900,
                      color: calendarRecords.isEmpty ? Colors.grey : null,
                    ),
                  ),
                if (calendarError != null)
                  TextButton(
                    onPressed: isCalendarLoading
                        ? null
                        : () {
                            setState(() {
                              calendarError = null;
                              calendarNeedsRefresh = true;
                            });
                            unawaited(_prepareWorkHistoryAfterLogin());
                          },
                    child: const Text('다시 시도'),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 18,
              vertical: 16,
            ),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '총근무시간',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Text(
                  hasCalendarLoaded
                      ? _totalWorkedText()
                      : '-',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _handleSystemBack() {
    final now = DateTime.now();
    final lastBackPressedAt = _lastBackPressedAt;

    if (lastBackPressedAt == null ||
        now.difference(lastBackPressedAt) > const Duration(seconds: 2)) {
      _lastBackPressedAt = now;

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('한 번 더 누르면 앱이 종료됩니다.'),
            duration: Duration(seconds: 2),
          ),
        );
      return;
    }

    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final completedState =
        attendanceStatus == 'COMPLETED';
    final isCompleted =
        completedState && !completedViewHidden;
    final isVerifying =
        attendanceStatus == 'VERIFYING';
    final visibleStatusText =
        completedState && completedViewHidden
            ? '현재 미출근'
            : statusText;
    final visibleClockInText =
        completedState && completedViewHidden
            ? '-'
            : clockInText;
    final visibleClockOutText =
        completedState && completedViewHidden
            ? '-'
            : clockOutText;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleSystemBack();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: '로그인 화면으로 돌아가기',
            onPressed: () {
              Navigator.of(context).pop();
            },
          ),
          title: const Text('출퇴근 관리'),
        ),
        body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Text(
                        widget.store,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.employee,
                        style: const TextStyle(
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Text(
                        visibleStatusText,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight:
                              FontWeight.bold,
                          color: attendanceStatus ==
                                  'WORKING'
                              ? Colors.green
                              : isCompleted
                                  ? const Color(
                                      0xFF2563EB,
                                    )
                                  : Colors.grey,
                        ),
                      ),
                      if (isCompleted) ...[
                        const SizedBox(height: 18),
                        const Text(
                          '오늘 근무시간',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          completedWorkedText.isEmpty
                              ? '0시간 0분'
                              : completedWorkedText,
                          style: const TextStyle(
                            fontSize: 25,
                            fontWeight:
                                FontWeight.w800,
                          ),
                        ),
                      ],
                      if (!isVerifying) ...[
                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment:
                              MainAxisAlignment
                                  .spaceBetween,
                          children: [
                            const Text('출근 시간'),
                            Text(visibleClockInText),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment:
                              MainAxisAlignment
                                  .spaceBetween,
                          children: [
                            const Text('퇴근 시간'),
                            Text(visibleClockOutText),
                          ],
                        ),
                      ],
                      if (attendanceStatus ==
                          'WORKING') ...[
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment:
                              MainAxisAlignment
                                  .spaceBetween,
                          children: [
                            const Text('현재 근무시간'),
                            Text(
                              liveWorkedText.isEmpty
                                  ? '0분'
                                  : liveWorkedText,
                              style: const TextStyle(
                                fontWeight:
                                    FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (isCompleted) ...[
                        if (showBreak) ...[
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment:
                                MainAxisAlignment
                                    .spaceBetween,
                            children: [
                              const Text('휴게시간'),
                              Text(
                                completedBreakText
                                        .isEmpty
                                    ? '0시간 0분'
                                    : completedBreakText,
                              ),
                            ],
                          ),
                        ],
                        const Divider(height: 30),
                        Row(
                          mainAxisAlignment:
                              MainAxisAlignment
                                  .spaceBetween,
                          children: [
                            const Text(
                              '총근무시간',
                              style: TextStyle(
                                fontWeight:
                                    FontWeight.w700,
                              ),
                            ),
                            Text(
                              completedGrossText.isEmpty
                                  ? completedWorkedText
                                  : completedGrossText,
                              style: const TextStyle(
                                fontWeight:
                                    FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '출근하기 버튼은 바로 사용할 수 있습니다.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (attendanceStatus ==
                  'WORKING') ...[
                const SizedBox(height: 16),
                TextField(
                  controller: noteController,
                  maxLines: 3,
                  minLines: 2,
                  enabled: !isPasswordChanging,
                  decoration: const InputDecoration(
                    labelText: '특이사항 (선택)',
                    hintText:
                        '퇴근 기록에 남길 내용이 있으면 입력해주세요.',
                    border: OutlineInputBorder(),
                    prefixIcon:
                        Icon(Icons.edit_note),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                height: 60,
                child: FilledButton(
                  onPressed:
                              authActionPending ||
                              isPasswordChanging ||
                              clockInQueuedAfterClockOut ||
                              isProcessing ||
                              (attendanceActionQueued && clockOutQueuedAfterClockIn) ||
                              !(attendanceStatus == 'NOT_IN' ||
                                  attendanceStatus == 'COMPLETED') ||
                              (attendanceStatus != 'COMPLETED' &&
                                  (isProcessing || attendanceActionQueued))
                          ? null
                          : requestClockIn,
                  child: const Text(
                    '출근하기',
                    style: TextStyle(fontSize: 18),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 60,
                child: FilledButton.tonal(
                  onPressed:
                      isPasswordChanging ||
                              isProcessing ||
                              attendanceStatus != 'WORKING'
                          ? null
                          : requestClockOut,
                  child: const Text(
                    '퇴근하기',
                    style: TextStyle(fontSize: 18),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 54,
                child: OutlinedButton.icon(
                  onPressed:
                      !isPasswordChanging
                          ? toggleWorkHistory
                          : null,
                  icon: Icon(
                    showWorkHistory
                        ? Icons.expand_less
                        : Icons.calendar_month,
                  ),
                  label: Text(
                    showWorkHistory
                        ? '근무기록 닫기'
                        : '근무기록',
                    style:
                        const TextStyle(fontSize: 16),
                  ),
                ),
              ),
              if (showWorkHistory) ...[
                const SizedBox(height: 10),
                _buildCalendar(),
              ],
              const SizedBox(height: 14),
              SizedBox(
                height: 54,
                child: OutlinedButton.icon(
                  onPressed:
                      !isPasswordChanging
                          ? _openCalculator
                          : null,
                  icon: const Icon(Icons.calculate),
                  label: const Text(
                    '계산기',
                    style:
                        TextStyle(fontSize: 16),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 54,
                child: OutlinedButton.icon(
                  onPressed:
                      !isPasswordChanging
                          ? openPasswordChangeDialog
                          : null,
                  icon: const Icon(Icons.lock_reset),
                  label: const Text(
                    '비밀번호 변경',
                    style:
                        TextStyle(fontSize: 16),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextButton.icon(
                onPressed:
                    !isPasswordChanging ? _logout : null,
                icon: const Icon(Icons.logout),
                label: const Text('로그아웃'),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
            if (isPasswordChanging)
              IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 18,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x26000000),
                          blurRadius: 14,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Text(
                      '잠시만 기다려주세요',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      ),
    );
  }
}
