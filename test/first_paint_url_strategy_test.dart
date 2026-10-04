import 'dart:async';
import 'dart:ui' show VoidCallback;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:attendance_app/first_paint_url_strategy.dart';

// A browser history in memory: entries, a current index, pushState dropping the forward entries, popstate on go().
class FakeHistory implements UrlStrategy {
  FakeHistory() : entries = [HistoryEntry(null, '/app/')];
  final List<HistoryEntry> entries;
  int index = 0;
  final calls = <String>[];
  final listeners = <void Function(Object? state)>[];

  Object? get state => entries[index].state;
  String get url => entries[index].url;

  @override
  void pushState(Object? state, String title, String url) {
    calls.add('push');
    entries.removeRange(index + 1, entries.length);
    entries.add(HistoryEntry(state, url.isEmpty ? this.url : url));
    index++;
  }

  @override
  void replaceState(Object? state, String title, String url) {
    calls.add('replace');
    entries[index] = HistoryEntry(state, url.isEmpty ? this.url : url);
  }

  @override
  Future<void> go(int count) async {
    calls.add('go($count)');
    index += count;
    for (final listener in List.of(listeners)) {
      listener(state);
    }
  }

  @override
  VoidCallback addPopStateListener(void Function(Object? state) fn) {
    listeners.add(fn);
    return () => listeners.remove(fn);
  }

  @override
  String getPath() => url;
  @override
  Object? getState() => state;
  @override
  String prepareExternalUrl(String internalUrl) => internalUrl;
}

class HistoryEntry {
  HistoryEntry(this.state, this.url);
  final Object? state;
  final String url;
}

// The history writes SingleEntryBrowserHistory makes at start-up (flutter/engine .../navigation/history.dart):
// Multi ctor + tearDown (WidgetsApp reads defaultRouteName), the origin marker, the flutter entry, and the
// Navigator announcing '/' (which replaces the flutter entry).
void engineStartup(UrlStrategy s) {
  s.replaceState({'serialCount': 0.0, 'state': null}, 'flutter', '/app/');
  s.replaceState(null, 'flutter', '/app/');
  s.replaceState({'origin': true, 'state': null}, 'origin', '');
  s.pushState({'flutter': true}, 'flutter', '/app/');
  s.replaceState({'flutter': true}, 'flutter', '/app/');
}

// What SingleEntryBrowserHistory.onPopState does for the origin entry: push the flutter entry again.
void enginePopStateRepush(UrlStrategy s, Object? state) {
  if (state is Map && state['origin'] == true) s.pushState({'flutter': true}, 'flutter', '/app/');
}

List<Object?> statesOf(FakeHistory h) => h.entries.map((e) => e.state).toList();

