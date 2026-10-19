import 'dart:async';
import 'dart:convert';

import 'package:attendance_app/calculator_notice.dart';
import 'package:attendance_app/calculator_page.dart';
import 'package:attendance_app/employee_server_preview.dart';
import 'package:attendance_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// url_launcher is already a dependency; its platform interface is how the call button is observed.
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

// The calculator settings (일반 안내문 / 빨간 경고 / 문의 전화 and the deduction) come from the server, with a cache and a per-build
// fallback: kb_main keeps its wording and 3.3%, every other build shows no notes and deducts nothing.
// Everything below goes through the real WorkPage -> CalculatorPage path against a fake employee API.
const kbApi = 'https://attendance-employee-api.lynje.workers.dev/employee/api';
const shop2Api = 'https://kb-checkin-shop2-employee.lynje.workers.dev/employee/api';
const kbInfo1 = '월급은 매월 10일에 지급돼요';
const kbInfo2 = '(주말이나 공휴일 껴있는 경우 10일 전후 2일 정도 차이 날 수 있어요.)';
const kbWarning = '본인 외 다른 직원에게 보여주지 마세요';
const kbPhoneLine = '문의: 01097465633';
const fixedLine = '자동으로 3.3% 계산이 돼요.';

class FakeApi {
  final bodies = <Map<String, dynamic>>[];
  Future<http.Response> Function(Map<String, dynamic> body)? notice;
  List<Map<String, dynamic>> get notices => bodies.where((b) => b['action'] == 'calculatorNotice').toList();
}

http.Response json(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json; charset=utf-8'});
// The deduction defaults to freelance_3_3 (the 3.3% every earlier assertion in this file was written under); pass {} for settings
// saved before the option existed, or another deduction to test it.
const freelance = {'deductionMode': 'freelance_3_3', 'deductionRateBp': 330};
http.Response configured(String info, String warning, String phone, [int updatedAt = 1700000000000, Map<String, Object?> deduction = freelance]) =>
    json({'success': true, 'configured': true, 'infoText': info, 'warningText': warning, 'contactPhone': phone, 'updatedAt': updatedAt, ...deduction, 'actionToken': ''});
final notConfigured = json({'success': true, 'configured': false, 'actionToken': ''});

FakeApi install(String api) {
  final fake = FakeApi();
  employeeServerPreview = EmployeeServerPreview(
    endpoint: Uri.parse(api),
    client: MockClient((request) async {
      final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
      fake.bodies.add(body);
      switch (body['action']) {
        case 'calculatorNotice':
          return fake.notice == null ? notConfigured : fake.notice!(body);
        case 'calendar':
          return json({'success': true, 'records': [{'workedText': '86시간 30분'}], 'actionToken': ''});
        default:
          return json({'success': true, 'attendance': {'status': 'NOT_IN', 'serverNowMs': DateTime.now().millisecondsSinceEpoch}, 'actionToken': ''});
      }
    }),
    read: (key) => secureStorage.read(key: key),
    write: (key, value) => secureStorage.write(key: key, value: value),
    remove: (key) => secureStorage.delete(key: key),
  );
  addTearDown(() => employeeServerPreview = null);
  return fake;
}

Future<void> openWork(WidgetTester tester, {Future<Map<String, dynamic>>? login, Map<String, String> storage = const {}}) async {
  FlutterSecureStorage.setMockInitialValues(Map<String, String>.of(storage));
  tester.view.physicalSize = const Size(1200, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: WorkPage(
    store: '제로백', employee: '직원', employeeId: 'e1', password: '7391',
    attendance: {'status': 'NOT_IN', 'serverNowMs': DateTime.now().millisecondsSinceEpoch},
    loginFuture: login ?? sendApiRequest({'action': 'status', 'employeeId': 'e1', 'password': '7391', 'selectedStore': '제로백'}),
    rememberDevice: false,
  )));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100)); // the cache restore finishes behind the first frame
}

