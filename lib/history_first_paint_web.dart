import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:web/web.dart' as web;

import 'first_paint_url_strategy.dart';

// Call once from main(), before runApp. On iPhone/iPad WebKit only, it wraps the browser URL strategy so the first
// history push waits for the first frame (see first_paint_url_strategy.dart). Everywhere else it changes nothing.
void installHistoryFirstPaint() {
  final inner = urlStrategy;
  if (inner == null) return;
  final navigator = web.window.navigator;
  final wrapped = wrapUrlStrategyForFirstPaint(
    inner,
    enabled: isIosWebKit(userAgent: navigator.userAgent, platform: navigator.platform, maxTouchPoints: navigator.maxTouchPoints),
    firstPaint: _firstPaintOnScreen,
    // Visible in Safari Web Inspector (Elements > <html>): data-history-first-paint = held | released.
    onPhase: (phase) => web.document.documentElement?.setAttribute('data-history-first-paint', phase),
  );
  // Not iOS: nothing is wrapped and the engine's own default URL strategy stays exactly as it is.
  if (!identical(wrapped, inner)) setUrlStrategy(wrapped);
}

// The first frame has been drawn (endOfFrame: after the first frame's post-frame callbacks, i.e. what the engine's
// "flutter-first-frame" is sent for) and the browser has then had two animation frames to present it. Not
// waitUntilFirstFrameRasterized: on web it is only reported for regular vsync frames, so an idle app never gets it.
Future<void> _firstPaintOnScreen() async {
  await WidgetsBinding.instance.endOfFrame;
  await _nextAnimationFrame();
  await _nextAnimationFrame();
}

Future<void> _nextAnimationFrame() {
  final frame = Completer<void>();
  web.window.requestAnimationFrame(((JSNumber _) => frame.complete()).toJS);
  return frame.future;
}
