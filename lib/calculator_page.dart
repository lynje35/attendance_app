import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'attendance_shared.dart';
import 'phone_launcher.dart';

export 'attendance_shared.dart' show earliestWorkMonth, workedTextToMinutes;

const String _inquiryPhone = '01097465633';

String formatWon(int value) {
  final text = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (i > 0 && (text.length - i) % 3 == 0) buffer.write(',');
    buffer.write(text[i]);
  }
  return buffer.toString();
}

class CalculatorPage extends StatefulWidget {
  const CalculatorPage({
    super.key,
    required this.loadMonthCalendar,
    required this.initialMonth,
    required this.now,
    required this.readSavedWage,
    required this.saveWage,
  });

  // Same API the 근무기록 calendar already uses (action: 'calendar'): no new endpoint.
  final Future<Map<String, dynamic>> Function(int year, int month) loadMonthCalendar;
  // Reuses whatever month the 근무기록 screen is currently showing (see lib/main.dart
  // _openCalculator, which passes its own calendarMonth); that value already defaults
  // to the current KST month, so this page never needs to compute "today" itself.
  final DateTime initialMonth;
  // Server-corrected clock (_serverNow() in lib/main.dart), used only to cap month
  // selection at the current month, same as the calendar's own bound.
  final DateTime now;
  final Future<String?> Function() readSavedWage;
  final Future<void> Function(String) saveWage;

  @override
  State<CalculatorPage> createState() => _CalculatorPageState();
}

class _CalculatorPageState extends State<CalculatorPage> {
  final _wageController = TextEditingController();
  late DateTime _month;
  int _totalMinutes = 0;
  bool _loading = true;
  String? _error;
  int _loadId = 0;

  DateTime get _maxMonth => DateTime(widget.now.year, widget.now.month, 1);

  @override
  void initState() {
    super.initState();
    _month = DateTime(widget.initialMonth.year, widget.initialMonth.month, 1);
    unawaited(_init());
  }

  Future<void> _init() async {
    final saved = await widget.readSavedWage();
    if (mounted && saved != null && saved.isNotEmpty) {
      _wageController.text = saved;
    }
    await _loadTotal();
  }

  Future<void> _loadTotal() async {
    final id = ++_loadId;
    final month = _month;

    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final data = await widget.loadMonthCalendar(month.year, month.month);
      if (!mounted || id != _loadId) return;

      if (data['success'] != true) {
        setState(() {
          _error = data['message']?.toString() ?? '근무기록을 불러오지 못했습니다.';
        });
        return;
      }

      var minutes = 0;
      final records = data['records'];
      if (records is List) {
        for (final item in records) {
          if (item is Map) {
            minutes += workedTextToMinutes(item['workedText']?.toString() ?? '');
          }
        }
      }

      setState(() {
        _totalMinutes = minutes;
      });
    } catch (_) {
      if (!mounted || id != _loadId) return;
      setState(() {
        _error = '근무기록을 불러오는 중 오류가 발생했습니다.';
      });
    } finally {
      if (mounted && id == _loadId) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _changeMonth(DateTime next) {
    if (next.isBefore(earliestWorkMonth) || next.isAfter(_maxMonth)) return;
    if (next.year == _month.year && next.month == _month.month) return;

    setState(() {
      _month = next;
    });
    unawaited(_loadTotal());
  }

  Future<void> _pickMonth() async {
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (_) => _MonthPickerDialog(month: _month, minMonth: earliestWorkMonth, maxMonth: _maxMonth),
    );
    if (picked != null) _changeMonth(picked);
  }

  void _onWageChanged(String text) {
    setState(() {});
    unawaited(widget.saveWage(text.trim()));
  }

