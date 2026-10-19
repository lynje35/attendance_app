import 'dart:convert';

// The calculator settings of the organization as its administrator set them (action `calculatorNotice`): the notes under
// 예상 실 지급액 (general text, red warning, contact phone) and how the pay is deducted. The deduction is a mode plus a rate in
// whole basis points (1% = 100) - never a float - and it, not any note text, drives both the calculation and the sentence
// "자동으로 N% 계산이 돼요." in calculator_page.dart.

// The only organization signal this app has is the API address it was built with (--dart-define=EMPLOYEE_API_URL, read in
// main()). The kb_main PWA and the kb_main APK both use this host; every other build (shop2, the local preview, tests)
// uses another one. The built-in wording below belongs to kb_main ALONE, so it is shown only for a build that is positively
// identified as kb_main - an unknown build errs towards showing nothing, never towards showing kb_main's text.
const String kbEmployeeApiHost = 'attendance-employee-api.lynje.workers.dev';

const String deductionNone = 'none', deductionFreelance = 'freelance_3_3', deductionCustom = 'custom';
const int freelanceRateBp = 330, maxRateBp = 10000;

// Is this a deduction the app understands? Anything else (an unknown mode, a rate that does not belong to its mode, a float)
// means the answer cannot be trusted and is not used.
bool validDeduction(Object? mode, Object? rateBp) {
  if (rateBp is! int) return false;
  return switch (mode) {
    deductionNone => rateBp == 0,
    deductionFreelance => rateBp == freelanceRateBp,
    deductionCustom => rateBp >= 0 && rateBp <= maxRateBp,
    _ => false,
  };
}

// 330 -> "3.3", 500 -> "5", 270 -> "2.7", 275 -> "2.75": no trailing zeros, no float arithmetic.
String formatRatePercent(int rateBp) {
  final whole = rateBp ~/ 100, fraction = rateBp % 100;
  if (fraction == 0) return '$whole';
  return '$whole.${fraction.toString().padLeft(2, '0').replaceFirst(RegExp(r'0$'), '')}';
}

class CalculatorNotice {
  const CalculatorNotice({
    required this.configured,
    this.infoText = '',
    this.warningText = '',
    this.contactPhone = '',
    this.updatedAt,
    this.deductionMode,
    this.deductionRateBp,
  });

  // True only for what the server actually has stored for the organization. The built-in values below are "not configured".
  final bool configured;
  final String infoText, warningText, contactPhone;
  final int? updatedAt;
  // null / null = the administrator has not chosen a deduction (no stored settings, or settings saved before the option
  // existed): effective() then uses this build's long-standing default, so that case never changes anyone's calculation.
  final String? deductionMode;
  final int? deductionRateBp;

  // What the kb_main calculator has always shown. Lines of infoText are separated by '\n'.
  static const CalculatorNotice kbBuiltIn = CalculatorNotice(
    configured: false,
    infoText: '월급은 매월 10일에 지급돼요\n(주말이나 공휴일 껴있는 경우 10일 전후 2일 정도 차이 날 수 있어요.)',
    warningText: '본인 외 다른 직원에게 보여주지 마세요',
    contactPhone: '01097465633',
    deductionMode: deductionFreelance,
    deductionRateBp: freelanceRateBp,
  );

  // No notes, and no deduction: another organization is never given kb_main's 3.3%.
  static const CalculatorNotice hidden = CalculatorNotice(configured: false, deductionMode: deductionNone, deductionRateBp: 0);

  // The wording shown while the organization has no stored settings (or before the server has answered).
  static CalculatorNotice builtInFor(Uri? endpoint) => endpoint?.host == kbEmployeeApiHost ? kbBuiltIn : hidden;

  // What the screen shows for this value: the organization's own settings, or - when it has none - the built-in for this build.
  // Stored notes with no deduction chosen keep their notes and take only the deduction of this build's built-in.
  CalculatorNotice effective(Uri? endpoint) {
    final builtIn = builtInFor(endpoint);
    if (!configured) return builtIn;
    if (deductionMode != null) return this;
    return CalculatorNotice(
      configured: true, infoText: infoText, warningText: warningText, contactPhone: contactPhone, updatedAt: updatedAt,
      deductionMode: builtIn.deductionMode, deductionRateBp: builtIn.deductionRateBp,
    );
  }

  // Reads a calculatorNotice answer. Anything that is not a well-formed answer gives null, and the caller keeps what it has.
  static CalculatorNotice? fromResponse(Map<String, dynamic> data) {
    if (data['success'] != true) return null;
    final configured = data['configured'];
    if (configured == false) return const CalculatorNotice(configured: false);
    if (configured != true) return null;
    final info = data['infoText'], warning = data['warningText'], phone = data['contactPhone'], updated = data['updatedAt'];
    if (info is! String || warning is! String || phone is! String) return null;
    // Both absent / null = not chosen (also what a server without this option sends). Otherwise they must fit each other.
    final mode = data['deductionMode'], rate = data['deductionRateBp'];
    final chosen = mode != null || rate != null;
    if (chosen && !validDeduction(mode, rate)) return null;
    return CalculatorNotice(
      configured: true, infoText: info, warningText: warning, contactPhone: phone, updatedAt: updated is num ? updated.toInt() : null,
      deductionMode: chosen ? mode as String : null, deductionRateBp: chosen ? rate as int : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'configured': configured,
        'infoText': infoText,
        'warningText': warningText,
        'contactPhone': contactPhone,
        'updatedAt': updatedAt,
        'deductionMode': deductionMode,
        'deductionRateBp': deductionRateBp,
      };

  @override
  bool operator ==(Object other) =>
      other is CalculatorNotice && other.configured == configured && other.infoText == infoText && other.warningText == warningText &&
      other.contactPhone == contactPhone && other.updatedAt == updatedAt && other.deductionMode == deductionMode && other.deductionRateBp == deductionRateBp;

  @override
  int get hashCode => Object.hash(configured, infoText, warningText, contactPhone, updatedAt, deductionMode, deductionRateBp);
}

// One cache entry per API host: an app installation talks to one organization's API, and a different host (another
// organization's build served from the same place, a local preview) never reads this entry.
String calculatorNoticeCacheKey(Uri endpoint) => 'calculator_notice_cache_v1_${endpoint.host}';

String encodeCalculatorNoticeCache(Uri endpoint, CalculatorNotice notice) => jsonEncode({'host': endpoint.host, ...notice.toJson()});

// A stored entry is used only if it is well-formed and was written for this very host; anything else is ignored.
CalculatorNotice? decodeCalculatorNoticeCache(Uri endpoint, String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded['host'] != endpoint.host) return null;
    return CalculatorNotice.fromResponse({...Map<String, dynamic>.from(decoded), 'success': true});
  } catch (_) {
    return null;
  }
}
