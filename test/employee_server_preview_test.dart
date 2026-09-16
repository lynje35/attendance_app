import 'dart:async';
import 'dart:convert';

import 'package:attendance_app/employee_server_preview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Map<String, String> storage;
  late List<Map<String, dynamic>> requests;
  late Future<http.Response> Function(Map<String, dynamic>) response;
  http.Response json(Map<String, dynamic> value) => http.Response(jsonEncode(value), 200);
  Map<String, dynamic> status(String id) => {'success': true, 'attendance': {'status': 'WORKING', 'recordId': id}};
  Map<String, dynamic> body(String action) => {'action': action, 'employeeId': 'test', 'password': '1234', 'selectedStore': 'store', '_clientSentAtMs': 123, 'actionToken': 'ignored'};
  EmployeeServerPreview bridge() => EmployeeServerPreview(
    endpoint: Uri.parse('http://127.0.0.1:8789/employee/api'),
    client: MockClient((request) async {
      expect(request.url.path, '/employee/api');
      final data = Map<String, dynamic>.from(jsonDecode(request.body));
      requests.add(data);
      return response(data);
    }),
    read: (key) async => storage[key],
    write: (key, value) async { storage[key] = value; },
    remove: (key) async { storage.remove(key); },
  );
  setUp(() {
    storage = {}; requests = [];
    response = (_) async => json(status('shift-a'));
  });

  test('clock-in persists a credential-free request before sending and reuses it after restart', () async {
    final first = bridge();
    await first.prepareIntent('clockIn', 'test', 'store');
    final raw = storage.values.single;
    expect(raw.contains('password'), false);
    final result = await first.send(body('clockIn'));
    expect(result['success'], true);
    final id = requests.last['requestId'];
    expect(id, matches(RegExp(r'^[a-f0-9]{32}$')));
    await bridge().send(body('clockIn'));
    expect(requests.last['requestId'], id);
    expect(requests.last.containsKey('_clientSentAtMs'), false);
    expect(requests.last.containsKey('actionToken'), false);
    await first.prepareIntent('clockIn', 'test', 'store');
    await first.send(body('clockIn'));
    expect(requests.last['requestId'], id);
  });
  test('checkout recovery keeps the original shift and note even when a later login sees a new shift', () async {
    final first = bridge();
    await first.send(body('status'));
    await first.prepareIntent('clockOut', 'test', 'store', note: 'original');
    response = (_) async => json(status('shift-b'));
    final restarted = bridge();
    await restarted.send(body('status'));
    await restarted.send({...body('clockOut'), 'note': 'edited'});
    expect(requests.last['recordId'], 'shift-a');
    expect(requests.last['note'], 'original');
  });
  test('missing persisted intent or checkout target never sends a write', () async {
    final adapter = bridge();
    expect((await adapter.send(body('clockIn')))['success'], false);
    await adapter.prepareIntent('clockOut', 'test', 'store');
    expect((await adapter.send(body('clockOut')))['success'], false);
    expect(requests, isEmpty);
  });
  test('clearing a completed request permits a fresh request and sequential new shift', () async {
    final adapter = bridge();
    await adapter.prepareIntent('clockIn', 'test', 'store');
    await adapter.send(body('clockIn'));
    final id = requests.last['requestId'];
    final clear = adapter.clearIntent('clockIn', 'test');
    final prepare = adapter.prepareIntent('clockIn', 'test', 'store');
    await Future.wait([clear, prepare]);
    await adapter.send(body('clockIn'));
    expect(requests.last['requestId'], isNot(id));
  });
  test('late status does not replace the newer checkout target', () async {
    final adapter = bridge();
    final old = Completer<http.Response>();
    response = (_) => old.future;
    final first = adapter.send(body('status'));
    await Future<void>.delayed(Duration.zero);
    response = (_) async => json(status('newer'));
    await adapter.send(body('status'));
    old.complete(json(status('older'))); await first;
    await adapter.prepareIntent('clockOut', 'test', 'store');
    await adapter.send(body('clockOut'));
    expect(requests.last['recordId'], 'newer');
  });
  test('duplicate receipts use fresh status instead of restoring an ended shift', () async {
    final adapter = bridge();
    await adapter.prepareIntent('clockIn', 'test', 'store');
    response = (data) async => json(data['action'] == 'status'
        ? {'success': true, 'attendance': {'status': 'NOT_IN'}}
        : {...status('old'), 'duplicate': true});
    final result = await adapter.send(body('clockIn'));
    expect((result['attendance'] as Map)['status'], 'NOT_IN');
    expect(requests.map((r) => r['action']), ['clockIn', 'status']);
  });
  test('calendar and password payloads follow server contract; maintenance makes no network request', () async {
    final adapter = bridge();
    await adapter.send({...body('calendar'), 'year': 2026, 'month': 9});
    expect(requests.last.keys.toSet(), {'action','employeeId','password','year','month'});
    await adapter.send({...body('changePassword'), 'currentPassword': '1234', 'newPassword': '4321', 'confirmPassword': '4321'});
    expect(requests.last.keys.toSet(), {'action','employeeId','currentPassword','newPassword','confirmPassword'});
    final count = requests.length;
    await adapter.send(body('maintenance'));
    expect(requests.length, count);
  });
}
