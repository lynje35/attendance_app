import 'package:web/web.dart' as web;

// Called synchronously (no await before the navigation call) from the call
// icon's onPressed, so the browser still treats this as a direct result of
// the user's tap rather than a script-initiated redirect it may block.
Future<bool> openTelLink(String phone) async {
  web.window.location.assign('tel:$phone');
  return true;
}
