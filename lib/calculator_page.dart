import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'phone_launcher.dart';

const String _inquiryPhone = '01097465633';

int workedTextToMinutes(String text) {
  final hourMatch = RegExp(r'(-?\d+)\s*시간').firstMatch(text);
  final minuteMatch = RegExp(r'(-?\d+)\s*분').firstMatch(text);
  final hours = int.tryParse(hourMatch?.group(1) ?? '0') ?? 0;
  final minutes = int.tryParse(minuteMatch?.group(1) ?? '0') ?? 0;
  final total = hours * 60 + minutes;
  return total < 0 ? 0 : total;
}

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
    required this.loadCurrentMonthCalendar,
    required this.readSavedWage,
    required this.saveWage,
  });

  final Future<Map<String, dynamic>> Function() loadCurrentMonthCalendar;
  final Future<String?> Function() readSavedWage;
  final Future<void> Function(String) saveWage;

  @override
  State<CalculatorPage> createState() => _CalculatorPageState();
}

class _CalculatorPageState extends State<CalculatorPage> {
  final _wageController = TextEditingController();
  int _totalMinutes = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
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
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final data = await widget.loadCurrentMonthCalendar();
      if (!mounted) return;

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
      if (!mounted) return;
      setState(() {
        _error = '근무기록을 불러오는 중 오류가 발생했습니다.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
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
    final totalHours = _totalMinutes / 60.0;
    final gross = wage * totalHours;
    final deduction = gross * 0.033;
    final net = (gross - deduction).round();
    final displayNet = net < 0 ? 0 : net;
    final hours = _totalMinutes ~/ 60;
    final minutes = _totalMinutes % 60;

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
                          if (_loading)
                            const Center(child: CircularProgressIndicator())
                          else if (_error != null)
                            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))
                          else
                            Text('현재 총 근무 시간: $hours시간${minutes == 0 ? '' : ' $minutes분'}'),
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
                          Text('${formatWon(displayNet)}원', style: Theme.of(context).textTheme.headlineMedium),
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
