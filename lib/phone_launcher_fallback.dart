import 'package:url_launcher/url_launcher.dart';

Future<bool> openTelLink(String phone) async {
  try {
    return await launchUrl(Uri(scheme: 'tel', path: phone));
  } catch (_) {
    return false;
  }
}