  Future<void> _call() async {
    final launched = await openTelLink(_inquiryPhone);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('전화 앱을 열지 못했어요.')),
      );
    }
  }

  @override
  void dispose() {
    _wageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wage = int.tryParse(_wageController.text.trim()) ?? 0;
    // While a newly selected month is still loading, the previous month's total is
    // deliberately not shown as if it belonged to the new month (see spec item 6):
    // both derived numbers below fall back to 0 until this load finishes.
    final knownMinutes = _loading || _error != null ? 0 : _totalMinutes;
    final totalHours = knownMinutes / 60.0;
    final gross = wage * totalHours;
    final deduction = gross * 0.033;
    final net = (gross - deduction).round();
    final displayNet = net < 0 ? 0 : net;
    final hours = _totalMinutes ~/ 60;
    final minutes = _totalMinutes % 60;

    Widget monthButton() => InkWell(
      onTap: _pickMonth,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('${_month.year}년 ${_month.month}월', style: const TextStyle(fontWeight: FontWeight.w700)),
          const Icon(Icons.arrow_drop_down, size: 20),
        ]),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('계산기')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('시급을 입력해주세요', style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _wageController,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                  onChanged: _onWageChanged,
                                  decoration: const InputDecoration(
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Text('원'),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: _loading
                                    ? const SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : _error != null
                                        ? Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
                                        : Text('현재 총 근무 시간: $hours시간${minutes == 0 ? '' : ' $minutes분'}'),
                              ),
                              const SizedBox(width: 8),
                              monthButton(),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('예상 실 지급액:', style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          _loading
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Text('${formatWon(displayNet)}원', style: Theme.of(context).textTheme.headlineMedium),
                          const Divider(height: 32),
                          const Text('자동으로 3.3% 계산이 돼요.'),
                          const Text('월급은 매월 10일에 지급돼요'),
                          const Text('(주말이나 공휴일 껴있는 경우 10일 전후 2일 정도 차이 날 수 있어요.)'),
                          const SizedBox(height: 12),
                          const Text(
                            '본인 외 다른 직원에게 보여주지 마세요',
                            style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  '문의: $_inquiryPhone',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              IconButton(
                                onPressed: _call,
                                icon: const Icon(Icons.call),
                                tooltip: '전화 걸기',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Year chevrons + a month grid, same interaction style as the 근무기록 calendar's
// month navigation (chevron_left/right), but lets the admin jump straight to any
// month in one tap instead of stepping one month at a time.
class _MonthPickerDialog extends StatefulWidget {
  const _MonthPickerDialog({required this.month, required this.minMonth, required this.maxMonth});
  final DateTime month, minMonth, maxMonth;

  @override
  State<_MonthPickerDialog> createState() => _MonthPickerDialogState();
}

class _MonthPickerDialogState extends State<_MonthPickerDialog> {
  late int _year = widget.month.year;

  bool _monthAllowed(int month) {
    final picked = DateTime(_year, month, 1);
    return !picked.isBefore(widget.minMonth) && !picked.isAfter(widget.maxMonth);
  }

  @override
  Widget build(BuildContext context) {
    final canGoPrevYear = !DateTime(_year - 1, 12, 1).isBefore(widget.minMonth);
    final canGoNextYear = !DateTime(_year + 1, 1, 1).isAfter(widget.maxMonth);
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(
              tooltip: '이전 해',
              onPressed: canGoPrevYear ? () => setState(() => _year--) : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Text('$_year년', style: Theme.of(context).textTheme.titleLarge),
            IconButton(
              tooltip: '다음 해',
              onPressed: canGoNextYear ? () => setState(() => _year++) : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ]),
          const SizedBox(height: 8),
          // A fixed 3x4 grid (not Wrap+ChoiceChip): every cell is exactly the same size
          // regardless of label width (1월 vs 12월) or selected state, so columns/rows
          // never drift and the check mark never pushes the month text off-centre.
          // Built from plain Row/Expanded rather than GridView: a scrolling GridView
          // can't report an intrinsic width, which AlertDialog's content area needs.
          for (var row = 0; row < 4; row++) ...[
            if (row > 0) const SizedBox(height: 8),
            Row(children: [
              for (var col = 0; col < 3; col++) ...[
                if (col > 0) const SizedBox(width: 8),
                Expanded(child: AspectRatio(aspectRatio: 1.8, child: _monthCell(context, row * 3 + col + 1))),
              ],
            ]),
          ],
          const SizedBox(height: 12),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('취소'))],
    );
  }

  Widget _monthCell(BuildContext context, int month) {
    final theme = Theme.of(context);
    final selected = _year == widget.month.year && month == widget.month.month;
    final allowed = _monthAllowed(month);
    final borderColor = !allowed
        ? theme.colorScheme.outlineVariant
        : selected
            ? theme.colorScheme.primary
            : theme.colorScheme.outline;

    return Material(
      color: selected ? theme.colorScheme.primaryContainer : Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: borderColor)),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: allowed ? () => Navigator.of(context).pop(DateTime(_year, month)) : null,
        // SizedBox.expand forces this Stack to fill the whole (fixed-size) grid cell, so
        // the centered text and the corner-pinned check mark are both relative to the
        // same, constant-size box — never to each other.
        child: SizedBox.expand(
          child: Stack(alignment: Alignment.center, children: [
            Text(
              '$month월',
              style: TextStyle(
                fontWeight: selected ? FontWeight.w700 : FontWeight.normal,
                color: !allowed ? theme.disabledColor : selected ? theme.colorScheme.onPrimaryContainer : null,
              ),
            ),
            if (selected)
              Positioned(
                right: 6,
                child: Icon(Icons.check, size: 16, color: theme.colorScheme.onPrimaryContainer),
              ),
          ]),
        ),
      ),
    );
  }
}
