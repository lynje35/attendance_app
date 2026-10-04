import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

// Only main_server_preview.dart installs this bridge. The normal app keeps Apps Script.
class EmployeeServerPreview {
  EmployeeServerPreview({
    required this.endpoint,
    required this.client,
    required this.read,
    required this.write,
    required this.remove,
  });

  final Uri endpoint;
  final http.Client client;
  final Future<String?> Function(String) read;
  final Future<void> Function(String, String) write;
  final Future<void> Function(String) remove;
  final _recordIds = <String, String>{};
  final _generations = <String, int>{};
  Future<void> _storageQueue = Future<void>.value();

  String _key(String action, String employee) =>
      'employee_server_preview_request_${action}_$employee';

  Future<T> _stored<T>(Future<T> Function() operation) {
    final result = _storageQueue.then((_) => operation());
    _storageQueue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Map<String, dynamic>?> _readIntent(String action, String employee) async {
    final raw = await read(_key(action, employee));
    if (raw == null) return null;
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<void> prepareIntent(String action, String employee, String store,
      {String note = ''}) {
    _generations[employee] = (_generations[employee] ?? 0) + 1;
    return _stored(() async {
      final old = await _readIntent(action, employee);
      final now = DateTime.now().millisecondsSinceEpoch;
      final age = now - ((old?['createdAtMs'] as num?)?.toInt() ?? 0);
      // A manual retry and recovery reuse the original immutable request.
      if (old != null && old['store'] == store && age >= 0 && age <= 300000) {
        return;
      }
      final random = Random.secure();
      final requestId = List.generate(16, (_) => random.nextInt(256)
          .toRadixString(16).padLeft(2, '0')).join();
      await write(_key(action, employee), jsonEncode({
        'action': action, 'requestId': requestId, 'store': store,
        'createdAtMs': now,
        if (action == 'clockOut') ...{
          'recordId': _recordIds[employee], 'note': note,
        },
      }));
    });
  }

  Future<void> clearIntent(String action, String employee) =>
      _stored(() => remove(_key(action, employee)));

  Future<Map<String, dynamic>> _post(Map<String, dynamic> body) async {
    final response = await client.post(endpoint,
        headers: {'Content-Type': 'text/plain; charset=UTF-8'},
        body: jsonEncode(body));
    final data = jsonDecode(response.body);
    if (data is! Map) throw const FormatException('서버 응답을 확인하지 못했습니다.');
    final result = Map<String, dynamic>.from(data);
    if (response.statusCode >= 500) result['retryable'] = true;
    return result;
  }

  Future<Map<String, dynamic>> send(Map<String, dynamic> original) async {
    final action = original['action']?.toString() ?? '';
    // Sheet housekeeping has no equivalent: D1 already commits record/audit/receipt together.
    if (action == 'maintenance') return {'success': true};
    final employee = original['employeeId']?.toString() ?? '';
    final tracksState = ['status', 'clockIn', 'clockOut', 'changePassword'].contains(action);
    final generation = tracksState
        ? (_generations[employee] = (_generations[employee] ?? 0) + 1)
        : (_generations[employee] ?? 0);
    final keys = switch (action) {
      'bootstrap' => ['action'],
      'status' => ['action', 'employeeId', 'password', 'selectedStore', 'actionToken'],
      'calendar' => ['action', 'employeeId', 'password', 'year', 'month', 'actionToken'],
      'changePassword' => ['action', 'employeeId', 'currentPassword', 'newPassword', 'confirmPassword'],
      'clockIn' || 'clockOut' => ['action', 'employeeId', 'password', 'selectedStore', 'actionToken'],
      _ => throw UnsupportedError('테스트에 연결되지 않은 요청입니다.'),
    };
    final body = <String, dynamic>{
      for (final key in keys) if (original.containsKey(key)) key: original[key],
    };
    if (action == 'clockIn' || action == 'clockOut') {
      var intent = await _stored(() => _readIntent(action, employee));
      // A checkout intent can be created before this session's own recordId cache is
      // populated (fresh resume, or immediately after clock-in). If a valid recordId has
      // since arrived, backfill it into the same requestId/store/note instead of failing.
      if (action == 'clockOut' && intent != null && intent['recordId'] == null &&
          intent['store'] == original['selectedStore'] && _recordIds[employee] != null) {
        intent = {...intent, 'recordId': _recordIds[employee]};
        await _stored(() => write(_key(action, employee), jsonEncode(intent)));
      }
      if (intent == null || intent['store'] != original['selectedStore'] ||
          (action == 'clockOut' && intent['recordId'] == null)) {
        return {
          'success': false,
          // `code`/`localOnly` only label this as produced here, with no HTTP request made, so the
          // app's diagnostics can tell it from a server rejection; the message and success are unchanged.
          'code': intent == null ? 'INTENT_MISSING' : intent['store'] != original['selectedStore'] ? 'INTENT_STORE_MISMATCH' : 'RECORD_ID_MISSING',
          'localOnly': true,
          'message': '저장 요청 정보를 확인하지 못했습니다. 현재 상태를 다시 확인해 주세요.',
        };
      }
      body['requestId'] = intent['requestId'];
      if (action == 'clockOut') {
        body['recordId'] = intent['recordId'];
        body['note'] = intent['note'];
      }
    }
    final result = await _post(body);
    if (result['success'] == true && result['duplicate'] == true) {
      // A replay receipt can describe a shift that has since ended. Display the current state.
      final current = await _post({
        'action': 'status', 'employeeId': employee,
        'password': original['password'], 'selectedStore': original['selectedStore'],
      });
      if (current['success'] != true) {
        return {'success': false, 'retryable': true, 'message': '저장 후 현재 상태를 확인하지 못했습니다.'};
      }
      result['attendance'] = current['attendance'];
    }
    if (result['success'] == true && tracksState && _generations[employee] == generation) {
      final attendance = result['attendance'];
      if (attendance is Map && attendance['status'] == 'WORKING' && attendance['recordId'] is String) {
        _recordIds[employee] = attendance['recordId'] as String;
      } else {
        _recordIds.remove(employee);
      }
    }
    return result;
  }
}
