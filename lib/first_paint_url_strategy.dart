import 'dart:async';
import 'dart:ui' show VoidCallback;

import 'package:flutter_web_plugins/url_strategy.dart';

// iPhone/iPad WebKit (Safari, the home-screen web app and every other iOS browser) swipe-back fix.
//
// Flutter Web's SingleEntryBrowserHistory creates its "origin" and "flutter" history entries while the widget tree
// is first mounted, i.e. BEFORE the first frame is drawn. WebKit stores a snapshot of the page for the entry that
// is left behind when a new entry is pushed, so the origin entry ends up with a snapshot of the still-blank page.
// On iOS, an edge swipe back to that entry combined with the engine's immediate re-push inside popstate then shows
// that blank snapshot for about 3 seconds (real-device test: pushing the flutter entry only after the first paint
// makes the swipe instant).
//
// This UrlStrategy wrapper keeps everything else the engine does and only holds back the very first pushState (and
// any history write that follows it) until the first frame is on screen, then replays them in the original order.

/// True for iPhone/iPad WebKit, including iPadOS in "desktop site" mode (Macintosh user agent with a touch screen).
bool isIosWebKit({required String userAgent, required String platform, required int maxTouchPoints}) {
  if (RegExp('iPhone|iPad|iPod').hasMatch(userAgent)) return true;
  return (platform == 'MacIntel' || userAgent.contains('Macintosh')) && maxTouchPoints > 1;
}

/// Completes once the first frame is really on screen.
typedef FirstPaintSignal = Future<void> Function();

/// Returns [inner] untouched unless [enabled]; then a [FirstPaintUrlStrategy] around it.
UrlStrategy wrapUrlStrategyForFirstPaint(
  UrlStrategy inner, {
  required bool enabled,
  required FirstPaintSignal firstPaint,
  void Function(String phase)? onPhase,
}) => enabled ? FirstPaintUrlStrategy(inner, firstPaint: firstPaint, onPhase: onPhase) : inner;

enum _Phase { waitingForFirstPush, holding, released }

class _HeldWrite {
  const _HeldWrite(this.push, this.state, this.title, this.url);
  final bool push;
  final Object? state;
  final String title, url;
}

/// A [UrlStrategy] that behaves exactly like [inner], except that the first `pushState` is held until [firstPaint]
/// completes. While it is held, later `pushState`/`replaceState` calls are queued behind it (so the engine's
/// "replace the flutter entry with the route name" keeps hitting the flutter entry, not the origin entry). Then the
/// queue is replayed in order and the strategy turns into a plain pass-through.
///
/// `replaceState` calls made before the first push (the engine's origin marker) pass straight through. Anything that
/// needs the real history (`go`, or a `popstate` delivered to the engine) first releases what is held.
class FirstPaintUrlStrategy implements UrlStrategy {
  FirstPaintUrlStrategy(
    this._inner, {
    required this.firstPaint,
    this.safetyTimeout = const Duration(seconds: 10),
    this.onPhase,
  });

  final UrlStrategy _inner;
  final FirstPaintSignal firstPaint;

  /// Last-resort release so history can never stay unset if the first-paint signal never arrives. Not the normal path.
  final Duration safetyTimeout;

  /// Reports 'held' when the first push is held and 'released' when it has been replayed.
  final void Function(String phase)? onPhase;

  final List<_HeldWrite> _held = <_HeldWrite>[];
  _Phase _phase = _Phase.waitingForFirstPush;
  Timer? _safetyTimer;

  @override
  void pushState(Object? state, String title, String url) {
    switch (_phase) {
      case _Phase.waitingForFirstPush:
        _phase = _Phase.holding;
        _held.add(_HeldWrite(true, state, title, url));
        onPhase?.call('held');
        _safetyTimer = Timer(safetyTimeout, release);
        Future<void>.sync(firstPaint).then((_) => release(), onError: (Object _) => release());
      case _Phase.holding:
        _held.add(_HeldWrite(true, state, title, url));
      case _Phase.released:
        _inner.pushState(state, title, url);
    }
  }

  @override
  void replaceState(Object? state, String title, String url) {
    if (_phase == _Phase.holding) {
      _held.add(_HeldWrite(false, state, title, url));
    } else {
      _inner.replaceState(state, title, url);
    }
  }

  /// Replays the held writes in their original order. Safe to call any time; only the first call after holding acts.
  void release() {
    if (_phase != _Phase.holding) return;
    _phase = _Phase.released;
    _safetyTimer?.cancel();
    _safetyTimer = null;
    final writes = List<_HeldWrite>.of(_held);
    _held.clear();
    for (final write in writes) {
      if (write.push) {
        _inner.pushState(write.state, write.title, write.url);
      } else {
        _inner.replaceState(write.state, write.title, write.url);
      }
    }
    onPhase?.call('released');
  }

  @override
  Future<void> go(int count) {
    release();
    return _inner.go(count);
  }

  @override
  VoidCallback addPopStateListener(void Function(Object? state) fn) => _inner.addPopStateListener((Object? state) {
    release();
    fn(state);
  });

  @override
  String getPath() => _inner.getPath();

  @override
  Object? getState() => _inner.getState();

  @override
  String prepareExternalUrl(String internalUrl) => _inner.prepareExternalUrl(internalUrl);
}