void main() {
  group('isIosWebKit', () {
    bool ios(String ua, {String platform = '', int touch = 0}) => isIosWebKit(userAgent: ua, platform: platform, maxTouchPoints: touch);
    test('iPhone, iPad and iPod user agents are iOS', () {
      expect(ios('Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1'), isTrue);
      expect(ios('Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 Version/17.5 Mobile/15E148 Safari/604.1'), isTrue);
      expect(ios('Mozilla/5.0 (iPod touch; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15'), isTrue);
      // iOS Chrome / Edge are WebKit too and keep the iPhone token.
      expect(ios('Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/126.0 Mobile/15E148 Safari/604.1'), isTrue);
    });
    test('iPadOS in desktop-site mode (Macintosh UA + touch screen) is iOS', () {
      const mac = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15';
      expect(ios(mac, platform: 'MacIntel', touch: 5), isTrue);
    });
    test('Mac Safari, Android, Windows and Linux are not iOS', () {
      const mac = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15';
      expect(ios(mac, platform: 'MacIntel', touch: 0), isFalse);
      expect(ios('Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36', platform: 'Linux armv81', touch: 5), isFalse);
      expect(ios('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36', platform: 'Win32', touch: 10), isFalse);
      expect(ios('Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0', platform: 'Linux x86_64'), isFalse);
    });
  });

  group('wrapUrlStrategyForFirstPaint', () {
    test('not iOS: the very same strategy comes back and every write goes straight through', () {
      final history = FakeHistory();
      final result = wrapUrlStrategyForFirstPaint(history, enabled: false, firstPaint: () => Completer<void>().future);
      expect(identical(result, history), isTrue);
      engineStartup(result);
      expect(history.calls, ['replace', 'replace', 'replace', 'push', 'replace']);
      expect(history.state, {'flutter': true});
    });
    test('iOS: wrapped', () {
      final result = wrapUrlStrategyForFirstPaint(FakeHistory(), enabled: true, firstPaint: () async {});
      expect(result, isA<FirstPaintUrlStrategy>());
    });
  });

  group('FirstPaintUrlStrategy', () {
    late FakeHistory history;
    late Completer<void> firstPaint;
    late FirstPaintUrlStrategy strategy;
    late List<String> phases;
    var signalRequested = 0;

    setUp(() {
      history = FakeHistory();
      firstPaint = Completer<void>();
      phases = [];
      signalRequested = 0;
      strategy = FirstPaintUrlStrategy(history, firstPaint: () { signalRequested++; return firstPaint.future; }, onPhase: phases.add);
    });
    tearDown(() => strategy.release());

    Future<void> paintAndSettle() async {
      firstPaint.complete();
      await Future<void>.delayed(Duration.zero);
    }

    test('only the first push is held; the origin marker replace passes straight through', () {
      engineStartup(strategy);
      // Multi ctor / tearDown / origin marker went through, the flutter push and the replace that follows it did not.
      expect(history.calls, ['replace', 'replace', 'replace']);
      expect(history.entries.length, 1);
      expect(history.state, {'origin': true, 'state': null});
      expect(phases, ['held']);
      expect(signalRequested, 1);
    });

    test('after the first paint the held push and replace run once, in the original order', () async {
      engineStartup(strategy);
      await paintAndSettle();
      expect(history.calls, ['replace', 'replace', 'replace', 'push', 'replace']);
      expect(phases, ['held', 'released']);
      expect(signalRequested, 1);
    });

    test('final history is identical to an unwrapped strategy: [origin, flutter], state {flutter:true}, same URL', () async {
      final plain = FakeHistory();
      engineStartup(plain);
      engineStartup(strategy);
      await paintAndSettle();
      expect(statesOf(history), statesOf(plain));
      expect(statesOf(history), [{'origin': true, 'state': null}, {'flutter': true}]);
      expect(history.index, plain.index);
      expect(history.state, {'flutter': true});
      expect(history.entries.map((e) => e.url).toList(), plain.entries.map((e) => e.url).toList());
      expect(history.url, '/app/');
    });

    test('the replace that follows the held push lands on the flutter entry, never on the origin entry', () async {
      engineStartup(strategy);
      strategy.replaceState({'flutter': true, 'late': 1}, 'flutter', '/app/');
      expect(history.state, {'origin': true, 'state': null}); // untouched while held
      await paintAndSettle();
      expect(statesOf(history), [{'origin': true, 'state': null}, {'flutter': true, 'late': 1}]);
    });

    test('later pushes (after the release) run immediately', () async {
      engineStartup(strategy);
      await paintAndSettle();
      history.calls.clear();
      strategy.pushState({'flutter': true, 'second': true}, 'flutter', '/app/');
      expect(history.calls, ['push']);
      expect(history.entries.length, 3);
      strategy.replaceState({'flutter': true, 'second': false}, 'flutter', '/app/');
      expect(history.calls, ['push', 'replace']);
    });

    test('a second push made while the first is still held queues behind it', () async {
      engineStartup(strategy);
      strategy.pushState({'flutter': true, 'second': true}, 'flutter', '/app/');
      expect(history.entries.length, 1);
      await paintAndSettle();
      expect(statesOf(history), [{'origin': true, 'state': null}, {'flutter': true}, {'flutter': true, 'second': true}]);
    });

    test('go() releases what is held first, so the real history has the flutter entry when it moves', () async {
      engineStartup(strategy);
      final moved = strategy.go(-1);
      await moved;
      expect(history.calls.sublist(3), ['push', 'replace', 'go(-1)']);
      expect(history.index, 0);
      expect(phases, ['held', 'released']);
    });

    test('a popstate reaching the engine releases what is held first', () async {
      Object? seen;
      strategy.addPopStateListener((state) {
        seen = state;
        expect(history.entries.length, 2); // the held push is already in the history when the engine hears about it
      });
      engineStartup(strategy);
      for (final listener in List.of(history.listeners)) {
        listener({'origin': true, 'state': null});
      }
      expect(seen, {'origin': true, 'state': null});
      expect(phases, ['held', 'released']);
    });

    test('the swipe-back path is unchanged: popstate(origin) -> immediate re-push -> [origin, flutter]', () async {
      engineStartup(strategy);
      await paintAndSettle();
      strategy.addPopStateListener((state) => enginePopStateRepush(strategy, state));
      history.calls.clear();
      await strategy.go(-1); // the browser goes back to the origin entry
      expect(history.calls, ['go(-1)', 'push']);
      expect(statesOf(history), [{'origin': true, 'state': null}, {'flutter': true}]);
      expect(history.index, 1);
      expect(history.state, {'flutter': true});
    });

    test('the read-only calls pass through', () {
      history.entries[0] = HistoryEntry({'x': 1}, '/app/#/route');
      expect(strategy.getState(), {'x': 1});
      expect(strategy.getPath(), '/app/#/route');
      expect(strategy.prepareExternalUrl('/a'), '/a');
    });

    test('an error from the first-paint signal releases anyway', () async {
      final failing = FirstPaintUrlStrategy(history, firstPaint: () async => throw StateError('no frame'));
      engineStartup(failing);
      await Future<void>.delayed(Duration.zero);
      expect(history.state, {'flutter': true});
    });

    test('safety net: the history is released even if the first paint never arrives', () async {
      final stuck = FirstPaintUrlStrategy(history, firstPaint: () => Completer<void>().future, safetyTimeout: const Duration(milliseconds: 30));
      engineStartup(stuck);
      expect(history.entries.length, 1);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(statesOf(history), [{'origin': true, 'state': null}, {'flutter': true}]);
    });

    test('release is idempotent and a late signal does nothing more', () async {
      engineStartup(strategy);
      strategy.release();
      strategy.release();
      await paintAndSettle();
      expect(history.calls, ['replace', 'replace', 'replace', 'push', 'replace']);
      expect(phases, ['held', 'released']);
    });

    test('the pop-state subscription can be cancelled', () {
      final cancel = strategy.addPopStateListener((_) {});
      expect(history.listeners.length, 1);
      cancel();
      expect(history.listeners, isEmpty);
    });

    test('a page reload that lands on the flutter entry makes no push, so nothing is held', () {
      history.entries[0] = HistoryEntry({'flutter': true}, '/app/');
      strategy.replaceState({'flutter': true}, 'flutter', '/app/'); // only a replace, like a Navigator announcement
      expect(history.calls, ['replace']);
      expect(phases, isEmpty);
      expect(signalRequested, 0);
    });
  });
}