// Taps 계산기 and lets the route animate in; whatever the notes request does is NOT waited for.
Future<void> openCalculator(WidgetTester tester) async {
  await tester.ensureVisible(find.text('계산기'));
  await tester.pump();
  await tester.tap(find.text('계산기'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

// The back arrow starts the closing animation on the next frame; the page is gone once it has run.
Future<void> closeCalculator(WidgetTester tester) async {
  await tester.pageBack();
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) { await tester.pump(const Duration(milliseconds: 100)); }
}

void expectKbWording() {
  expect(find.text(fixedLine), findsOneWidget);
  expect(find.text(kbInfo1), findsOneWidget); expect(find.text(kbInfo2), findsOneWidget);
  expect(find.text(kbWarning), findsOneWidget); expect(find.text(kbPhoneLine), findsOneWidget);
  expect(find.byIcon(Icons.call), findsOneWidget);
}

void expectOnlyFixedLine() {
  expect(find.text(fixedLine), findsOneWidget);
  for (final gone in [kbInfo1, kbInfo2, kbWarning, kbPhoneLine]) { expect(find.text(gone), findsNothing, reason: gone); }
  expect(find.textContaining('문의'), findsNothing);
  expect(find.textContaining('01097465633'), findsNothing);
  expect(find.byIcon(Icons.call), findsNothing);
}

// A build that is not kb_main, with nothing stored: no kb_main notes, no phone, and no deduction sentence at all.
void expectNothingShown() {
  expect(find.textContaining('자동으로'), findsNothing);
  for (final gone in [kbInfo1, kbInfo2, kbWarning, kbPhoneLine]) { expect(find.text(gone), findsNothing, reason: gone); }
  expect(find.textContaining('문의'), findsNothing);
  expect(find.textContaining('01097465633'), findsNothing);
  expect(find.byIcon(Icons.call), findsNothing);
}

String cacheKey(String api) => calculatorNoticeCacheKey(Uri.parse(api));

class FakeLauncher extends UrlLauncherPlatform with MockPlatformInterfaceMixin {
  final launched = <String>[];
  // The link widget delegate is never used here; every other member the page needs is overridden below.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
  @override
  Future<bool> canLaunch(String url) async => true;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async { launched.add(url); return true; }
}

void main() {
  group('which wording a build falls back to', () {
    test('only the kb_main API host gets the built-in wording; shop2, the local preview, tests and look-alike hosts get nothing', () {
      expect(CalculatorNotice.builtInFor(Uri.parse(kbApi)), CalculatorNotice.kbBuiltIn);
      for (final other in [shop2Api, 'http://127.0.0.1:8789/employee/api', 'http://test.invalid/employee/api', 'https://attendance-employee-api.lynje.workers.dev.evil.example/employee/api',
        'https://x-attendance-employee-api.lynje.workers.dev/employee/api', 'https://attendance-api-dev.lynje.workers.dev/employee/api']) {
        expect(CalculatorNotice.builtInFor(Uri.parse(other)), CalculatorNotice.hidden, reason: other);
      }
      expect(CalculatorNotice.builtInFor(null), CalculatorNotice.hidden); // no API at all: still nothing from kb_main
      expect(CalculatorNotice.hidden.infoText + CalculatorNotice.hidden.warningText + CalculatorNotice.hidden.contactPhone, isEmpty);
    });

    test('a stored setting wins; "not configured" means the built-in for that build', () {
      const own = CalculatorNotice(configured: true, infoText: '샵2 안내', warningText: '', contactPhone: '0212345678', updatedAt: 7, deductionMode: deductionCustom, deductionRateBp: 500);
      expect(own.effective(Uri.parse(shop2Api)), own);
      expect(own.effective(Uri.parse(kbApi)), own);
      const none = CalculatorNotice(configured: false);
      expect(none.effective(Uri.parse(kbApi)), CalculatorNotice.kbBuiltIn);
      expect(none.effective(Uri.parse(shop2Api)), CalculatorNotice.hidden);
    });

    test('answers are parsed strictly: anything that is not a well-formed answer gives null', () {
      expect(CalculatorNotice.fromResponse({'success': true, 'configured': false}), const CalculatorNotice(configured: false));
      expect(CalculatorNotice.fromResponse({'success': true, 'configured': true, 'infoText': 'a', 'warningText': 'b', 'contactPhone': '0212345678', 'updatedAt': 5.0})?.updatedAt, 5);
      for (final bad in <Map<String, dynamic>>[
        {'success': false, 'code': 'INVALID_CREDENTIALS'}, {'success': true}, {'success': true, 'configured': 'yes'}, {'success': true, 'configured': true},
        {'success': true, 'configured': true, 'infoText': 1, 'warningText': '', 'contactPhone': ''}, {'success': true, 'configured': true, 'infoText': '', 'warningText': null, 'contactPhone': ''},
      ]) { expect(CalculatorNotice.fromResponse(bad), isNull, reason: '$bad'); }
    });

    test('the cache is per API host and is only read back by the host that wrote it', () {
      final kb = Uri.parse(kbApi), shop2 = Uri.parse(shop2Api);
      expect(calculatorNoticeCacheKey(kb), isNot(calculatorNoticeCacheKey(shop2)));
      const notice = CalculatorNotice(configured: true, infoText: 'x', warningText: 'y', contactPhone: '0212345678', updatedAt: 9);
      final stored = encodeCalculatorNoticeCache(shop2, notice);
      expect(decodeCalculatorNoticeCache(shop2, stored), notice);
      expect(decodeCalculatorNoticeCache(kb, stored), isNull); // same bytes under the wrong host: ignored
      for (final bad in [null, '', 'not json', '[]', '{"host":"${shop2.host}"}', '{"host":"${shop2.host}","configured":"x"}']) { expect(decodeCalculatorNoticeCache(shop2, bad), isNull, reason: '$bad'); }
    });
  });

  group('opening the calculator', () {
    testWidgets('the page opens at once, with the wording of its own build, while the request is still open', (tester) async {
      for (final (api, kb) in [(kbApi, true), (shop2Api, false)]) {
        final fake = install(api);
        final held = Completer<http.Response>();
        fake.notice = (_) => held.future;
        await openWork(tester);
        await openCalculator(tester);
        expect(find.byType(CalculatorPage), findsOneWidget);
        expect(fake.notices, hasLength(1)); // asked for, not waited for
        if (kb) { expectKbWording(); } else { expectNothingShown(); } // no kb wording flashes up on shop2 while waiting
        held.complete(notConfigured);
        await settle(tester);
        if (kb) { expectKbWording(); } else { expectNothingShown(); }
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('kb_main, nothing stored, server says not configured: the wording it always had stays', (tester) async {
      install(kbApi).notice = (_) async => notConfigured;
      await openWork(tester);
      await openCalculator(tester);
      await settle(tester);
      expectKbWording();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('shop2, nothing stored, server says not configured: no kb_main wording, no phone number and no 3.3% line', (tester) async {
      install(shop2Api).notice = (_) async => notConfigured;
      await openWork(tester);
      await openCalculator(tester);
      await settle(tester);
      expectNothingShown();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a configured organization shows its own values (multi-line text line by line) in place of the built-in ones', (tester) async {
      for (final api in [kbApi, shop2Api]) {
        install(api).notice = (_) async => configured('샵 급여일은 25일\n입금은 오후에\n\n문의는 사무실로', '타인에게 보이지 마세요', '0212345678');
        await openWork(tester);
        await openCalculator(tester);
        await settle(tester);
        expect(find.text(fixedLine), findsOneWidget);
        for (final line in ['샵 급여일은 25일', '입금은 오후에', '문의는 사무실로', '타인에게 보이지 마세요', '문의: 0212345678']) { expect(find.text(line), findsOneWidget, reason: line); }
        for (final gone in [kbInfo1, kbInfo2, kbWarning, kbPhoneLine]) { expect(find.text(gone), findsNothing); }
        expect(tester.widget<Text>(find.text('타인에게 보이지 마세요')).style?.color, Colors.red); // the red warning style is kept
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('an empty part is hidden on its own: no general text, no warning, or no phone line with its call button', (tester) async {
      final fake = install(shop2Api);
      Future<void> showWith(String info, String warning, String phone) async {
        fake.notice = (_) async => configured(info, warning, phone);
        await openWork(tester);
        await openCalculator(tester);
        await settle(tester);
      }
      await showWith('', '경고만', '');
      expect(find.text(fixedLine), findsOneWidget); expect(find.text('경고만'), findsOneWidget);
      expect(find.textContaining('문의'), findsNothing); expect(find.byIcon(Icons.call), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await showWith('안내만', '', '');
      expect(find.text('안내만'), findsOneWidget);
      expect(tester.widgetList<Text>(find.byType(Text)).where((t) => t.style?.color == Colors.red), isEmpty);
      expect(find.textContaining('문의'), findsNothing); expect(find.byIcon(Icons.call), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await showWith('', '', '0212345678');
      expect(find.text('문의: 0212345678'), findsOneWidget); expect(find.byIcon(Icons.call), findsOneWidget);
      expect(find.text('안내만'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await showWith('', '', ''); // configured, and everything switched off
      expectOnlyFixedLine();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the call button dials the number shown, through the same launcher as before', (tester) async {
      final launcher = FakeLauncher();
      final previous = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = launcher;
      addTearDown(() => UrlLauncherPlatform.instance = previous);
      install(shop2Api).notice = (_) async => configured('', '', '0212345678');
      await openWork(tester);
      await openCalculator(tester);
      await settle(tester);
      await tester.tap(find.byIcon(Icons.call));
      await tester.pump();
      expect(launcher.launched, ['tel:0212345678']);
      await tester.pumpWidget(const SizedBox());
      // and kb_main's built-in number still dials as before
      install(kbApi).notice = (_) async => notConfigured;
      await openWork(tester);
      await openCalculator(tester);
      await settle(tester);
      await tester.tap(find.byIcon(Icons.call));
      await tester.pump();
      expect(launcher.launched.last, 'tel:01097465633');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the 3.3% calculation is the same whatever the notes say (kb_main, nothing chosen or freelance_3_3)', (tester) async {
      for (final response in [notConfigured, configured('', '', ''), configured('다른 안내', '다른 경고', '0212345678')]) {
        install(kbApi).notice = (_) async => response;
        await openWork(tester);
        await openCalculator(tester);
        await settle(tester);
        await tester.enterText(find.byType(TextField), '10000');
        await tester.pump();
        expect(find.text('현재 총 근무 시간: 86시간 30분'), findsOneWidget);
        expect(find.text('836,455원'), findsOneWidget); // 86.5h x 10000 less 3.3%
        await tester.pumpWidget(const SizedBox());
      }
    });
  });

  group('cache', () {
    testWidgets('a stored value is on screen the moment the calculator opens, before the server has answered', (tester) async {
      final fake = install(shop2Api);
      final held = Completer<http.Response>();
      fake.notice = (_) => held.future;
      const stored = CalculatorNotice(configured: true, infoText: '캐시 안내', warningText: '캐시 경고', contactPhone: '0311234567', updatedAt: 3);
      await openWork(tester, storage: {cacheKey(shop2Api): encodeCalculatorNoticeCache(Uri.parse(shop2Api), stored)});
      await openCalculator(tester);
      for (final line in ['캐시 안내', '캐시 경고', '문의: 0311234567']) { expect(find.text(line), findsOneWidget, reason: line); }
      held.complete(configured('새 안내', '', '', 4));
      await settle(tester);
      expect(find.text('캐시 안내'), findsNothing); expect(find.text('새 안내'), findsOneWidget);
      expect(find.text('캐시 경고'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a successful answer updates the open screen and is written to the cache (own key, own host inside)', (tester) async {
      install(shop2Api).notice = (_) async => configured('저장될 안내', '저장될 경고', '0212345678', 42);
      await openWork(tester);
      await openCalculator(tester);
      await settle(tester);
      final raw = await secureStorage.read(key: cacheKey(shop2Api));
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map;
      expect([decoded['host'], decoded['configured'], decoded['infoText'], decoded['warningText'], decoded['contactPhone'], decoded['updatedAt']],
          [Uri.parse(shop2Api).host, true, '저장될 안내', '저장될 경고', '0212345678', 42]);
      await tester.pumpWidget(const SizedBox());
      // a new session starts from that cache
      final fake = install(shop2Api);
      fake.notice = (_) => Completer<http.Response>().future;
      await openWork(tester, storage: {cacheKey(shop2Api): raw});
      await openCalculator(tester);
      expect(find.text('저장될 안내'), findsOneWidget);
      await tester.pump(apiCallTimeout + const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('"not configured" from the server replaces an older stored setting with the build\'s own wording and updates the cache', (tester) async {
      const stored = CalculatorNotice(configured: true, infoText: '예전 안내', warningText: '', contactPhone: '', updatedAt: 1);
      for (final (api, kb) in [(kbApi, true), (shop2Api, false)]) {
        install(api).notice = (_) async => notConfigured;
        await openWork(tester, storage: {cacheKey(api): encodeCalculatorNoticeCache(Uri.parse(api), stored)});
        await openCalculator(tester);
        await settle(tester);
        expect(find.text('예전 안내'), findsNothing);
        if (kb) { expectKbWording(); } else { expectNothingShown(); }
        expect(jsonDecode((await secureStorage.read(key: cacheKey(api)))!)['configured'], false);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('a cache of another host or a broken cache is never used: the build falls back to its own wording', (tester) async {
      const kbStored = CalculatorNotice(configured: true, infoText: 'kb 캐시 안내', warningText: 'kb 캐시 경고', contactPhone: '01011112222', updatedAt: 2);
      final foreign = encodeCalculatorNoticeCache(Uri.parse(kbApi), kbStored);
      for (final storage in <Map<String, String>>[
        {cacheKey(kbApi): foreign}, // the kb entry is simply under another key
        {cacheKey(shop2Api): foreign}, // kb bytes planted under shop2's key: the host inside does not match
        {cacheKey(shop2Api): 'not json'},
        {cacheKey(shop2Api): '{"host":"${Uri.parse(shop2Api).host}","configured":true,"infoText":5}'},
      ]) {
        final fake = install(shop2Api);
        fake.notice = (_) => Completer<http.Response>().future;
        await openWork(tester, storage: storage);
        await openCalculator(tester);
        expectNothingShown();
        expect(find.textContaining('kb 캐시'), findsNothing);
        await tester.pump(apiCallTimeout + const Duration(seconds: 1));
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('a cache that cannot be read or written never stops the calculator', (tester) async {
      install(shop2Api).notice = (_) async => configured('안내', '경고', '');
      await openWork(tester, storage: {cacheKey(shop2Api): '\u0000garbage'});
      await openCalculator(tester);
      await settle(tester);
      expect(find.text('안내'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('when the server does not help', () {
    // Each failure leaves exactly what was on screen, shows nothing to the user and does not touch the stored copy.
    const stored = CalculatorNotice(configured: true, infoText: '지금 안내', warningText: '지금 경고', contactPhone: '0212345678', updatedAt: 5, deductionMode: deductionFreelance, deductionRateBp: freelanceRateBp);
    final failures = <String, Future<http.Response> Function(Map<String, dynamic>)>{
      'an error answer (wrong PIN / session)': (_) async => json({'success': false, 'code': 'INVALID_CREDENTIALS', 'message': '비밀번호가 일치하지 않습니다.'}),
      'ACTION_NOT_AVAILABLE from an older server': (_) async => json({'success': false, 'code': 'ACTION_NOT_AVAILABLE', 'message': '아직 테스트에 연결되지 않은 기능입니다.'}, 400),
      'a server error': (_) async => json({'success': false, 'code': 'EMPLOYEE_UNAVAILABLE'}, 503),
      'a reply that is not JSON': (_) async => http.Response('<html>bad gateway</html>', 502),
      'a connection that fails': (_) async => throw http.ClientException('connection lost'),
      'an answer in the wrong shape': (_) async => json({'success': true, 'configured': true, 'infoText': 5}),
      'a rate-limit answer': (_) async => json({'success': false, 'code': 'RATE_LIMITED'}),
    };
    for (final entry in failures.entries) {
      testWidgets('${entry.key}: the screen, the cache and the user are left alone', (tester) async {
        install(shop2Api).notice = entry.value;
        await openWork(tester, storage: {cacheKey(shop2Api): encodeCalculatorNoticeCache(Uri.parse(shop2Api), stored)});
        await openCalculator(tester);
        await settle(tester);
        for (final line in ['지금 안내', '지금 경고', '문의: 0212345678']) { expect(find.text(line), findsOneWidget, reason: line); }
        expect(find.byType(SnackBar), findsNothing); expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
        expect(await secureStorage.read(key: cacheKey(shop2Api)), encodeCalculatorNoticeCache(Uri.parse(shop2Api), stored));
        // and the calculator itself still works
        await tester.enterText(find.byType(TextField), '10000');
        await tester.pump();
        expect(find.text('836,455원'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('a request that never answers times out quietly (the app\'s 12 s limit) and leaves the screen as it was', (tester) async {
      final fake = install(kbApi);
      fake.notice = (_) => Completer<http.Response>().future;
      await openWork(tester);
      await openCalculator(tester);
      expectKbWording();
      await tester.pump(apiCallTimeout + const Duration(seconds: 1));
      expectKbWording();
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with no API configured at all the calculator still opens and shows nothing from kb_main', (tester) async {
      employeeServerPreview = null;
      await openWork(tester, login: Completer<Map<String, dynamic>>().future);
      await openCalculator(tester);
      expect(find.byType(CalculatorPage), findsOneWidget);
      expectNothingShown();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('deduction', () {
    test('the built-ins: kb_main deducts 3.3%, every other build deducts nothing', () {
      expect([CalculatorNotice.kbBuiltIn.deductionMode, CalculatorNotice.kbBuiltIn.deductionRateBp], [deductionFreelance, 330]);
      expect([CalculatorNotice.hidden.deductionMode, CalculatorNotice.hidden.deductionRateBp], [deductionNone, 0]);
      expect(CalculatorNotice.builtInFor(Uri.parse(kbApi)).deductionRateBp, 330);
      for (final other in [shop2Api, 'https://example.com/employee/api', 'https://attendance-employee-api.lynje.workers.dev.evil.example/employee/api']) {
        expect(CalculatorNotice.builtInFor(Uri.parse(other)).deductionRateBp, 0, reason: other);
      }
      expect(CalculatorNotice.builtInFor(null).deductionRateBp, 0);
    });

    test('notes saved without a chosen deduction keep their notes and take only the deduction of the build; a chosen one always wins', () {
      const unset = CalculatorNotice(configured: true, infoText: '안내', warningText: '', contactPhone: '0212345678', updatedAt: 3);
      final onKb = unset.effective(Uri.parse(kbApi)), onShop2 = unset.effective(Uri.parse(shop2Api));
      expect([onKb.infoText, onKb.contactPhone, onKb.updatedAt, onKb.configured, onKb.deductionMode, onKb.deductionRateBp], ['안내', '0212345678', 3, true, deductionFreelance, 330]);
      expect([onShop2.infoText, onShop2.contactPhone, onShop2.configured, onShop2.deductionMode, onShop2.deductionRateBp], ['안내', '0212345678', true, deductionNone, 0]);
      const chosen = CalculatorNotice(configured: true, infoText: '안내', updatedAt: 3, deductionMode: deductionNone, deductionRateBp: 0);
      expect(chosen.effective(Uri.parse(kbApi)), chosen); // kb_main's administrator picked 공제 없음: that is what applies
      expect(chosen.effective(Uri.parse(shop2Api)), chosen);
    });

    test('answers: the three modes parse; absent or null means not chosen; anything inconsistent is not an answer at all', () {
      Map<String, dynamic> answer(Map<String, Object?> extra) => {'success': true, 'configured': true, 'infoText': 'a', 'warningText': 'b', 'contactPhone': '', 'updatedAt': 5, ...extra};
      for (final (mode, bp) in [(deductionNone, 0), (deductionFreelance, 330), (deductionCustom, 0), (deductionCustom, 1), (deductionCustom, 270), (deductionCustom, 500), (deductionCustom, 10000)]) {
        final parsed = CalculatorNotice.fromResponse(answer({'deductionMode': mode, 'deductionRateBp': bp}))!;
        expect([parsed.deductionMode, parsed.deductionRateBp, parsed.configured, parsed.infoText], [mode, bp, true, 'a']);
      }
      for (final unset in <Map<String, Object?>>[{}, {'deductionMode': null, 'deductionRateBp': null}]) {
        final parsed = CalculatorNotice.fromResponse(answer(unset))!;
        expect([parsed.deductionMode, parsed.deductionRateBp, parsed.infoText], [null, null, 'a']);
      }
      for (final bad in <Map<String, Object?>>[
        {'deductionMode': deductionCustom, 'deductionRateBp': -1}, {'deductionMode': deductionCustom, 'deductionRateBp': 10001}, {'deductionMode': deductionCustom, 'deductionRateBp': 270.5},
        {'deductionMode': deductionCustom, 'deductionRateBp': 500.0}, {'deductionMode': deductionCustom, 'deductionRateBp': '500'}, {'deductionMode': deductionCustom, 'deductionRateBp': null},
        {'deductionMode': deductionNone, 'deductionRateBp': 100}, {'deductionMode': deductionNone, 'deductionRateBp': null}, {'deductionMode': deductionFreelance, 'deductionRateBp': 300},
        {'deductionMode': 'something_new', 'deductionRateBp': 5}, {'deductionMode': 3, 'deductionRateBp': 330}, {'deductionMode': null, 'deductionRateBp': 330}, {'deductionRateBp': 330},
        {'deductionMode': deductionFreelance},
      ]) { expect(CalculatorNotice.fromResponse(answer(bad)), isNull, reason: '$bad'); }
    });

    test('the percentage shown has no trailing zeros and no float noise', () {
      for (final (bp, text) in [(330, '3.3'), (500, '5'), (270, '2.7'), (275, '2.75'), (205, '2.05'), (100, '1'), (1, '0.01'), (10, '0.1'), (10000, '100'), (1250, '12.5')]) {
        expect(formatRatePercent(bp), text);
      }
    });

    test('the cache keeps the deduction; an entry written before the option existed reads back as "not chosen"; a broken deduction is ignored', () {
      final shop2 = Uri.parse(shop2Api);
      const withDeduction = CalculatorNotice(configured: true, infoText: 'x', warningText: '', contactPhone: '', updatedAt: 9, deductionMode: deductionCustom, deductionRateBp: 270);
      expect(decodeCalculatorNoticeCache(shop2, encodeCalculatorNoticeCache(shop2, withDeduction)), withDeduction);
      final oldEntry = '{"host":"${shop2.host}","configured":true,"infoText":"x","warningText":"","contactPhone":"","updatedAt":9}';
      final read = decodeCalculatorNoticeCache(shop2, oldEntry)!;
      expect([read.configured, read.infoText, read.deductionMode, read.deductionRateBp], [true, 'x', null, null]);
      for (final bad in ['"deductionMode":"custom","deductionRateBp":101000', '"deductionMode":"custom","deductionRateBp":"5"', '"deductionMode":"weird","deductionRateBp":1']) {
        expect(decodeCalculatorNoticeCache(shop2, oldEntry.replaceFirst('"updatedAt":9', '"updatedAt":9,$bad')), isNull, reason: bad);
      }
    });

    final amounts = <String, ({Map<String, Object?> deduction, String net, String? line})>{
      'none': (deduction: {'deductionMode': 'none', 'deductionRateBp': 0}, net: '865,000원', line: null),
      'freelance_3_3': (deduction: freelance, net: '836,455원', line: '자동으로 3.3% 계산이 돼요.'),
      'custom 1%': (deduction: {'deductionMode': 'custom', 'deductionRateBp': 100}, net: '856,350원', line: '자동으로 1% 계산이 돼요.'),
      'custom 2.7%': (deduction: {'deductionMode': 'custom', 'deductionRateBp': 270}, net: '841,645원', line: '자동으로 2.7% 계산이 돼요.'),
      'custom 5%': (deduction: {'deductionMode': 'custom', 'deductionRateBp': 500}, net: '821,750원', line: '자동으로 5% 계산이 돼요.'),
      'custom 5.00 written as 500': (deduction: {'deductionMode': 'custom', 'deductionRateBp': 500}, net: '821,750원', line: '자동으로 5% 계산이 돼요.'),
      'custom 100%': (deduction: {'deductionMode': 'custom', 'deductionRateBp': 10000}, net: '0원', line: '자동으로 100% 계산이 돼요.'),
      'custom 0%': (deduction: {'deductionMode': 'custom', 'deductionRateBp': 0}, net: '865,000원', line: null),
    };
    for (final api in [kbApi, shop2Api]) {
      for (final entry in amounts.entries) {
        testWidgets('${api == kbApi ? 'kb_main' : 'shop2'} with ${entry.key}: the amount and the sentence follow the server setting, whatever the note text says', (tester) async {
          // the notes talk about other percentages on purpose: they take no part in the calculation
          install(api).notice = (_) async => configured('수수료 50% 공제, 3.3% 아님', '10% 입니다', '', 1700000000000, entry.value.deduction);
          await openWork(tester);
          await openCalculator(tester);
          await settle(tester);
          await tester.enterText(find.byType(TextField), '10000');
          await tester.pump();
          expect(find.text('현재 총 근무 시간: 86시간 30분'), findsOneWidget);
          expect(find.text(entry.value.net), findsOneWidget);
          if (entry.value.line == null) { expect(find.textContaining('자동으로'), findsNothing); } else { expect(find.text(entry.value.line!), findsOneWidget); }
          expect(find.text('수수료 50% 공제, 3.3% 아님'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }

    testWidgets('settings saved with no deduction chosen: kb_main still deducts 3.3% (same amount as before), another build deducts nothing', (tester) async {
      for (final (api, net, line) in [(kbApi, '836,455원', fixedLine), (shop2Api, '865,000원', null)]) {
        install(api).notice = (_) async => configured('안내', '', '0212345678', 1700000000000, const {});
        await openWork(tester);
        await openCalculator(tester);
        await settle(tester);
        await tester.enterText(find.byType(TextField), '10000');
        await tester.pump();
        expect(find.text(net), findsOneWidget, reason: api);
        if (line == null) { expect(find.textContaining('자동으로'), findsNothing); } else { expect(find.text(line), findsOneWidget); }
        expect(find.text('안내'), findsOneWidget); expect(find.text('문의: 0212345678'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('a background answer changes the amount and the sentence on the open screen at once, and the cache keeps the deduction', (tester) async {
      final fake = install(kbApi);
      final held = Completer<http.Response>();
      fake.notice = (_) => held.future;
      await openWork(tester);
      await openCalculator(tester);
      await tester.enterText(find.byType(TextField), '10000');
      await tester.pump();
      await settle(tester); // the month total is in; the notes request is still open
      expect(find.text('836,455원'), findsOneWidget); // kb_main's own 3.3% while waiting
      expect(find.text(fixedLine), findsOneWidget);
      held.complete(configured('안내', '', '', 1700000000001, const {'deductionMode': 'custom', 'deductionRateBp': 500}));
      await settle(tester);
      expect(find.text('821,750원'), findsOneWidget);
      expect(find.text('836,455원'), findsNothing);
      expect(find.text('자동으로 5% 계산이 돼요.'), findsOneWidget); expect(find.text(fixedLine), findsNothing);
      expect(find.text('10000'), findsOneWidget); // the typed wage was not touched
      final cached = jsonDecode((await secureStorage.read(key: cacheKey(kbApi)))!) as Map<String, dynamic>;
      expect([cached['deductionMode'], cached['deductionRateBp']], ['custom', 500]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a stored deduction is used the moment the calculator opens; a cache from before the option existed is read without a crash', (tester) async {
      const stored = CalculatorNotice(configured: true, infoText: '캐시 안내', updatedAt: 3, deductionMode: deductionCustom, deductionRateBp: 270);
      final fake = install(shop2Api);
      final held = Completer<http.Response>();
      fake.notice = (_) => held.future;
      await openWork(tester, storage: {cacheKey(shop2Api): encodeCalculatorNoticeCache(Uri.parse(shop2Api), stored)});
      await openCalculator(tester);
      await settle(tester);
      await tester.enterText(find.byType(TextField), '10000');
      await tester.pump();
      expect(find.text('841,645원'), findsOneWidget);
      expect(find.text('자동으로 2.7% 계산이 돼요.'), findsOneWidget);
      held.complete(notConfigured);
      await settle(tester);
      expect(find.text('865,000원'), findsOneWidget); // "not configured" on shop2: nothing is deducted
      expect(find.textContaining('자동으로'), findsNothing);
      await tester.pumpWidget(const SizedBox());

      // a v1 entry written by the previous version: no deduction fields at all
      for (final (api, net, line) in [(kbApi, '836,455원', fixedLine), (shop2Api, '865,000원', null)]) {
        final host = Uri.parse(api).host;
        final legacy = '{"host":"$host","configured":true,"infoText":"옛 캐시","warningText":"","contactPhone":"","updatedAt":1}';
        final legacyFake = install(api);
        final legacyHeld = Completer<http.Response>();
        legacyFake.notice = (_) => legacyHeld.future;
        await openWork(tester, storage: {cacheKey(api): legacy});
        await openCalculator(tester);
        await settle(tester);
        await tester.enterText(find.byType(TextField), '10000');
        await tester.pump();
        expect(find.text('옛 캐시'), findsOneWidget);
        expect(find.text(net), findsOneWidget, reason: api);
        if (line == null) { expect(find.textContaining('자동으로'), findsNothing); } else { expect(find.text(line), findsOneWidget); }
        expect(tester.takeException(), isNull);
        legacyHeld.complete(notConfigured);
        await settle(tester);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('a failed or never-answered request leaves the build\'s own calculation in place (kb_main 3.3%, shop2 none)', (tester) async {
      for (final (api, net) in [(kbApi, '836,455원'), (shop2Api, '865,000원')]) {
        install(api).notice = (_) async => json({'success': false, 'code': 'EMPLOYEE_UNAVAILABLE'}, 503);
        await openWork(tester);
        await openCalculator(tester);
        await settle(tester);
        await tester.enterText(find.byType(TextField), '10000');
        await tester.pump();
        expect(find.text(net), findsOneWidget, reason: api);
        expect(find.byType(SnackBar), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
      final fake = install(shop2Api);
      fake.notice = (_) => Completer<http.Response>().future;
      await openWork(tester);
      await openCalculator(tester);
      await tester.pump(apiCallTimeout + const Duration(seconds: 1));
      await tester.enterText(find.byType(TextField), '10000');
      await tester.pump();
      expect(find.text('865,000원'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an answer with a deduction the app does not understand is ignored: the screen and the cache stay as they were', (tester) async {
      const stored = CalculatorNotice(configured: true, infoText: '지금 안내', updatedAt: 5, deductionMode: deductionCustom, deductionRateBp: 500);
      install(shop2Api).notice = (_) async => configured('새 안내', '', '', 6, const {'deductionMode': 'brand_new_mode', 'deductionRateBp': 7});
      await openWork(tester, storage: {cacheKey(shop2Api): encodeCalculatorNoticeCache(Uri.parse(shop2Api), stored)});
      await openCalculator(tester);
      await settle(tester);
      await tester.enterText(find.byType(TextField), '10000');
      await tester.pump();
      expect(find.text('지금 안내'), findsOneWidget); expect(find.text('새 안내'), findsNothing);
      expect(find.text('821,750원'), findsOneWidget);
      expect(await secureStorage.read(key: cacheKey(shop2Api)), encodeCalculatorNoticeCache(Uri.parse(shop2Api), stored));
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('timing and safety', () {
    testWidgets('the screen is not held back by the login check, and the request waits for it', (tester) async {
      final fake = install(shop2Api);
      fake.notice = (_) async => configured('로그인 뒤 안내', '', '');
      final login = Completer<Map<String, dynamic>>();
      await openWork(tester, login: login.future);
      await openCalculator(tester);
      expect(find.byType(CalculatorPage), findsOneWidget); // open although the login check has not finished
      await settle(tester);
      expect(fake.notices, isEmpty); // a protected request is not sent before the login is confirmed
      login.complete({'success': true, 'attendance': {'status': 'NOT_IN', 'serverNowMs': DateTime.now().millisecondsSinceEpoch}, 'actionToken': ''});
      await settle(tester);
      expect(fake.notices, hasLength(1));
      expect(find.text('로그인 뒤 안내'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the request carries only the employee, the PIN and the saved session token - never an organization', (tester) async {
      final fake = install(shop2Api);
      await openWork(tester, storage: {'attendance_action_token_v1_e1': 'T' * 43});
      await openCalculator(tester);
      await settle(tester);
      expect(fake.notices, hasLength(1));
      final body = fake.notices.single;
      expect(body['action'], 'calculatorNotice'); expect(body['employeeId'], 'e1'); expect(body['password'], '7391');
      expect(body.keys.toSet().difference({'action', 'employeeId', 'password', 'actionToken'}), isEmpty);
      for (final key in body.keys) { expect(key.toLowerCase(), isNot(contains('org'))); }
      await tester.pumpWidget(const SizedBox());
    });

    test('the request layer lets exactly the four known fields of calculatorNotice through, whatever else a caller adds', () async {
      final fake = install(shop2Api);
      await employeeServerPreview!.send({'action': 'calculatorNotice', 'employeeId': 'e1', 'password': '7391', 'actionToken': 'T', 'organizationId': 'kb_main', 'organization_id': 'kb_main', 'selectedStore': '제로백', 'extra': 1});
      expect(fake.notices.single, {'action': 'calculatorNotice', 'employeeId': 'e1', 'password': '7391', 'actionToken': 'T'});
    });

    testWidgets('an answer that arrives after the whole screen is gone does nothing and throws nothing', (tester) async {
      final logged = <String>[];
      final previousPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => logged.add(message ?? '');
      final fake = install(shop2Api);
      final held = Completer<http.Response>();
      fake.notice = (_) => held.future;
      await openWork(tester);
      await openCalculator(tester);
      await tester.pumpWidget(const SizedBox()); // the work page and the calculator are disposed
      held.complete(configured('늦은 안내', '', ''));
      await tester.pump(const Duration(milliseconds: 300));
      debugPrint = previousPrint; // flutter_test insists the hook is back before the test ends
      expect(tester.takeException(), isNull);
      expect(await secureStorage.read(key: cacheKey(shop2Api)), isNull); // nothing was written on behalf of a closed screen
      expect(logged.where((line) => line.contains('계산기안내')), isEmpty); // and it never even got as far as a swallowed error
    });

    testWidgets('an answer that arrives after only the calculator was closed updates the next opening', (tester) async {
      final fake = install(shop2Api);
      final held = Completer<http.Response>();
      var calls = 0;
      fake.notice = (_) { calls++; return calls == 1 ? held.future : Completer<http.Response>().future; }; // the second one is never answered
      await openWork(tester);
      await openCalculator(tester);
      await closeCalculator(tester);
      expect(find.byType(CalculatorPage), findsNothing);
      held.complete(configured('닫은 뒤 도착', '', ''));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await openCalculator(tester); // opened again: shows what arrived meanwhile, at once
      expect(find.text('닫은 뒤 도착'), findsOneWidget);
      expect(fake.notices, hasLength(2));
      await tester.pump(apiCallTimeout + const Duration(seconds: 1));
      expect(find.text('닫은 뒤 도착'), findsOneWidget); // the unanswered second request changed nothing
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('opening it again while the first request is still running does not stack a second request', (tester) async {
      final fake = install(shop2Api);
      final held = Completer<http.Response>();
      fake.notice = (_) => held.future;
      await openWork(tester);
      await openCalculator(tester);
      await closeCalculator(tester);
      await openCalculator(tester);
      expect(fake.notices, hasLength(1));
      held.complete(notConfigured);
      await settle(tester);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
