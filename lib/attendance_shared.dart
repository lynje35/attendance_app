// Shared between the calendar/attendance screen (lib/main.dart) and the calculator
// (lib/calculator_page.dart): both need the same "no data before this month" floor
// and the same "H시간 M분" worked-time text parser.

/// No attendance data exists before this month: month navigation never offers an
/// earlier one, in either the calendar or the calculator.
final DateTime earliestWorkMonth = DateTime(2026, 8, 1);

/// Parses a "H시간 M분" worked-time string (as returned by the calendar API) into
/// minutes. Missing/empty/unparsable parts default to 0; negative totals clamp to 0.
int workedTextToMinutes(String text) {
  final hourMatch = RegExp(r'(-?\d+)\s*시간').firstMatch(text);
  final minuteMatch = RegExp(r'(-?\d+)\s*분').firstMatch(text);
  final hours = int.tryParse(hourMatch?.group(1) ?? '0') ?? 0;
  final minutes = int.tryParse(minuteMatch?.group(1) ?? '0') ?? 0;
  final total = hours * 60 + minutes;
  return total < 0 ? 0 : total;
}
